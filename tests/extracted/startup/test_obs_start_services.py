import contextlib
import fcntl
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock


HELPER = Path(__file__).resolve().parents[3] / 'payload/NIGHTRIDERCO-OBS-AUTOSTART/start-services.py'
spec = importlib.util.spec_from_file_location('obs_start_services', HELPER)
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)


class ServiceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='nrc-startup-test-')
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        self.identity = self.folder / 'identity.html'
        self.identity.write_bytes(b'<title>correct local fixture</title>')
        self.spec = {
            'port': 9999, 'url': 'http://127.0.0.1:9999/identity.html',
            'identity': self.identity, 'cwd': self.folder,
            'command': ['fixture-server', '--start'],
        }
        self.state = {'ready': False, 'started': False}

    def test_ready_service_is_reused_without_launch(self):
        with mock.patch.object(helper, 'probe', return_value=(True, True)), \
                mock.patch.object(helper.subprocess, 'Popen') as launch:
            helper.ensure_service('assets', self.spec, self.state, self.folder)
        launch.assert_not_called()
        self.assertEqual(self.state, {'ready': True, 'started': False})

    def test_wrong_listener_is_rejected_without_launch(self):
        with mock.patch.object(helper, 'probe', return_value=(True, False)), \
                mock.patch.object(helper.subprocess, 'Popen') as launch:
            with self.assertRaisesRegex(RuntimeError, 'already occupied'):
                helper.ensure_service('assets', self.spec, self.state, self.folder)
        launch.assert_not_called()
        self.assertFalse(self.state['ready'])

    def test_new_service_detaches_and_waits_until_identity_matches(self):
        process = mock.Mock(pid=12345)
        process.poll.return_value = None
        with mock.patch.object(helper, 'probe', side_effect=[(False, False), (True, False), (True, True)]), \
                mock.patch.object(helper.subprocess, 'Popen', return_value=process) as launch, \
                mock.patch.object(helper.time, 'sleep'):
            helper.ensure_service('chat', self.spec, self.state, self.folder)
        self.assertEqual(self.state, {'ready': True, 'started': True, 'pid': 12345})
        args, kwargs = launch.call_args
        self.assertEqual(args[0], self.spec['command'])
        self.assertEqual(kwargs['cwd'], str(self.folder))
        self.assertEqual(kwargs['env']['NRC_CHAT_PORT'], '9999')
        self.assertTrue(kwargs['start_new_session'])
        self.assertTrue(kwargs['close_fds'])
        self.assertEqual(kwargs['stdin'], helper.subprocess.DEVNULL)
        self.assertEqual(kwargs['stderr'], helper.subprocess.STDOUT)

    def test_exited_launcher_reports_log_path(self):
        process = mock.Mock(pid=12345)
        process.poll.return_value = 1
        with mock.patch.object(helper, 'probe', return_value=(False, False)), \
                mock.patch.object(helper.subprocess, 'Popen', return_value=process):
            with self.assertRaisesRegex(RuntimeError, 'exited with code 1; see .*chat.log'):
                helper.ensure_service('chat', self.spec, self.state, self.folder)

    def test_http_probe_compares_exact_fixture_bytes(self):
        response = mock.MagicMock(status=200)
        response.__enter__.return_value = response
        with mock.patch.object(helper.socket, 'create_connection', return_value=contextlib.nullcontext()), \
                mock.patch.object(helper.HTTP, 'open', return_value=response):
            response.read.return_value = self.identity.read_bytes()
            self.assertEqual(helper.probe(self.spec, self.identity.read_bytes()), (True, True))
            response.read.return_value = b'<title>unrelated service</title>'
            self.assertEqual(helper.probe(self.spec, self.identity.read_bytes()), (True, False))

    def test_refused_connection_is_free_but_permission_failure_is_an_error(self):
        with mock.patch.object(helper.socket, 'create_connection', side_effect=ConnectionRefusedError()):
            self.assertEqual(helper.probe(self.spec, b'fixture'), (False, False))
        with mock.patch.object(helper.socket, 'create_connection', side_effect=PermissionError('denied')):
            with self.assertRaisesRegex(RuntimeError, 'Cannot check local port'):
                helper.probe(self.spec, b'fixture')

    def test_status_includes_started_and_is_atomic(self):
        path = self.folder / 'status.json'
        value = {'ok': True, 'services': {'assets': {'started': False}, 'chat': {'started': True}}}
        helper.save_status(path, value)
        result = json.loads(path.read_text())
        self.assertTrue(result['started'])
        self.assertTrue(result['updated_at'].endswith('+00:00'))
        self.assertFalse((self.folder / 'status.json.tmp').exists())

    def test_lock_busy_leaves_existing_status_intact(self):
        runtime = self.folder / 'runtime'
        runtime.mkdir()
        status = runtime / 'status.json'
        status.write_text('existing status')
        with (runtime / 'startup.lock').open('a') as lock, \
                mock.patch.object(helper, 'PACKAGE', self.folder), \
                mock.patch.object(helper, 'service_specs') as specs, \
                contextlib.redirect_stdout(io.StringIO()) as output:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertEqual(helper.main(['--status-file', str(status)]), 0)
        specs.assert_not_called()
        self.assertEqual(status.read_text(), 'existing status')
        self.assertTrue(json.loads(output.getvalue())['busy'])

    def test_one_conflict_does_not_prevent_other_service_check(self):
        def ensure(name, spec, state, logs):
            if name == 'assets':
                raise RuntimeError('port conflict fixture')
            state['ready'] = True

        status = self.folder / 'status.json'
        with mock.patch.object(helper, 'PACKAGE', self.folder), \
                mock.patch.object(helper, 'service_specs', return_value={'assets': self.spec, 'chat': self.spec}), \
                mock.patch.object(helper, 'ensure_service', side_effect=ensure) as checked, \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(helper.main(['--status-file', str(status)]), 1)
        result = json.loads(status.read_text())
        self.assertEqual(checked.call_count, 2)
        self.assertEqual(result['state'], 'error')
        self.assertIn('port conflict fixture', result['message'])
        self.assertTrue(result['services']['chat']['ready'])

    def test_missing_prerequisites_save_error_status_without_launching_services(self):
        cases = (
            ('node', RuntimeError('Install Node.js 22 or newer before starting the tools.'), 'Install Node.js 22'),
            ('keychain helper', None, 'Missing executable SecureDocks/native/keychain-tool'),
        )
        status = self.folder / 'obs-status.json'
        for name, node_error, expected_message in cases:
            with self.subTest(prerequisite=name):
                status.write_text(json.dumps({'ok': True, 'state': 'ready', 'services': {}}))
                with mock.patch.object(helper, 'PACKAGE', self.folder), \
                        mock.patch.object(helper, 'node_runtime', return_value='/fixture/node', side_effect=node_error), \
                        mock.patch.object(helper.os, 'access', return_value=False), \
                        mock.patch.object(helper, 'ensure_service') as checked, \
                        mock.patch.object(helper.subprocess, 'Popen') as launch, \
                        contextlib.redirect_stdout(io.StringIO()) as output:
                    self.assertEqual(helper.main(['--status-file', str(status)]), 1)
                checked.assert_not_called()
                launch.assert_not_called()
                result = json.loads(status.read_text())
                self.assertFalse(result['ok'])
                self.assertFalse(result['started'])
                self.assertEqual(result['state'], 'error')
                self.assertEqual(result['services'], {})
                self.assertIn(expected_message, result['message'])
                self.assertTrue(result['updated_at'].endswith('+00:00'))
                self.assertEqual(json.loads(output.getvalue()), result)
                self.assertFalse(status.with_name(status.name + '.tmp').exists())


if __name__ == '__main__':
    unittest.main()
