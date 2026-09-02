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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUPPORT_SCRIPT="$SCRIPT_DIR/sync_support.sh"
[ -f "$SUPPORT_SCRIPT" ] || SUPPORT_SCRIPT="$SCRIPT_DIR/../sync_support.sh"
if [ ! -f "$SUPPORT_SCRIPT" ]; then
  echo "Missing sync_support.sh; re-run local/install_local.sh." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$SUPPORT_SCRIPT"

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
PHOTOS_LIBRARY="${PHOTOS_LIBRARY:-$HOME/Pictures/Photos Library.photoslibrary}"

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
BATCH_SPAN_MONTHS="${PHOTOS_BATCH_SPAN_MONTHS:-12}"
BATCH_PAUSE_SECONDS="${PHOTOS_BATCH_PAUSE_SECONDS:-5}"
PHOTOS_VERBOSE="${PHOTOS_VERBOSE:-0}"

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

# Rotate the log before this run if it has grown large (for example, when
# diagnostic PHOTOS_VERBOSE=1 was enabled); nothing else trims it.
LOG_MAX_BYTES=$((100 * 1024 * 1024))
if [ -f "$LOG_FILE" ] && [ "$(stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)" -gt "$LOG_MAX_BYTES" ]; then
  mv -f "$LOG_FILE" "$LOG_FILE.1"
fi

exec >> "$LOG_FILE" 2>&1

echo "===== $(date '+%Y-%m-%d %H:%M:%S') $LOG_TAG run start ====="

# Start reporting before any destination, tool, or library preflight so failed
# runs are represented in both the health log and JSON summary.
init_sync_observability "local"
trap 'finish_sync_observability $?' EXIT

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
  local from_date="$1" to_date="${2:-}"
  local output_file status
  local cmd=(
    "$OSXPHOTOS_BIN" export "$DEST_ROOT"
    --library "$PHOTOS_LIBRARY"
    --update
    --exportdb "$EXPORT_DB"
    --download-missing
    --directory "{created.date}"
    --retry 3
    --touch-file
    --exiftool
  )
  if [ "$PHOTOS_VERBOSE" = "1" ]; then
    cmd+=(--verbose)
  fi
  if [ -n "$from_date" ]; then
    cmd+=(--from-date "$from_date")
  fi
  if [ -n "$to_date" ]; then
    cmd+=(--to-date "$to_date")
  fi
  if command -v taskpolicy >/dev/null 2>&1; then
    cmd=(taskpolicy -b "${cmd[@]}")
  fi
  output_file="$(mktemp "${TMPDIR:-/tmp}/photos-local-export.XXXXXX")"
  if command -v caffeinate >/dev/null 2>&1; then
    caffeinate -i -s -m "${cmd[@]}" 2>&1 | tee "$output_file"
    status="${PIPESTATUS[0]}"
  else
    "${cmd[@]}" 2>&1 | tee "$output_file"
    status="${PIPESTATUS[0]}"
  fi
  record_export_output "$output_file" "$status"
  rm -f "$output_file"
  return "$status"
}

if ! [[ "$BATCH_START" =~ ^[0-9]{4}-(0[1-9]|1[0-2])$ ]]; then
  echo "$LOG_TAG ERROR: PHOTOS_BATCH_START must use YYYY-MM format (got: $BATCH_START)."
  exit 1
fi
if ! [[ "$BATCH_PAUSE_SECONDS" =~ ^[0-9]+$ ]]; then
  echo "$LOG_TAG ERROR: PHOTOS_BATCH_PAUSE_SECONDS must be a non-negative integer (got: $BATCH_PAUSE_SECONDS)."
  exit 1
fi
if ! [[ "$BATCH_SPAN_MONTHS" =~ ^[1-9][0-9]*$ ]]; then
  echo "$LOG_TAG ERROR: PHOTOS_BATCH_SPAN_MONTHS must be a positive integer (got: $BATCH_SPAN_MONTHS)."
  exit 1
fi
if [ "$PHOTOS_VERBOSE" != "0" ] && [ "$PHOTOS_VERBOSE" != "1" ]; then
  echo "$LOG_TAG ERROR: PHOTOS_VERBOSE must be 0 or 1 (got: $PHOTOS_VERBOSE)."
  exit 1
fi

next_month() {
  date -j -f "%Y-%m-%d" "$1-01" -v+1m "+%Y-%m"
}

add_months() {
  date -j -f "%Y-%m-%d" "$1-01" -v+"$2"m "+%Y-%m"
}

month_end() {
  date -j -f "%Y-%m-%d" "$1-01" -v+1m -v-1d "+%Y-%m-%d"
}

previous_day() {
  date -j -f "%Y-%m-%d" "$1" -v-1d "+%Y-%m-%d"
}

# Run each bounded range in a new osxphotos process. This balances transient
# memory against the full-library setup cost paid by every new process. The
# cursor is advanced atomically only after a successful range, so an
# interruption resumes that range on the next launch. Once a complete pass
# reaches the month that was current at run start, later launches switch to a
# single open-ended update that discovers edits and newly imported old photos.
run_end_month="$(date '+%Y-%m')"
if [[ "$BATCH_START" > "$run_end_month" ]]; then
  echo "$LOG_TAG ERROR: PHOTOS_BATCH_START ($BATCH_START) cannot be later than the current month ($run_end_month)."
  exit 1
