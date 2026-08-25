#!/bin/bash
# Mounts the cm5 NAS Samba share at /Volumes/data if it isn't already mounted.
# Uses the credentials already saved in your macOS Keychain (from the first
# time you connected via Finder -> Cmd+K -> smb://cm5.local/data with
# "Remember this password in my keychain" checked). This script never
# stores or handles your password directly.
set -euo pipefail

SHARE_URL="smb://cm5.local/data"
MOUNT_POINT="/Volumes/data"
LOG_TAG="[photos-nas-sync/mount]"

if mount | grep -q " on ${MOUNT_POINT} "; then
  echo "$LOG_TAG Already mounted at $MOUNT_POINT"
  exit 0
fi

echo "$LOG_TAG Mounting $SHARE_URL ..."
/usr/bin/osascript -e "mount volume \"${SHARE_URL}\"" >/dev/null 2>&1 || {
  echo "$LOG_TAG ERROR: could not mount $SHARE_URL." >&2
  echo "$LOG_TAG Check that cm5.local is reachable on the network and that" >&2
  echo "$LOG_TAG credentials for this share are saved in Keychain Access" >&2
  echo "$LOG_TAG (connect once via Finder if needed: Cmd+K -> $SHARE_URL)." >&2
  exit 1
}

# Give macOS a moment to finish attaching the volume.
for _ in 1 2 3 4 5; do
  if mount | grep -q " on ${MOUNT_POINT} "; then
    echo "$LOG_TAG Mounted successfully."
    exit 0
  fi
  sleep 1
done

echo "$LOG_TAG ERROR: mount did not appear at $MOUNT_POINT after mounting." >&2
exit 1
