#!/usr/bin/env python3
"""Authorize GDriveShelf with an existing Google Desktop client (stdlib only).

No account tokens are read from other applications. The imported JSON is the
Desktop client configuration downloaded from Google Cloud Console.
"""
import argparse
import base64
import hashlib
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
from pathlib import Path
import secrets
import socket
import tempfile
import time
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, urlencode, urlsplit
from urllib.request import HTTPSHandler, HTTPRedirectHandler, Request, build_opener
import ssl
import sys
import webbrowser

AUTH_ENDPOINT = 'https://accounts.google.com/o/oauth2/v2/auth'
TOKEN_ENDPOINT = 'https://oauth2.googleapis.com/token'
ABOUT_ENDPOINT = 'https://www.googleapis.com/drive/v3/about?fields=user(permissionId,emailAddress)'
SCOPE = 'https://www.googleapis.com/auth/drive'
MAX_JSON = 1024 * 1024


class AuthorizationError(Exception):
    """A safe, credential-free explanation suitable for terminal output."""


def pkce_challenge(verifier):
    return base64.urlsafe_b64encode(hashlib.sha256(verifier.encode('ascii')).digest()).rstrip(b'=').decode('ascii')


def make_pkce():
    verifier = secrets.token_urlsafe(64)
    return verifier, pkce_challenge(verifier)


def load_client(path):
    try:
        with open(path, 'rb') as handle:
            raw = handle.read(MAX_JSON + 1)
        if len(raw) > MAX_JSON:
            raise AuthorizationError('Client JSON is too large.')
        data = json.loads(raw)
        installed = data.get('installed')
        if not isinstance(installed, dict) or not isinstance(installed.get('client_id'), str) or not installed['client_id']:
            raise AuthorizationError('Import Google OAuth Desktop app client JSON (installed configuration).')
        result = {'client_id': installed['client_id']}
        if isinstance(installed.get('client_secret'), str):
            result['client_secret'] = installed['client_secret']
        return result
    except (OSError, ValueError, AttributeError, TypeError) as from_error:
        raise AuthorizationError('Cannot read valid Desktop client JSON.') from from_error


def authorization_url(client, redirect_uri, state, challenge):
    return AUTH_ENDPOINT + '?' + urlencode({
        'client_id': client['client_id'], 'redirect_uri': redirect_uri,
        'response_type': 'code', 'scope': SCOPE, 'state': state,
        'code_challenge': challenge, 'code_challenge_method': 'S256',
        'access_type': 'offline', 'prompt': 'consent',
    })


def parse_callback(target, state):
    parts = urlsplit(target)
    if parts.path != '/callback':
        raise AuthorizationError('Unexpected callback path.')
    params = parse_qs(parts.query, keep_blank_values=True)
    received = params.get('state', [])
    if len(received) != 1 or not secrets.compare_digest(received[0], state):
        raise AuthorizationError('Authorization state did not match. Run authorization again.')
    if 'error' in params:
        raise AuthorizationError('Google authorization was declined or failed.')
    code = params.get('code', [])
    if len(code) != 1 or not code[0] or len(code[0]) > 8192:
        raise AuthorizationError('No valid authorization code was returned.')
    return code[0]


class CallbackServer:
    def __init__(self, state, timeout=180):
        self.state, self.timeout = state, timeout
        self.code, self.error = None, None
        owner = self

        class Handler(BaseHTTPRequestHandler):
            # HTTPServer is bound to an IPv4 loopback interface exclusively.
            def do_GET(self):
                if self.path == '/favicon.ico':
                    self.send_error(404)
                    return
                if len(self.path) > 16384:
                    self.send_error(414)
                    return
                try:
                    owner.code = parse_callback(self.path, owner.state)
                    message = b'Authorization received. You can close this tab.'
                    status = 200
                except AuthorizationError as error:
                    owner.error = error
                    message = b'Authorization failed. Return to the terminal.'
                    status = 400
                self.send_response(status)
                self.send_header('Content-Type', 'text/plain; charset=utf-8')
                self.send_header('Content-Length', str(len(message)))
                self.send_header('Cache-Control', 'no-store')
                self.send_header('Content-Security-Policy', "default-src 'none'")
                self.end_headers()
                self.wfile.write(message)

            def log_message(self, *_):
                pass  # Callback URLs contain a short-lived authorization code.

        self.server = HTTPServer(('127.0.0.1', 0), Handler)
        # Prevent a local partial HTTP request from blocking the bounded wait.
        original_get_request = self.server.get_request

        def get_request():
            conn, address = original_get_request()
            conn.settimeout(min(2.0, max(0.01, timeout)))
            return conn, address

        self.server.get_request = get_request
        self.server.handle_error = lambda *_: None
        self.redirect_uri = f'http://127.0.0.1:{self.server.server_port}/callback'

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.server.server_close()

    def wait(self):
        deadline = time.monotonic() + self.timeout
        while self.code is None and self.error is None:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise AuthorizationError('Authorization timed out. Run the command again.')
            self.server.timeout = min(remaining, 0.5)
            self.server.handle_request()
        if self.error:
            raise self.error
        return self.code


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *_args, **_kwargs):
        raise AuthorizationError('Unexpected redirect refused.')


