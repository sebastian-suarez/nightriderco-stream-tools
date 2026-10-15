#!/usr/bin/python3
"""Loopback-only dock host. Passwords pass to the native Keychain tool via stdin."""
import argparse
import json
import mimetypes
import re
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit, unquote

ROOT = Path(__file__).resolve().parent
PORT = 17642
MAX_BODY = 16384
ASSET_DIRS = {'07_AUTOMATION', '08_LAYOUT_DOCK', 'shared'}
ASSET_TYPES = {'.html', '.css', '.js', '.png', '.svg', '.gif'}
CSP = "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self' ws://127.0.0.1:*; img-src 'self' data:; base-uri 'none'; form-action 'none'; object-src 'none'; frame-ancestors 'none'"
INDEX = b'''<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>NIGHTRIDERCO Secure Docks</title></head><body><h1>NIGHTRIDERCO Secure Docks</h1><p>The local Keychain helper is running. Use these URLs in OBS &rarr; Docks &rarr; Custom Browser Docks:</p><ul><li><a href="/07_AUTOMATION/desktop-dock.html">Desktop Switch</a> &mdash; http://127.0.0.1:17642/07_AUTOMATION/desktop-dock.html</li><li><a href="/08_LAYOUT_DOCK/layout-dock.html">Scene Layout</a> &mdash; http://127.0.0.1:17642/08_LAYOUT_DOCK/layout-dock.html</li></ul><p>Both share the saved OBS password in your macOS login Keychain. Enter a replacement password in either dock when you change it in OBS. Forget saved password removes the shared entry.</p></body></html>'''


