#!/bin/bash
# Incrementally exports every photo/video in the Photos library to the cm5
# NAS share, organized into one folder per capture day (YYYY-MM-DD).
#
# Why per-day and not per-"Moment/Event": osxphotos (the export tool this
# script relies on) does not expose Photos' Moments/Events clustering as a
# stable, documented identifier -- and that clustering can be re-computed by
# Photos over time, which would silently move/duplicate files across runs of
# an incremental sync. Per-day folders based on the fixed capture date are
# stable, which is required for --update to work correctly. This matches the
# explicit fallback you specified.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUPPORT_SCRIPT="$SCRIPT_DIR/sync_support.sh"
[ -f "$SUPPORT_SCRIPT" ] || SUPPORT_SCRIPT="$SCRIPT_DIR/../sync_support.sh"
if [ ! -f "$SUPPORT_SCRIPT" ]; then
  echo "Missing sync_support.sh; re-run nas/install.sh." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$SUPPORT_SCRIPT"

# Destination folder is configurable -- install.sh prompts for it and saves
# the choice to CONFIG_FILE as DEST_ROOT_NAS. Falls back to the original
# default if unset (e.g. an older config, or the script run standalone).
# PHOTOS_NAS_DEST always wins when set, for one-off overrides without
# touching the saved config.
CONFIG_FILE="$HOME/Library/Application Support/photos-sync/config"
if [ -f "$CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi
DEST_ROOT="${PHOTOS_NAS_DEST:-${DEST_ROOT_NAS:-/Volumes/data/Photos}}"

LOG_FILE="$HOME/Library/Logs/photos-nas-sync.log"
LOG_TAG="[photos-nas-sync]"

# The --update export database is kept on LOCAL disk, not inside $DEST_ROOT.
# osxphotos' database is a SQLite file, and SQLite's locking doesn't work
# reliably over SMB -- if the database lives on the NAS, a run that gets
# interrupted (or just flaky SMB locking) can leave it unreadable/stale, so
# the next run can't tell what was already exported and re-exports
# everything, creating "(1)"-suffixed duplicates next to the originals.
# Keeping it locally makes --update's progress tracking reliable regardless
# of the network share's behavior.
EXPORT_DB_DIR="$HOME/Library/Application Support/photos-nas-sync"
EXPORT_DB="$EXPORT_DB_DIR/export.db"
BATCH_CURSOR="$EXPORT_DB_DIR/batch-cursor"
BATCH_START="${PHOTOS_BATCH_START:-2005-08}"
BATCH_SPAN_MONTHS="${PHOTOS_BATCH_SPAN_MONTHS:-12}"
BATCH_PAUSE_SECONDS="${PHOTOS_BATCH_PAUSE_SECONDS:-5}"
PHOTOS_VERBOSE="${PHOTOS_VERBOSE:-0}"
PHOTOS_LIBRARY="${PHOTOS_LIBRARY:-$HOME/Pictures/Photos Library.photoslibrary}"

mkdir -p "$(dirname "$LOG_FILE")"

# Local (non-network) lock so a launchd-triggered run and a manual run can
# never overlap. Two processes racing to create $DEST_ROOT on the SMB share
# at the same instant is what caused the "mkdir: Operation not permitted"
# error during install -- this lock makes that impossible going forward.
#
# The lock dir's pid file lets a later run tell a genuinely-still-running
# sync (plausible for hours on an initial 1TB+ export) apart from a stale
# lock left by a run that was killed (crash, force-quit, kill -9) before its
# EXIT trap could fire -- without this check, a stale lock would silently
# block every future scheduled run forever.
LOCK_DIR="/tmp/photos-nas-sync.lock"
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

# Start reporting before any NAS, destination, tool, or library preflight so
# failed runs are represented in both the health log and JSON summary.
init_sync_observability "nas"
trap 'finish_sync_observability $?' EXIT

# 1. Make sure the NAS share is mounted before we try to write anything to it.
if ! "$SCRIPT_DIR/mount_nas_share.sh"; then
  echo "$LOG_TAG Aborting: NAS share not reachable/mounted. Will retry next scheduled run."
  exit 1
fi

if ! mkdir -p "$DEST_ROOT"; then
  echo "$LOG_TAG ERROR: could not create $DEST_ROOT."
  echo "$LOG_TAG If this persists (not just a one-off), jason likely lacks write"
  echo "$LOG_TAG permission on /Volumes/data itself -- see README Troubleshooting."
  exit 1
fi

mkdir -p "$EXPORT_DB_DIR"

echo "$LOG_TAG Destination free space: $(df -h "$DEST_ROOT" | awk 'NR==2{print $4}')"

# 2. Locate the osxphotos binary (handles pipx / brew / pip --user installs).
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
  echo "$LOG_TAG ERROR: osxphotos not found on this Mac. Run install.sh first."
  exit 1
fi

echo "$LOG_TAG Using osxphotos at $OSXPHOTOS_BIN"

# exiftool is required by --exiftool below (osxphotos shells out to it) to
# write Photos' own metadata -- GPS location, title, caption, keywords,
# person names -- into each exported file's EXIF/IPTC/XMP tags. Without
# this, only whatever metadata the camera originally embedded survives;
# anything added or edited inside the Photos app itself (e.g. manually
# geotagging a screenshot, or Photos' own reverse-geocoded location) lives
# only in the Photos library database and would otherwise be silently lost
# on export.
if ! command -v exiftool >/dev/null 2>&1; then
  echo "$LOG_TAG ERROR: exiftool not found on this Mac. Run install.sh first (or 'brew install exiftool')."
  exit 1
fi

# 3. Incremental, full-resolution export.
#    --library            pins the source library explicitly instead of
#                         letting osxphotos auto-detect it by reading
#                         ~/Library/Containers/com.apple.Photos/.../
#                         com.apple.Photos.plist. That plist lives inside
#                         Photos' sandboxed container and requires Full Disk
#                         Access -- if that TCC grant is ever missing/reset
#                         (e.g. after an OS update or a pipx reinstall
#                         changes the binary's signature), auto-detection
#                         fails and every run, including scheduled ones,
#                         crashes immediately. Being explicit here removes
#                         that dependency.
#    --update            only exports items new/changed since the last run
#                         (tracked via --exportdb below) -- this is the
#                         "sync" mechanism, nothing is re-copied or
#                         duplicated on repeat runs.
#    --exportdb           puts the tracking database on LOCAL disk instead of
#                         $DEST_ROOT (see EXPORT_DB comment above) so
#                         --update's state survives flaky SMB locking.
#    --download-missing  forces download of full-resolution originals that
#                         are only iCloud-optimized (not fully on this Mac),
#                         so nothing scaled-down ever lands on the NAS.
#    --directory          "{created.date}" is osxphotos' built-in ISO date
#                         field -> one folder per capture day, e.g. 2026-08-18/
#    --retry 3            osxphotos' own recommendation when exporting to a
#                         NAS: automatically retries a *file* on transient
#                         network/SMB errors. This is short (seconds) and
#                         doesn't cover a NAS actually rebooting -- that's
#                         handled by the run-level retry loop below instead.
#    --exiftool            writes Photos' metadata (GPS location, title,
#                         caption, keywords, person names) into each
#                         exported file's EXIF/IPTC/XMP tags via exiftool,
#                         so metadata that only exists in the Photos
#                         library database -- not in the original file --
#                         is retained on the NAS copy too.
#    (original filenames are kept by default -- no flag needed for that)
if [ ! -d "$PHOTOS_LIBRARY" ]; then
  echo "$LOG_TAG ERROR: Photos library not found at $PHOTOS_LIBRARY."
  echo "$LOG_TAG If your library lives elsewhere, update PHOTOS_LIBRARY in this script."
  exit 1
fi

# Wrapped in caffeinate so macOS doesn't idle/system-sleep mid-export and
# drop the SMB mount -- this run can take hours (or longer) on an initial
# large library. Note this can't override a closed laptop lid forcing
# clamshell sleep; keep the lid open (or an external display attached) and
# the Mac plugged into power for the initial export.
#
# Also wrapped in `taskpolicy -b` so osxphotos and the exiftool process it
# shells out to run under macOS's "Darwin background" scheduling class --
# throttled CPU and disk/network I/O priority relative to foreground apps.
# Without this, a large export (thousands of files, --exiftool per file,
# writes going out over SMB) competes for the CPU/IO on equal footing with
# whatever you're doing interactively, which is what causes the mouse/
# keyboard to stutter during a run. This only throttles this script's own
# process tree -- if the machine still bogs down with `taskpolicy` in place,
# check Activity Monitor for photolibraryd/cloudphotod: --download-missing
# asks Photos to pull full-resolution originals down from iCloud, and that
# download itself runs in Photos' own background daemons, outside this
# script's control. For a large initial iCloud library, turning on Photos ->
# Settings -> iCloud -> "Download Originals to this Mac" ahead of time lets
# macOS fetch them at its own pace instead of osxphotos forcing it all at
# once.
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
  output_file="$(mktemp "${TMPDIR:-/tmp}/photos-nas-export.XXXXXX")"
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

# Run-level retry with backoff: if the NAS itself reboots or drops the SMB
# session mid-export, osxphotos' own recovery is short (~30s) and gives up
# by crashing the whole export rather than skipping ahead -- without this,
# that means waiting for the next scheduled run (up to 24h) or a manual
# restart. --update + the local --exportdb make a retry cheap: it resumes
# at the first not-yet-exported item rather than starting over.
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

next_month() { date -j -f "%Y-%m-%d" "$1-01" -v+1m "+%Y-%m"; }
add_months() { date -j -f "%Y-%m-%d" "$1-01" -v+"$2"m "+%Y-%m"; }
month_end() { date -j -f "%Y-%m-%d" "$1-01" -v+1m -v-1d "+%Y-%m-%d"; }
previous_day() { date -j -f "%Y-%m-%d" "$1" -v-1d "+%Y-%m-%d"; }

# A new osxphotos process is used for each bounded range, releasing transient
# resources without repeating its full-library startup work every month.
# Persist the next month only after success so interrupted exports resume safely.
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
    # The first batching release stored no boundary. Fall back to the
    # configured beginning rather than risk skipping assets after a long
    # interruption; --update still avoids recopying completed exports.
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

RETRY_DELAYS=(60 180 300)

# Once the initial historical pass is complete, one open-ended --update run is
# enough to find new and changed assets regardless of capture date. Repeating
# every historical range daily would recreate the slowdown batching avoids.
if [ "$full_pass_complete" = true ]; then
  echo "$LOG_TAG Initial historical pass is complete; starting single incremental update."
  attempt=1
  while true; do
    set +e
    run_export ""
    status=$?
    set -e
    [ "$status" -eq 0 ] && break
    if [ "$attempt" -gt "${#RETRY_DELAYS[@]}" ]; then
      echo "$LOG_TAG Incremental update failed after $attempt attempts (exit $status) -- will retry next run."
      exit "$status"
    fi
    delay="${RETRY_DELAYS[$((attempt - 1))]}"
    echo "$LOG_TAG Incremental update attempt $attempt failed (exit $status) -- retrying in ${delay}s."
    sleep "$delay"
    "$SCRIPT_DIR/mount_nas_share.sh" || true
    attempt=$((attempt + 1))
  done
  echo "===== $(date '+%Y-%m-%d %H:%M:%S') $LOG_TAG run end ====="
  exit 0
fi

# Check the unbounded range before BATCH_START on every invocation. This
# prevents old scans or newly corrected dates from being excluded, even when
# the persisted range cursor is already far ahead during the initial pass.
past_to="$(previous_day "$BATCH_START-01")"
echo "$LOG_TAG Starting pre-start batch (through $past_to)."
attempt=1
while true; do
  set +e
  run_export "" "$past_to"
  status=$?
  set -e
  [ "$status" -eq 0 ] && break
  if [ "$attempt" -gt "${#RETRY_DELAYS[@]}" ]; then
    echo "$LOG_TAG Pre-start batch failed after $attempt attempts (exit $status) -- will retry it next run."
    exit "$status"
  fi
  delay="${RETRY_DELAYS[$((attempt - 1))]}"
  echo "$LOG_TAG Pre-start batch attempt $attempt failed (exit $status) -- retrying in ${delay}s."
  sleep "$delay"
  "$SCRIPT_DIR/mount_nas_share.sh" || true
  attempt=$((attempt + 1))
done
echo "$LOG_TAG Completed pre-start batch."

while [ "$batch_month" != "future" ] && [[ "$batch_month" < "$run_end_month" || "$batch_month" == "$run_end_month" ]]; do
  from_date="$batch_month-01"
  batch_end_month="$(add_months "$batch_month" "$((BATCH_SPAN_MONTHS - 1))")"
  if [[ "$batch_end_month" > "$run_end_month" ]]; then
    batch_end_month="$run_end_month"
  fi
  to_date="$(month_end "$batch_end_month")"
  echo "$LOG_TAG Starting batch $batch_month through $batch_end_month ($from_date through $to_date)."
  attempt=1
  while true; do
    set +e
    run_export "$from_date" "$to_date"
    status=$?
    set -e
    [ "$status" -eq 0 ] && break
    if [ "$attempt" -gt "${#RETRY_DELAYS[@]}" ]; then
      echo "$LOG_TAG Batch $batch_month through $batch_end_month failed after $attempt attempts (exit $status) -- will resume this range next run."
      exit "$status"
    fi
    delay="${RETRY_DELAYS[$((attempt - 1))]}"
    echo "$LOG_TAG Batch $batch_month through $batch_end_month attempt $attempt failed (exit $status) -- retrying in ${delay}s."
    sleep "$delay"
    "$SCRIPT_DIR/mount_nas_share.sh" || true
    attempt=$((attempt + 1))
  done
  following_month="$(next_month "$batch_end_month")"
  printf '%s\n' "$following_month" > "$BATCH_CURSOR.tmp"
  mv -f "$BATCH_CURSOR.tmp" "$BATCH_CURSOR"
  echo "$LOG_TAG Completed batch $batch_month through $batch_end_month; next batch is $following_month."
  batch_month="$following_month"
  if [[ "$batch_month" < "$run_end_month" || "$batch_month" == "$run_end_month" ]]; then
    sleep "$BATCH_PAUSE_SECONDS"
  fi
done

# Finish with an open-ended batch so photos whose capture dates are later
# than the current month are never omitted. Reuse the same retry/remount
# policy as a normal month and persist a sentinel for exact resumption.
if [ -z "$future_from" ]; then
  future_from="$(next_month "$run_end_month")-01"
fi
printf 'future:%s\n' "$future_from" > "$BATCH_CURSOR.tmp"
mv -f "$BATCH_CURSOR.tmp" "$BATCH_CURSOR"
echo "$LOG_TAG Starting future-dated batch ($future_from and later)."
attempt=1
while true; do
  set +e
  run_export "$future_from"
  status=$?
  set -e
  [ "$status" -eq 0 ] && break
  if [ "$attempt" -gt "${#RETRY_DELAYS[@]}" ]; then
    echo "$LOG_TAG Future-dated batch failed after $attempt attempts (exit $status) -- will resume this batch next run."
    exit "$status"
  fi
  delay="${RETRY_DELAYS[$((attempt - 1))]}"
  echo "$LOG_TAG Future-dated batch attempt $attempt failed (exit $status) -- retrying in ${delay}s."
  sleep "$delay"
  "$SCRIPT_DIR/mount_nas_share.sh" || true
  attempt=$((attempt + 1))
done
echo "$LOG_TAG Completed future-dated batch."

printf '%s\n' "complete" > "$BATCH_CURSOR.tmp"
mv -f "$BATCH_CURSOR.tmp" "$BATCH_CURSOR"
echo "$LOG_TAG Completed full pass through $run_end_month; future runs will use one incremental update."

echo "===== $(date '+%Y-%m-%d %H:%M:%S') $LOG_TAG run end ====="
