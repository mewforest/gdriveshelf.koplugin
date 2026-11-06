[Русская версия](authentication.ru.md) · [Back to README](../README.md)

# Connect Google Drive

GDriveShelf uses your own Google OAuth **Desktop app** client. The authorization helper needs Python 3 with its standard library and a desktop browser. It has been tested on macOS. You can authorize on a computer and transfer the resulting JSON to your reader.

## 1. Create a Desktop app client

1. Open [Google Cloud Console](https://console.cloud.google.com/) and create or select a project.
2. Enable the **Google Drive API** for that project.
3. Configure the OAuth consent screen. If the app is in **Testing**, add the Google account you will use as a test user.
4. Create an OAuth client with application type **Desktop app** and download its client JSON.

Use the downloaded Desktop client JSON, which contains an `installed` configuration. A web application client or service-account key will not work with this helper. See Google’s [OAuth guide for desktop apps](https://developers.google.com/identity/protocols/oauth2/native-app) for the project and consent settings.

## 2. Authorize in your browser

From a source checkout, run:

```sh
python3 tools/authorize.py \
  --client /path/to/client.json \
  --output /path/to/gdriveshelf-credentials.json
```

From a release ZIP, use `gdriveshelf-tools/authorize.py` instead of `tools/authorize.py`.

The helper opens your system browser. Sign in on Google’s website, review the permissions, and approve access. It does not ask for your Google password. Authorization retrieves tokens and your Drive account identifier; it does not change your Drive files.

The requested scope is **`https://www.googleapis.com/auth/drive`**, which grants broad read and write access to Drive. GDriveShelf needs access to existing library files and permission to create and update native `.sdr` folders beside them. The narrower `drive.file` scope does not provide access to an arbitrary existing library. Choose a Google account you are comfortable granting this access to.

The helper uses PKCE S256, a random `state`, and a temporary callback listener bound only to `127.0.0.1` on an available port. The default browser timeout is 180 seconds; add `--timeout 300` if you need longer. If consent is declined or times out, rerun the command. Keep the callback URL private.

## 3. Import into KOReader

1. Transfer `gdriveshelf-credentials.json` to a location KOReader can access.
2. Open **GDriveShelf → Settings** and choose the credentials JSON import action.
3. Select the generated credentials file. Do not select the original OAuth client JSON.
4. After a successful import, remove unnecessary copies from Downloads and the transfer device.

The generated JSON contains the OAuth client configuration, access and refresh tokens, expiry, scope, a stable `account_id` based on Drive’s `user.permissionId`, and the account email for display. The helper saves it atomically with owner-only permissions (`0600`) and does not print tokens. The plugin keeps a private local copy and saves refreshed credentials there.

Do not commit either JSON file, include them in plugin archives, attach them to issues, or paste them into logs or chats. Anyone with the generated credentials may be able to access your Drive.

## Renew or revoke access

If authorization fails with `invalid_grant`, or you revoke access, rerun the helper and import a new credentials JSON. If Google does not return a refresh token, repeat consent; you may need to revoke the old grant first. Apps in Testing can receive refresh tokens with a limited lifetime under Google’s OAuth policies.

To stop access, remove the app’s permission from your [Google account connections](https://myaccount.google.com/connections). Deleting a local credentials file alone does not revoke the grant.

## HTTPS verification

The plugin validates certificate chains and hostnames before sending HTTP headers. Redirects are refused so credentials are not forwarded to another host. The included Mozilla CA bundle comes from [curl CA Extract](https://curl.se/docs/caextract.html); its provenance, checksum, and license are in [CA-BUNDLE.md](../gdriveshelf.koplugin/CA-BUNDLE.md). Certificate verification cannot be disabled in plugin settings. The Python helper uses the standard verified SSL context.

The plugin uses KOReader’s `socketutil` timeouts: 15 seconds for blocking input and 120 seconds for a transfer after the request begins. DNS resolution is outside those timeouts. API errors expose a safe code and HTTP status without response bodies or tokens.
