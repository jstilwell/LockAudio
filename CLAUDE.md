# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**AirPods Sound Quality Fixer** is a macOS menu bar application that improves AirPods sound quality and battery life by forcing the Mac to use the built-in microphone instead of AirPods' microphone. This prevents macOS from mixing down the audio output quality.

## Technology Stack

- **Language**: Objective-C
- **Platform**: macOS (minimum: 10.13 High Sierra, deployment target: 10.14 Mojave)
- **Build System**: Xcode project files (.xcodeproj)
- **Frameworks**:
  - CoreAudio.framework - for audio device management
  - Cocoa.framework - for UI and system integration
  - GBLaunchAtLogin - third-party library for launch-at-login functionality

## Build Commands

### Building the application
```bash
# Build from command line
xcodebuild -project "AirPods Sound Quality Fixer.xcodeproj" -scheme "AirPods Sound Quality Fixer" -configuration Release build

# Or open in Xcode
open "AirPods Sound Quality Fixer.xcodeproj"
```

### Clean build
```bash
xcodebuild -project "AirPods Sound Quality Fixer.xcodeproj" -scheme "AirPods Sound Quality Fixer" clean
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
AirPods Sound Quality Fixer/
├── AppDelegate.h/m          # Main application controller
├── main.m                   # Entry point
├── Info.plist               # App metadata and configuration
├── Assets.xcassets          # Asset catalog
├── Base.lproj/MainMenu.xib  # Interface builder file
└── airpods-icon*.png        # Menu bar icons

GBLaunchAtLogin/
├── GBLaunchAtLogin.h/m      # Launch-at-login helper
├── LICENSE
└── README.md
```

## Development Notes

- Application uses LSUIElement to run as menu bar-only (no dock icon)
- CoreAudio APIs used are deprecated; consider migrating to AVAudioSession/AVAudioEngine in future
- No unit tests present in project
- Sandbox is disabled (com.apple.Sandbox = 0 in project.pbxproj)
- Development team ID: SGKB9R23YT
- Bundle identifier: com.milgra.asqf

## Code Patterns

- Objective-C manual memory management patterns (though ARC is enabled)
- C-style CoreAudio callback functions bridged to Objective-C via `__bridge`
- Menu items use target-action pattern for event handling
- Property listeners registered on `kAudioObjectSystemObject` for global audio changes