def request_json(url, data=None, token=None):
    headers = {'Accept': 'application/json'}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    if data is not None:
        data = urlencode(data).encode('ascii')
        headers['Content-Type'] = 'application/x-www-form-urlencoded'
    # Python/OpenSSL validates both certificate chains and hostnames.
    opener = build_opener(HTTPSHandler(context=ssl.create_default_context()), NoRedirect())
    try:
        with opener.open(Request(url, data=data, headers=headers), timeout=30) as response:
            raw = response.read(MAX_JSON + 1)
        if len(raw) > MAX_JSON:
            raise AuthorizationError('Google returned an oversized response.')
        result = json.loads(raw)
        if not isinstance(result, dict):
            raise AuthorizationError('Google returned an invalid response.')
        return result
    except HTTPError as error:
        # Never print exception body/URL: it may contain credential material.
        raise AuthorizationError(f'Google request failed (HTTP {error.code}).') from None
    except (URLError, OSError, ValueError):
        raise AuthorizationError('Secure Google request failed. Check the network and system clock.') from None


def credentials_from_response(response, client):
    if not all(isinstance(response.get(key), str) and response[key] for key in ('access_token', 'refresh_token')):
        raise AuthorizationError('Google did not issue offline credentials. Run again and approve consent.')
    scope = response.get('scope')
    if scope is not None and SCOPE not in scope.split():
        raise AuthorizationError('The required full Google Drive scope was not granted.')
    try:
        expires_in = int(response['expires_in'])
        if expires_in <= 0:
            raise ValueError
    except (KeyError, ValueError, TypeError, OverflowError):
        raise AuthorizationError('Google returned an invalid token expiry.') from None
    return dict(client, access_token=response['access_token'], refresh_token=response['refresh_token'],
                expires_at=int(time.time()) + expires_in, scope=SCOPE)


def save_credentials(path, credentials):
    path = Path(path).expanduser()
    fd, temporary = tempfile.mkstemp(prefix='.' + path.name + '.', suffix='.tmp', dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, 'w', encoding='utf-8') as handle:
            fd = None
            json.dump(credentials, handle, ensure_ascii=False, indent=2)
            handle.write('\n')
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if fd is not None:
            os.close(fd)
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def authorize(client, output, timeout=180):
    verifier, challenge = make_pkce()
    state = secrets.token_urlsafe(32)
    with CallbackServer(state, timeout) as callback:
        url = authorization_url(client, callback.redirect_uri, state, challenge)
        if not webbrowser.open(url, new=1):
            raise AuthorizationError('Could not open the system browser. Check the macOS default browser.')
        print('Waiting for Google authorization in the system browser…')
        code = callback.wait()
        request = dict(client, code=code, code_verifier=verifier, redirect_uri=callback.redirect_uri,
                       grant_type='authorization_code')
        credentials = credentials_from_response(request_json(TOKEN_ENDPOINT, data=request), client)
    about = request_json(ABOUT_ENDPOINT, token=credentials['access_token'])
    user = about.get('user')
    if not isinstance(user, dict) or not isinstance(user.get('permissionId'), str) or not user['permissionId']:
        raise AuthorizationError('Google did not return a stable account identifier.')
    credentials['account_id'] = user['permissionId']
    if isinstance(user.get('emailAddress'), str):
        credentials['account_email'] = user['emailAddress']
    save_credentials(output, credentials)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--client', required=True, type=Path, help='Existing Google Desktop OAuth client JSON')
    parser.add_argument('--output', required=True, type=Path, help='New credentials JSON (private, mode 0600)')
    parser.add_argument('--timeout', type=int, default=180, help='Browser authorization timeout in seconds (default: 180)')
    args = parser.parse_args(argv)
    if not 1 <= args.timeout <= 1800:
        parser.error('--timeout must be between 1 and 1800 seconds')
    try:
        authorize(load_client(args.client), args.output, args.timeout)
    except (AuthorizationError, OSError):
        # Only explicitly safe AuthorizationError text is surfaced below.
        error = sys.exc_info()[1]
        print('Authorization failed: ' + (str(error) if isinstance(error, AuthorizationError) else 'Could not access the local authorization file or loopback listener.'), file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print('Authorization cancelled.', file=sys.stderr)
        return 130
    print('Authorization saved with private permissions. Import the file in GDriveShelf settings.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
