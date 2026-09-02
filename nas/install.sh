#!/bin/bash
# One-time installer for the Photos -> cm5 NAS sync service.
# Run this once on the Mac that has the Photos library:
#   bash install.sh
set -euo pipefail

INSTALL_DIR="$HOME/photos_sync"
PLIST_LABEL="com.jason.photosnassync"
PLIST_DEST="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
SCRIPT_SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$HOME/Library/Application Support/photos-sync/config"

echo "== Installing Photos -> NAS sync =="

echo "-- 1/7 Choosing destination folder"
DEFAULT_DEST="/Volumes/data/Photos"
if [ -n "${PHOTOS_NAS_DEST:-}" ]; then
  NAS_DEST="$PHOTOS_NAS_DEST"
  echo "   Using PHOTOS_NAS_DEST=$NAS_DEST"
elif [ -t 0 ]; then
  read -r -p "   Destination folder on the NAS share [$DEFAULT_DEST]: " NAS_DEST
  NAS_DEST="${NAS_DEST:-$DEFAULT_DEST}"
else
  NAS_DEST="$DEFAULT_DEST"
  echo "   Non-interactive shell; using default: $NAS_DEST"
fi
mkdir -p "$(dirname "$CONFIG_FILE")"
touch "$CONFIG_FILE"
grep -v '^DEST_ROOT_NAS=' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" 2>/dev/null || true
mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
printf 'DEST_ROOT_NAS=%q\n' "$NAS_DEST" >> "$CONFIG_FILE"
echo "   Saved to $CONFIG_FILE (change later by re-running install.sh, or editing that file directly)"

echo "-- 2/7 Installing osxphotos (if needed)"
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

echo "-- 3/7 Installing exiftool (if needed)"
# sync_photos.sh passes osxphotos' --exiftool flag so that metadata living
# only in the Photos library database (GPS location, title, caption,
# keywords, person names) gets written into each exported file's own
# EXIF/IPTC/XMP tags -- exiftool is the external binary osxphotos shells
# out to for that.
if ! command -v exiftool >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    brew install exiftool
  else
    echo "NOTE: Homebrew not found, so exiftool wasn't installed automatically."
    echo "      Install it yourself (e.g. via https://exiftool.org) before running"
    echo "      sync_photos.sh, or metadata like GPS location that only exists in"
    echo "      the Photos library (not the original file) won't be preserved on export."
  fi
else
  echo "exiftool already installed: $(command -v exiftool)"
fi

echo "-- 4/7 Copying scripts to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
if [ "$SCRIPT_SRC_DIR" != "$INSTALL_DIR" ]; then
  cp "$SCRIPT_SRC_DIR/sync_photos.sh" "$INSTALL_DIR/"
  cp "$SCRIPT_SRC_DIR/mount_nas_share.sh" "$INSTALL_DIR/"
  cp "$SCRIPT_SRC_DIR/../sync_support.sh" "$INSTALL_DIR/"
  cp "$SCRIPT_SRC_DIR/../change_photo_library.sh" "$INSTALL_DIR/"
else
  echo "   Already running from $INSTALL_DIR; nothing to copy."
fi
rm -f "$INSTALL_DIR/change_photo_library"
chmod +x "$INSTALL_DIR/sync_photos.sh" "$INSTALL_DIR/mount_nas_share.sh" \
  "$INSTALL_DIR/change_photo_library.sh"

echo "-- 5/7 Running first sync now (this can take a while for a large library)"
echo "   macOS may pop up a permission dialog asking to allow access to your"
echo "   Photos library -- click Allow, or scheduled runs will silently fail."
echo "   (Deliberately done BEFORE the launchd agent is installed below, so"
echo "   this manual run can't race with a login-triggered run over SMB.)"
echo "   All progress output goes to the log below, not this terminal --"
echo "   open another terminal window and run this to watch it live:"
echo "     tail -f \"$HOME/Library/Logs/photos-nas-sync.log\""
echo "   For a large (e.g. ~1TB) library: prefer a wired network connection,"
echo "   keep this Mac plugged into power, and keep the lid open (or an"
echo "   external display attached) so macOS can't clamshell-sleep mid-copy."
if "$INSTALL_DIR/sync_photos.sh"; then
  echo "First run completed."
else
  echo "First run reported an error -- check $HOME/Library/Logs/photos-nas-sync.log"
  echo "Continuing to install the launchd agent anyway; fix the error above, then re-run:"
  echo "  ~/photos_sync/sync_photos.sh"
fi

echo "-- 6/7 Installing launchd agent"
mkdir -p "$HOME/Library/LaunchAgents"
sed "s#/Users/jason#$HOME#g" "$SCRIPT_SRC_DIR/${PLIST_LABEL}.plist" > "$PLIST_DEST"
launchctl unload "$PLIST_DEST" >/dev/null 2>&1 || true
launchctl load "$PLIST_DEST"

echo "-- 7/7 Done."
echo ""
echo "Logs:        $HOME/Library/Logs/photos-nas-sync.log"
echo "Destination: $NAS_DEST/YYYY-MM-DD/"
echo "Schedule:    daily at 03:00, plus once at every login (RunAtLoad)"
echo "Check job:   launchctl list | grep photosnassync"
