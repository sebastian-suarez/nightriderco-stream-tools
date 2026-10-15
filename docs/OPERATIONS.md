# 🛠️ Running and maintaining the toolkit

## Start and stop

`Start tools.command` starts four background web services. They remain running after Terminal closes and after OBS quits. The OBS startup Lua script checks the same services, reuses a matching page, and leaves an unrelated listener alone. No login item or LaunchAgent is installed.

Open the Husky app separately. Its paw menu provides Pause/Resume, microphone controls, and Quit. A reboot or logout stops the background services; launch them again when needed.

To stop individual web helpers without logging out, identify their listening processes:

```sh
lsof -nP -iTCP:3377 -iTCP:8765 -iTCP:17642 -iTCP:17643 -sTCP:LISTEN
```

In Activity Monitor, inspect the reported PID and command before quitting it. Only quit the processes running this installation's `server.mjs`, `secure-docks.py`, or asset HTTP server. Do not use a blanket command that kills every Node or Python process.

The startup report is `NIGHTRIDERCO-OBS-AUTOSTART/runtime/status.json`; diagnostics are in that component's `logs/`. These files belong to your installation and should not be published.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| A dock is blank or unavailable | Run `Start tools.command`; inspect the startup report; open its URL in a regular browser. |
| A port is already occupied | Identify the existing listener. Stop your old toolkit instance before starting a new version. The launcher never kills it automatically. |
| Node is missing | Install Node 22+ from nodejs.org. The launcher checks PATH, Homebrew's standard paths, and nvm installations. |
| `/usr/bin/python3` is missing | Install Apple's Command Line Tools with `xcode-select --install`. |
| WebSocket authentication fails | Enable OBS's WebSocket server and authentication; enter the current password in a secure dock; unlock the login Keychain if prompted. |
| Resolution cannot connect | Open OBS; enable its WebSocket server; check that OBS has saved its current configuration. The helper reads that user's local OBS config. |
| Camera Switch says sources are missing | Use the exact scene and source names in [OBS setup](OBS-SETUP.md). The dock does not create sources. |
| Typing buddy is blank | Open `Husky Typist.app`; check `http://127.0.0.1:8876/preview.html`; keep `web/` beside the app. |
| Typing/voice does not react | Enable Input Monitoring/microphone in the paw menu and macOS settings. Reopen the app if macOS requests it. Secure Input can suppress typing activity. |
| Studio Display is unavailable | Connect the display, allow OBS Screen Recording, select the actual capture source, and refresh display detection. Generic external-monitor matching is not validated. |
| Limit Reset says SET RESET TIME | Set `resetAt` in its `config.js` to the newly observed deadline, including date and offset. Refresh the Browser Source afterward. |
| Theme or frames are absent | Select Yami/NIGHTRIDERCO and restart OBS after outputs stop. The extension intentionally stays inactive on unsupported OBS/Qt versions. |

For helper startup delays, the original local retry pages are included under `NIGHTRIDERCO-OBS-AUTOSTART/docks/`. You can use the corresponding `file://` URL as the Custom Browser Dock URL; it waits for the service and redirects to the normal HTTP dock. Use the local file's full path, with spaces URL-encoded. These pages do not start the service themselves.

## Update or move an installation

1. Stop streaming/recording, export a backup of the scene collection in OBS, and keep your existing installation.
2. Download the new repository version and install it into a **new destination that does not exist yet**, for example `~/Documents/NIGHTRIDERCO-TOOLS-v2`. Its parent folder must already exist.
3. Copy intentional configuration edits such as Limit Reset's new deadline or artwork settings into the new version. Do not copy `runtime`, logs, snapshots, or credentials into the repository.
4. Stop the old web helpers and quit Husky. The readiness check compares the landing page; it cannot prove that an older matching server is serving the new version's other files.
5. In OBS, remove the old startup Lua script, add the new one, and update the Desktop Auto/Scene Layout script paths and local Browser Source/media paths. Check the asset-folder setting on Desktop Auto.
6. Start the new helpers, reopen Husky, and complete the OBS acceptance checklist before broadcasting. Re-signing or moving native helpers may require macOS permission or Keychain approval again.
7. Keep the previous folder until the new setup works. To roll back, stop the new helpers and restore the previous script/source paths and saved scene collection.

A repeated installer run against the same unchanged package is a verification/no-op. Edited `config.js` files are preserved and reported. Other changes or unowned files require a new destination; the installer does not merge or delete your work.

## Remove

1. Stop outputs and remove the toolkit's Lua scripts and Custom Browser Docks from OBS.
2. Remove or relink its scene sources before deleting the referenced files.
3. Quit the Husky helper and stop the four web services as above.
4. Move the installed toolkit folder to Trash. The repository checkout can be removed separately.
5. For optional styling, remove `NIGHTRIDERCO.ovt` from `~/Library/Application Support/obs-studio/themes/` and `nightrider-panel-frames.plugin` from `~/Library/Application Support/obs-studio/plugins/` with OBS closed. Restore any backups you made before replacing an existing theme or extension.

Removing files does not erase Keychain items. Use **Forget saved password** in a dock before removal if you want to erase its stored OBS password. An already authenticated OBS connection can remain valid until disconnected. Existing LaunchAgents from older standalone packages are outside this installer's ownership; review and remove those separately if migrating from that setup.
