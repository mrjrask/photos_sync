#!/bin/bash
# Incrementally exports every photo/video in the Photos library to a folder
# on this Mac's own disk, organized into one folder per capture day
# (YYYY-MM-DD). This is the local-disk counterpart of sync_photos.sh, for
# when you want a backup on this Mac itself instead of (or in addition to)
# the cm5 NAS share -- e.g. no NAS available, or you just want a second copy.
#
# Why per-day and not per-"Moment/Event": see sync_photos.sh -- same
# reasoning applies here (osxphotos doesn't expose a stable Moments/Events
# ID, and per-day folders based on the fixed capture date are required for
# --update to work correctly across runs).
set -euo pipefail

# Destination folder is configurable -- install_local.sh prompts for it and
# saves the choice to CONFIG_FILE as DEST_ROOT_LOCAL. Falls back to the
# original default if unset (e.g. an older config, or the script run
# standalone). PHOTOS_LOCAL_DEST always wins when set, for one-off
# overrides without touching the saved config.
CONFIG_FILE="$HOME/Library/Application Support/photos-sync/config"
if [ -f "$CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi
DEST_ROOT="${PHOTOS_LOCAL_DEST:-${DEST_ROOT_LOCAL:-$HOME/Pictures/PhotosBackup}}"

LOG_FILE="$HOME/Library/Logs/photos-local-sync.log"
LOG_TAG="[photos-local-sync]"

# The --update export database. Unlike the NAS variant, DEST_ROOT here is
# already local disk, so there's no SMB locking concern -- but it's still
# kept outside DEST_ROOT (in Application Support) so it survives even if you
# ever move or reorganize the export folder itself.
EXPORT_DB_DIR="$HOME/Library/Application Support/photos-local-sync"
EXPORT_DB="$EXPORT_DB_DIR/export.db"
BATCH_CURSOR="$EXPORT_DB_DIR/batch-cursor"
BATCH_START="${PHOTOS_BATCH_START:-2005-08}"
BATCH_PAUSE_SECONDS="${PHOTOS_BATCH_PAUSE_SECONDS:-5}"

mkdir -p "$(dirname "$LOG_FILE")"

# Local lock so a launchd-triggered run and a manual run can never overlap.
LOCK_DIR="/tmp/photos-local-sync.lock"
LOCK_PID_FILE="$LOCK_DIR/pid"

acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo $$ > "$LOCK_PID_FILE"
    return 0
  fi
  local existing_pid
  existing_pid="$(cat "$LOCK_PID_FILE" 2>/dev/null || true)"
  if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then
    return 1
  fi
  echo "$(date '+%Y-%m-%d %H:%M:%S') $LOG_TAG Removing stale lock at $LOCK_DIR (owner pid ${existing_pid:-unknown} not running)." >> "$LOG_FILE"
  rm -rf "$LOCK_DIR"
  mkdir "$LOCK_DIR" 2>/dev/null || return 1
  echo $$ > "$LOCK_PID_FILE"
}

if ! acquire_lock; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') $LOG_TAG Another sync is already running (lock held at $LOCK_DIR). Exiting." >> "$LOG_FILE"
  exit 0
fi
trap 'rm -rf "$LOCK_DIR" 2>/dev/null' EXIT

# Rotate the log before this run if it's grown large -- --verbose on a
# library this size produces a lot of output, and nothing else trims it.
LOG_MAX_BYTES=$((100 * 1024 * 1024))
if [ -f "$LOG_FILE" ] && [ "$(stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)" -gt "$LOG_MAX_BYTES" ]; then
  mv -f "$LOG_FILE" "$LOG_FILE.1"
fi

exec >> "$LOG_FILE" 2>&1

echo "===== $(date '+%Y-%m-%d %H:%M:%S') $LOG_TAG run start ====="

if ! mkdir -p "$DEST_ROOT"; then
  echo "$LOG_TAG ERROR: could not create $DEST_ROOT."
  exit 1
fi

mkdir -p "$EXPORT_DB_DIR"

echo "$LOG_TAG Destination free space: $(df -h "$DEST_ROOT" | awk 'NR==2{print $4}')"

# Locate the osxphotos binary (handles pipx / brew / pip --user installs).
OSXPHOTOS_BIN="$(command -v osxphotos || true)"
if [ -z "$OSXPHOTOS_BIN" ]; then
  for candidate in "$HOME/.local/bin/osxphotos" "/opt/homebrew/bin/osxphotos" "/usr/local/bin/osxphotos"; do
    if [ -x "$candidate" ]; then
      OSXPHOTOS_BIN="$candidate"
      break
    fi
  done
fi

if [ -z "$OSXPHOTOS_BIN" ]; then
  echo "$LOG_TAG ERROR: osxphotos not found on this Mac. Run install_local.sh first."
  exit 1
fi

echo "$LOG_TAG Using osxphotos at $OSXPHOTOS_BIN"

# exiftool is required by --exiftool below (osxphotos shells out to it) to
# write Photos' own metadata -- GPS location, title, caption, keywords,
# person names -- into each exported file's EXIF/IPTC/XMP tags. See
# sync_photos.sh for the full explanation.
if ! command -v exiftool >/dev/null 2>&1; then
  echo "$LOG_TAG ERROR: exiftool not found on this Mac. Run install_local.sh first (or 'brew install exiftool')."
  exit 1
