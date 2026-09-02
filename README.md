# Photos → cm5 NAS sync

Ongoing service that exports every photo and video in your Mac's Photos
library, full resolution, to the `data` Samba share on `cm5.local`, sorted
into one folder per capture day.

**Want a copy on this Mac's own disk instead of (or in addition to) the
NAS?** See [Local-disk variant](#local-disk-variant) below — it's the same
tool, just writing to `~/Pictures/PhotosBackup` instead of `/Volumes/data`,
and can be installed independently of everything above.

## What it does

- **Destination:** `/Volumes/data/Photos/YYYY-MM-DD/` by default — one folder
  per capture date, e.g. `2026-08-18/`. `install.sh` asks which folder to use
  (see **Choosing the destination folder** below) and remembers your answer.
  Photos' Moments/Events grouping isn't exposed as a stable ID by the export
  tool, so day-based folders are used instead, per your fallback instruction
  — this also keeps incremental syncs reliable (files never need to move
  between folders on a later run).
- **Full resolution:** originals only, never Photos' scaled/preview copies.
  Items that are iCloud-optimized (not fully downloaded to this Mac) are
  force-downloaded before export.
- **Metadata preserved:** each exported file keeps its original embedded
  EXIF/location data, *and* gets Photos' own metadata (GPS location, title,
  caption, keywords, person names) written into it via `exiftool` — so
  anything that only lives in the Photos library database (e.g. a location
  you added or corrected inside Photos itself) is retained on the NAS copy
  too, not just what the camera originally embedded in the file.
- **Incremental:** each run only exports items that are new or changed since
  the last run — nothing is re-copied or duplicated. The tracking database
  that makes this work is kept on local disk (`~/Library/Application
  Support/photos-nas-sync/export.db`), not on the NAS share, since SQLite's
  file locking isn't reliable over SMB.
- **Bounded yearly batches:** each invocation first runs an open-ended batch
  for assets dated before `2005-08`, then exports 12 capture months per fresh
  `osxphotos` process through the current month. This releases transient memory
  and file resources without paying the very expensive 585,000-item Photos
  database startup/scan once for every single month. A five-second pause
  separates batches. An open-ended final batch includes assets dated after the
  current month. The span is configurable if a particular Mac needs smaller
  batches.
- **Schedule:** runs daily at 3:00 AM, plus once whenever you log in.
- **Tooling:** [osxphotos](https://github.com/RhetTbull/osxphotos) (the
  standard CLI for scripted Photos exports) driven by a macOS launchd agent.

## Requirements

