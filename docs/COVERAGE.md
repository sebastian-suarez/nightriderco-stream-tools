# 📚 Extraction coverage

This package reconciles **21 recovered streaming sessions**, the later OBS theme/dock refinements, and the current installed source files. Organization-only sessions supplied an index rather than an additional runtime tool. Historical drafts and troubleshooting advice are not installed as competing versions.

| Session topic | Included result |
| --- | --- |
| Generate Kick channel assets — four related sessions | Latest full brand/channel tree; scene artwork, compact alerts, 60 FPS transition, bilingual overlays, display layouts, audio, emotes, badges, social sources, and generation prompts |
| Add Kick chat component | Chat Studio, live Kick adapter, Community/Minimal overlays, source and tests |
| Add scene layout dock | Current Camera Switch-aware layout script and dock |
| Store passwords in keychain | Secure local dock host, native Keychain helper source/binary and shared client |
| Add FHD and 2K dock toggle | Resolution engine, server, connection module, frontend, and regression tests |
| Run commands in OBS automatically | Local services Lua launcher, Python startup logic, and delayed-dock pages |
| Fix OBS display detection | Display inventory module and reconnect/recovery logic |
| Add OBS source switching dock | Camera Switch controller and reusable-scene support |
| Create a husky typing mascot | Intact native app and editable source; latest 1.8.3 sibling artwork, voice, pointer and scroll reactions |
| Create dancing Husky limit scene | Latest chibi scene, artwork, animation and clock; deadline cleared for fresh setup |
| Add a simracing husky view | Driving artwork/animation and the final three-way camera controller |
| Fix camera switch dock loading | Current helper document-navigation behavior and delayed-dock startup page |
| Fix typing buddy display | Dependency on the running Husky helper is explicit in the startup/setup instructions |
| Bitrate | StreamMenuBar OBS provider, app and tests |
| Auth and viewers | StreamMenuBar OAuth/viewer code and tests; live verification limitation retained |
| Followers unofficial endpoint | Existing StreamMenuBar source preserved; requested follow-on metrics are not represented as completed |
| Fix OBS Kick server connection; Troubleshoot OBS connection drops | No separate reusable tool was created. Personal server/key/output settings are excluded; configure current platform requirements yourself. |
| Build matching OBS theme and later refinements | Current native theme, matching dock CSS, Panel Frames 1.1.0 source/binary, and paired main-window spacing changes |

## Version choices

- Current installed secure-dock/runtime files supersede older nested copies of the same tools.
- The main asset tree supplies `obs.js` and `obs.css`, which some recovered snapshots omitted. The Resolution dock's required `obs-client.mjs` was also recovered from its original source.
- Desktop Auto includes the display-inventory module and current Camera Switch behavior. A separate main-scene export is intentionally not supplied.
- The native Husky app keeps its original signed bundle. The sibling `web/` folder is the newer approved artwork and takes precedence over the bundle fallback.
- The latest dock styling and Panel Frames 1.1.0 are retained. Old theme backups and historical rollback packages remain outside the public repository.

## Packaging changes

The toolkit's application logic is retained. Installation adaptations include relative component paths, Node discovery and prerequisite error reporting, starting the four required local services, an unset countdown, removal of personal signing-team settings, test-path repairs, and the new staging installer/documentation. The native Keychain helper is rebuilt with a macOS 13 target; the Panel Frames build remaps source paths to keep private build locations out of the binary. SecureDocks contains the pages it serves; reusable overlay artwork and Lua scripts live in the main asset tree.

`source-manifest.json` lists the final distributed source/asset files and their SHA-256 values. Private origin paths and session transcripts are not included.

## Deliberate exclusions

No credentials, OAuth tokens, stream keys, personal OBS profiles/scene exports, logs, service snapshots, browser storage, Xcode user data, generated build caches, screenshots of the user's desktop, duplicate ZIPs, or superseded installers are published. Four missing historical full-pack ZIPs are not reconstructed; the latest available editable assets are included instead.

No new platform port, chat integration, telemetry source, or metric implementation is claimed by this extraction.