fi

# Incremental, full-resolution export -- see sync_photos.sh for a full
# explanation of each flag. The only structural difference from that script
# is DEST_ROOT being a local folder, so there's no NAS mount step and no
# run-level retry loop for a dropped network share.
PHOTOS_LIBRARY="$HOME/Pictures/Photos Library.photoslibrary"
if [ ! -d "$PHOTOS_LIBRARY" ]; then
  echo "$LOG_TAG ERROR: Photos library not found at $PHOTOS_LIBRARY."
  echo "$LOG_TAG If your library lives elsewhere, update PHOTOS_LIBRARY in this script."
  exit 1
fi

# Wrapped in caffeinate so macOS doesn't idle/system-sleep mid-export -- this
# run can take hours (or longer) on an initial large library. Also wrapped
# in `taskpolicy -b` so osxphotos and the exiftool process it shells out to
# run under macOS's background scheduling class, so a large export doesn't
# make the machine feel sluggish while you're using it. See sync_photos.sh
# for the full explanation of both.
run_export() {
  local from_date="$1" to_date="$2"
  local cmd=(
    "$OSXPHOTOS_BIN" export "$DEST_ROOT"
    --library "$PHOTOS_LIBRARY"
    --update
    --exportdb "$EXPORT_DB"
    --from-date "$from_date"
    --to-date "$to_date"
    --download-missing
    --directory "{created.date}"
    --retry 3
    --touch-file
    --exiftool
    --verbose
  )
  if command -v taskpolicy >/dev/null 2>&1; then
    cmd=(taskpolicy -b "${cmd[@]}")
  fi
  if command -v caffeinate >/dev/null 2>&1; then
    caffeinate -i -s -m "${cmd[@]}"
  else
    "${cmd[@]}"
  fi
}

if ! [[ "$BATCH_START" =~ ^[0-9]{4}-(0[1-9]|1[0-2])$ ]]; then
  echo "$LOG_TAG ERROR: PHOTOS_BATCH_START must use YYYY-MM format (got: $BATCH_START)."
  exit 1
fi
if ! [[ "$BATCH_PAUSE_SECONDS" =~ ^[0-9]+$ ]]; then
  echo "$LOG_TAG ERROR: PHOTOS_BATCH_PAUSE_SECONDS must be a non-negative integer (got: $BATCH_PAUSE_SECONDS)."
  exit 1
fi

next_month() {
  date -j -f "%Y-%m-%d" "$1-01" -v+1m "+%Y-%m"
}

month_end() {
  date -j -f "%Y-%m-%d" "$1-01" -v+1m -v-1d "+%Y-%m-%d"
}

# Run each calendar month in a new osxphotos process. This bounds the amount
# of work and transient memory retained by any one process. The cursor is
# advanced atomically only after a successful month, so an interruption
# resumes that month on the next launch. Once a complete pass reaches the
# month that was current at run start, reset the cursor for the next run;
# this allows --update to discover edits or newly imported older photos.
run_end_month="$(date '+%Y-%m')"
if [[ "$BATCH_START" > "$run_end_month" ]]; then
  echo "$LOG_TAG ERROR: PHOTOS_BATCH_START ($BATCH_START) cannot be later than the current month ($run_end_month)."
  exit 1
fi
batch_month="$BATCH_START"
if [ -f "$BATCH_CURSOR" ]; then
  saved_cursor="$(cat "$BATCH_CURSOR")"
  if [[ "$saved_cursor" =~ ^[0-9]{4}-(0[1-9]|1[0-2])$ ]] && [[ "$saved_cursor" > "$BATCH_START" || "$saved_cursor" == "$BATCH_START" ]]; then
    batch_month="$saved_cursor"
  else
    echo "$LOG_TAG Ignoring invalid batch cursor: $saved_cursor"
  fi
fi

while [[ "$batch_month" < "$run_end_month" || "$batch_month" == "$run_end_month" ]]; do
  from_date="$batch_month-01"
  to_date="$(month_end "$batch_month")"
  echo "$LOG_TAG Starting batch $batch_month ($from_date through $to_date)."
  set +e
  run_export "$from_date" "$to_date"
  status=$?
  set -e
  if [ "$status" -ne 0 ]; then
    echo "$LOG_TAG Batch $batch_month failed (exit $status) -- will resume this month at the next scheduled sync."
    exit "$status"
  fi
  following_month="$(next_month "$batch_month")"
  printf '%s\n' "$following_month" > "$BATCH_CURSOR.tmp"
  mv -f "$BATCH_CURSOR.tmp" "$BATCH_CURSOR"
  echo "$LOG_TAG Completed batch $batch_month; next batch is $following_month."
  batch_month="$following_month"
  if [[ "$batch_month" < "$run_end_month" || "$batch_month" == "$run_end_month" ]]; then
    sleep "$BATCH_PAUSE_SECONDS"
  fi
done

printf '%s\n' "$BATCH_START" > "$BATCH_CURSOR.tmp"
mv -f "$BATCH_CURSOR.tmp" "$BATCH_CURSOR"
echo "$LOG_TAG Completed full pass through $run_end_month; cursor reset to $BATCH_START for the next run."

echo "===== $(date '+%Y-%m-%d %H:%M:%S') $LOG_TAG run end ====="
