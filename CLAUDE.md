# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**LockAudio** (formerly Mac Audio Input Locker, renamed in 2.0.0) is a macOS menu bar application that locks the system's audio **input** and/or **output** to user-chosen devices, so macOS and Bluetooth devices (e.g. AirPods) can't switch them away. The original use case — and still the default — is forcing the input to the built-in microphone instead of AirPods' mic, which keeps output in high-quality mode and improves AirPods battery life. As of 2.0.0 the same forcing can be applied independently to the output device.

## Technology Stack

- **Language**: Objective-C
- **Platform**: macOS. Note: there's an unresolved deployment-target inconsistency — the project-level `MACOSX_DEPLOYMENT_TARGET` is 10.14, but the target build configs override it to 15.6, and the appcast advertises `minimumSystemVersion 10.14`. The effective minimum the binary is built against is 15.6; reconcile these before relying on a stated minimum.
- **Build System**: Xcode project files (.xcodeproj)
- **Frameworks**:
  - CoreAudio.framework - for audio device management
  - Cocoa.framework - for UI and system integration
  - Sparkle (SPM) - automatic update framework
  - GBLaunchAtLogin - third-party library for launch-at-login functionality

## Build Commands

### Development build
```bash
# Open in Xcode
open "LockAudio.xcodeproj"

# Build from command line
xcodebuild -project "LockAudio.xcodeproj" -scheme "LockAudio" -configuration Release build
```

### Release build
```bash
# Build Universal Binary (Intel + Apple Silicon) and create DMG
./bin/build-release.sh

# Build and upload to GitHub with interactive release notes
./bin/build-release.sh --upload

# The script will:
# - Check if version already exists on GitHub
# - Build universal binary for x86_64 and arm64
# - Create DMG with Applications folder symlink
# - Sign update with EdDSA key from Keychain
# - Generate appcast.xml with proper signatures
# - Upload appcast.xml to Cloudflare R2 automatically
# - Optionally create GitHub release and upload DMG
```

## Architecture

### Core Components

**AppDelegate.m** (main application logic)
- Application controller implementing NSApplicationDelegate and NSMenuDelegate
- Owns two `AudioLock` instances — `inputLock` and `outputLock` — and orchestrates them
- Manages the menu bar status item and builds the menu (one section per shown direction)
- Registers a CoreAudio default-device property listener per direction; the callback rebuilds the menu and re-applies forcing
- Persists preferences via NSUserDefaults (see State Management for the keys)

**AudioLock.h/m** (per-direction lock abstraction, added in 2.0.0)
- Encapsulates the direction-specific CoreAudio plumbing so input and output share one implementation. Parameterized by `AudioLockDirection` (input/output).
- Owns: `forcedID`, `forcedName`, `paused`, the scope/selector constants (`kAudioHardwarePropertyDefaultInputDevice` vs `…OutputDevice`, `kAudioDevicePropertyScopeInput` vs `…Output`), prefs load/save, device-participation check, read-current-default, apply-force, and the listener address.
- AppDelegate instantiates it twice; the menu/notification/show-hide wiring lives in AppDelegate.

**Audio Device Management**
- Uses CoreAudio `AudioObject*` APIs (`AudioObjectGetPropertyData`/`AudioObjectSetPropertyData`/`AudioObjectAddPropertyListener`)
- Monitors `kAudioHardwarePropertyDefaultInputDevice` and `…DefaultOutputDevice` (plus `kAudioHardwarePropertyDevices` for add/remove) via property listeners
- Forces each locked direction back to the user-selected device when something else takes it
- Recovers a forced device by name across disconnect/reconnect (the AudioDeviceID can change)

**Menu Bar Integration**
- Creates NSStatusItem in system menu bar; menu rebuilt on every device change via `listDevices`
- Per direction (when shown): a "Forced input:"/"Forced output:" section listing that direction's devices with a checkmark on the forced one, plus a "Pause … Lock" item
- "Show Input/Output Options" toggles hide a direction's whole section (and pause its lock); input shown by default, output hidden by default
- Device rows carry `representedObject` `@[@(direction), @(deviceID)]` so clicks route to the correct lock (a device can appear in both lists); app-control items carry SF Symbol icons to distinguish them from device rows