class NativeKeychain:
    def __init__(self, executable):
        self.executable = str(executable)
        self.lock = threading.Lock()

    def call(self, payload):
        # Serialize Keychain operations, and never use argv or logs for credentials.
        with self.lock:
            result = subprocess.run([self.executable], input=json.dumps(payload).encode(),
                                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                    timeout=30, check=False)
        response = json.loads(result.stdout)
        if not isinstance(response, dict):
            raise ValueError('Invalid native response')
        return response


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    server_version = 'NRCDocks'
    sys_version = ''

    def log_message(self, *args):
        pass  # Do not log paths, headers, or request bodies.

    def reply(self, status, body, content_type='application/json; charset=utf-8'):
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Referrer-Policy', 'no-referrer')
        self.send_header('Content-Security-Policy', CSP)
        self.send_header('X-Frame-Options', 'DENY')
        self.send_header('Connection', 'close')
        self.end_headers()
        self.close_connection = True
        self.wfile.write(body)

    def error(self, status, message):
        self.reply(status, json.dumps({'error': message}).encode())

    def trusted_host(self):
        return self.headers.get_all('Host') == [self.server.allowed_host]

    def do_GET(self):
        if not self.trusted_host():
            self.error(403, 'Local host required.'); return
        path = unquote(urlsplit(self.path).path)
        # Public dock HTML may open as a top-level navigation from the local
        # startup page. Cross-site subresources and every API remain isolated.
        public_document_navigation = (
            path in {'/07_AUTOMATION/desktop-dock.html', '/08_LAYOUT_DOCK/layout-dock.html', '/shared/camera-switch.html'}
            and self.headers.get_all('Sec-Fetch-Mode') == ['navigate']
            and self.headers.get_all('Sec-Fetch-Dest') == ['document']
        )
        if self.headers.get('Sec-Fetch-Site') == 'cross-site' and not public_document_navigation:
            self.error(403, 'Open the dock directly in OBS.'); return
        if path == '/':
            self.reply(200, INDEX, 'text/html; charset=utf-8'); return
        parts = Path(path).parts
        if len(parts) < 3 or parts[1] not in ASSET_DIRS:
            self.error(404, 'Not found.'); return
        candidate = (self.server.root / path.lstrip('/')).resolve()
        asset_root = self.server.root / parts[1]
        if not candidate.is_relative_to(asset_root) or candidate.suffix.lower() not in ASSET_TYPES or not candidate.is_file():
            self.error(404, 'Not found.'); return
        try:
            body = candidate.read_bytes()
        except OSError:
            self.error(404, 'Not found.'); return
        self.reply(200, body, mimetypes.guess_type(str(candidate))[0] or 'application/octet-stream')

    def do_POST(self):
        origin = 'http://' + self.server.allowed_host
        if not self.trusted_host() or self.headers.get_all('Origin') != [origin] or self.headers.get_all('X-NRC-Dock') != ['1']:
            self.error(403, 'Open the secure dock URL in OBS.'); return
        if self.headers.get('Sec-Fetch-Site') not in (None, 'same-origin'):
            self.error(403, 'Same-origin request required.'); return
        action = {'/api/status': 'status', '/api/save': 'save', '/api/auth': 'auth', '/api/forget': 'forget'}.get(self.path)
        if action is None:
            self.error(404, 'Not found.'); return
        if self.headers.get_content_type() != 'application/json' or self.headers.get('Transfer-Encoding') is not None:
            self.error(415, 'JSON required.'); return
        lengths = self.headers.get_all('Content-Length') or []
        if len(lengths) != 1 or not 1 <= len(lengths[0]) <= 5 or not lengths[0].isascii() or not lengths[0].isdigit() or not 1 <= int(lengths[0]) <= MAX_BODY:
            self.error(413, 'Invalid request length.'); return
        try:
            body = self.rfile.read(int(lengths[0]))
            data = json.loads(body)
            if not isinstance(data, dict) or type(data.get('port')) is not int or not 1 <= data['port'] <= 65535:
                raise ValueError()
            required = {'status': {'port'}, 'forget': {'port'}, 'save': {'port', 'password'}, 'auth': {'port', 'salt', 'challenge'}}[action]
            if set(data) != required:
                raise ValueError()
            for key in required - {'port'}:
                if not isinstance(data[key], str) or not 1 <= len(data[key].encode('utf-8')) <= (4096 if key == 'password' else 1024):
                    raise ValueError()
            data['action'] = action
        except (ValueError, UnicodeError, OSError, RecursionError):
            self.error(400, 'Invalid request.'); return
        try:
            response = self.server.keychain.call(data)
            # Explicit allowlist: even a broken native tool cannot return password bytes.
            if response.get('ok') is False:
                message = {
                    'missing_password': 'No saved OBS password. Enter it once to save it in Keychain.',
                    'keychain_locked': 'Unlock your login Keychain and connect again.',
                    'keychain_denied': 'Keychain access was denied. Allow the NIGHTRIDERCO helper to access its saved password.',
                    'invalid_request': 'Invalid Keychain request.',
                }.get(response.get('error'), 'Keychain access failed. Unlock your login Keychain and try again.')
                self.error(409, message); return
            if action == 'auth':
                authentication = response.get('authentication')
                if not isinstance(authentication, str) or re.fullmatch(r'[A-Za-z0-9+/]{43}=', authentication) is None:
                    raise ValueError()
                safe = {'authentication': authentication}
            else:
                if type(response.get('saved')) is not bool:
                    raise ValueError()
                safe = {'saved': response['saved']}
            self.reply(200, json.dumps(safe).encode())
        except (OSError, ValueError, subprocess.TimeoutExpired):
            self.error(503, 'Keychain helper is unavailable. Unlock your login Keychain and try again.')

    def do_OPTIONS(self):
        self.error(403, 'Cross-origin access is disabled.')


class DockServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 16

    def get_request(self):
        connection, address = super().get_request()
        connection.settimeout(10)
        return connection, address


def create_server(root=ROOT, port=PORT, keychain=None):
    server = DockServer(('127.0.0.1', port), Handler)
    server.root = Path(root).resolve()
    server.allowed_host = '127.0.0.1:' + str(server.server_port)
    server.keychain = keychain or NativeKeychain(server.root / 'native' / 'keychain-tool')
    return server


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='NIGHTRIDERCO local secure dock host')
    parser.add_argument('--port', type=int, default=PORT)
    args = parser.parse_args()
    with create_server(port=args.port) as server:
        server.serve_forever()
