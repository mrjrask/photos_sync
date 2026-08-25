#!/bin/bash
# One-time installer for the Photos -> local disk sync service.
# This is the local-disk counterpart of install.sh: it exports to a folder
# on this Mac (~/Pictures/PhotosBackup by default) instead of the cm5 NAS
# share, and can be installed independently of (or alongside) install.sh.
# Run this once on the Mac that has the Photos library:
#   bash install_local.sh
set -euo pipefail

INSTALL_DIR="$HOME/photos_sync"
PLIST_LABEL="com.jason.photoslocalsync"
PLIST_DEST="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
SCRIPT_SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$HOME/Library/Application Support/photos-sync/config"

echo "== Installing Photos -> local disk sync =="

echo "-- 1/6 Choosing destination folder"
DEFAULT_DEST="$HOME/Pictures/PhotosBackup"
if [ -n "${PHOTOS_LOCAL_DEST:-}" ]; then
  LOCAL_DEST="$PHOTOS_LOCAL_DEST"
  echo "   Using PHOTOS_LOCAL_DEST=$LOCAL_DEST"
elif [ "$(uname -s)" = "Darwin" ] && command -v osascript >/dev/null 2>&1 && [ -t 0 ]; then
  DEFAULT_LOCATION="$HOME/Pictures"
  [ -d "$DEFAULT_LOCATION" ] || DEFAULT_LOCATION="$HOME"
  echo "   Opening a Finder window -- choose (or create) the destination folder..."
  PICKED="$(osascript <<OSA 2>/dev/null || true
try
  set chosenFolder to choose folder with prompt "Choose destination folder for Photos backup" default location (POSIX file "$DEFAULT_LOCATION")
  return POSIX path of chosenFolder
on error number -128
  return ""
end try
OSA
)"
  PICKED="${PICKED%/}"
  if [ -n "$PICKED" ]; then
    LOCAL_DEST="$PICKED"
    echo "   Selected: $LOCAL_DEST"
  else
    echo "   No folder selected; falling back to typed entry."
    read -r -p "   Destination folder on this Mac [$DEFAULT_DEST]: " LOCAL_DEST
    LOCAL_DEST="${LOCAL_DEST:-$DEFAULT_DEST}"
  fi
elif [ -t 0 ]; then
  read -r -p "   Destination folder on this Mac [$DEFAULT_DEST]: " LOCAL_DEST
  LOCAL_DEST="${LOCAL_DEST:-$DEFAULT_DEST}"
else
  LOCAL_DEST="$DEFAULT_DEST"
  echo "   Non-interactive shell; using default: $LOCAL_DEST"
fi
mkdir -p "$(dirname "$CONFIG_FILE")"
touch "$CONFIG_FILE"
grep -v '^DEST_ROOT_LOCAL=' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" 2>/dev/null || true
mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
printf 'DEST_ROOT_LOCAL=%q\n' "$LOCAL_DEST" >> "$CONFIG_FILE"
echo "   Saved to $CONFIG_FILE (change later by re-running install_local.sh, or editing that file directly)"

echo "-- 2/6 Installing osxphotos (if needed)"
if ! command -v osxphotos >/dev/null 2>&1; then
  if command -v pipx >/dev/null 2>&1; then
    pipx install osxphotos
  elif command -v brew >/dev/null 2>&1; then
    brew install pipx
    pipx ensurepath
    pipx install osxphotos
  else
    python3 -m pip install --user -U osxphotos
    echo "NOTE: if 'osxphotos' isn't found afterwards, add \$HOME/Library/Python/*/bin to your PATH."
  fi
else
  echo "osxphotos already installed: $(command -v osxphotos)"
fi

echo "-- 3/6 Installing exiftool (if needed)"
# sync_photos_local.sh passes osxphotos' --exiftool flag so that metadata
# living only in the Photos library database (GPS location, title, caption,
# keywords, person names) gets written into each exported file's own
# EXIF/IPTC/XMP tags -- exiftool is the external binary osxphotos shells
# out to for that.
if ! command -v exiftool >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    brew install exiftool
  else
    echo "NOTE: Homebrew not found, so exiftool wasn't installed automatically."
    echo "      Install it yourself (e.g. via https://exiftool.org) before running"
    echo "      sync_photos_local.sh, or metadata like GPS location that only exists"
    echo "      in the Photos library (not the original file) won't be preserved on export."
  fi
else
  echo "exiftool already installed: $(command -v exiftool)"
fi

echo "-- 4/6 Copying script to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
if [ "$SCRIPT_SRC_DIR" != "$INSTALL_DIR" ]; then
  cp "$SCRIPT_SRC_DIR/sync_photos_local.sh" "$INSTALL_DIR/"
else
  echo "   Already running from $INSTALL_DIR; nothing to copy."
fi
chmod +x "$INSTALL_DIR/sync_photos_local.sh"

echo "-- 5/6 Running first sync now (this can take a while for a large library)"
echo "   macOS may pop up a permission dialog asking to allow access to your"
echo "   Photos library -- click Allow, or scheduled runs will silently fail."
echo "   All progress output goes to the log below, not this terminal --"
echo "   open another terminal window and run this to watch it live:"
echo "     tail -f \"$HOME/Library/Logs/photos-local-sync.log\""
echo "   For a large library, keep this Mac plugged into power and the lid"
echo "   open (or an external display attached) so macOS can't clamshell-sleep"
echo "   mid-copy, and make sure the destination disk has enough free space."
if "$INSTALL_DIR/sync_photos_local.sh"; then
  echo "First run completed."
else
  echo "First run reported an error -- check $HOME/Library/Logs/photos-local-sync.log"
  echo "Continuing to install the launchd agent anyway; fix the error above, then re-run:"
  echo "  ~/photos_sync/sync_photos_local.sh"
fi

echo "-- 6/6 Installing launchd agent"
mkdir -p "$HOME/Library/LaunchAgents"
sed "s#/Users/jason#$HOME#g" "$SCRIPT_SRC_DIR/${PLIST_LABEL}.plist" > "$PLIST_DEST"
launchctl unload "$PLIST_DEST" >/dev/null 2>&1 || true
launchctl load "$PLIST_DEST"

echo "-- Done."
echo ""
echo "Logs:        $HOME/Library/Logs/photos-local-sync.log"
echo "Destination: $LOCAL_DEST/YYYY-MM-DD/"
echo "Schedule:    daily at 03:15, plus once at every login (RunAtLoad)"
echo "Check job:   launchctl list | grep photoslocalsync"
