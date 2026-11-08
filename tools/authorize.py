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
from queue import Empty, Queue
import secrets
import subprocess
import tempfile
from threading import Thread
import time
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, urlencode, urlsplit
from urllib.request import HTTPSHandler, HTTPRedirectHandler, Request, build_opener
import ssl
import sys
try:
    import webbrowser
except ImportError:
    webbrowser = None  # Optional on Android; Termux has its own browser command.

AUTH_ENDPOINT = 'https://accounts.google.com/o/oauth2/v2/auth'
TOKEN_ENDPOINT = 'https://oauth2.googleapis.com/token'
ABOUT_ENDPOINT = 'https://www.googleapis.com/drive/v3/about?fields=user(permissionId,emailAddress)'
GUIDE_URL = 'https://github.com/mewforest/gdriveshelf.koplugin/blob/master/docs/authentication.md'
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


def authorization_url(client, redirect_uri, state, challenge, select_account=False):
    return AUTH_ENDPOINT + '?' + urlencode({
        'client_id': client['client_id'], 'redirect_uri': redirect_uri,
        'response_type': 'code', 'scope': SCOPE, 'state': state,
        'code_challenge': challenge, 'code_challenge_method': 'S256',
        'access_type': 'offline', 'prompt': 'select_account consent' if select_account else 'consent',
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
                    message = b'Authorization failed. Return to the Google Drive Shelf helper.'
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
                raise AuthorizationError('Authorization timed out. Start authorization again.')
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
    if scope is not None and (not isinstance(scope, str) or SCOPE not in scope.split()):
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
        if hasattr(os, 'fchmod'):
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


def open_browser(url, *, termux=False):
    if termux:
        try:
            return subprocess.run(['termux-open-url', url], stdin=subprocess.DEVNULL,
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                  timeout=15).returncode == 0
        except (OSError, subprocess.TimeoutExpired):
            return False
    return webbrowser is not None and webbrowser.open(url, new=1)


def request_credentials(client, timeout=180, *, select_account=False, termux=False):
    verifier, challenge = make_pkce()
    state = secrets.token_urlsafe(32)
    with CallbackServer(state, timeout) as callback:
        url = authorization_url(client, callback.redirect_uri, state, challenge, select_account)
        if not open_browser(url, termux=termux):
            if termux:
                raise AuthorizationError('Could not open your browser with termux-open-url.')
            raise AuthorizationError('Could not open the system browser. Check your default browser.')
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
    return credentials


def authorize(client, output, timeout=180, *, termux=False):
    print('Waiting for Google authorization in the system browser…')
    save_credentials(output, request_credentials(client, timeout, termux=termux))


def run_gui(client_path, timeout):
    try:
        import tkinter as tk
        from tkinter import filedialog, ttk
    except ImportError:
        print('Tkinter is unavailable. Install your Python distribution’s Tk support or use --client and --output.', file=sys.stderr)
        return 1
    try:
        root = tk.Tk()
    except tk.TclError:
        print('Could not open a desktop window. Use --client and --output to run in a terminal.', file=sys.stderr)
        return 1

    root.title('Connect Google Drive Shelf')
    panel = ttk.Frame(root, padding=24)
    panel.grid(sticky='nsew')
    root.columnconfigure(0, weight=1)
    panel.columnconfigure(0, weight=1)

    ttk.Label(panel, text='Connect Google Drive Shelf', font=('TkDefaultFont', 16, 'bold')).grid(sticky='w')
    ttk.Label(panel, text='1. Choose the Google Cloud client JSON', font=('TkDefaultFont', 13, 'bold')).grid(
        sticky='w', pady=(16, 4))
    ttk.Label(panel, text='In Google Cloud, create a Desktop app client and download its JSON. It tells the helper which OAuth client to use.',
              wraplength=470).grid(sticky='w', pady=(0, 4))
    ttk.Button(panel, text='Open setup guide', command=lambda: webbrowser.open(GUIDE_URL)).grid(sticky='w')
    selected = tk.StringVar(value='No client JSON selected.')
    next_step = tk.StringVar(value='Choose a valid client JSON in step 1 to enable sign-in.')
    status = tk.StringVar(value='')
    credentials = None
    results = Queue()
    json_files = [('JSON files', '*.json'), ('All files', '*')]

    def select_client(path):
        nonlocal client_path, credentials
        credentials = None
        save_button.state(['disabled'])
        try:
            client = load_client(path)
        except AuthorizationError as error:
            client_path = None
            selected.set(str(error))
            next_step.set('Choose a valid client JSON in step 1 to enable sign-in.')
            sign_in.state(['disabled'])
            status.set('')
            return None
        client_path = Path(path)
        selected.set(f'Client JSON selected: {client_path.name}')
        next_step.set('Ready. Select Sign in with Google, then choose your account in the browser.')
        sign_in.state(['!disabled'])
        status.set('')
        return client

    def choose_client():
        path = filedialog.askopenfilename(parent=root, title='Choose Google OAuth Desktop client JSON',
                                          filetypes=json_files)
        if path:
            select_client(path)

    def save():
        path = filedialog.asksaveasfilename(parent=root, title='Save Google Drive Shelf credentials',
                                          initialfile='gdriveshelf-credentials.json',
                                          defaultextension='.json', filetypes=json_files)
        if not path:
            status.set('Still signed in. Select Save credentials when you are ready.')
            return
        try:
            target = Path(path)
            if target.exists() and target.samefile(client_path):
                status.set('Choose a different file to keep your original OAuth client JSON.')
                return
            save_credentials(target, credentials)
        except OSError:
            status.set('Could not save the credentials here. Choose another folder and retry.')
            return
        status.set('Saved. Import this JSON in Google Drive Shelf on your reader. Keep the file private.')

    def receive_result():
        nonlocal credentials
        try:
            credentials, error = results.get_nowait()
        except Empty:
            root.after(100, receive_result)
            return
        choose.state(['!disabled'])
        sign_in.state(['!disabled'])
        if error:
            status.set(error)
            return
        save_button.state(['!disabled'])
        status.set('Signed in. Save the credentials to a private folder.')
        save()

    def start():
        client = select_client(client_path)
        if client is None:
            return
        choose.state(['disabled'])
        sign_in.state(['disabled'])
        save_button.state(['disabled'])
        status.set('Waiting for Google sign-in in your browser…')

        def worker():
            try:
                results.put((request_credentials(client, timeout, select_account=True), None))
            except AuthorizationError as error:
                results.put((None, str(error)))
            except OSError:
                results.put((None, 'Could not start local authorization. Check your browser and system settings.'))

        Thread(target=worker, daemon=True).start()
        root.after(100, receive_result)

    choose = ttk.Button(panel, text='Choose client JSON…', command=choose_client)
    choose.grid(sticky='w', pady=(5, 4))
    ttk.Label(panel, textvariable=selected, wraplength=470).grid(sticky='w')

    ttk.Label(panel, text='2. Sign in with Google', font=('TkDefaultFont', 13, 'bold')).grid(sticky='w', pady=(16, 4))
    ttk.Label(panel, textvariable=next_step, wraplength=470).grid(sticky='w', pady=(0, 4))
    sign_in = ttk.Button(panel, text='Sign in with Google', command=start, state='disabled')
    sign_in.grid(sticky='w')

    ttk.Label(panel, text='3. Save the credentials for KOReader', font=('TkDefaultFont', 13, 'bold')).grid(
        sticky='w', pady=(16, 4))
    ttk.Label(panel, text='After sign-in, save the new JSON and import it in Google Drive Shelf on your reader.',
              wraplength=470).grid(sticky='w', pady=(0, 4))
    save_button = ttk.Button(panel, text='Save credentials…', command=save, state='disabled')
    save_button.grid(sticky='w')
    ttk.Label(panel, textvariable=status, wraplength=470).grid(sticky='w', pady=(8, 0))
    if client_path is not None:
        select_client(client_path)
    root.mainloop()
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--gui', action='store_true', help='Open the graphical helper (also the default without arguments)')
    parser.add_argument('--termux', action='store_true', help='Open the Android browser using termux-open-url in terminal mode')
    parser.add_argument('--client', type=Path, help='Existing Google Desktop OAuth client JSON')
    parser.add_argument('--output', type=Path, help='New private credentials JSON')
    parser.add_argument('--timeout', type=int, default=180, help='Browser authorization timeout in seconds (default: 180)')
    args = parser.parse_args(argv)
    if not 1 <= args.timeout <= 1800:
        parser.error('--timeout must be between 1 and 1800 seconds')
    if args.gui or (not args.termux and args.client is None and args.output is None):
        if args.output is not None or args.termux:
            parser.error('--output and --termux are only used in terminal mode')
        return run_gui(args.client, args.timeout)
    if args.client is None or args.output is None:
        parser.error('terminal mode requires both --client and --output')
    try:
        authorize(load_client(args.client), args.output, args.timeout, termux=args.termux)
    except (AuthorizationError, OSError):
        # Only explicitly safe AuthorizationError text is surfaced below.
        error = sys.exc_info()[1]
        print('Authorization failed: ' + (str(error) if isinstance(error, AuthorizationError) else 'Could not access the local authorization file or loopback listener.'), file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print('Authorization cancelled.', file=sys.stderr)
        return 130
    print('Authorization saved. Import the file in GDriveShelf settings and keep it private.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
