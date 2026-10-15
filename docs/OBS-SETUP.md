# 🎬 Set up a fresh OBS collection

This guide creates the required scenes and sources manually on macOS. Installing the files prepares the tools; OBS still needs your camera, display captures, and named scene sources.

**Work off air.** Stop streaming, recording, replay buffer, and virtual camera before setup or resolution changes. Choose the collection/profile you intend to configure. The tools do not configure your streaming account, choose your microphone, or adjust audio routing.

**Validation status:** the source dependencies and coordinates below have been checked against the packaged code. A complete run on a fresh OBS installation is still pending. Finish the checklist at the end before relying on the setup during a stream.

## 📁 Find your installed files

`$INSTALL` means the installation folder you chose. Its default is:

```text
~/Documents/NIGHTRIDERCO-TOOLS
```

`$INSTALL` is shorthand in this guide. **Do not paste it literally into an OBS file field.** Use the file chooser to select the file inside your installation folder. On macOS, press **⌘⇧G** in that chooser and enter `~/Documents/NIGHTRIDERCO-TOOLS` to reach the default folder.

The components keep these folder names:

| Folder inside `$INSTALL` | Used for |
| --- | --- |
| `NIGHTRIDERCO` | Brand assets, overlays, Desktop Auto and layout preparation |
| `NIGHTRIDERCO-CHAT` | Chat Studio and local chat overlay |
| `NIGHTRIDERCO-HUSKY` | Typing, pointer and voice companion |
| `NIGHTRIDERCO-HUSKY-SIMRACING` | Driving companion |
| `NIGHTRIDERCO-LIMIT-RESET` | Manual cooldown scene |
| `SecureDocks` | Desktop, layout and camera dock pages; Keychain helper |
| `NIGHTRIDERCO-OBS-AUTOSTART` | Local service starter and waiting dock pages |
| `NIGHTRIDERCO-Resolution-Dock` | FHD / 2K resolution helper |

Keep the installed folder in place after setup. Browser sources, scripts and image sources refer to those files.

## 🧰 1. Prepare OBS and start the tools

1. Complete the repository's installation steps first. This package needs macOS, Node.js 22 or newer, Python, and the native build prerequisites described in the main README.
2. Open OBS. Create a new scene collection for this setup if you want to keep another collection separate.
3. In **Settings → Video**, choose **Base (Canvas) Resolution: 2560×1440**. The coordinates in this guide use that canvas. Choose the output settings appropriate to your stream separately. After setup, the Resolution dock can switch the collection between **2560×1440** and **1920×1080**.
4. Open **`$INSTALL/Start tools.command`**. It starts/checks the local asset, chat, secure-dock and resolution services. It does not start a stream.
5. For automatic service startup when this collection loads, open **Tools → Scripts → +** and add:

   ```text
   $INSTALL/NIGHTRIDERCO-OBS-AUTOSTART/nightriderco-local-services.lua
   ```

   The script's **Start / check servers** button repeats the check. Keep `start-services.py` beside it. Adding the script is per collection; repeat this step for another collection that needs the tools.

The typing companion is a separate app. Open **`$INSTALL/NIGHTRIDERCO-HUSKY/Husky Typist.app`** when you want live typing, pointer or microphone reactions. In its paw menu, choose **Enable typing & mouse access** and grant **Input Monitoring** permission. For voice, choose **Enable microphone** and grant microphone permission. Select those permissions yourself; they are independent of OBS's permissions.

## 🔌 2. Connect OBS WebSocket

