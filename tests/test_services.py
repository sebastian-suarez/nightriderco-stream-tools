"""Smoke-test staged HTTP services on isolated ports, without connecting to OBS."""
import importlib.util
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import unittest
import urllib.request


ROOT = Path(__file__).resolve().parents[1]


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class StagedServicesTests(unittest.TestCase):
    def test_four_services_from_relocated_installation(self):
        installer = load(ROOT / "install.py", "smoke_installer")
        with tempfile.TemporaryDirectory(dir=os.path.realpath(tempfile.gettempdir())) as temporary:
            destination = Path(temporary) / "fresh tools with spaces"
            installer.stage_install(ROOT / "payload", destination)
            startup = load(destination / "NIGHTRIDERCO-OBS-AUTOSTART/start-services.py", "smoke_startup")
            specs = startup.service_specs()
            self.assertEqual(set(specs), {"assets", "chat", "secure", "resolution"})
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
            for name, spec in specs.items():
                with self.subTest(service=name):
                    self.assertTrue(spec["cwd"].is_relative_to(destination))
                    with socket.socket() as reservation:
                        reservation.bind(("127.0.0.1", 0))
                        port = reservation.getsockname()[1]
                    command = list(spec["command"])
                    env = os.environ.copy()
                    env["PYTHONDONTWRITEBYTECODE"] = "1"
                    if name == "assets":
                        command[command.index("8765")] = str(port)
                    elif name == "secure":
                        command += ["--port", str(port)]
                    else:
                        env["NRC_CHAT_PORT" if name == "chat" else "NRC_RESOLUTION_PORT"] = str(port)
                    url = spec["url"].replace(":" + str(spec["port"]) + "/", ":" + str(port) + "/")
                    expected = spec["identity"].read_bytes()
                    with tempfile.TemporaryFile() as output:
                        process = subprocess.Popen(command, cwd=spec["cwd"], env=env,
                                                   stdin=subprocess.DEVNULL, stdout=output, stderr=output)
                        try:
                            deadline = time.monotonic() + 10
                            while True:
                                try:
                                    with opener.open(url, timeout=0.5) as response:
                                        self.assertEqual(response.read(), expected)
                                    break
                                except (OSError, urllib.error.URLError):
                                    if process.poll() is not None or time.monotonic() > deadline:
                                        output.seek(0)
                                        self.fail(f"{name} failed to serve its staged page: {output.read().decode(errors='replace')}")
                                    time.sleep(0.05)
                        finally:
                            process.terminate()
                            try:
                                process.wait(timeout=5)
                            except subprocess.TimeoutExpired:
                                process.kill()
                                process.wait()
            self.assertEqual(installer.stage_install(ROOT / "payload", destination, verify=True)["status"], "verified")


if __name__ == "__main__":
    unittest.main()
