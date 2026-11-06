[Back to README](../README.md)

# Validation guide

GDriveShelf targets the **KOReader 2026.07 API**. Native checks have run on official **macOS ARM64 KOReader `v2026.07.2-310-gd183b7f`** and **Android ARM64 KOReader `v2026.07`** in an Android 11 / API 30 AOSP emulator. Validation was performed on 6 November 2026. The emulator does not validate physical E-Ink rendering or vendor firmware APIs.

## Automated checks

Install LuaJIT and Python 3, then run from the source checkout:

```sh
make test
make package VERSION=0.1.0
```

`make test` runs Lua suites and Python authorization tests without Google credentials. `make package` also checks syntax and builds an allowlisted release ZIP and SHA-256 checksum in `dist/`.

Coverage includes independent storage budgets and the free-space reserve, LRU eviction and open-book protection, offline opening, folder boundaries and pagination, bounded downloads and MD5 verification, safe Lua metadata parsing, native sidecar naming, progress snapshots, persistent sync queues, stale-write rejection, conflict handling, temporary-file cleanup, and UI behavior. Packaging excludes runtime state and credentials.

## Native KOReader integration

`tools/auth_ui_smoke.lua` exercises first-run setup, native chooser navigation and selection, rejection of a Desktop-client JSON, private credential storage, and transition into the library. Run it from the official runtime with a dedicated disposable `KO_HOME` and `GDRIVESHELF_ROOT`. It uses synthetic credentials and forces offline mode; it never signs in or contacts Google Drive.

Use an official KOReader runtime with its bundled LuaJIT and modules. Run harnesses from that runtime directory with a separate, disposable `KO_HOME`. Keep it separate from your regular reading profile.

For example, after changing to the KOReader runtime directory:

```sh
export GDRIVESHELF_ROOT=/absolute/path/to/source-checkout
export KO_HOME="$(mktemp -d /tmp/gdriveshelf-profile.XXXXXX)"
export GDRIVESHELF_TEST_ROOT="$(mktemp -d /tmp/gdriveshelf-native.XXXXXX)"
./luajit "$GDRIVESHELF_ROOT/tools/native_integration.lua"
```

`tools/native_integration.lua` checks atomic JSON storage, owner-only state permissions, free-space reporting, cleanup of interrupted downloads, native `DocSettings` sidecar round trips, extension case, and worker execution while UI timers continue.

`tools/ui_preview.lua` renders the title library, library actions, settings and icons, storage, offline tree, title information, logo, and native reader from local fixtures. It checks saved title sorting and resumes the last document before turning a native page. Set `GDRIVESHELF_LANGUAGE=en_US` for English screenshots (`*-en.png`), or `ru` for Russian. It requires `GDRIVESHELF_SAMPLES` to point at a fixture directory with `folder.json`, a matching CBZ, `cover.jpg`, and `index.json`. Read the harness before preparing fixtures: it expects a particular chapter filename pattern and page count. Use redistributable or locally owned material. Review the resulting images in `docs/screenshots/` for clipped text, overlapping controls, language, and readable contrast.

Native checks have also covered the credential file chooser and import of synthetic authorization data. HTTPS was verified using the bundled CA store and an intentionally invalid test token; the expected result was an authorization rejection after a verified TLS connection.

## Optional live Google Drive checks

These checks need real credentials and an explicitly chosen test folder. Keep credentials outside the checkout and use a dedicated test library. The helper scripts refresh the supplied credentials file when necessary; never publish that file or its contents.

From the KOReader runtime directory, set:

```sh
export GDRIVESHELF_CREDS=/private/path/to/gdriveshelf-credentials.json
export GDRIVESHELF_TEST_PARENT=drive-folder-id
export GDRIVESHELF_OUTPUT="$(mktemp -d /tmp/gdriveshelf-live.XXXXXX)"
```

With `GDRIVESHELF_ROOT` and the disposable `KO_HOME` still set:

```sh
./luajit "$GDRIVESHELF_ROOT/tools/live_smoke.lua"
```

This reads Drive listings, downloads the first supported book and adjacent cover/metadata into the output directory, checks size and MD5, and safely reads existing `.sdr` data when present. It does not change the cloud library. Confirm the test folder contains suitable fixtures before running it.

For sync writes, place a small, valid test archive named `Smoke.cbz` in `GDRIVESHELF_OUTPUT`, inspect `tools/live_sync_smoke.lua`, then run:

```sh
./luajit "$GDRIVESHELF_ROOT/tools/live_sync_smoke.lua"
```

This creates a new test child under the supplied parent, uploads the fixture, creates and reads native `.sdr` data, checks conditional updates and stale-write rejection, and simulates a progress conflict. It moves its own test child to Drive trash afterwards. If execution is interrupted, inspect the local `test-artifact.json` to identify the test child for cleanup.