1. Open **Tools → WebSocket Server Settings** in OBS.
2. Enable the server and authentication. Note the port, normally **4455**, and the password shown by OBS.
3. Open the [Scene Layout dock page](http://127.0.0.1:17642/08_LAYOUT_DOCK/layout-dock.html). Expand **Connection**, enter the port/password, and choose **Connect to OBS**.

The local helper saves the password in your macOS Keychain. Desktop Switch and Camera Switch reuse that credential for the same port. Camera Switch has no password form, so complete this step in Scene Layout or Desktop Switch first. A missing scene message at this point is expected; the next steps create those scenes.

Keep OBS credentials on this Mac. The repository does not need your WebSocket password, streaming key, OBS profile, or personal scene export.

## 🗂️ 3. Create the scenes and hardware inputs

Create scenes with these exact names, preserving spaces and capitalization:

```text
Starting Soon
BRB
Workshop
Gameplay
Just Chatting
Ending
Overlays
Camera Switch
Inputs
```

**Workshop**, **Gameplay**, and **Camera Switch** are required by the layout/camera controls. The other scene names organize the optional artwork. **Inputs** is a convenient place to create reusable sources.

In **Inputs**, create your actual hardware sources:

| Source | Recommended name | Setup |
| --- | --- | --- |
| Video Capture Device | `Webcam` **(exact name required)** | Choose your camera and a supported 16:9 format when available. |
| macOS Screen Capture | `MacBook Display` | Choose **Display Capture** and your built-in display. |
| macOS Screen Capture | `Studio Display` | Create a separate source and choose the external Studio Display. |
| Game/window capture, if needed | Your choice | Choose the game or window to show in Gameplay. |

Grant OBS the macOS screen-recording and camera permissions needed for those inputs. The two capture sources must be distinct. Their names can differ from the recommendations because you select them explicitly in Desktop Auto.

Automatic display detection is designed for a **MacBook built-in display plus Apple Studio Display**. A single capture can use Desktop Auto, but the Desktop Switch dock needs both captures configured. Other display arrangements require checking the selected source manually; the automatic matching rules do not cover every monitor or a Mac with no built-in screen.

Do not add `Webcam` directly to Workshop or Gameplay. Those scenes will receive the shared Camera Switch component later. Do not create `NRC | Desktop Auto` manually; its script creates and owns that scene.

## 💬 4. Create the chat sources

Open [Chat Studio](http://127.0.0.1:3377/). Enter the intended Kick channel and choose **Connect Kick**. Use the copied live overlay URL for each style; the Studio's demo preview is separate from live chat.

In **Inputs**, add two **Browser** sources with **Local file turned off**:

| Exact source name | Style / URL parameter | Browser width × height |
| --- | --- | --- |
| `[HTML] Chat Community` | Community, `theme=panel` | **680×923** |
| `[HTML] Chat Minimal` | Minimal, `theme=minimal` | **560×800** |

For the included public channel, minimal examples are:

```text
http://127.0.0.1:3377/overlay.html?channel=nightriderco&theme=panel
http://127.0.0.1:3377/overlay.html?channel=nightriderco&theme=minimal
```

Use your own channel when appropriate. Keep the `theme` parameter: Desktop Auto rejects a template URL without it. Its template must use `http://127.0.0.1:3377/overlay.html` or `http://localhost:3377/overlay.html`.

Keep the default transparent Browser Source CSS. The layout preparation script will reuse `[HTML] Chat Minimal`; Desktop Auto will create its own Community and Minimal instances from your chosen template. Do not rename those two templates after configuring the scripts.

## 🐺 5. Build the shared Camera Switch scene

Open **Camera Switch** and add these sources at the scene's top level. Use **Add Existing** for `Webcam`; do not create a second camera input.

| Exact source name | Type | File or URL | Source size |
| --- | --- | --- | --- |
| `Webcam` | Existing camera input | Your selected camera | Camera's native format |
| `NRC Camera Frame · Workshop` | Image | `$INSTALL/NIGHTRIDERCO/08_LAYOUT_DOCK/webcam-frame-560x315.png` | The image is **576×331** |
| `[HTML] Typing buddy` | Browser, Local file **off** | `http://127.0.0.1:8876/overlay.html` | **600×600**, custom **60 FPS** |
| `[HTML] Driving buddy` | Browser, Local file **on** | `$INSTALL/NIGHTRIDERCO-HUSKY-SIMRACING/overlay.html` | **600×600**, custom **60 FPS** |

Driving buddy is optional. Keep its `assets` folder and `simracing.js` beside `overlay.html`. It animates automatically and does not read a physical racing wheel. Typing buddy needs the running Husky Typist app; a local-file copy does not provide live input reactions.

The frame name contains a middle dot: **`NRC Camera Frame · Workshop`**. The camera dock recognizes that exact name even though the source lives in **Camera Switch**. Keep all four scene items separate; do not put them in a new group.

### 📐 Camera Switch transforms at 2560×1440

For each item, open **Transform → Edit Transform**. Set **Rotation: 0**, **Positional Alignment: Top Left**, **Bounding Box Type: Scale to inner bounds**, and **Alignment in Bounding Box: Center**. Set all crop fields to **0**. Then enter:

| Scene item | Position X | Position Y | Bounding box width | Bounding box height |
| --- | ---: | ---: | ---: | ---: |
| `Webcam` | **61.87** | **34.80** | **2436.25** | **1370.39** |
| `NRC Camera Frame · Workshop` | **27.07** | **0** | **2505.86** | **1440** |
| `[HTML] Typing buddy` | **560** | **0** | **1440** | **1440** |
| `[HTML] Driving buddy` | **560** | **0** | **1440** | **1440** |

These are fresh-setup coordinates derived from the frame's **576×331** proportions. **Scale to inner bounds** preserves each source's aspect ratio; a non-16:9 webcam may leave space inside the frame. The Scene Layout script later crops the shared scene's narrow side margins and places a **576×331** instance in each working scene. The buddy remains square within that area.

Place the frame above Webcam in the Sources list. Initially show **Webcam and its frame**; hide **both buddies**. The Camera Switch dock changes this shared selection everywhere the scene is reused. Scene Layout independently controls whether each Workshop/Gameplay instance is visible and where it sits.

## 🖼️ 6. Add the branded artwork

For each row below, create a **Browser** source in the named scene, with **Local file off**, **2560×1440**, and custom **60 FPS**. Keep transparent CSS. Use **Transform → Fit to Screen** on this QHD canvas.

| Scene | Suggested source name | URL |
| --- | --- | --- |
| Starting Soon | `[HTML] Starting Soon` | `http://127.0.0.1:8765/03_OBS/starting-soon.html` |
| BRB | `[HTML] BRB` | `http://127.0.0.1:8765/03_OBS/brb.html` |
| Workshop | `[HTML] Workshop` | `http://127.0.0.1:8765/03_OBS/workshop.html` |
| Gameplay | `[HTML] Gameplay` | `http://127.0.0.1:8765/08_LAYOUT_DOCK/gameplay-layout.html` |
| Just Chatting | `[HTML] Just Chatting` | `http://127.0.0.1:8765/03_OBS/just-chatting.html` |
| Ending | `[HTML] Ending` | `http://127.0.0.1:8765/03_OBS/ending.html` |
| Overlays | `[HTML] Alerts` | `http://127.0.0.1:8765/03_OBS/alerts.html` |

The Gameplay URL above is the movable-camera layout. `03_OBS/gameplay.html` contains a fixed webcam border, which would remain behind when the dock moves the camera.

In **Workshop**, add an existing display/window capture below its artwork. In **Gameplay**, add your chosen game/window/display capture below its artwork. Set each capture's placement for the content you intend to show; use aspect-preserving bounds. Keep the later camera/chat items above those captures. Add the existing **Overlays** scene above the other sources wherever alerts should appear.

For **Just Chatting**, add the existing **Camera Switch** scene and `[HTML] Chat Community` below `[HTML] Just Chatting`. Use top-left positioning, centered **Scale to inner bounds**, and zero crop/rotation:

| Item | X | Y | Bounding box |
| --- | ---: | ---: | --- |
| Camera Switch | **80** | **250** | **1640×923** |
| `[HTML] Chat Community` | **1800** | **250** | **680×923** |

Those positions match the two transparent openings in the artwork. The Camera Switch scene retains its own frame and transparent margins.

Full-frame pages support language selection through `?lang=en` or `?lang=es`; Starting Soon also accepts `?minutes=5`.

`alerts.html` renders local alert events; it does not subscribe to Kick or another platform's follower/subscriber events by itself. Configure any event integration separately. Audio behavior belongs to the source/settings you choose; inspect it before use.

## 🧭 7. Prepare the Scene Layout controls

In **Tools → Scripts → +**, add:

```text
$INSTALL/NIGHTRIDERCO/08_LAYOUT_DOCK/nightriderco-layout-setup.lua
```

With streaming and recording stopped, select the script and click **Prepare Workshop + Gameplay**. It adds:

- `NRC Camera · Workshop` inside Workshop, containing Camera Switch.
- `NRC Camera · Gameplay` inside Gameplay, containing Camera Switch.
- `[HTML] Chat Minimal` in each scene if it is missing.

At QHD the initial camera group is **X 52, Y 992**, with a **576×331** shared scene instance. Chat starts at **X 2024, Y 680**, at **70%** source scale. Existing camera/chat placements are preserved on subsequent runs.

Keep the script loaded. The dock's **Prepare scenes** button invokes its registered setup hotkey. A missing scene/source message means an earlier setup step is incomplete; the button does not create the base scenes, camera input, buddies, or chat template.

## 🖥️ 8. Create Desktop Auto

Add this script in **Tools → Scripts → +**:

```text
$INSTALL/NIGHTRIDERCO/07_AUTOMATION/nightriderco-desktop-auto.lua
```

Keep `nrc-displays.lua`, `capture-hold.html` and `capture-hold.js` beside it. Set:

| Script field | Value |
| --- | --- |
| Managed scene / Escena automática | `NRC | Desktop Auto` |
| MacBook Pro / Primary capture / Captura principal | Your existing MacBook capture |
| Studio Display capture (optional) / Captura opcional | Your separate Studio Display capture |
| Camera Switch / camera source | `Camera Switch` |
| display-layouts folder / Carpeta | `$INSTALL/NIGHTRIDERCO/03_OBS/display-layouts` |
| Animated EN/ES overlays | Enabled for the animated layouts |
| Community / Minimal chat by display | Enable if using chat |
| Existing local chat template | `[HTML] Chat Community` |
| Native ice wipe between displays | Optional; uses the included QHD 60 FPS alpha `.mov` |

With another scene on Program and no output running, click **Create / Update managed scene / Crear o actualizar**. The script creates its managed scene, overlays, safety cover and optional chat sources. **Do not select the newly managed scene on Program while rebuilding it.** A scene nested anywhere in the current Program scene also counts as in use.

The selected chat template creates **both** styles: Community for the MacBook layout and Minimal for Studio Display. Changing the template is a rebuild setting, not the active display selector. The script can accept one capture, but choose both to use Desktop Switch's two display buttons.

Use **Detect / Refresh displays / Detectar pantallas** after connecting a display or fixing macOS capture permissions. Supported capture shapes are approximately **16:10** for the MacBook and **16:9** for Studio Display. The script does not provide an ultrawide layout.

Add your existing Overlays scene or other optional sources to Desktop Auto only after it is created. Keep any audio configuration under your own control.

## 🧩 9. Add the four custom docks

Open **Docks → Custom Browser Docks** in OBS and add:

| Dock name | URL |
| --- | --- |
| Desktop Switch | `http://127.0.0.1:17642/07_AUTOMATION/desktop-dock.html` |
| Scene Layout | `http://127.0.0.1:17642/08_LAYOUT_DOCK/layout-dock.html` |
| Camera Switch | `http://127.0.0.1:17642/shared/camera-switch.html` |
| Resolution | `http://127.0.0.1:17643/` |

The waiting pages in **`$INSTALL/NIGHTRIDERCO-OBS-AUTOSTART/docks`** can recover when OBS opens before its local helpers are ready. For each dock, open the matching HTML file in your browser and copy that file's complete `file:///…` address into OBS: `desktop-switch.html`, `scene-layout.html`, `camera-switch.html`, or `resolution.html`. Its address must refer to this Mac's installation. The waiting page redirects to the HTTP URL above when the service responds.

Connect Scene Layout or Desktop Switch with your WebSocket password if needed. Camera Switch then reconnects using the same saved credential. Scene Layout controls Workshop and Gameplay only; Camera Switch selects the shared Webcam/Typing/Driving content; Desktop Switch selects the configured display.

Use **FHD** or **2K** in Resolution only with all outputs stopped. It changes the canvas, output size, full-frame browser dimensions and collection transforms. **Undo** returns to its saved previous resolution state while the same collection/profile and source identities are still available. Reload the current Desktop Auto Lua script if the dock says FHD support is not active.

## ⏳ 10. Optional cooldown scene and appearance

For the cooldown scene, create a new scene and add a **Browser** source with **Local file on**, selecting:

```text
$INSTALL/NIGHTRIDERCO-LIMIT-RESET/scene.html
```

Use **2560×1440**, custom **60 FPS**, on the initial QHD canvas and keep the component's files together. Edit `NIGHTRIDERCO-LIMIT-RESET/config.js` with your desired `timeZone` and ISO `resetAt` date/time, then refresh the browser source. The packaged deadline is unset; enter a newly observed deadline before use. This is a manual countdown; it does not inspect an account's current usage or determine a future reset time.

The page supplies the artwork, husky, and clock. **Chat and Terminal are separate OBS sources**, placed above that background:

| New source | Properties | QHD placement |
| --- | --- | --- |
| `[HTML] Limit Chat` | New Browser source, Local file off; `http://127.0.0.1:3377/overlay.html?channel=nightriderco&theme=minimal`; width **528**, height **541**, transparent CSS | X **1029.33**, Y **304**, scale **1** |
| `Limit Terminal` | macOS Screen Capture in Window mode, selecting your actual Terminal window | After cropping, top-left position X **154.67**, Y **989.33**; centered **Scale to inner bounds**, **800×226.67** |

Use your channel in the chat URL. Create this Browser source separately so its dimensions do not change the chat templates in other scenes. For Terminal, crop the capture to only the current usage-limit message and reset time; the crop amounts depend on your window and font size. Then apply the bounds above. The background intentionally leaves those areas blank without these sources. Its `?preview=1` placeholders are a visual demo and do not supply live chat or a Terminal capture.

The repository's **`extras/obs-theme/NIGHTRIDERCO.ovt`** and **`extras/panel-frames`** are separate optional appearance components. **`extras/StreamMenuBar`** contains the separate menu-bar app source. Follow [the optional component instructions](OPTIONAL.md) from the repository; these extras are not staged by the default tool installer. Install the panel plugin with OBS closed. They do not create scenes or replace any of the setup above.

## ✅ Finish the off-air check

- [ ] The asset pages and Chat Studio open after starting the tools.
- [ ] The typing companion preview responds after the requested macOS permissions are granted.
- [ ] Camera Switch selects Webcam, Typing buddy and the optional Driving buddy, showing one mode at a time. The webcam frame follows Webcam visibility.
- [ ] Scene Layout moves and hides camera/chat in Workshop and Gameplay independently. No fixed Gameplay camera border remains behind.
- [ ] Desktop Auto loads both configured captures, adapts their layout and shows the expected chat style. The Desktop Switch buttons work.
- [ ] Disconnect/reconnect a display while off air and verify the selected capture and safety cover recover.
- [ ] With all outputs stopped, verify **FHD → 2K → Undo** and inspect each scene after the change.
- [ ] Close and reopen OBS. Verify the four local services, custom docks and loaded scripts. Open Husky Typist separately if live input reactions are wanted.
- [ ] Check camera framing, capture content and audio in your own OBS preview/recording before a live stream.

If a check fails, keep the collection off air and use the visible dock error or **Tools → Scripts → Script Log** to identify the missing prerequisite. Do not repeatedly run a historical migration or installer against an already configured collection.
