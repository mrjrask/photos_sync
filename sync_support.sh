#!/bin/bash
# Shared capacity, health, and machine-readable run reporting helpers.

init_sync_observability() {
  SYNC_VARIANT="$1"
  HEALTH_LOG="$HOME/Desktop/photos-sync-health.log"
  SUMMARY_LOG="$HOME/Library/Logs/photos-${SYNC_VARIANT}-sync-summary.jsonl"
  RUN_STARTED_EPOCH="$(date +%s)"
  RUN_EXPORT_PROCESSES=0
  RUN_FAILED_PROCESSES=0
  RUN_EXPORTED=0
  RUN_UPDATED=0
  RUN_SKIPPED=0
  RUN_EXPORTED_FOUND=false
  RUN_UPDATED_FOUND=false
  RUN_SKIPPED_FOUND=false
  SOURCE_SIZE_KB=0
  DEST_AVAILABLE_KB=0
  mkdir -p "$(dirname "$SUMMARY_LOG")"
  mkdir -p "$HOME/Desktop" 2>/dev/null || true
  health_note "START library=$PHOTOS_LIBRARY destination=$DEST_ROOT"
}

health_note() {
  # The Desktop log is auxiliary. A protected, redirected, or otherwise
  # unavailable Desktop must not prevent the synchronization from running.
  { printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$SYNC_VARIANT" "$*" >> "$HEALTH_LOG"; } 2>/dev/null || true
}

preflight_capacity() {
  local required_with_margin cached_size="" size_cache="$EXPORT_DB_DIR/source-size-kb"
  if [ -f "$size_cache" ]; then read -r cached_size < "$size_cache" || true; fi
  if [[ "$cached_size" =~ ^[0-9]+$ ]]; then
    SOURCE_SIZE_KB="$cached_size"
    health_note "PREFLIGHT using cached source estimate=${SOURCE_SIZE_KB}KiB"
  else
    health_note "PREFLIGHT estimating source size; this can take several minutes for a large library"
    if ! SOURCE_SIZE_KB="$(du -sk "$PHOTOS_LIBRARY" 2>/dev/null | awk 'NR==1 {print $1}')"; then
      SOURCE_SIZE_KB=""
    fi
    if [[ "${SOURCE_SIZE_KB:-}" =~ ^[0-9]+$ ]] && [ "$SOURCE_SIZE_KB" -gt 0 ]; then
      printf '%s\n' "$SOURCE_SIZE_KB" > "$size_cache.tmp"
      mv -f "$size_cache.tmp" "$size_cache"
    fi
  fi
  if ! DEST_AVAILABLE_KB="$(df -Pk "$DEST_ROOT" 2>/dev/null | awk 'NR==2 {print $4}')"; then
    DEST_AVAILABLE_KB=""
  fi
  SOURCE_SIZE_KB="${SOURCE_SIZE_KB:-0}"
  DEST_AVAILABLE_KB="${DEST_AVAILABLE_KB:-0}"
  required_with_margin=$((SOURCE_SIZE_KB + SOURCE_SIZE_KB / 10))
  echo "$LOG_TAG Preflight estimated library size: $((SOURCE_SIZE_KB / 1024 / 1024)) GiB; destination available: $((DEST_AVAILABLE_KB / 1024 / 1024)) GiB."
  if [ "$SOURCE_SIZE_KB" -eq 0 ] || [ "$DEST_AVAILABLE_KB" -eq 0 ]; then
    health_note "WARNING capacity estimate unavailable estimated=${SOURCE_SIZE_KB}KiB available=${DEST_AVAILABLE_KB}KiB"
    echo "$LOG_TAG WARNING: capacity preflight could not obtain both source size and destination free space."
  elif [ "$DEST_AVAILABLE_KB" -lt "$required_with_margin" ]; then
    health_note "WARNING destination may be too small: estimated=${SOURCE_SIZE_KB}KiB available=${DEST_AVAILABLE_KB}KiB recommended=${required_with_margin}KiB"
    echo "$LOG_TAG WARNING: destination has less than the estimated library size plus a 10% margin."
    echo "$LOG_TAG The estimate is advisory because optimized iCloud libraries and exported metadata can change the final size."
  else
    health_note "PREFLIGHT_OK estimated=${SOURCE_SIZE_KB}KiB available=${DEST_AVAILABLE_KB}KiB"
  fi
}

record_export_output() {
  local output_file="$1" status="$2" value
  RUN_EXPORT_PROCESSES=$((RUN_EXPORT_PROCESSES + 1))
  [ "$status" -eq 0 ] || RUN_FAILED_PROCESSES=$((RUN_FAILED_PROCESSES + 1))
  # osxphotos wording has varied between releases. Capture counters when its
  # normal summary exposes them; null is emitted instead of inventing a value.
  for metric in exported updated skipped; do
    value="$(awk -v key="$metric" '
      tolower($0) ~ key "[^0-9]*[0-9]+" {
        line=tolower($0); sub(".*" key "[^0-9]*", "", line)
        sub("[^0-9].*", "", line); if (line != "") { total += line; found=1 }
      }
      END { if (found) print total }
    ' "$output_file")"
    if [ -n "$value" ]; then
      case "$metric" in
        exported) RUN_EXPORTED=$((RUN_EXPORTED + value)); RUN_EXPORTED_FOUND=true ;;
        updated) RUN_UPDATED=$((RUN_UPDATED + value)); RUN_UPDATED_FOUND=true ;;
        skipped) RUN_SKIPPED=$((RUN_SKIPPED + value)); RUN_SKIPPED_FOUND=true ;;
      esac
    fi
  done
}

