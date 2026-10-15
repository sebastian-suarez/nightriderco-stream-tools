# 🐺 NIGHTRIDERCO Stream Tools

The NIGHTRIDERCO × Skadi streaming toolkit: OBS controls, animated overlays, local Kick chat, reactive mascots, a matching theme, and a macOS menu-bar companion.

This repository gathers the latest available versions from the project's streaming sessions. It includes editable source and artwork. The installation package targets **macOS on Apple silicon**; fresh OBS scenes and device permissions are configured using the steps below.

## 🧰 What's included

| Tool | Purpose | Location |
| --- | --- | --- |
| Desktop Auto + Desktop Switch | Adapt one scene to the MacBook or Studio Display; refresh monitor detection | `payload/NIGHTRIDERCO/07_AUTOMATION` |
| Scene Layout | Move camera and chat independently in Workshop and Gameplay | `payload/NIGHTRIDERCO/08_LAYOUT_DOCK` |
| Camera Switch | Select Webcam, Typing buddy, or Driving buddy through one reusable scene | `payload/SecureDocks/shared` |
| Resolution | Switch FHD/QHD layouts with output checks and undo | `payload/NIGHTRIDERCO-Resolution-Dock` |
| Secure docks | Local dock server and macOS Keychain authentication bridge | `payload/SecureDocks` |
| Local startup | Start and reuse the four local web services when OBS loads its script | `payload/NIGHTRIDERCO-OBS-AUTOSTART` |
| Kick Chat Studio | Local chat controls and transparent Community/Minimal overlays | `payload/NIGHTRIDERCO-CHAT` |
| Husky Typist | Typing, pointer, scrolling, and microphone-level reactions | `payload/NIGHTRIDERCO-HUSKY` |
| Driving buddy | Logitech RS50 artwork with simulated steering | `payload/NIGHTRIDERCO-HUSKY-SIMRACING` |
| Limit Reset | Dancing chibi husky, chat space, Bogotá clock, and configurable countdown | `payload/NIGHTRIDERCO-LIMIT-RESET` |
| Channel and stream assets | Brand files, bilingual scenes, overlays, alerts, sounds, panels, emotes, badges, and social templates | `payload/NIGHTRIDERCO/01_BRAND` through `06_AUDIO` |
| OBS theme + Panel Frames | Matching native OBS styling and optional rounded video-panel frames | `extras/obs-theme`, `extras/panel-frames` |
| StreamMenuBar | Editable macOS app for local OBS bitrate and Kick integration | `extras/StreamMenuBar` |

See [component and session coverage](docs/COVERAGE.md) for version choices and exclusions.

## ✅ Requirements

