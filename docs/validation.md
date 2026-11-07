[Back to README](../README.md)

# Validation guide

GDriveShelf targets the **KOReader 2026.07 API**. Native checks have run on official **macOS ARM64 KOReader `v2026.07.2-310-gd183b7f`** and **Android ARM64 KOReader `v2026.07`** in an Android 11 / API 30 AOSP emulator. Validation was performed on 6–7 November 2026. The emulator does not validate physical E-Ink rendering or vendor firmware APIs.

## Automated checks

Install LuaJIT and Python 3, then run from the source checkout:

```sh
make test
make package VERSION=0.1.8
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

### UX release checks

The [sanitized UX result](test-results/android-ux-api30.json) records **30 additional passed checks** on Android API 30 with KOReader v2026.07. These cover the native right-hand menu and **Start with** integration, one-level indexing, bounded cover processing, live Store/Deflate ZIP range previews, cancelled opening, and immediate download feedback from both native EOF paths. The automatic-next test joined an already-running prefetch; the popup test selected the native next-file action.

Generated EPUB and PDF fixtures exercised native reading positions, offline reopening, durable pending progress, and cloud `.sdr` round trips with local `doc`, `dir`, and `hash` storage. EPUB positions were checked as xpointers. Relocation tests covered cancellation before opening, an offline interrupted move with newer progress, durable paths after refresh/eviction, and an injected failure after committing the new paths. Restarting an old-path reader and closing it preserved its latest page at the new path.

The corresponding opt-in harnesses are `tools/ux_drive_fixtures.lua`, `tools/android_ux_smoke.lua`, `tools/android_ux_followup.lua`, and `tools/android_ui_gallery.lua`. They require a private fixture plan produced inside a disposable test subtree; inspect the scripts before running them. `tools/ux_native_smoke.lua` checks local Store/Deflate previews with the bundled native runtime. `tools/ui_preview.lua` also renders the folder grid, categorized settings and storage in English and Russian.

The automated suite adds regressions for account/name/case path collisions, folder ordering and history grouping, indexing intervals, cancellation races, local jobs while offline, relocation recovery, stale preview invalidation, malformed ZIPs, and servers that ignore Range. Preview tests enforce response validation before accepting bytes and forbid a complete remote archive even across combined ranges. Android's missing monolithic zlib export was handled with a checked system-zlib fallback and verified with a Deflate fixture.

Screenshots were inspected from both native runtimes. The emulator evidence does not establish physical E-Ink refresh performance or guarantee that every vendor firmware behaves identically.

### Layout refinement

The follow-up layout checks use `tools/layout_smoke.lua` with native KOReader widgets. They cover 5, 9 and 11 entries, a partial final row and second page, long titles, bounded card contents, a toolbar and optional information header. Checks passed at 1200 × 1600 and 600 × 800. The old layout fails the margin check; the revised layout keeps fixed columns and separate card gutters. Set `GDRIVESHELF_ROOT`, a disposable `KO_HOME`, and `GDRIVESHELF_OUTPUT`, then run the script from the native runtime directory. `GDRIVESHELF_LAYOUT_IMAGE` optionally selects a local image; the default is the bundled logo.

`tools/android_layout_smoke.lua` is an optional temporary userpatch for the previously prepared isolated AVD. It reuses only its cached disposable fixtures, forces offline mode and rejects provider access. The actual five-item grid, memory, actions, settings and information screens were inspected on Android API 30. It does not import OAuth files or write to Drive. Russian and English galleries were regenerated; stale screenshots from the superseded settings layout were removed.

A small warm-render comparison on macOS used identical local images and ten measured nine-card redraws after warm-up: median approximately 14.9 ms before and 12.8 ms after. This only checks for a large layout regression; it does not measure physical E-Ink refresh time. No network operations, scanners or image decoders were added by the layout changes.

### Reliability, incremental catalog and AppStore

The release adds deterministic regressions for retained active jobs across retry/suspend/offline, priority and cancellation, local failures without global backoff, bounded diagnostics with hostile test payloads, recursive catalog checkpoints and change replay, shared-drive scope and pagination, visible SDR discovery/cache invalidation, confirmed emptiness, native cover isolation, and metadata outbox/conflict recovery. Source `_meta.lua` uses a development sentinel; packaging tests verify literal AppStore identity and matching release metadata/`PACKAGE_VERSION`, with no source mutation.

The [read-only live catalog result](test-results/live-catalog-progress.json) covers two real libraries with 5 and 123 supported documents. Established empty change checks made one HTTP request each. A seven-book page with seven native sidecars used two grouped metadata listings and seven Lua reads; a repeated warm page used zero requests. Forced unchanged listing rechecks did not redownload Lua. The harness refused Drive writes and archive reads. Counts exclude additional pages/retries and are not latency benchmarks. Shared-drive behavior was validated with protocol fixtures rather than a second live shared-drive account.

[Native local-cover checks](test-results/native-covers.json) used EPUB, PDF and CBZ against missing, empty, corrupt and valid sidecars. All twelve combinations produced bounded covers while leaving source/SDR bytes, timestamps and backups unchanged. The adapter made zero native sidecar API accesses and zero network requests, retained an inherited active document and left the original provider class unchanged. CB7 was skipped. `tools/native_cover_smoke.lua` reproduces these checks with independently authored fixtures.

`tools/browser_layout_smoke.lua` verifies native widgets at 600×800 and 1200×1600: fixed card columns, compact coverless header, bounded 144dp cover, measured corner badges/fallback, and an activity update that repaints exactly its own rectangle. `tools/ui_preview.lua` renders Russian and English information, editor, diagnostics, recovery, activity/queue, settings and stable local preview screens. Run SDL checks with `SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software` and `EMULATE_READER_W/H` to get exact dimensions independent of desktop window limits.

[AppStore native evidence](test-results/appstore-native.json) uses genuine upstream `appstore.koplugin` at the recorded commit. Only `socket.http.request` is replaced with synthetic GitHub API/raw/release responses. The real release picker, native archive reader, nested plugin extraction, collision checks, manual repository matching, install tracking and version comparison run unchanged. On macOS, separate native processes check startup after fresh release updates, an actual old 0.1.6 manual installation, and a nested source archive. Eleven synthetic protected files retain bytes, timestamps and permissions, including authorization, readable book paths, native SDR, queues, history and user metadata. The selected installed target reports its release version and no further update.

Android API 30 also passed an actual AppStore release-ZIP upgrade from the old 0.1.6 fixture and a separate-process restart in an app-private test profile. The target `0.1.701` is a synthetic fixture version. The same eleven files remained intact, existing synthetic credentials needed no reimport, and the native list showed one tracked plugin with no update. See the native Android screen and `tools/android_appstore_update_smoke.lua`; the existing Drive-test profile was kept separate.

The [Android reliability checks](test-results/android-reliability.json) add twenty passed checks on the real API 30 runtime: recursive indexing/catch-up and incremental refresh, local CBZ/EPUB/PDF covers, empty/malformed SDR preservation, offline reading with `doc`/`dir`/`hash` metadata, active-request cooldown/sleep/wake, native automatic-next joining prefetch, next from KOReader's popup, folder boundaries, conditional native SDR roundtrip, unchanged-SDR zero-download checks, and diagnostics privacy. Four further [folder-metadata checks](test-results/android-folder-metadata.json) cover durable offline edits and cover, ordered cloud uploads, a real external-client conflict and explicit conditional resolution. Two [navigation checks](test-results/android-navigation.json) verify the parent arrow on the first offline paint and its actual parent-folder tap. Cloud writes were confined to a newly created disposable child of the authorized test library; original libraries were read-only.

The AppStore harness uses its documented synchronous update-check fallback; asynchronous check cancellation is not covered. Old 0.1.6 has no metadata version, so its initial fixture update check uses a later synthetic release date; checks after upgrading use the installed literal version. The source-archive case tests extraction compatibility, not the recommended update route. Use release ZIPs for stable versions. Unauthenticated public discovery/download remains untested while this repository is private; it must be checked after the owner changes visibility. See `tools/appstore_update_smoke.lua` for required disposable profiles and fixtures; it never uses a real Google account.

### Light mode and cover gallery

The synthetic initial index for 40 subfolders and 800 documents now makes five full index writes, down from 89 on the prior release. The suite also checks 800 subfolders, pause and resume mid-batch, failed checkpoint writes, and the 15-minute light-mode listing lifetime. These are operation counts from fixtures.

Native macOS layout checks at 400×600, 600×800 and 1200×1600 cover the description and cover in the comic header, fixed grid columns, badges and bounded activity repaint. The native worker checks include PDF and CBZ page selection and WebP import. Opening those archives for gallery previews leaves the document and its native reading metadata unchanged.

Android API 30 checks at 1404×1872 and 600×800 use a local comic archive and a simulated provider. Both languages render the catalog, editor and cover gallery. The tests select a page and cancel its draft, pause and resume indexing, move a download to the background, and cancel a foreground request. The settings screen stays pixel-identical while a background transfer advances. These checks exercise KOReader on Android. Physical E-Ink timing is still device-specific.

The genuine AppStore installer also updated the packaged 0.1.7 build to 0.1.8 using simulated GitHub responses. The installed version stayed current after a separate-process restart. Authorization, documents, native progress, history and both outboxes retained their stored state.

### Reader polish and public repository checks

The conflict tests exercise version guards, an interrupted resolution, a newer local edit during verification, HTTP 412, and a stale cached cloud copy after an upload. The storage tests cover protected paths, scoped account cleanup, and same-account reimport. Native macOS KOReader verified that clearing an archive refreshes the same memory screen and preserves the .sdr.

Native Android layout and interactions passed at 1404×1872 and 600×800. The compact run also verified that finishing a background download offers Open without entering the reader and that selective cleanup retains the native .sdr on the same storage screen. AppStore upgraded a separate test profile from the 0.1.8 release ZIP to the 0.1.9 candidate using fixture GitHub responses. Settings, credentials, history, and queues survived the restart.

On Android API 30, the quick-preview viewer opened and turned a page using synthetic range responses. It removed its temporary files on close. Five cold-process runs per format used identical synthetic JPEGs in ZIP, ordinary RAR5 and solid RAR5 archives. Median CPU time for a first cover was 24.5 ms, 53.4 ms and 115.0 ms respectively. Peak process memory was about 105, 114 and 116 MiB. This compares the existing native paths on the emulator. Physical reader performance may differ.

The publication review checked Git history and refs, eight preceding releases and Actions logs, zero retained Actions artifacts, and screenshot metadata plus OCR. The selected catalog screenshot is visually unchanged. It was saved as PNG without the source metadata. The owner authorized the visible catalog data and the existing commit identity. GitHub attributes the reviewed history to the same maintainer account. The repository remained private during validation.

### Physical readers

Before relying on a physical reader, check:

- TLS/LuaSec and the bundled CA store in that KOReader build.
- Permissions and free-space reporting on the selected storage volume.
- Opening a downloaded chapter with network access blocked.
- Touch and long-press actions, scrolling, and e-ink redraws.
- Sleep/resume, process termination, and low-memory behavior.
- Recovery of interrupted downloads and pending progress sync after restart.

Downloads require KOReader to remain running. Report device-specific failures with the KOReader version, operating system, reproduction steps, and sanitized diagnostics.