Live checks have confirmed these flows against Drive, including HTTP 412 for a stale conditional update. The provider uses Drive v2 for the ETag snapshot and conditional update where needed; listing, creation, and downloads use v3. Binary content identity uses equal MD5 values even when Drive changes a service version number.

## Android device checklist

### Reproducible emulator import regression

`tools/android_import_smoke.lua` is a temporary KOReader userpatch for an isolated test emulator. It exercises the real native JSON chooser, import, and library transition. It also runs a real subprocess with IPC while checking the UI timer; an optional local CBZ checks page navigation and native `.sdr` saving. It does not use real Drive credentials or make Drive requests.

Prepare the emulator with the plugin installed, synthetic `gdriveshelf-credentials.json` in `/sdcard/Download/`, and plugin settings `offline=true, sync_enabled=false`. Copy the harness to `/sdcard/koreader/patches/2-gdriveshelf-import-test.lua`, then restart KOReader. For the optional reader check, supply a valid multi-page archive at `/sdcard/Download/GDriveShelf-smoke.cbz`. Capture `adb logcat` before launch and look for the three `GDriveShelf Android smoke: PASS` messages. Remove the temporary patch afterwards so normal launches do not run the test again.

This reproduced the pre-fix import failure, `missing declaration for symbol 'fchmod'`, on official Android v2026.07. The plugin now declares the function explicitly after loading the platform's `mode_t`; newer KOReader versions also accept that declaration. On the emulator the imported credential file had `0600` permissions.

### Expanded live Drive and failure checks

The [sanitized Android result](test-results/android-api30.json) records 28 passed checks on the same Android build. These cover independent metadata caching, checksum-verified downloads, native reading, threshold prefetch, auto-cache LRU with preserved sidecars/pending progress, pinned recursive downloads, parent-folder boundaries, cleanup of all pools, and the 512 MiB free-space reserve.

The emulator's Wi-Fi and mobile-data radios were disabled for the offline checks. Cached opening returned without a network job; pending progress survived on disk. Restoring connectivity sent native progress for a book whose archive had already been evicted. Follow-up checks exercised existing `.sdr` updates, HTTP 412 stale-write rejection, both-side conflict preservation/resolution, and rejection of executable Lua metadata without executing it. Wrong OAuth credentials, injected menu/confirmation errors, and worker preparation/cancellation errors left KOReader running. The file-sort menu and persisted selection were also checked on Android.

`tools/android_drive_setup.lua` prepares only a new child of the explicitly supplied `GDRIVESHELF_TEST_PARENT`; use `GDRIVESHELF_EXTEND=1` for its nested-title fixture. The private output plan and import JSON are consumed by `tools/android_drive_smoke.lua` as a temporary startup patch. That patch pauses at the network-off/on checkpoints; use adb to change the radios and create the corresponding `settings/gdriveshelf-avd-network-off.flag` / `network-on.flag` files. Replace it with `tools/android_sync_fault_smoke.lua` for the conflict and fault checks. Never run these live harnesses against a normal library account state or without an explicitly authorized test parent.

After validation the temporary Drive subtree was moved to trash, startup patches were removed, and real OAuth files were removed from the reusable emulator. Original manga files and original reading progress were not changed. The setup helper's `GDRIVESHELF_CLEANUP=1` mode checks the recorded parent before trashing its test child.

Two Android-2026.07 compatibility failures found by these runs are covered: the missing POSIX declaration and the absent natural-sort preparation hook. Unexpected UI errors now write code locations to `gdriveshelf-diagnostic.log` in KOReader's data folder; error payloads, credentials, and JSON contents are excluded.

`tools/android_end_action_smoke.lua` adds a fresh-fixture run through real paged-reader EOF events. Native **Nothing**, **Ask**, **Open next file**, and auto-mark-finished behavior were checked, including cached and uncached next chapters, the final chapter boundary, and restarting with `start_with=last` at page 2. A cache budget too small for both protected/open and next archives was rejected safely; increase the budget or pin files when prefetch needs more space. Approximate folder bars were rendered on Android from cached children with no network jobs.

### Physical readers

Before relying on a physical reader, check:

- TLS/LuaSec and the bundled CA store in that KOReader build.
- Permissions and free-space reporting on the selected storage volume.
- Opening a downloaded chapter with network access blocked.
- Touch and long-press actions, scrolling, and e-ink redraws.
- Sleep/resume, process termination, and low-memory behavior.
- Recovery of interrupted downloads and pending progress sync after restart.

Downloads require KOReader to remain running. Report device-specific failures with the KOReader version, operating system, reproduction steps, and sanitized diagnostics.
