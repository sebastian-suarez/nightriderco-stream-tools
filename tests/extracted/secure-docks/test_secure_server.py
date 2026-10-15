"""HTTP regressions for the dock host, using synthetic credentials only.

Run from the repository root: python3 -m unittest discover -s tests/extracted/secure-docks -p test_secure_server.py -v
No native executable is launched and no system Keychain is accessed.
"""
import base64
import hashlib
import http.client
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest


SERVER_PATH = Path(__file__).resolve().parents[3] / 'payload/SecureDocks/secure-docks.py'
SPEC = importlib.util.spec_from_file_location('secure_docks_test_target', SERVER_PATH)
SERVER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SERVER)
SYNTHETIC_PASSWORD = 'synthetic-password-for-test-only-ß'


class FakeKeychain:
    def __init__(self):
        self.passwords = {}
        self.calls = []
        self.override = None
        self.failure = None

    def call(self, payload):
        self.calls.append(dict(payload))
        if self.failure:
            raise self.failure
        if self.override is not None:
            return self.override
        port, action = payload['port'], payload['action']
        if action == 'save':
            self.passwords[port] = payload['password']
            return {'ok': True, 'saved': True, 'password': payload['password']}
        if action == 'forget':
            self.passwords.pop(port, None)
            return {'ok': True, 'saved': False}
        if action == 'status':
            return {'ok': True, 'saved': port in self.passwords}
        if port not in self.passwords:
            return {'ok': False, 'error': 'missing_password', 'message': 'No saved password.'}
        secret = base64.b64encode(hashlib.sha256((self.passwords[port] + payload['salt']).encode()).digest()).decode()
        authentication = base64.b64encode(hashlib.sha256((secret + payload['challenge']).encode()).digest()).decode()
        return {'ok': True, 'authentication': authentication, 'password': self.passwords[port]}


class SecureHTTPTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='nrc-secure-docks-test-')
        self.root = Path(self.temporary.name)
        for name in ('07_AUTOMATION', '08_LAYOUT_DOCK', 'shared', 'native'):
            (self.root / name).mkdir()
        for name in ('07_AUTOMATION/desktop-dock.html', '08_LAYOUT_DOCK/layout-dock.html', 'shared/keychain-client.js', 'shared/site.css', 'shared/image.svg'):
            (self.root / name).write_text('Synthetic static asset only.', encoding='utf-8')
        for name in ('root-private.js', 'native/keychain-tool', 'native/keychain-tool.m', 'native/debug.js', 'secure-docks.py', 'shared/private.json', 'shared/private.txt'):
            (self.root / name).write_text('PRIVATE TEST CONTENT', encoding='utf-8')
        self.keychain = FakeKeychain()
        self.server = SERVER.create_server(root=self.root, port=0, keychain=self.keychain)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.host = self.server.allowed_host
        self.origin = 'http://' + self.host

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.temporary.cleanup()

    def request(self, method='POST', path='/api/status', data=None, headers=None, raw_body=None):
        body = raw_body if raw_body is not None else json.dumps({'port': 4455} if data is None else data).encode()
        if method in ('GET', 'OPTIONS') and raw_body is None:
            body = b''
        base_headers = [('Host', self.host)]
        if method == 'POST':
            base_headers += [('Origin', self.origin), ('X-NRC-Dock', '1'), ('Content-Type', 'application/json'), ('Content-Length', str(len(body)))]
        if headers is not None:
            replaced = {key.lower() for key, value in headers}
            base_headers = [(key, value) for key, value in base_headers if key.lower() not in replaced]
            base_headers += [(key, value) for key, value in headers if value is not None]
        connection = http.client.HTTPConnection('127.0.0.1', self.server.server_port, timeout=3)
        try:
            connection.putrequest(method, path, skip_host=True, skip_accept_encoding=True)
            for key, value in base_headers:
                connection.putheader(key, value)
            connection.endheaders(body)
            response = connection.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            connection.close()

    def assert_rejected(self, expected, **kwargs):
        before = len(self.keychain.calls)
        status, _, _ = self.request(**kwargs)
        self.assertEqual(status, expected)
        self.assertEqual(len(self.keychain.calls), before, 'Rejected request reached the native helper')

    def test_loopback_only_and_exact_host(self):
        self.assertEqual(self.server.server_address[0], '127.0.0.1')
        for host in ('localhost:' + str(self.server.server_port), '127.0.0.1', self.host + '.evil.test', 'evil.test', self.host.upper() + ' '):
            with self.subTest(host=host):
                self.assert_rejected(403, headers=[('Host', host)])
        self.assert_rejected(403, headers=[('Host', None)])
        self.assert_rejected(403, headers=[('Host', self.host), ('Host', self.host)])

    def test_origin_is_exact_required_and_not_null(self):
        for origin in (None, 'null', 'https://' + self.host, 'http://localhost:' + str(self.server.server_port), self.origin + '/', 'https://evil.test'):
            with self.subTest(origin=origin):
                self.assert_rejected(403, headers=[('Origin', origin)])
        self.assert_rejected(403, headers=[('Origin', self.origin), ('Origin', self.origin)])

    def test_custom_header_exact_required(self):
        for value in (None, '0', 'true', '1, 1'):
            with self.subTest(value=value):
                self.assert_rejected(403, headers=[('X-NRC-Dock', value)])
        self.assert_rejected(403, headers=[('X-NRC-Dock', '1'), ('X-NRC-Dock', '1')])

    def test_cross_site_and_same_site_posts_rejected(self):
        for value in ('cross-site', 'same-site', 'none', 'null'):
            with self.subTest(value=value):
                self.assert_rejected(403, headers=[('Sec-Fetch-Site', value)])
        status, _, _ = self.request(headers=[('Sec-Fetch-Site', 'same-origin')])
        self.assertEqual(status, 200)

    def test_cors_preflight_rejected_and_never_enabled(self):
        status, headers, _ = self.request(method='OPTIONS', headers=[('Origin', 'https://evil.test'), ('Access-Control-Request-Method', 'POST')])
        self.assertEqual(status, 403)
        self.assertFalse(any(key.lower().startswith('access-control-') for key in headers))

    def test_request_length_validation(self):
        for value in (None, '', '0', '-1', '+1', '1.0', 'banana', str(SERVER.MAX_BODY + 1)):
            with self.subTest(length=value):
                self.assert_rejected(413, headers=[('Content-Length', value)])
        self.assert_rejected(413, headers=[('Content-Length', '14'), ('Content-Length', '14')])

    def test_overlong_decimal_length_is_rejected_without_exception(self):
        self.assert_rejected(413, headers=[('Content-Length', '9' * 5000)])

    def test_transfer_encoding_and_non_json_rejected(self):
        self.assert_rejected(415, headers=[('Transfer-Encoding', 'chunked')])
        self.assert_rejected(415, headers=[('Content-Type', 'text/plain')])

    def test_malformed_json_invalid_utf8_and_non_objects_rejected(self):
        for value in (b'{', b'null', b'[]', b'"text"', b'\xff', b'{"port":NaN}', b'{"port":Infinity}'):
            with self.subTest(body=value):
                self.assert_rejected(400, raw_body=value)

    def test_deeply_nested_json_is_rejected_without_exception(self):
        self.assert_rejected(400, raw_body=b'[' * 2000 + b']' * 2000)

    def test_port_validation_and_extra_fields(self):
        for port in (0, 65536, -1, True, False, None, 4455.0, '4455'):
            with self.subTest(port=port):
                self.assert_rejected(400, data={'port': port})
        self.assert_rejected(400, data={'port': 4455, 'password': 'should-not-be-here'})
        self.assert_rejected(400, data={})

    def test_password_and_challenge_byte_limits(self):
        for password in ('', None, 1, 'x' * 4097, 'ß' * 2049):
            with self.subTest(password_type=type(password).__name__):
                self.assert_rejected(400, path='/api/save', data={'port': 4455, 'password': password})
        for key in ('salt', 'challenge'):
            for value in ('', None, 1, 'x' * 1025, 'ß' * 513):
                with self.subTest(key=key, value_type=type(value).__name__):
                    data = {'port': 4455, 'salt': 'salt', 'challenge': 'challenge', key: value}
                    self.assert_rejected(400, path='/api/auth', data=data)

    def test_shared_saved_credentials_by_port_and_forget(self):
        status, _, body = self.request()
        self.assertEqual((status, json.loads(body)), (200, {'saved': False}))
        status, _, body = self.request(path='/api/save', data={'port': 4455, 'password': SYNTHETIC_PASSWORD})
        self.assertEqual((status, json.loads(body)), (200, {'saved': True}))
        status, _, body = self.request(headers=[('Referer', self.origin + '/08_LAYOUT_DOCK/layout-dock.html')])
        self.assertEqual((status, json.loads(body)), (200, {'saved': True}))
        status, _, body = self.request(data={'port': 4456})
        self.assertEqual((status, json.loads(body)), (200, {'saved': False}))
        status, _, body = self.request(path='/api/auth', data={'port': 4455, 'salt': 'salt', 'challenge': 'challenge'})
        self.assertEqual(status, 200)
        self.assertEqual(set(json.loads(body)), {'authentication'})
        self.assertEqual(len(base64.b64decode(json.loads(body)['authentication'])), 32)
        self.assertNotIn(SYNTHETIC_PASSWORD.encode(), body)
        status, _, body = self.request(path='/api/forget')
        self.assertEqual((status, json.loads(body)), (200, {'saved': False}))
        status, _, body = self.request()
        self.assertEqual((status, json.loads(body)), (200, {'saved': False}))

    def test_native_success_extra_fields_not_returned(self):
        self.keychain.override = {'ok': True, 'saved': True, 'password': SYNTHETIC_PASSWORD, 'raw': SYNTHETIC_PASSWORD}
        status, _, body = self.request()
        self.assertEqual((status, json.loads(body)), (200, {'saved': True}))
        self.assertNotIn(SYNTHETIC_PASSWORD.encode(), body)

    def test_native_error_text_cannot_echo_credentials(self):
        self.keychain.override = {'ok': False, 'error': 'keychain_unavailable', 'message': SYNTHETIC_PASSWORD}
        status, _, body = self.request()
        self.assertEqual(status, 409)
        self.assertNotIn(SYNTHETIC_PASSWORD.encode(), body)
        self.assertNotIn(SYNTHETIC_PASSWORD, json.loads(body)['error'])

    def test_unavailable_timeout_and_bad_helper_output(self):
        for failure in (FileNotFoundError('synthetic missing helper'), ValueError('synthetic invalid JSON'), subprocess.TimeoutExpired('synthetic-helper', 30)):
            with self.subTest(failure=type(failure).__name__):
                self.keychain.failure = failure
                status, _, body = self.request()
                self.assertEqual(status, 503)
                self.assertNotIn(str(failure), body.decode())
        self.keychain.failure = None
        for response in ({}, {'saved': 'yes'}, {'saved': 1}):
            with self.subTest(response=response):
                self.keychain.override = response
                status, _, _ = self.request()
                self.assertEqual(status, 503)
        self.keychain.override = {'authentication': 'too short'}
        status, _, _ = self.request(path='/api/auth', data={'port': 4455, 'salt': 'salt', 'challenge': 'challenge'})
        self.assertEqual(status, 503)

    def test_unknown_api_and_get_cannot_operate_keychain(self):
        self.assert_rejected(404, path='/api/status?port=4455')
        self.assert_rejected(404, path='/api/unknown')
        self.assert_rejected(404, method='GET', path='/api/status')

    def test_allowed_assets_and_security_headers(self):
        for path in ('/', '/07_AUTOMATION/desktop-dock.html', '/08_LAYOUT_DOCK/layout-dock.html', '/shared/keychain-client.js', '/shared/site.css', '/shared/image.svg'):
            with self.subTest(path=path):
                status, headers, _ = self.request(method='GET', path=path)
                self.assertEqual(status, 200)
                self.assertEqual(headers.get('Cache-Control'), 'no-store')
                self.assertEqual(headers.get('X-Content-Type-Options'), 'nosniff')
                self.assertEqual(headers.get('X-Frame-Options'), 'DENY')
                self.assertIn("default-src 'none'", headers.get('Content-Security-Policy', ''))
                self.assertFalse(any(key.lower().startswith('access-control-') for key in headers))

    def test_native_source_binary_and_non_assets_not_exposed(self):
        for path in ('/secure-docks.py', '/native/keychain-tool', '/native/keychain-tool.m', '/native/debug.js', '/shared/private.json', '/shared/private.txt', '/root-private.js', '/shared/'):
            with self.subTest(path=path):
                status, _, body = self.request(method='GET', path=path)
                self.assertEqual(status, 404)
                self.assertNotIn(b'PRIVATE TEST CONTENT', body)

    def test_traversal_cannot_escape_asset_directory(self):
        for path in ('/shared/../root-private.js', '/shared/%2e%2e/root-private.js', '/shared/../native/debug.js', '/shared/%2e%2e/native/debug.js', '/shared/../../etc/passwd', '/shared/%2f..%2froot-private.js'):
            with self.subTest(path=path):
                status, _, body = self.request(method='GET', path=path)
                self.assertEqual(status, 404)
                self.assertNotIn(b'PRIVATE TEST CONTENT', body)

    def test_symlink_cannot_escape_asset_directory(self):
        (self.root / 'shared' / 'private-link.js').symlink_to(self.root / 'root-private.js')
        status, _, body = self.request(method='GET', path='/shared/private-link.js')
        self.assertEqual(status, 404)
        self.assertNotIn(b'PRIVATE TEST CONTENT', body)

    def test_cross_site_get_rejected(self):
        self.assert_rejected(403, method='GET', path='/shared/keychain-client.js', headers=[('Sec-Fetch-Site', 'cross-site')])


if __name__ == '__main__':
    unittest.main()
