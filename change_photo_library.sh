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

mkdir -p "$(dirname "$CONFIG_FILE")"
CONFIG_TMP="$(mktemp "$CONFIG_FILE.tmp.XXXXXX")"
trap 'rm -f "$CONFIG_TMP"' EXIT
if [ -f "$CONFIG_FILE" ]; then
  grep -v '^PHOTOS_LIBRARY=' "$CONFIG_FILE" > "$CONFIG_TMP" || true
fi
printf 'PHOTOS_LIBRARY=%q\n' "$SELECTED" >> "$CONFIG_TMP"

# An osxphotos export database belongs to the library it indexed. Preserve but
# retire existing state when the source actually changes, preventing a new
# library from inheriting a misleading completed cursor or update database.
# Prepare the replacement config before moving any state, then roll back every
# move if either archiving or the atomic config rename fails.
ARCHIVE_DIRS=()
restore_archived_state() {
  local archive_dir state_dir state_file
  for archive_dir in "${ARCHIVE_DIRS[@]}"; do
    state_dir="${archive_dir%/*}"
    for state_file in export.db batch-cursor source-size-kb; do
      if [ -e "$archive_dir/$state_file" ]; then
        mv "$archive_dir/$state_file" "$state_dir/$state_file" || \
          echo "Unable to restore $state_dir/$state_file from $archive_dir." >&2
      fi
    done
    rmdir "$archive_dir" 2>/dev/null || true
  done
}

if [ -n "$PREVIOUS_LIBRARY" ] && [ "$PREVIOUS_LIBRARY" != "$SELECTED" ]; then
  STAMP="$(date '+%Y%m%d-%H%M%S')-$$"
  for state_dir in \
    "$HOME/Library/Application Support/photos-nas-sync" \
    "$HOME/Library/Application Support/photos-local-sync"; do
    archive_dir="$state_dir/library-state-archive-$STAMP"
    for state_file in export.db batch-cursor source-size-kb; do
      if [ -e "$state_dir/$state_file" ]; then
        if [ ! -d "$archive_dir" ]; then
          if ! mkdir "$archive_dir"; then
            restore_archived_state
            exit 1
          fi
          ARCHIVE_DIRS+=("$archive_dir")
        fi
        if ! mv "$state_dir/$state_file" "$archive_dir/"; then
          restore_archived_state
          exit 1
        fi
      fi
    done
  done

  if ! mv "$CONFIG_TMP" "$CONFIG_FILE"; then
    echo "Unable to update the library configuration; restoring previous sync state." >&2
    restore_archived_state
    exit 1
  fi
  echo "Previous export tracking state was archived; the new library will receive a full pass."
else
  mv "$CONFIG_TMP" "$CONFIG_FILE"
fi
trap - EXIT

echo "Photos library changed to: $SELECTED"
echo "The next NAS and local sync runs will use this library."