**GBLaunchAtLogin** (third-party dependency)
- Located in `/GBLaunchAtLogin/` directory
- Provides launch-at-login functionality
- Simple API: `isLoginItem`, `addAppAsLoginItem`, `removeAppFromLoginItems`

**Sparkle Auto-Update System**
- Integrated via Swift Package Manager (SPM)
- Public EdDSA key stored in Info.plist (`SUPublicEDKey`)
- Private key stored securely in macOS Keychain
- Update feed URL: `https://updates.lockaudio.com/appcast.xml` (the pre-rename host `https://updates.macaudioinputlocker.com/appcast.xml` is kept alive to serve the one-time "we've moved to LockAudio" notice to old `com.audio.locker` installs)
- Updates are signed with EdDSA signatures in appcast.xml
- Build script automatically signs DMG files using Sparkle's `sign_update` tool

### Key Implementation Details

**Device Forcing Logic**
- `listDevices` is the orchestrator: it builds the menu shell and calls `appendDevicesForLock:toMenu:` once per shown direction (resolve/recover the forced device, list participating devices, re-apply force if another device took the default).
- Forcing runs from the per-direction property-listener callback and on manual device selection (`deviceSelected:`).
- Each lock has its own pause; hiding a direction force-pauses it. A user-initiated switch sets a one-shot suppress flag so it doesn't fire a misleading "forced active" notification.