fi
batch_month="$BATCH_START"
future_from=""
full_pass_complete=false
if [ -f "$BATCH_CURSOR" ]; then
  saved_cursor="$(cat "$BATCH_CURSOR")"
  if [ "$saved_cursor" = "complete" ]; then
    full_pass_complete=true
  elif [[ "$saved_cursor" =~ ^future:([0-9]{4}-(0[1-9]|1[0-2])-01)$ ]]; then
    batch_month="future"
    future_from="${BASH_REMATCH[1]}"
  elif [ "$saved_cursor" = "future" ]; then
    # Compatibility with the original sentinel, which did not retain its
    # boundary. Starting at BATCH_START is deliberately conservative: it
    # cannot omit an asset even if this cursor sat untouched for months.
    batch_month="future"
    future_from="$BATCH_START-01"
    echo "$LOG_TAG Legacy future cursor has no boundary; resuming open-ended from $future_from."
  elif [[ "$saved_cursor" =~ ^[0-9]{4}-(0[1-9]|1[0-2])$ ]] && [[ "$saved_cursor" > "$BATCH_START" || "$saved_cursor" == "$BATCH_START" ]]; then
    batch_month="$saved_cursor"
  else
    echo "$LOG_TAG Ignoring invalid batch cursor: $saved_cursor"
  fi
fi

if [ "$full_pass_complete" != true ]; then
  preflight_capacity
else
  if ! DEST_AVAILABLE_KB="$(df -Pk "$DEST_ROOT" 2>/dev/null | awk 'NR==2 {print $4}')"; then
    DEST_AVAILABLE_KB=""
  fi
  DEST_AVAILABLE_KB="${DEST_AVAILABLE_KB:-0}"
  health_note "INCREMENTAL_PREFLIGHT available=${DEST_AVAILABLE_KB}KiB"
fi

# After the initial historical pass, one open-ended --update invocation catches
# new and changed assets at any capture date without rescanning once per range.
if [ "$full_pass_complete" = true ]; then
  echo "$LOG_TAG Initial historical pass is complete; starting single incremental update."
  set +e
  run_export ""
  status=$?
  set -e
  if [ "$status" -ne 0 ]; then
    echo "$LOG_TAG Incremental update failed (exit $status) -- will retry at the next scheduled sync."
    exit "$status"
  fi
  echo "===== $(date '+%Y-%m-%d %H:%M:%S') $LOG_TAG run end ====="
  exit 0
fi

# Always begin with an open-ended pre-start batch. This catches scans, bad
# camera clocks, and later date adjustments before BATCH_START without
# guessing how old an asset might be. It is intentionally repeated on every
# invocation so an older import cannot wait for the current cursor pass to
# wrap; --update makes already completed items cheap to revisit.
past_to="$(previous_day "$BATCH_START-01")"
echo "$LOG_TAG Starting pre-start batch (through $past_to)."
set +e
run_export "" "$past_to"
status=$?
set -e
if [ "$status" -ne 0 ]; then
  echo "$LOG_TAG Pre-start batch failed (exit $status) -- will retry it at the next scheduled sync."
  exit "$status"
fi
echo "$LOG_TAG Completed pre-start batch."

while [ "$batch_month" != "future" ] && [[ "$batch_month" < "$run_end_month" || "$batch_month" == "$run_end_month" ]]; do
  from_date="$batch_month-01"
  batch_end_month="$(add_months "$batch_month" "$((BATCH_SPAN_MONTHS - 1))")"
  if [[ "$batch_end_month" > "$run_end_month" ]]; then
    batch_end_month="$run_end_month"
  fi
  to_date="$(month_end "$batch_end_month")"
  echo "$LOG_TAG Starting batch $batch_month through $batch_end_month ($from_date through $to_date)."
  set +e
  run_export "$from_date" "$to_date"
  status=$?
  set -e
  if [ "$status" -ne 0 ]; then
    echo "$LOG_TAG Batch $batch_month through $batch_end_month failed (exit $status) -- will resume this range at the next scheduled sync."
    exit "$status"
  fi
  following_month="$(next_month "$batch_end_month")"
  printf '%s\n' "$following_month" > "$BATCH_CURSOR.tmp"
  mv -f "$BATCH_CURSOR.tmp" "$BATCH_CURSOR"
  echo "$LOG_TAG Completed batch $batch_month through $batch_end_month; next batch is $following_month."
  batch_month="$following_month"
  if [[ "$batch_month" < "$run_end_month" || "$batch_month" == "$run_end_month" ]]; then
    sleep "$BATCH_PAUSE_SECONDS"
  fi
done

# Capture assets dated beyond the current month (for example, a bad camera
# clock or a manually adjusted date). With no --to-date this final batch is
# intentionally open-ended. Persist a sentinel first so a failure resumes
# here instead of repeating all completed calendar months.
if [ -z "$future_from" ]; then
  future_from="$(next_month "$run_end_month")-01"
fi
printf 'future:%s\n' "$future_from" > "$BATCH_CURSOR.tmp"
mv -f "$BATCH_CURSOR.tmp" "$BATCH_CURSOR"
echo "$LOG_TAG Starting future-dated batch ($future_from and later)."
set +e
run_export "$future_from"
status=$?
set -e
if [ "$status" -ne 0 ]; then
  echo "$LOG_TAG Future-dated batch failed (exit $status) -- will resume this batch at the next scheduled sync."
  exit "$status"
fi
echo "$LOG_TAG Completed future-dated batch."

printf '%s\n' "complete" > "$BATCH_CURSOR.tmp"
mv -f "$BATCH_CURSOR.tmp" "$BATCH_CURSOR"
echo "$LOG_TAG Completed full pass through $run_end_month; future runs will use one incremental update."

echo "===== $(date '+%Y-%m-%d %H:%M:%S') $LOG_TAG run end ====="
