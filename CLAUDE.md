# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Mac Audio Input Locker** is a macOS menu bar application that improves AirPods sound quality and battery life by forcing the Mac to use the built-in microphone instead of AirPods' microphone. This prevents macOS from mixing down the audio output quality.

## Technology Stack

- **Language**: Objective-C
- **Platform**: macOS (minimum: 10.13 High Sierra, deployment target: 10.14 Mojave)
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
open "Mac Audio Input Locker.xcodeproj"

# Build from command line
xcodebuild -project "Mac Audio Input Locker.xcodeproj" -scheme "Mac Audio Input Locker" -configuration Release build
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
- Single-file application controller implementing NSApplicationDelegate and NSMenuDelegate
- Manages the menu bar status item and menu construction
- Handles CoreAudio device enumeration and switching
- Persists user preferences via NSUserDefaults (key: "Device")
- Registers CoreAudio property listener callback to detect input device changes

**Audio Device Management**
- Uses deprecated CoreAudio APIs (AudioHardwareGetProperty, AudioHardwareSetProperty, AudioDeviceGetProperty)
- Monitors `kAudioHardwarePropertyDefaultInputDevice` for changes via property listener callback
- Forces input device to user-selected device when AirPods microphone is detected
- Stores forced device ID (AudioDeviceID) in NSUserDefaults

**Menu Bar Integration**
- Creates NSStatusItem in system menu bar
- Dynamically rebuilds menu on each device change
- Displays all available input devices with checkmark on selected device
- Includes pause functionality to temporarily disable forcing

**GBLaunchAtLogin** (third-party dependency)
- Located in `/GBLaunchAtLogin/` directory
- Provides launch-at-login functionality
- Simple API: `isLoginItem`, `addAppAsLoginItem`, `removeAppFromLoginItems`

**Sparkle Auto-Update System**
- Integrated via Swift Package Manager (SPM)
- Public EdDSA key stored in Info.plist (`SUPublicEDKey`)
- Private key stored securely in macOS Keychain
- Update feed URL: `https://mac-audio-input-locker.jesse.id/appcast.xml`
- Updates are signed with EdDSA signatures in appcast.xml
- Build script automatically signs DMG files using Sparkle's `sign_update` tool

### Key Implementation Details

**Device Forcing Logic** (AppDelegate.m:292-311)
- When default input device changes and doesn't match `forcedInputID`, app forces the device back
- Forcing happens in both the callback (when device changes) and on manual device selection
- "Pause" feature sets `paused` flag to temporarily disable forcing

**State Management**
- `forcedInputID`: AudioDeviceID of device to force (UINT32_MAX means built-in default)
- `paused`: BOOL to temporarily disable forcing
- `itemsToIDS`: NSMutableDictionary mapping device names to AudioDeviceID values
- Preferences stored in NSUserDefaults with key "Device"

**UI Behavior**
- Menu is rebuilt on every device change via `listDevices` method
- Shows "forcing..." message when actively switching devices (AppDelegate.m:131-134, 305-309)
- LSUIElement=true in Info.plist makes it a menu bar-only app (no dock icon)

## File Structure

```
Mac Audio Input Locker/
├── AppDelegate.h/m          # Main application controller
├── main.m                   # Entry point
├── Info.plist               # App metadata, Sparkle config
├── Assets.xcassets          # Asset catalog
├── Base.lproj/MainMenu.xib  # Interface builder file
└── airpods-icon*.png        # Menu bar icons

.env.example                   # R2 config template (copy to .env)

bin/
└── build-release.sh         # Automated release build script

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
- Bundle identifier: com.audio.locker

## Release Process

### Version Management
1. Update `CFBundleShortVersionString` in Info.plist to new semantic version (e.g., 1.0.4)
2. The build script automatically checks if the version already exists on GitHub
3. Version format: semantic versioning (MAJOR.MINOR.PATCH)

### Creating a Release
1. Run `./bin/build-release.sh --upload`
2. Script prompts for release notes (one feature per line, empty line to finish)
3. Builds universal binary (Intel + Apple Silicon)
4. Creates DMG with proper Applications folder layout
5. Signs DMG with EdDSA key from Keychain
6. Generates appcast.xml with signatures and file metadata
7. Uploads appcast.xml to Cloudflare R2 automatically
8. Creates GitHub release with formatted release notes
9. Uploads DMG to GitHub releases

### Cloudflare R2 Setup (one-time)
The appcast.xml update feed is hosted on Cloudflare R2 at `mac-audio-input-locker.jesse.id`.

- **Bucket**: `mac-audio-input-locker` (with public access via custom domain)
- **Custom domain**: `mac-audio-input-locker.jesse.id` (CNAME pointing to R2 bucket)
- **Feed URL**: `https://mac-audio-input-locker.jesse.id/appcast.xml`

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
- Keys generated once with: `~/Library/Developer/Xcode/DerivedData/Mac_Audio_Input_Locker-*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys`
- Never commit private key or export it unless migrating to new machine

## Code Patterns

- Objective-C with ARC enabled
- C-style CoreAudio callback functions bridged to Objective-C via `__bridge`
- Menu items use target-action pattern for event handling
- Property listeners registered on `kAudioObjectSystemObject` for global audio changes
- Version display shows only marketing version (not build number)
- DMG layout: app on left, Applications symlink on right (using space prefix trick: " Applications")