- An **Apple silicon Mac**. The bundled Husky helper targets macOS 13 or newer. Your OBS version may require a newer macOS release.
- [OBS Studio](https://obsproject.com/download) with Browser Sources, Lua scripting, and its built-in WebSocket server. The source setup was developed with **OBS 32.2.2**.
- [Node.js](https://nodejs.org/en/download) **22 or newer**; Node 24 is the tested runtime. The Node services use built-in modules and need no `npm install`.
- Python **3.9 or newer**, plus Apple's Command Line Tools (`xcode-select --install`). The OBS startup Lua script invokes `/usr/bin/python3`, supplied by those tools.
- Free local ports: **3377, 8765, 8876, 17642, 17643**.

StreamMenuBar is optional and has separate **Xcode 27 / macOS 27** requirements. Panel Frames is optional and supports **only OBS 32.2.2 + bundled Qt 6.11.1 + arm64**. See [optional components](docs/OPTIONAL.md).

## 📦 1. Download and install the files

Download this repository with GitHub's **Code → Download ZIP**, extract it, and open Terminal in the extracted folder. If using Git, clone the repository and enter its folder instead.

Preview the installation:

```sh
python3 install.py --dry-run
```

Install:

```sh
python3 install.py
```

The default destination is **`~/Documents/NIGHTRIDERCO-TOOLS`**. For a new installation, the destination must not exist yet, and its parent folder must already exist. To choose another location:

```sh
python3 install.py --destination "$HOME/Documents/My Stream Tools"
```

The installer copies the toolkit and records file checksums. It does **not** import a personal OBS profile, change scenes, start services, or copy credentials. It refuses an unrelated existing destination. For an upgrade with changed package files, install into a new folder, then follow [updating and removal](docs/OPERATIONS.md).

Verify an installation:

```sh
python3 install.py --verify
# For a custom destination, add the same --destination argument.
```

## 🚀 2. Start the tools

Open **`Start tools.command` inside the installed folder**. It starts the asset, chat, secure-dock, and resolution servers. Repeated starts reuse matching servers and refuse unrelated processes on the same ports.

Open **`NIGHTRIDERCO-HUSKY/Husky Typist.app`** separately to enable the live typing buddy. Keep its sibling `web` folder beside it; that folder contains the current artwork.

Use the paw menu to enable Input Monitoring and, if wanted, the microphone. These permissions belong to the helper separately from OBS. Typing activity and microphone level drive the animation; typed characters and audio recordings are not collected.

The helpers are locally signed and not notarized. If macOS blocks an app you intentionally downloaded, use its normal **Privacy & Security → Open Anyway** flow. Do not disable Gatekeeper system-wide.

Open Chat Studio at **<http://127.0.0.1:3377>**, select Kick, and connect your channel. Empty chat remains blank. The included channel defaults to NIGHTRIDERCO and can be changed in the studio.

## 🎬 3. Set up a fresh OBS installation

Follow **[the complete fresh-OBS setup guide](docs/OBS-SETUP.md)** in order. It supplies exact scene/source names, dimensions, file locations, camera transforms, and script buttons.

1. Create a new scene collection and grant OBS Screen Recording, Camera, and Microphone permissions as needed.
2. Enable **Tools → WebSocket Server Settings**, with authentication enabled. Use the normal port **4455** unless you need another one.
3. Create the base scenes, chat sources, and reusable **Camera Switch** scene described in the guide.
4. Add the Scene Layout and Desktop Auto Lua scripts through **Tools → Scripts**. Configure the actual capture devices and use their explicit setup buttons while outputs are stopped.
5. Add the docks below through **Docks → Custom Browser Docks**. Enter the WebSocket password once in a secure dock; it is stored in your login Keychain.
6. Add `NIGHTRIDERCO-OBS-AUTOSTART/nightriderco-local-services.lua` to start the four web services when this collection loads. The Husky app remains a separate launch.

| Dock | URL |
| --- | --- |
| Desktop Switch | `http://127.0.0.1:17642/07_AUTOMATION/desktop-dock.html` |
| Scene Layout | `http://127.0.0.1:17642/08_LAYOUT_DOCK/layout-dock.html` |
| Camera Switch | `http://127.0.0.1:17642/shared/camera-switch.html` |
| Resolution | `http://127.0.0.1:17643/` |
| Chat Studio | `http://127.0.0.1:3377/` |

The Resolution helper reads the current user's OBS WebSocket configuration locally; it does not use the secure docks' Keychain bridge. Keep that OBS configuration private. No credentials are supplied by this repository.

## 🎨 4. Add scenes, mascots, and styling

- Animated stream scenes use a **2560×1440 design canvas**, with Browser Source custom frame rate **60 FPS**. Canvas size and broadcast output size are separate choices; set your output to your streaming platform's current requirements. The Resolution dock supports QHD, which does not establish platform acceptance.
- Typing buddy: **`http://127.0.0.1:8876/overlay.html`**, 600×600, 60 FPS.
- Driving buddy: select the installed `NIGHTRIDERCO-HUSKY-SIMRACING/overlay.html` as a local Browser Source. Steering is simulated; wheel telemetry is not implemented.
- Limit Reset: edit the installed `NIGHTRIDERCO-LIMIT-RESET/config.js` with a **new, explicit reset date/time including its UTC offset**, then use `scene.html`. The repository intentionally ships no deadline. See the setup guide for the separate chat and Terminal sources.
- Theme and optional native frames: follow [optional component instructions](docs/OPTIONAL.md). The theme is installed in the user's OBS theme folder and selected manually.

## 🔐 Local data and permissions

Web services bind to `127.0.0.1`. Secure dock passwords live in macOS Keychain; OBS also maintains its own WebSocket settings. Account sign-in and device permissions must be completed on each new Mac. This repository contains no stream keys, OAuth tokens, saved chat sessions, personal OBS configuration, or Keychain export.

## 🧪 Verification and current limits

See **[verification results](docs/VERIFICATION.md)** for the checks run on this package and their limits. The installation tests use temporary folders and isolated services; they are not proof of a complete fresh-machine OBS setup.

Known limits:

- Full fresh-machine scene/device setup still needs the manual acceptance checklist in the OBS guide.
- Automatic display matching is tailored to a built-in Mac display and an Apple Studio Display. Other external displays need separate validation.
- StreamMenuBar's live Kick sign-in/viewer polling remains unverified after a scope-encoding fix. Followers, subscriber counts, and expanded metrics must not be treated as completed features.
- Panel Frames' native fixture tests do not establish live OBS GPU rendering. Unsupported OBS/Qt versions leave the extension inactive.
- YouTube chat and real wheel telemetry are future extensions.

## 🛠️ Maintenance

[Start/stop, troubleshooting, updating, and removal](docs/OPERATIONS.md) · [Optional builds and theme setup](docs/OPTIONAL.md) · [Third-party notices](THIRD-PARTY-NOTICES.md)

The repository does not grant a blanket open-source license to the original code or branded artwork. Third-party files retain their own notices and license terms.