**State Management**
- Per-lock runtime state lives on the `AudioLock` instances (`forcedID` — `UINT32_MAX` means built-in default not yet resolved; `forcedName`; `paused`).
- NSUserDefaults keys (input keys keep their original names for backward compatibility):
  - Input: `Device` / `DeviceName`, `NotificationsEnabled`, `ShowInputOptions`, `InputPaused`
  - Output: `OutputDevice` / `OutputDeviceName`, `OutputNotificationsEnabled`, `ShowOutputOptions`, `OutputPaused`
  - `LaunchAtLogin` (mirrors SMAppService state so it's migratable)
- Pause, device choices, and show/hide toggles all persist across quit and reboot. Runtime `paused` on launch = persisted pause preference OR section hidden.
- Defaults: input shown + not paused; output hidden + paused (opt-in); input notify on, output notify off.

**UI Behavior**
- Menu is rebuilt on every device change via `listDevices`
- LSUIElement=true in Info.plist makes it a menu bar-only app (no dock icon)

## File Structure

```
LockAudio/
├── AppDelegate.h/m          # Main application controller (owns the two AudioLocks)
├── AudioLock.h/m            # Per-direction lock abstraction (input/output)
├── main.m                   # Entry point
├── Info.plist               # App metadata, Sparkle config
├── Assets.xcassets          # Asset catalog
├── Base.lproj/MainMenu.xib  # Interface builder file
└── airpods-icon*.png        # Menu bar icons

CHANGELOG.md                 # Per-version release notes (build script reads these)
.env.example                 # R2 config template (copy to .env)

bin/
├── build-release.sh         # Automated release build script (notarize, sign, appcast, R2, GitHub)
├── test-build.sh            # Local debug build + launch + log tail
└── copy-appcast.sh          # Upload appcast.xml to R2 (reads .env)

GBLaunchAtLogin/
├── GBLaunchAtLogin.h/m      # Launch-at-login helper
├── LICENSE
└── README.md

release/                     # Build output (gitignored)
└── *.dmg                    # Signed DMG files
```

## Development Notes

- Application uses LSUIElement to run as menu bar-only (no dock icon)
- Uses modern `kAudioObjectPropertyElementMain` (not deprecated `kAudioObjectPropertyElementMaster`)
- No unit tests present in project
- Sandbox is disabled (com.apple.Sandbox = 0 in project.pbxproj)
- Bundle identifier: com.lockaudio.app (was com.audio.locker before 2.0.0; the bundle-id change means upgrading users get a one-time settings migration in AppDelegate.m — see `migrateSettingsFromLegacyBundleIfNeeded`)

## Release Process

### Version Management
1. Update `CFBundleShortVersionString` (and `CFBundleVersion`) in Info.plist to the new semantic version. These literal values are what ship — they override the `MARKETING_VERSION` build setting, so update the plist.
2. Add a matching `## <version> - MM-DD-YYYY` entry to `CHANGELOG.md` (the build script reads release notes from here — see below).
3. The build script checks whether the version already exists on GitHub.

### Creating a Release
1. Add the `CHANGELOG.md` entry first. The build script extracts the section between `## <version>` and the next `##`, turns each `- ` bullet into an appcast `<li>`, and uses the section as the GitHub release body. Write bullets as user-facing notes; avoid markdown emphasis (`**`, links) — the appcast renders them as plain HTML, so markdown shows literally.
2. Run `./bin/build-release.sh --upload`
3. Builds universal binary (Intel + Apple Silicon), creates the DMG, notarizes + staples
4. Signs the DMG with the EdDSA key from Keychain
5. Generates appcast.xml and uploads it to Cloudflare R2 (`lockaudio` bucket)
6. Creates the GitHub release and uploads the DMG

### Release tagging (IMPORTANT — known gotcha)
`build-release.sh` runs `gh release create "v<version>" … ` **without `--target`**, so `gh` tags the repo's **default branch** (`main`). If you build/release from a feature branch (e.g. a version branch like `2.0.0`) that has **not** been merged to `main` yet, the `v<version>` tag will point at the wrong commit (old `main`), not your release code. This happened with `v2.0.0`.

To avoid it, do one of:
- **Merge the release branch into `main` before** running `--upload`, so the default branch already has the release code; or
- After releasing from a branch, **re-point the tag** once the branch is merged:
  ```bash
  git tag -f v<version> <merge-commit>
  git push origin -f v<version>
  gh release edit v<version> --repo jstilwell/LockAudio --target main
  ```
Verify after release: `gh release view v<version> --json tagName,targetCommitish` should point at a commit that actually contains the release code (check its CHANGELOG entry exists).

### Cloudflare R2 Setup (one-time)
The appcast.xml update feed is hosted on Cloudflare R2 at `updates.lockaudio.com`. The pre-rename host `updates.macaudioinputlocker.com` (bucket `mac-audio-input-locker`) is kept alive to serve a one-time "we've moved to LockAudio" notice to old `com.audio.locker` installs, since the bundle-id change means they cannot auto-update across to the new app.

- **Bucket**: `lockaudio` (with public access via custom domain)
- **Custom domain**: `updates.lockaudio.com` (CNAME pointing to R2 bucket, min TLS 1.0)
- **Feed URL**: `https://updates.lockaudio.com/appcast.xml`

To set up R2 credentials for the build script:
1. Copy `.env.example` to `.env` and fill in your Cloudflare Account ID
2. Create an R2 API token in Cloudflare dashboard (Object Read & Write permissions)
3. Configure AWS CLI with an R2 profile:
   ```bash
   aws configure --profile r2
   # Access Key ID: <from R2 API token>
   # Secret Access Key: <from R2 API token>
   # Region: auto
   ```

The build script automatically reads configuration from `.env` (gitignored) and updates `SUFeedURL` in Info.plist to match before building.

### Sparkle Key Management
- Public key is in Info.plist (`SUPublicEDKey`)
- Private key is stored in macOS Keychain (named "Private key for signing Sparkle updates")
- Keys generated once with: `~/Library/Developer/Xcode/DerivedData/LockAudio-*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys`
- Never commit private key or export it unless migrating to new machine

## Code Patterns

- Objective-C with ARC enabled
- C-style CoreAudio callback functions bridged to Objective-C via `__bridge`
- Menu items use target-action pattern for event handling
- Property listeners registered on `kAudioObjectSystemObject` for global audio changes
- Version display shows only marketing version (not build number)
- DMG layout: app on left, Applications symlink on right (using space prefix trick: " Applications")
