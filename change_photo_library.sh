#!/bin/bash
# Select a Photos library package without opening or descending into it.
set -euo pipefail

CONFIG_FILE="$HOME/Library/Application Support/photos-sync/config"
PREVIOUS_LIBRARY="$HOME/Pictures/Photos Library.photoslibrary"
if [ -f "$CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  PREVIOUS_LIBRARY="${PHOTOS_LIBRARY:-$PREVIOUS_LIBRARY}"
fi

if [ "$(uname -s)" != "Darwin" ] || ! command -v osascript >/dev/null 2>&1; then
  echo "change_photo_library.sh requires macOS and Finder." >&2
  exit 1
fi

echo "Opening the Photos Library picker. External drives are available under Locations."
SELECTED="$(osascript <<'OSA'
try
  set chosenLibrary to choose file with prompt "Choose the Photos Library to sync (external drives are under Locations)" of type {"com.apple.photos.library"} invisibles false showing package contents false
  return POSIX path of chosenLibrary
on error number -128
  return ""
end try
OSA
)"

if [ -z "$SELECTED" ]; then
  echo "No library selected; configuration was not changed."
  exit 0
fi
if [ ! -d "$SELECTED" ] || [[ "$SELECTED" != *.photoslibrary ]]; then
  echo "The selected item is not a .photoslibrary package: $SELECTED" >&2
  exit 1
fi

# An osxphotos export database belongs to the library it indexed. Preserve but
# retire existing state when the source actually changes, preventing a new
# library from inheriting a misleading completed cursor or update database.
# Archive every state file before changing the configuration so an archival
# failure leaves subsequent syncs pointed at the previous library.
if [ -n "$PREVIOUS_LIBRARY" ] && [ "$PREVIOUS_LIBRARY" != "$SELECTED" ]; then
  STAMP="$(date '+%Y%m%d-%H%M%S')"
  for state_dir in \
    "$HOME/Library/Application Support/photos-nas-sync" \
    "$HOME/Library/Application Support/photos-local-sync"; do
    if [ -d "$state_dir" ]; then
      mkdir -p "$state_dir/library-state-archive-$STAMP"
      for state_file in export.db batch-cursor source-size-kb; do
        if [ -e "$state_dir/$state_file" ]; then
          mv "$state_dir/$state_file" "$state_dir/library-state-archive-$STAMP/"
        fi
      done
    fi
  done
  echo "Previous export tracking state was archived; the new library will receive a full pass."
fi

mkdir -p "$(dirname "$CONFIG_FILE")"
grep -v '^PHOTOS_LIBRARY=' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" 2>/dev/null || true
printf 'PHOTOS_LIBRARY=%q\n' "$SELECTED" >> "$CONFIG_FILE.tmp"
mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"

echo "Photos library changed to: $SELECTED"
echo "The next NAS and local sync runs will use this library."