- macOS with the Photos library you want to sync
- `bash` (preinstalled on macOS)
- Network access to `cm5.local`
- One of `pipx`, Homebrew, or `pip3` available so `install.sh` can install
  [osxphotos](https://github.com/RhetTbull/osxphotos)
- Homebrew (to install `exiftool`, used to write Photos' metadata into
  exported files — see **What it does** above). Without Homebrew, install
  [exiftool](https://exiftool.org) yourself before running `sync_photos.sh`.

## Files

The repo is split into a `nas/` folder (exports to the cm5 NAS share) and a
`local/` folder (exports to a folder on this Mac) — see
[Local-disk variant](#local-disk-variant) below for the latter.

| File | Purpose |
|---|---|
| `nas/install.sh` | One-time setup — run this first |
| `nas/uninstall.sh` | Removes the service (see **Uninstalling** below) |
| `nas/mount_nas_share.sh` | Mounts `smb://cm5.local/data` at `/Volumes/data` if not already mounted |
| `nas/sync_photos.sh` | The actual sync: mount check + `osxphotos export` |
| `nas/com.jason.photosnassync.plist` | launchd agent definition (installed to `~/Library/LaunchAgents/`) |
| `local/install_local.sh`, `local/uninstall_local.sh`, `local/sync_photos_local.sh`, `local/com.jason.photoslocalsync.plist` | The [local-disk variant](#local-disk-variant) — same idea, no NAS involved |
| `change_photo_library` | Opens a macOS picker for choosing any `.photoslibrary`, including one on an external drive |
| `sync_support.sh` | Shared capacity preflight, Desktop health log, and JSON-lines run summaries |

All `.sh` scripts are tracked as executable in this repo, so `./install.sh`
and `./uninstall.sh` work directly from within their folder; `bash install.sh`
also still works.

## Prerequisite (do this once, before running install.sh)

Connect to the share once via Finder so macOS saves the password in your
Keychain — the scripts read from Keychain and never handle your password
directly:

1. Finder → **Go → Connect to Server** (`Cmd+K`)
2. Enter `smb://cm5.local/data`, sign in as `jason`, and check **"Remember
   this password in my keychain"**.

If this share is already mounted/connected on your Mac today, this is
already done — skip ahead.

## Setup

```bash
cd photos_sync/nas
./install.sh
```

This installs osxphotos (via pipx, or Homebrew+pipx, or `pip3 --user` as a
fallback), copies the scripts to `~/photos_sync/`, installs and loads the
launchd agent, and runs the first sync immediately.

**Important:** the first run may trigger a macOS permission dialog asking to
allow access to your Photos library. Click **Allow** — if you don't, the
scheduled background runs will fail silently (no GUI dialog can appear when
launchd runs headless).

### Choosing the destination folder

`install.sh` starts by asking:
```
Destination folder on the NAS share [/Volumes/data/Photos]:
```
Press Enter to accept the default, or type a different path. Your answer is
saved to `~/Library/Application Support/photos-sync/config` as
`DEST_ROOT_NAS` and used by every future run of `sync_photos.sh`. To change
it later, either re-run `./install.sh` (it re-prompts) or edit that config
file directly. You can also skip the prompt entirely by setting
`PHOTOS_NAS_DEST` before running `install.sh`, e.g.:
```bash
PHOTOS_NAS_DEST="/Volumes/data/Photos Backup" ./install.sh
```

## Verifying it's working

Check the launchd job is loaded:
```bash
launchctl list | grep photosnassync
```

Check the log after a run:
```bash
tail -50 ~/Library/Logs/photos-nas-sync.log
```

Read the short, append-only health history maintained on the Desktop:
```bash
tail -50 ~/Desktop/photos-sync-health.log
```

Each completed or failed run also appends a machine-readable JSON object to
`~/Library/Logs/photos-nas-sync-summary.jsonl` (or
`photos-local-sync-summary.jsonl`). It includes status, elapsed seconds,
process and failure counts, capacity figures, and exported/updated/skipped
counters plus item throughput when the installed osxphotos version prints
those counters in its normal summary. Unavailable counters and throughput are
recorded as JSON `null`, never as a misleading zero.

Check files landed on the NAS:
```bash
ls /Volumes/data/Photos/
ls "/Volumes/data/Photos/$(date +%Y-%m-%d)/"
```

Force a run right now without waiting for the schedule:
```bash
~/photos_sync/sync_photos.sh
tail -f ~/Library/Logs/photos-nas-sync.log
```

## Adjusting the schedule

Edit `~/Library/LaunchAgents/com.jason.photosnassync.plist`, change the
`Hour`/`Minute` under `StartCalendarInterval` (or replace it with
`StartInterval` + a number of seconds for "every N hours" instead of once a
day), then reload:

```bash
launchctl unload ~/Library/LaunchAgents/com.jason.photosnassync.plist
launchctl load ~/Library/LaunchAgents/com.jason.photosnassync.plist
```

## Doing a large (e.g. ~1TB) initial migration

The first run exports your entire library and can take many hours. It is
automatically divided into 12-month batches beginning with August 2005;
before those batches, an open-ended pre-start batch exports everything dated
through July 31, 2005. It is retried on each initial-migration invocation until
it succeeds; after migration, the open-ended incremental update covers these
older dates too. The month after each completed range is recorded locally in
`batch-cursor`, beside that variant's export database. If the run fails or is stopped, the next launch
retries the interrupted range rather than returning to the beginning. After a
full pass through the month that was current when the run started, a final
open-ended batch exports anything dated in the future (such as an asset from a
misconfigured camera clock or a manually adjusted date). The cursor uses the
`future:YYYY-MM-01` marker while that batch runs. The date is the batch's
original lower boundary and remains unchanged across retries and later
launches, including when the calendar month rolls over, so an interruption
cannot create a gap. After it succeeds, the cursor changes to `complete`.
Later scheduled runs use one open-ended `--update` process, which detects new
or changed items at any capture date without restarting osxphotos for every
historical range. This prevents routine daily syncs from repeating the initial
migration's setup cost. A few things make this go smoothly:

- **Capacity is checked before the initial export.** The script measures the
  selected Photos library package with `du`, compares it with destination free
  space, and warns in both the normal and Desktop health logs when there is
  less than the estimate plus a 10% margin. It remains advisory because an
  iCloud-optimized library can be smaller than the originals it represents,
  while previews inside the package can make the package larger than the
  exported originals. The estimate is cached with the export state, so an
  interrupted migration and routine incremental runs do not repeat the
  expensive source scan.

- **Resource usage and rescans are balanced.** Each 12-month batch uses a
  completely new `osxphotos` process, so accumulated memory is returned to
  macOS. A process startup must still inspect the Photos database, however;
  annual ranges reduce those full-library setup passes from roughly 250 to
  roughly 21 for an August 2005 start. Per-file export and metadata work is
  unchanged. The wrapper waits five seconds before starting the next range.
  After that first pass, each daily sync uses only one process.
- **Verbose per-file logging is off by default.** At hundreds of thousands of
  files, formatting and writing a line for every item adds substantial I/O and
  can make the log itself enormous. Set `PHOTOS_VERBOSE=1` only while
  diagnosing a problem; normal osxphotos progress and batch boundaries remain
  logged.
- **Changing the starting month, batch span, or pause:** the library's
  configured earliest month is `2005-08`. Override it for either script with
  `PHOTOS_BATCH_START=YYYY-MM`. Assets before that month remain covered by the
  open-ended pre-start batch, but choosing a value near the oldest expected
  asset keeps that catch-all batch small. `PHOTOS_BATCH_SPAN_MONTHS` controls
  the number of months per process (default 12); use 6 if memory still grows
  too high, or 24 if startup scans dominate and memory remains stable. Set
  `PHOTOS_BATCH_PAUSE_SECONDS` to change the five-second inter-batch pause. For
  example:
  ```bash
  PHOTOS_BATCH_START=2005-08 PHOTOS_BATCH_SPAN_MONTHS=12 \
    PHOTOS_BATCH_PAUSE_SECONDS=10 \
    ~/photos_sync/sync_photos.sh
  ```
  If you intentionally change the start month during an unfinished pass,
  delete that variant's `batch-cursor` so the new value takes effect
  immediately. Do not delete `export.db`.

- **Prefer wired ethernet** over Wi-Fi for both this Mac and cm5 if possible
  — much faster and far less prone to dropping mid-transfer.
- **Keep the Mac plugged into power and awake.** `sync_photos.sh` now wraps
  the export in `caffeinate` to prevent idle/system sleep, but that cannot
  override a closed-lid (clamshell) sleep — keep the lid open, or keep an
  external display/keyboard/mouse attached, for the duration of the initial
  run.
- **Watch progress live:** the sync's own output goes entirely to the log
  file, not the terminal running `install.sh`. Open a second terminal and
  run `tail -f ~/Library/Logs/photos-nas-sync.log`.
- **Watch health at a glance:** `tail -f ~/Desktop/photos-sync-health.log`
  shows starts, capacity warnings, success/failure, duration, process counts,
  and any summary counters without the full export chatter.
- **It's fine if it doesn't finish in one sitting.** The export is incremental
  (`--update`) and resumable at the current batch — if a run is
  interrupted (network drop, sleep, reboot), the next run (scheduled at 3 AM,
  at login, or run manually) retries that range and then continues forward.
  For ~1TB it may legitimately take more than one day/run to complete.
- **Check free space first** on both ends: `df -h /Volumes/data` on the NAS
  side (the sync now logs this automatically at the start of each run) and
  enough free space on this Mac's local disk, since iCloud-optimized
  originals are downloaded locally before being exported to the NAS.
- If a run is ever killed abruptly (force-quit, `kill -9`, crash) instead of
  exiting normally, `sync_photos.sh` now detects that its lock is stale (the
  owning process is no longer running) and reclaims it automatically on the
  next run, rather than blocking forever.

## Troubleshooting

### Changing the Photos library

Run the installed picker whenever the source library moves or you want to sync
a different library:

```bash
~/photos_sync/change_photo_library
```

The native macOS selection window shows external disks under **Locations**,
hides invisible files, and treats a Photos library package as one selectable
item instead of opening it like an ordinary folder. Canceling makes no change.
The selected path is validated as a `.photoslibrary` package and saved as
`PHOTOS_LIBRARY` in `~/Library/Application Support/photos-sync/config`, shared
by both sync variants. Stop an active sync before changing libraries. Each
variant's existing `export.db` and `batch-cursor` are automatically moved into
a timestamped archive when the configured path changes, so the new library
receives a clean full pass without destroying the old tracking state.

- **A "Python" icon appears in the Dock while a sync is running, and
  right-clicking it always says "Application Not Responding"** — this is
  expected and harmless, not a hang. Reading your Photos library at all
  requires osxphotos to request PhotoKit authorization (the same permission
  system behind the "Allow access to your Photos library" dialog above),
  and that promotes the plain command-line Python process to a foreground
  app in macOS's eyes. Since it's a CLI tool with no windows and no Cocoa
  event loop, the Dock can't get a response out of it to its "are you
  alive?" check, so it always shows "Not Responding" even while the export
  is actively progressing fine in the log
  (`tail -f ~/Library/Logs/photos-nas-sync.log`). Don't force-quit it from
  the Dock — that kills the export mid-run.
- **The whole Mac slows to a crawl (laggy/stuttering keyboard and mouse)
  while a sync is running** — usually caused by `--download-missing`
  forcing Photos to pull large numbers of full-resolution originals down
  from iCloud during the export, which is genuinely CPU/memory-intensive
  work that happens in Photos' own background daemons (check Activity
  Monitor for `photolibraryd` / `cloudphotod` during a slow patch), not in
  osxphotos itself -- so it's mostly outside this script's control.
  `sync_photos.sh` now runs osxphotos under `taskpolicy -b` (macOS's
  background scheduling class), which deprioritizes the CPU/disk/network
  usage of osxphotos and the `exiftool` process it shells out to relative
  to whatever you're actively using -- update to the latest version of this
  script if `taskpolicy` isn't already in `run_export()`. If it's still bad
  after that, the iCloud download itself is almost certainly the cause; the
  most effective fix is to avoid forcing it during export in the first
  place: open Photos -> Settings -> iCloud and turn on **"Download
  Originals to this Mac"** a day or more before your next big sync, so
  macOS fetches full-resolution originals in the background at its own
  (much gentler) pace. Once your library is fully downloaded locally,
  `--download-missing` has nothing left to force and this slowdown should
  disappear; it's mainly a one-time pain point for the initial large
  migration, not something later small incremental runs should reproduce.
- **"osxphotos not found"** — re-run `install.sh`, or check
  `~/Library/Python/*/bin` / `~/.local/bin` is on your `PATH`.
- **"exiftool not found"** — re-run `install.sh` (it installs `exiftool` via
  Homebrew), or install it manually from https://exiftool.org. Without it,
  `sync_photos.sh` now refuses to run rather than silently exporting files
  that are missing Photos-only metadata (like a manually-added location).
- **Mount fails / share unreachable** — the sync simply logs an error and
  exits; it will retry on the next scheduled run. Check `cm5.local` is
  reachable (`ping cm5.local`) and that Keychain has saved credentials for
  it (Keychain Access app → search "cm5").
- **No files exported after the first run** — that's expected; `--update`
  means only *new* items copy on subsequent runs.
- **Permission dialog never appeared / export silently does nothing** — run
  `~/photos_sync/sync_photos.sh` manually from Terminal once so macOS can
  prompt you for Photos access interactively, then check
  System Settings → Privacy & Security → Photos.
- **`Operation not permitted:
  .../Containers/com.apple.Photos/Data/Library/Preferences/com.apple.Photos.plist`**
  — macOS is blocking access to Photos' own sandboxed preferences file, which
  `osxphotos` reads to auto-detect your library. `sync_photos.sh` now passes
  `--library` explicitly so this shouldn't happen going forward, but if it
  does: check System Settings → Privacy & Security → Full Disk Access and
  make sure Terminal (or whatever runs this script) is listed and enabled —
  quit and reopen Terminal after changing it. This can also surface after a
  reinstall of `osxphotos` (a new binary signature can require re-granting
  access).
- **NAS reboots or drops the SMB connection mid-export** — `osxphotos`'s own
  recovery for this is short (~30 seconds) and it crashes the whole export
  rather than continuing, so `sync_photos.sh` now retries the whole export
  itself up to 3 times with backoff (1 min, 3 min, 5 min), re-checking the
  mount before each retry. Since progress is tracked locally
  (`--exportdb`), a retry resumes at the first not-yet-exported item rather
  than starting over — no duplicates, nothing lost. If it still fails after
  all retries, it logs that and waits for the next scheduled run (or run
  `~/photos_sync/sync_photos.sh` manually once the NAS is confirmed
  back up).
- **`mkdir: /Volumes/data/Photos: Operation not permitted`** — this happened
  during initial install because the manual first run and the login-triggered
  launchd run raced to create the folder at the same instant over SMB. Fixed:
  `sync_photos.sh` now uses a local lock file so two runs can never overlap,
  and `install.sh` runs the manual verification pass *before* loading the
  launchd agent. If you still see this error on a clean run (not right after
  install), it means jason genuinely lacks write permission on
  `/Volumes/data` — check Samba's `write list`/permissions for the `data`
  share on cm5, and confirm `touch /Volumes/data/testfile` works from
  Terminal.
- **`Error: No such option '--original-name'`** — that flag doesn't exist in
  current osxphotos (it already preserves original filenames by default);
  it's been removed from `sync_photos.sh`.
- **`WARNING ... could not find search db: .../database/search/psi.sqlite`**
  — harmless, safe to ignore. `psi.sqlite` is Apple's *search index* database
  (powers Photos' natural-language search, e.g. "beach" or "dog") — it's
  built separately by the Photos app itself and isn't always present (e.g.
  on-device analysis hasn't finished, or the library is new). `osxphotos`
  only uses it for optional search-term metadata; when it's missing,
  `osxphotos` logs this warning and moves on. Your actual files, dates,
  EXIF/location data, and the `--exiftool`-written metadata (GPS, title,
  caption, keywords, person names) are unaffected, and the export continues
  normally.
- **`⚠️  exiftool warning ... Duplicate Orientation tag in IFD0`** — harmless,
  safe to ignore. This means the *original* file itself already has
  malformed EXIF (two Orientation tags), usually from having passed through
  older/other editing software at some point before it was ever imported
  into Photos. `exiftool` just picks one and warns; it still writes the rest
  of the metadata and the file still exports normally.
- **Exported filenames get a `(N)` suffix, e.g. `millerpark (6).jpg`** — on
  its own this is expected, not a bug: it means `N` *different* photos in
  your library (distinct UUIDs) would otherwise land on the same filename in
  that day's folder (e.g. your camera/software reused a filename, or you
  have several imports/edits of visually-similar shots), so `osxphotos`
  uniquifies them so nothing gets silently overwritten. This is different
  from the "re-copy everything from scratch" duplicate problem below — here
  the number `N` should stay small and stable across runs (it's just
  labeling genuinely distinct photos). Only treat it as the
  tracking-database problem below if you also see the
  same photo re-exported repeatedly across separate runs, or `N` growing
  unbounded on runs that shouldn't be adding new photos.
- **A run appears to re-copy everything from scratch, including files that
  already made it to the NAS** — this happens if `--update`'s tracking
  database can't be read (e.g. a prior run was interrupted, or SQLite's
  locking failed over SMB), so osxphotos no longer knows those files were
  already exported. Since the destination filenames already exist, osxphotos
  exports them again under new, uniquified names (e.g. `IMG_1234 (1).jpg`)
  instead of overwriting — i.e. duplicates. `sync_photos.sh` now keeps the
  tracking database on local disk
  (`~/Library/Application Support/photos-nas-sync/export.db`) specifically to
  avoid this. If you're on an older copy of this script (no `--exportdb` in
  the `osxphotos export` command), update to the latest version first.
  To recover:
  1. **Stop the run now** — `Ctrl+C` in the terminal it's running in (or, if
     it's the scheduled launchd run, `launchctl stop com.jason.photosnassync`)
     — so it doesn't create more duplicates while you sort this out.
  2. **Try to preserve existing tracking state** before running the updated
     script: if `/Volumes/data/Photos/.osxphotos_export.db` still exists
     from before, copy it to the new local path so osxphotos doesn't start
     from a blank slate (which would just re-trigger the same re-export):
     ```bash
     mkdir -p ~/Library/Application\ Support/photos-nas-sync
     cp "/Volumes/data/Photos/.osxphotos_export.db" \
        ~/Library/Application\ Support/photos-nas-sync/export.db
     ```
     Skip this if that file doesn't exist, or if osxphotos errors trying to
     read it later (delete the copy and let osxphotos create a fresh one).
  3. **Preview before trusting it:** run
     `osxphotos export /Volumes/data/Photos --update --exportdb ~/Library/Application\ Support/photos-nas-sync/export.db --dry-run --verbose`
     once and skim the output. If it lists files that are already correctly
     on the NAS as things it's about to export, the copied database didn't
     carry over the state you wanted — stop and ask before running for real.
  4. **Find and clean up duplicates already created:**
     `find /Volumes/data/Photos -regex '.* ([0-9]+)\..*'` lists them (the
     `IMG_1234 (1).jpg`-style names). Review the list, confirm the
     non-suffixed original is intact for each, then delete, e.g.
     `find /Volumes/data/Photos -regex '.* ([0-9]+)\..*' -delete`.
  5. Once you're satisfied, re-run `~/photos_sync/sync_photos.sh` for
     real; future runs will go back to being a true incremental delta.

## Uninstalling

```bash
cd photos_sync/nas
./uninstall.sh
```

By default this stops and removes the launchd agent and deletes the copied
scripts (`sync_photos.sh`, `mount_nas_share.sh`) from `~/photos_sync` (the
folder itself stays if the [local-disk variant](#local-disk-variant) is also
installed there). It deliberately leaves alone: anything already exported to
your destination folder (your synced photos/videos), osxphotos itself, and
the Keychain entry for the share — none of those are safe to delete
automatically.

Optional flags:
```bash
./uninstall.sh --remove-logs        # also delete the log files
./uninstall.sh --remove-osxphotos   # also uninstall osxphotos
```

To delete the exported photos/videos from the NAS too, do that manually from
Finder/Terminal on your destination folder (default `/Volumes/data/Photos`)
— this is intentionally not automated since it's not reversible.

## Local-disk variant

Everything above exports to the NAS. If you'd rather (or also) keep a copy
on this Mac's own disk — no NAS, no Samba share, no Keychain step — use the
local-disk variant instead. It's the same tool (same `osxphotos` flags, same
incremental/`--exiftool`/locking/log-rotation behavior described above),
just pointed at a local folder.

| File | Purpose |
|---|---|
| `local/install_local.sh` | One-time setup for the local-disk variant |
| `local/uninstall_local.sh` | Removes it (same `--remove-logs` / `--remove-osxphotos` flags as `uninstall.sh`) |
| `local/sync_photos_local.sh` | The actual sync: `osxphotos export` to your chosen local folder |
| `local/com.jason.photoslocalsync.plist` | launchd agent definition (runs daily at 03:15, offset from the NAS variant's 03:00 so the two don't race if both are installed) |

### Setup

```bash
cd photos_sync/local
./install_local.sh
```

This prompts for a destination folder:
```
Destination folder on this Mac [/Users/you/Pictures/PhotosBackup]:
```
Press Enter to accept the default, or type a different path (e.g. an
external drive mounted under `/Volumes`). Your answer is saved to
`~/Library/Application Support/photos-sync/config` as `DEST_ROOT_LOCAL` and
used by every future run of `sync_photos_local.sh`. To change it later,
either re-run `./install_local.sh` (it re-prompts) or edit that config file
directly. You can also skip the prompt by setting `PHOTOS_LOCAL_DEST`
beforehand, e.g.:
```bash
PHOTOS_LOCAL_DEST="/Volumes/External SSD/Photos" ./install_local.sh
```

Like `install.sh`, this also installs osxphotos and exiftool if needed,
copies `sync_photos_local.sh` to `~/photos_sync/`, runs the first sync
immediately, and installs the launchd agent.

**Important:** as with the NAS variant, the first run may trigger a macOS
permission dialog asking to allow access to your Photos library — click
**Allow**, or scheduled runs will fail silently.

### Verifying it's working

```bash
launchctl list | grep photoslocalsync
tail -50 ~/Library/Logs/photos-local-sync.log
ls ~/Pictures/PhotosBackup/          # or your chosen destination
```

Force a run right now:
```bash
~/photos_sync/sync_photos_local.sh
tail -f ~/Library/Logs/photos-local-sync.log
```

### Differences from the NAS variant

- No `mount_nas_share.sh` step and no run-level retry-with-backoff loop for
  a dropped SMB connection — a local disk doesn't disconnect mid-export the
  way a network share can. `osxphotos`' own `--retry 3` (per-file) still
  applies, and a failed run still resumes cleanly on the next scheduled sync
  thanks to `--update` and the local `--exportdb`.
- Its own log file (`~/Library/Logs/photos-local-sync.log`), export
  database (`~/Library/Application Support/photos-local-sync/export.db`),
  lock (`/tmp/photos-local-sync.lock`), and launchd label
  (`com.jason.photoslocalsync`) — installing this variant never interferes
  with the NAS variant, and both can run side by side.
- Everything else — day-based folders, full-resolution/`--download-missing`
  originals, `--exiftool` metadata preservation, `caffeinate`/`taskpolicy`
  wrapping, the local lock file, log rotation, and all the troubleshooting
  entries above about osxphotos/exiftool/Photos-library-not-found/duplicate
  re-exports — applies identically. The only NAS-specific troubleshooting
  entries that don't apply are the ones about mounting, SMB drops, and
  `/Volumes/data` permissions.

### Uninstalling

```bash
cd photos_sync/local
./uninstall_local.sh
```

Same behavior as `uninstall.sh`, scoped to this variant: stops and removes
the `com.jason.photoslocalsync` launchd agent and deletes
`sync_photos_local.sh` from `~/photos_sync` (again, that folder stays if the
NAS variant is also installed there). Leaves your exported
photos/videos, osxphotos, and the shared config file alone.
