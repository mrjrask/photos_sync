#!/bin/bash
# Removes the Photos -> local disk sync service (the local-disk counterpart
# of uninstall.sh).
#
# By default this only:
#   - unloads and deletes the launchd agent (stops future scheduled runs)
#   - removes sync_photos_local.sh from ~/photos_sync (that folder itself is
#     left in place if the NAS variant's scripts are also installed there --
#     see uninstall.sh)
#
# It deliberately does NOT touch:
#   - anything already exported to your chosen destination folder (your
#     synced photos -- default ~/Pictures/PhotosBackup)
#   - osxphotos itself (other tools/scripts on this Mac may use it)
#
# Pass --remove-logs to also delete the log files, and
# --remove-osxphotos to additionally uninstall osxphotos.
set -euo pipefail

INSTALL_DIR="$HOME/photos_sync"
PLIST_LABEL="com.jason.photoslocalsync"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
LOG_FILES=(
  "$HOME/Library/Logs/photos-local-sync.log"
  "$HOME/Library/Logs/photos-local-sync.out.log"
  "$HOME/Library/Logs/photos-local-sync.err.log"
  "$HOME/Library/Logs/photos-local-sync-summary.jsonl"
)

REMOVE_LOGS=false
REMOVE_OSXPHOTOS=false
for arg in "$@"; do
  case "$arg" in
    --remove-logs) REMOVE_LOGS=true ;;
    --remove-osxphotos) REMOVE_OSXPHOTOS=true ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

echo "== Uninstalling Photos -> local disk sync =="

echo "-- 1/4 Stopping and removing the launchd agent"
if [ -f "$PLIST_PATH" ]; then
  launchctl unload "$PLIST_PATH" >/dev/null 2>&1 || true
  rm -f "$PLIST_PATH"
  echo "   Removed $PLIST_PATH"
else
  echo "   No launchd agent found at $PLIST_PATH (already removed?)"
fi

echo "-- 2/4 Removing installed script"
if [ -d "$INSTALL_DIR" ]; then
  rm -f "$INSTALL_DIR/sync_photos_local.sh"
  if [ ! -f "$INSTALL_DIR/sync_photos.sh" ]; then
    rm -f "$INSTALL_DIR/sync_support.sh" "$INSTALL_DIR/change_photo_library" \
      "$INSTALL_DIR/change_photo_library.sh"
  fi
  rmdir "$INSTALL_DIR" 2>/dev/null || true
  echo "   Removed sync_photos_local.sh from $INSTALL_DIR"
  if [ -d "$INSTALL_DIR" ]; then
    echo "   ($INSTALL_DIR left in place -- other files, e.g. the NAS"
    echo "   variant's sync_photos.sh, still live there)"
  fi
else
  echo "   $INSTALL_DIR not found (already removed?)"
fi

echo "-- 3/4 Logs"
if [ "$REMOVE_LOGS" = true ]; then
  for f in "${LOG_FILES[@]}"; do
    rm -f "$f"
  done
  if [ ! -f "$HOME/Library/LaunchAgents/com.jason.photosnassync.plist" ]; then
    rm -f "$HOME/Desktop/photos-sync-health.log"
  fi
  echo "   Removed log files"
else
  echo "   Left log files in place (re-run with --remove-logs to delete them)"
fi

echo "-- 4/4 osxphotos"
if [ "$REMOVE_OSXPHOTOS" = true ]; then
  if command -v pipx >/dev/null 2>&1 && pipx list 2>/dev/null | grep -q osxphotos; then
    pipx uninstall osxphotos
  elif command -v pip3 >/dev/null 2>&1; then
    python3 -m pip uninstall -y osxphotos || true
  fi
  echo "   osxphotos uninstalled"
else
  echo "   Left osxphotos installed (re-run with --remove-osxphotos to remove it)"
fi

echo ""
echo "Done. Note: files already exported to your destination folder (see"
echo "DEST_ROOT_LOCAL in ~/Library/Application Support/photos-sync/config,"
echo "default ~/Pictures/PhotosBackup) were NOT deleted -- remove them"
echo "yourself if you no longer want them."
