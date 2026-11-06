[Back to README](../README.md)

# Validation guide

GDriveShelf targets the **KOReader 2026.07 API**. Native integration and visual checks have been run on the official **macOS ARM64 KOReader `v2026.07.2-310-gd183b7f`** build. Baseline validation was performed on 6 November 2026. Physical Android reader validation remains outstanding; desktop results do not establish firmware compatibility.

## Automated checks

Install LuaJIT and Python 3, then run from the source checkout:

```sh
make test
make package VERSION=0.1.0
```

`make test` runs Lua suites and Python authorization tests without Google credentials. `make package` also checks syntax and builds an allowlisted release ZIP and SHA-256 checksum in `dist/`.

Coverage includes independent storage budgets and the free-space reserve, LRU eviction and open-book protection, offline opening, folder boundaries and pagination, bounded downloads and MD5 verification, safe Lua metadata parsing, native sidecar naming, progress snapshots, persistent sync queues, stale-write rejection, conflict handling, temporary-file cleanup, and UI behavior. Packaging excludes runtime state and credentials.

## Native KOReader integration

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

Before relying on a physical reader, check:

- TLS/LuaSec and the bundled CA store in that KOReader build.
- Permissions and free-space reporting on the selected storage volume.
- Opening a downloaded chapter with network access blocked.
- Touch and long-press actions, scrolling, and e-ink redraws.
- Sleep/resume, process termination, and low-memory behavior.
- Recovery of interrupted downloads and pending progress sync after restart.

Downloads require KOReader to remain running. Report device-specific failures with the KOReader version, operating system, reproduction steps, and sanitized diagnostics.
