# 🎨 Optional components and native builds

These components remain in the repository's `extras/` folder. The main installer stages the `payload/` tools only.

## OBS theme

With OBS closed, copy `extras/obs-theme/NIGHTRIDERCO.ovt` into:

```text
~/Library/Application Support/obs-studio/themes/
```

Create that folder if necessary. Back up an existing file with the same name before replacing it. Open OBS and choose **Yami → NIGHTRIDERCO** in Settings → Appearance (older OBS versions place theme selection in General). The theme extends OBS's bundled Yami resources. The packaged version was developed against OBS 32.2.2; other versions need a visual check. [OBS theme installation reference](https://obsproject.com/kb/themes-guide).

## Panel Frames 1.1.0

This optional native extension adds rounded panel frames and the paired top-spacing adjustments. It requires **Apple silicon, OBS 32.2.2, Qt 6.11.1**, and the matching NIGHTRIDERCO theme. The installer checks the installed OBS and Qt versions and the packaged binary hash/signature. The plugin also checks its runtime before activating.

After installing the theme, close OBS and run from the repository:

```sh
python3 extras/panel-frames/install.py
```

Open OBS normally afterward. An existing extension is backed up under `~/Library/Application Support/NIGHTRIDERCO/StyleBackups/`. This does not modify `OBS.app` or bundle another Qt runtime. After an OBS upgrade, leave the extension disabled until it is rebuilt and verified for that version.

To build from source, use the **arm64 Qt archive from [OBS dependencies 2026-08-26](https://github.com/obsproject/obs-deps/releases/tag/2026-08-26)**, with Xcode Command Line Tools and OBS 32.2.2 installed at `/Applications/OBS.app`. Extract the SDK so its root contains `lib/` and `libexec/`, then run:

```sh
NRC_QT_SDK="/path/to/extracted/qt-sdk" \
NRC_BUILD_DIR="/tmp/nightrider-panel-frames-build" \
python3 extras/panel-frames/source/build.py
```

The source includes the native fixture and test assets. The build creates a local plugin and fixture in the build folder; it does not install them. Run the fixture's `Contents/MacOS/panel-frame-check` executable to exercise native lifecycle/layout checks. A new build requires a newly verified manifest/archive before distributing it; do not replace the packaged binary while retaining its old hashes.

The small `verification.json` beside the installer records the packaged binary's previously measured lifecycle result. Fresh package verification is documented separately in [VERIFICATION.md](VERIFICATION.md). Fixture results do not establish actual OBS GPU composition.

## StreamMenuBar

Open `extras/StreamMenuBar/StreamMenuBar.xcodeproj` with **Xcode 27** on **macOS 27**. Choose the StreamMenuBar scheme and My Mac. Select your own signing team if Xcode requires one; the original development-team setting was removed from the public project. Existing app/Keychain identifiers remain stable.

Build locally without a developer-team identity from the repository root:

```sh
xcodebuild -project extras/StreamMenuBar/StreamMenuBar.xcodeproj \
  -scheme StreamMenuBar -configuration Debug \
  -derivedDataPath /tmp/nightrider-menubar-build \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build
```

The resulting app is under `/tmp/nightrider-menubar-build/Build/Products/Debug/`. Open it and configure OBS and Kick in its Settings. Supply your own Kick developer-app configuration and authorize your own account; credentials are not included.

OBS bitrate comes from local OBS independently of Kick. Kick auth/viewer code and tests are included, but live sign-in/viewer polling remains unverified after the final scope fix. Additional follower/subscriber/health metrics are not promised by this extraction.

## Husky and Keychain helper builds

The staged Husky bundle is intact and ad-hoc signed. Its current artwork lives in sibling `web/`; do not replace it with the older bundle fallback. For native changes, follow `payload/NIGHTRIDERCO-HUSKY/source/BUILD.txt` from that component directory, then re-sign and re-authorize the app as needed.

The secure dock's native helper can be rebuilt on Apple silicon with:

```sh
sh payload/SecureDocks/native/build.sh
```

This overwrites and re-signs that checkout's helper binary. Rebuild before staging, or build the installed copy intentionally while its service is stopped. Never modify a binary and then claim its previous signature/checksum is still the one tested.
