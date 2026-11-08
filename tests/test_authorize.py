import importlib.util
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch
import contextlib
import io
from urllib.parse import parse_qs, urlsplit

MODULE = Path(__file__).resolve().parents[1] / 'tools' / 'authorize.py'
assert MODULE.exists(), 'OAuth helper is not implemented'
spec = importlib.util.spec_from_file_location('authorize', MODULE)
auth = importlib.util.module_from_spec(spec)
spec.loader.exec_module(auth)

class AuthorizeTests(unittest.TestCase):
    def test_pkce_and_full_drive_scope(self):
        verifier, challenge = auth.make_pkce()
        self.assertGreaterEqual(len(verifier), 43)
        self.assertEqual(auth.pkce_challenge('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'), 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM')
        q = parse_qs(urlsplit(auth.authorization_url({'client_id': 'desktop'}, 'http://127.0.0.1:99/callback', 'state', challenge)).query)
        self.assertEqual(q['scope'], ['https://www.googleapis.com/auth/drive'])
        self.assertEqual(q['code_challenge_method'], ['S256'])
        self.assertEqual(q['access_type'], ['offline'])
        self.assertEqual(q['state'], ['state'])

    def test_callback_rejects_missing_or_mismatched_state(self):
        for query in ('code=secret', 'state=wrong&code=secret', 'state=ok&state=wrong&code=secret'):
            with self.assertRaises(auth.AuthorizationError):
                auth.parse_callback('/callback?' + query, 'ok')
        self.assertEqual(auth.parse_callback('/callback?state=ok&code=accepted', 'ok'), 'accepted')

    def test_client_import_accepts_only_desktop_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / 'client.json'
            p.write_text(json.dumps({'installed': {'client_id': 'client', 'client_secret': 'secret', 'auth_uri': 'https://evil.test/'}}))
            c = auth.load_client(p)
            self.assertEqual(c['client_id'], 'client')
            self.assertNotIn('auth_uri', c)
            p.write_text(json.dumps({'web': {'client_id': 'client'}}))
            with self.assertRaises(auth.AuthorizationError):
                auth.load_client(p)

    def test_atomic_private_credentials_and_no_secret_stdout(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / 'credentials.json'
            auth.save_credentials(p, {'access_token': 'secret'})
            self.assertEqual(stat.S_IMODE(p.stat().st_mode), 0o600)
            self.assertEqual(json.loads(p.read_text())['access_token'], 'secret')
            auth.save_credentials(p, {'access_token': 'replacement'})
            self.assertEqual(json.loads(p.read_text())['access_token'], 'replacement')

    def test_loopback_timeout_is_bounded(self):
        with auth.CallbackServer('ok', timeout=0.01) as server:
            self.assertTrue(server.redirect_uri.startswith('http://127.0.0.1:'))
            with self.assertRaises(auth.AuthorizationError):
                server.wait()

    def test_token_exchange_requires_refresh_token(self):
        with self.assertRaises(auth.AuthorizationError):
            auth.credentials_from_response({'access_token': 'a', 'expires_in': 3600}, {'client_id': 'c'})
        creds = auth.credentials_from_response({'access_token': 'a', 'refresh_token': 'r', 'expires_in': 3600}, {'client_id': 'c'})
        self.assertEqual(creds['refresh_token'], 'r')
        self.assertGreater(creds['expires_at'], 0)

    def test_authorize_persists_stable_account_id_and_pkce_without_printing_tokens(self):
        class Callback:
            redirect_uri = 'http://127.0.0.1:1234/callback'
            def __init__(self, *_): pass
            def __enter__(self): return self
            def __exit__(self, *_): pass
            def wait(self): return 'authorization-code'
        requests = []
        def request(url, data=None, token=None):
            requests.append((url, data, token))
            if data is not None:
                self.assertEqual(data['code'], 'authorization-code')
                self.assertEqual(data['grant_type'], 'authorization_code')
                self.assertEqual(data['redirect_uri'], Callback.redirect_uri)
                self.assertGreaterEqual(len(data['code_verifier']), 43)
                return {'access_token': 'private-access', 'refresh_token': 'private-refresh', 'expires_in': 3600}
            self.assertEqual(token, 'private-access')
            return {'user': {'permissionId': 'stable-id', 'emailAddress': 'reader@example.test'}}
        with tempfile.TemporaryDirectory() as tmp, patch.object(auth, 'CallbackServer', Callback), patch.object(auth.webbrowser, 'open', return_value=True), patch.object(auth, 'request_json', side_effect=request):
            output = Path(tmp) / 'credentials.json'
            capture = io.StringIO()
            with contextlib.redirect_stdout(capture):
                auth.authorize({'client_id': 'client'}, output)
            credentials = json.loads(output.read_text())
            self.assertEqual(credentials['account_id'], 'stable-id')
            self.assertEqual(credentials['account_email'], 'reader@example.test')
            self.assertEqual(len(requests), 2)
            self.assertNotIn('private-access', capture.getvalue())
            self.assertNotIn('private-refresh', capture.getvalue())

    def test_wrong_scope_does_not_create_credentials(self):
        with self.assertRaises(auth.AuthorizationError):
            auth.credentials_from_response({'access_token': 'a', 'refresh_token': 'r', 'expires_in': 3600, 'scope': 'https://www.googleapis.com/auth/drive.file'}, {'client_id': 'c'})

    def test_desktop_authorization_opens_gui_with_optional_client(self):
        with patch.object(auth, 'run_gui', return_value=0) as gui:
            self.assertEqual(auth.main([]), 0)
            gui.assert_called_once_with(None, 180)
            gui.reset_mock()
            self.assertEqual(auth.main(['--gui', '--client', 'desktop.json']), 0)
            gui.assert_called_once_with(Path('desktop.json'), 180)

    def test_graphical_authorization_can_choose_account_and_defer_saving(self):
        with patch.object(auth, 'CallbackServer') as listener, \
                patch.object(auth.webbrowser, 'open', return_value=True) as browser, \
                patch.object(auth, 'request_json', side_effect=[
                    {'access_token': 'access', 'refresh_token': 'refresh', 'expires_in': 3600},
                    {'user': {'permissionId': 'stable-id'}},
                ]), patch.object(auth, 'save_credentials') as save:
            callback = listener.return_value.__enter__.return_value
            callback.redirect_uri = 'http://127.0.0.1:4321/callback'
            callback.wait.return_value = 'code'
            result = auth.request_credentials({'client_id': 'client'}, select_account=True)
            query = parse_qs(urlsplit(browser.call_args.args[0]).query)
            self.assertEqual(set(query['prompt'][0].split()), {'consent', 'select_account'})
            self.assertEqual(result['account_id'], 'stable-id')
            save.assert_not_called()

    def test_termux_opens_url_without_webbrowser(self):
        url = 'https://accounts.google.com/o/oauth2/v2/auth?state=test&code_challenge=pkce'
        with patch.object(auth, 'webbrowser', None), patch.object(auth, 'subprocess') as process:
            process.run.return_value.returncode = 0
            self.assertTrue(auth.open_browser(url, termux=True))
            self.assertEqual(process.run.call_args.args[0], ['termux-open-url', url])

if __name__ == '__main__':
    unittest.main()
