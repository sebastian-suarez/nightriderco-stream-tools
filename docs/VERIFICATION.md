# 🧪 Package verification

Validation performed on an Apple silicon Mac with Node 24.21.0, Python 3.9, LuaJIT, Xcode 27, and the OBS 32.2.2 / Qt 6.11.1 build environment. Tests ran against the extracted package, not the original application folders.

| Check | Result |
| --- | --- |
| Installer filesystem acceptance | 22 tests passed: dry run, atomic staging, repeat, config preservation, runtime additions, collisions, symlink refusal, tamper detection, and failed-copy cleanup |
| Full payload in a new path containing spaces | Dry run, installation, repeated install, integrity verification, and installed native signatures passed |
| Four staged web services | Assets, chat, secure docks, and Resolution each served their exact staged page on an isolated temporary port; post-run installation verification passed |
| Startup regression suite | 10 tests passed using mocked process launches and network probes, including missing prerequisite error reporting |
| Secure HTTP bridge | 22 tests passed with a fake Keychain and ephemeral loopback server |
| Chat, Resolution, Keychain client, Camera Switch, Scene Layout | 87 Node tests passed |
| Desktop Switch controller | 26 checks passed |
| Capture holding-screen behavior | 14 checks passed |
| Display inventory and reconnection | 11 LuaJIT checks passed using mocked OBS APIs |
| Husky native helper | Packaged source compiled for arm64/macOS 13; shipped and rebuilt helpers passed the synthetic self-test without microphone/input capture; packaged and installed signatures verified |
| Native Keychain helper | Rebuilt for arm64/macOS 13, signature verified, and 43 checks passed using a temporary isolated Keychain; the real login Keychain was not accessed by tests |
| StreamMenuBar | Packaged Xcode project built successfully with local ad-hoc signing; app not launched for a live account test |
| Panel Frames | Clean source build and Cocoa native fixture passed; zero video-surface destructions in the fixture; extracted distribution signature verified |

The full HTTP suites require permission to bind temporary loopback ports. Xcode compilation and the native fixture require normal macOS compiler/window access. Initial sandbox failures were rerun with those capabilities; they are not counted as successful tests.

The panel fixture's initial queued-layout check was made timing-tolerant after a reproducible race. A bounded one-second wait preserves the original assertion; the plugin runtime is unchanged. Ten consecutive fixture runs and a separate final run passed after this test-only correction.

## Re-run the portable checks

From the repository root:

```sh
python3 -B -m unittest discover -s tests -p 'test_*.py' -v
python3 -B -m unittest discover -s tests/extracted/startup -p 'test_*.py' -v
python3 -B -m unittest discover -s tests/extracted/secure-docks -p 'test_*.py' -v
node --test payload/NIGHTRIDERCO-CHAT/tests/*.test.mjs \
  payload/NIGHTRIDERCO-Resolution-Dock/tests/*.test.mjs \
  payload/NIGHTRIDERCO/07_AUTOMATION/tests/*.cjs \
  tests/extracted/camera/*.cjs tests/extracted/layout/*.cjs
node tests/extracted/desktop/test-dock.cjs
node tests/extracted/desktop/test_hold_animation.cjs
luajit tests/extracted/desktop/test-displays.lua
```

The four-service smoke test requires Node and a system that permits local sockets. It stages a temporary copy, fetches static pages only, and terminates its own processes. It does not call Resolution's OBS endpoints or the secure bridge's real credential APIs.

See [extracted test scopes](../tests/extracted/README.md) and [native build instructions](OPTIONAL.md) for details. The native panel fixture leaves its preview window open; after it writes `source/evidence/native-lifecycle.json`, inspect the result and close the fixture.

## Not established by these tests

- A complete clean-Mac installation with real camera, screen-capture permissions, audio, and scene composition.
- Current live Kick chat availability or StreamMenuBar OAuth/viewer polling after its scope fix.
- Real steering-wheel telemetry; the driving animation is deliberately simulated.
- Panel Frames' actual GPU appearance in OBS, or compatibility with any other OBS/Qt version.
- Windows/Linux support or arbitrary external-monitor detection.

Use the off-air acceptance checklist in [OBS-SETUP.md](OBS-SETUP.md) on each new installation. Historical verification reports and personal screenshots are excluded from the public package.
