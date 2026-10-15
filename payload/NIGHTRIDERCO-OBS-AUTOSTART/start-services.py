#!/usr/bin/env python3
"""Start the local NIGHTRIDERCO services once when OBS loads its script."""

import argparse
import datetime
import fcntl
import json
import logging
import os
from pathlib import Path
import socket
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request


PACKAGE = Path(__file__).resolve().parent
INSTALL = PACKAGE.parent
ASSETS = INSTALL / "NIGHTRIDERCO"
CHAT = INSTALL / "NIGHTRIDERCO-CHAT"
SECURE = INSTALL / "SecureDocks"
RESOLUTION = INSTALL / "NIGHTRIDERCO-Resolution-Dock"
READY_TIMEOUT = 10.0
HTTP = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def node_runtime():
    candidates = [shutil.which("node"), "/opt/homebrew/bin/node", "/usr/local/bin/node"]
    candidates += [str(p) for p in sorted((Path.home() / ".nvm/versions/node").glob("*/bin/node"), reverse=True)]
    for candidate in candidates:
        if not candidate or not Path(candidate).is_file():
            continue
        try:
            result = subprocess.run([candidate, "-e", "process.exit(Number(process.versions.node.split('.')[0]) >= 22 ? 0 : 1)"],
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
            if result.returncode == 0:
                return candidate
        except (OSError, subprocess.TimeoutExpired):
            continue
    raise RuntimeError("Install Node.js 22 or newer from nodejs.org before starting the tools.")


def service_specs():
    node = node_runtime()
    if not os.access(SECURE / "native/keychain-tool", os.X_OK):
        raise RuntimeError("Missing executable SecureDocks/native/keychain-tool. Reinstall the package or build it with native/build.sh.")
    return {
        "assets": {
            "port": 8765,
            "url": "http://127.0.0.1:8765/03_OBS/alerts.html",
            "identity": ASSETS / "03_OBS/alerts.html",
            "cwd": ASSETS,
            "command": [sys.executable, "-m", "http.server", "8765", "--bind", "127.0.0.1"],
        },
        "chat": {
            "port": 3377,
            "url": "http://127.0.0.1:3377/overlay.html",
            "identity": CHAT / "public/overlay.html",
            "cwd": CHAT,
            "command": [node, str(CHAT / "server.mjs")],
        },
        "secure": {
            "port": 17642,
            "url": "http://127.0.0.1:17642/shared/camera-switch.html",
            "identity": SECURE / "shared/camera-switch.html",
            "cwd": SECURE,
            "command": [sys.executable, str(SECURE / "secure-docks.py")],
        },
        "resolution": {
            "port": 17643,
            "url": "http://127.0.0.1:17643/",
            "identity": RESOLUTION / "dock.html",
            "cwd": RESOLUTION,
            "command": [node, str(RESOLUTION / "server.mjs")],
        },
    }


def probe(spec, expected):
    """Return (listening, matching), never accepting an unrelated server."""
    try:
        with socket.create_connection(("127.0.0.1", spec["port"]), timeout=0.75):
            pass
    except ConnectionRefusedError:
        return False, False
    except OSError as error:
        raise RuntimeError("Cannot check local port {}: {}".format(spec["port"], error)) from error
    try:
        with HTTP.open(spec["url"], timeout=1.0) as response:
            return True, response.status == 200 and response.read(len(expected) + 1) == expected
    except (OSError, urllib.error.URLError):
        return True, False


def ensure_service(name, spec, state, logs):
    expected = spec["identity"].read_bytes()
    listening, matching = probe(spec, expected)
    if matching:
        state["ready"] = True
        logging.info("%s: reusing the matching service on port %s", name, spec["port"])
        return
    if listening:
        raise RuntimeError(
            "Port {} is already occupied, but {} does not match the local {} file. "
            "The existing process was left running; see {}."
            .format(spec["port"], spec["url"], name, logs / (name + ".log"))
        )

    env = os.environ.copy()
    if name == "chat":
        env["NRC_CHAT_PORT"] = str(spec["port"])
    log_path = logs / (name + ".log")
    with log_path.open("ab", buffering=0) as output:
        process = subprocess.Popen(
            spec["command"], cwd=str(spec["cwd"]), env=env,
            stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.STDOUT,
            close_fds=True, start_new_session=True,
        )
    state.update(started=True, pid=process.pid)
    logging.info("%s: started PID %s; output is in %s", name, process.pid, log_path)
    deadline = time.monotonic() + READY_TIMEOUT
    while time.monotonic() < deadline:
        _, matching = probe(spec, expected)
        if matching:
            state["ready"] = True
            logging.info("%s: ready at %s", name, spec["url"])
            return
        result = process.poll()
        if result is not None:
            raise RuntimeError("{} exited with code {}; see {}".format(name, result, log_path))
        time.sleep(0.2)
    raise RuntimeError("{} was not ready after {} seconds; see {}".format(name, READY_TIMEOUT, log_path))


def save_status(path, status):
    status["updated_at"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    status["started"] = any(service["started"] for service in status["services"].values())
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(status, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--status-file", type=Path, default=PACKAGE / "runtime/status.json")
    args = parser.parse_args(argv)
    runtime = PACKAGE / "runtime"
    logs = PACKAGE / "logs"
    for folder in (runtime, logs, args.status_file.parent):
        folder.mkdir(parents=True, exist_ok=True)
    logging.basicConfig(
        filename=str(logs / "startup.log"), level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )
    with (runtime / "startup.lock").open("a") as lock:
        try:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            logging.info("Another startup check is already running; leaving its status intact")
            print(json.dumps({"ok": True, "busy": True, "message": "Startup check already running"}))
            return 0

        status = {
            "ok": False, "state": "starting", "message": "Starting local NIGHTRIDERCO services",
            "services": {},
        }
        save_status(args.status_file, status)
        try:
            specs = service_specs()
        except Exception as error:
            status.update(state="error", message="Local service discovery failed: {}".format(error))
            logging.error(status["message"])
            save_status(args.status_file, status)
            print(json.dumps(status))
            return 1
        status["services"] = {
            name: {"port": spec["port"], "url": spec["url"], "ready": False, "started": False}
            for name, spec in specs.items()
        }
        save_status(args.status_file, status)
        failures = []
        for name, spec in specs.items():
            try:
                ensure_service(name, spec, status["services"][name], logs)
            except Exception as error:
                message = "{}: {}".format(name, error)
                status["services"][name]["error"] = str(error)
                failures.append(message)
                logging.error(message)
            save_status(args.status_file, status)
        status.update(
            ok=not failures, state="error" if failures else "ready",
            message="; ".join(failures) if failures else "All local services are ready",
        )
        save_status(args.status_file, status)
        print(json.dumps(status))
        return 1 if failures else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        logging.error("Startup failed: %s", error)
        print(json.dumps({"ok": False, "state": "error", "message": str(error)}), file=sys.stderr)
        sys.exit(1)
