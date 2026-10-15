# Extracted regression tests

These tests exercise the packaged source. Run the commands below from the repository root. Python 3 and Node.js 22 or later are required; the display tests additionally require LuaJIT.

The JavaScript controllers use fake OBS sockets and scene fixtures. The startup tests mock process launches, network probes and service discovery. The secure HTTP suite serves synthetic files on its own temporary loopback port and uses an in-memory Keychain substitute. None of these tests connects to OBS, uses a production service port, reads saved credentials or changes the system Keychain.

## Commands

```sh
python3 -B -m unittest discover -s tests/extracted/secure-docks -p test_secure_server.py -v
python3 -B -m unittest discover -s tests/extracted/startup -p test_obs_start_services.py -v
node tests/extracted/desktop/test-dock.cjs
node tests/extracted/desktop/test_hold_animation.cjs
node --test tests/extracted/camera/camera.test.cjs tests/extracted/layout/layout-component.test.cjs
luajit tests/extracted/desktop/test-displays.lua
```

| Scope | What it checks |
| --- | --- |
| Secure dock HTTP host | Loopback binding, exact host/origin checks, request validation, protected file handling and safe credential responses |
| Service startup | Existing service reuse, conflicting listener handling, detached startup, identity checks, atomic status and concurrent-launch locking |
| Desktop dock | OBS handshake, source metadata, selected display state, safe hotkeys, display availability and failure recovery |
| Holding screen | Opaque fallback, animation timing, language switching, reduced motion and browser lifecycle |
| Camera Switch | Webcam/typing/driving transitions, shared frame visibility and failure cases |
| Scene Layout | Placement and visibility of local Camera Switch instances at different canvas sizes |
| Display detection | Display matching, reconnection and fallback behavior using mocked OBS APIs and a synthetic monitor inventory |

The startup conflict test supplies its own two-service fixture. It does not restrict the packaged helper to two services. The tests do not validate real screen captures, microphone or input permissions, live Kick availability, or appearance inside OBS.

The desktop dock and holding-screen checks print their results. To save either result as JSON, set `NRC_TEST_REPORT_PATH` to a writable file path when running that check. They write no report by default.

Component-specific chat, Resolution and native helper tests remain beside their sources. Historical live-install scripts and native migration fixtures are excluded from this directory.