finish_sync_observability() {
  local status="$1" elapsed result exported updated skipped throughput item_count
  elapsed=$(( $(date +%s) - RUN_STARTED_EPOCH ))
  if [ "$status" -eq 0 ]; then result="success"; else result="failure"; fi
  if [ "$RUN_EXPORTED_FOUND" = true ]; then exported="$RUN_EXPORTED"; else exported=null; fi
  if [ "$RUN_UPDATED_FOUND" = true ]; then updated="$RUN_UPDATED"; else updated=null; fi
  if [ "$RUN_SKIPPED_FOUND" = true ]; then skipped="$RUN_SKIPPED"; else skipped=null; fi
  if [ "$RUN_EXPORTED_FOUND" = true ] && [ "$RUN_UPDATED_FOUND" = true ]; then
    item_count=$((RUN_EXPORTED + RUN_UPDATED))
    if [ "$elapsed" -gt 0 ]; then throughput="$(awk -v n="$item_count" -v s="$elapsed" 'BEGIN { printf "%.3f", n / s }')"; else throughput=null; fi
  else
    throughput=null
  fi
  # Summary reporting is auxiliary. Do not let an unwritable log mask a
  # successful export or interrupt the remaining EXIT-trap cleanup.
  { printf '{"timestamp":"%s","variant":"%s","status":"%s","elapsed_seconds":%d,"export_processes":%d,"failed_processes":%d,"exported":%s,"updated":%s,"skipped":%s,"throughput_items_per_second":%s,"source_size_kb":%d,"destination_available_kb":%d}\n' \
      "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$SYNC_VARIANT" "$result" "$elapsed" \
      "$RUN_EXPORT_PROCESSES" "$RUN_FAILED_PROCESSES" "$exported" "$updated" "$skipped" "$throughput" \
      "$SOURCE_SIZE_KB" "$DEST_AVAILABLE_KB" >> "$SUMMARY_LOG"; } 2>/dev/null || true
  health_note "END status=$result elapsed=${elapsed}s export_processes=$RUN_EXPORT_PROCESSES failed_processes=$RUN_FAILED_PROCESSES exported=$exported updated=$updated skipped=$skipped"
  rm -rf "$LOCK_DIR" 2>/dev/null || true
}
