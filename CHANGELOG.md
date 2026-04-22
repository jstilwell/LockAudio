# Changelog

All notable changes to this project will be documented in this file.

## 1.1.2 - 04-22-2026

### Fixed

- Suppress misleading "Forced input active" notifications when the selected forced input is not connected. The app now tracks whether the forced device is present in the current device list and skips the force-set call (and its notification) when it isn't, instead of silently no-op'ing the CoreAudio set and still firing the notification. When the device reconnects, the existing name-recovery path restores forcing automatically.
- Only post the forced-input notification when `AudioObjectSetPropertyData` actually returns `noErr`, so other silent-failure cases can't produce a misleading notification either

## 1.1.1 - 04-22-2026

### Added

- "About" menu item (replaces "Hide") opening a window with the app version, website, GitHub, support email, and copyright
- SF Symbol icons on the "Sound settings…", "Check for updates", "About", and "Quit" menu items (macOS 11+)

### Changed

- Appcast update feed moved to `https://updates.macaudioinputlocker.com/appcast.xml` (the legacy `mac-audio-input-locker.jesse.id` host will keep serving older versions during a transition period)
- Copyright string in Info.plist corrected to "Jesse Stilwell"
- `build-release.sh` preflights notarization credentials and Apple agreement status before starting the build, and surfaces the underlying notarytool error if the submission fails (instead of a generic message)

## 1.1.0 - 04-22-2026

### Added

- Optional notification every time the app forces the input back to the selected device (toggle: "Notify on forced input", enabled by default). Notification body names both the interloping device and the restored device, e.g. "AirPods took input control. Forced input back to HyperX."
- 2-second minimum gap between forced-input notifications to suppress CoreAudio churn (e.g. AirPods reconnecting fires the default-input callback multiple times in quick succession). Manually picking a device from the menu always bypasses the gap so rapid user-driven switching still fires every notification.
- "Sound settings…" menu item that opens the system Sound pane directly to the Input tab (macOS 13+) or the Sound preference pane (older versions)

### Fixed

- Clear the device name → ID lookup table at the start of each menu rebuild so stale entries from disconnected devices can't be selected

## 1.0.7 - 03-31-2026

### Fixed

- Forced input selection is now persistent across device disconnects and reconnects — the app saves the device name and automatically restores the selection when the same device reappears with a new system ID

## 1.0.6 - 03-30-2026

### Fixed

- Detect USB-C microphones connected or reconnected while the app is running (added listener for device list changes, not just default input changes)

## 1.0.5 - 02-12-2026

### Changed

- Eliminated recursive menu rebuild loop: when forcing the input device back, the CoreAudio property listener callback now handles the subsequent menu refresh instead of manually dispatching a redundant `listDevices` call
- Moved `setMenu:` call outside the device enumeration loop so it runs once after all devices are processed, not on every iteration
- Dynamically allocate device array based on actual device count instead of using a fixed-size `dev_array[64]` buffer
- Scoped `deviceName` buffer to inside the loop where it's used instead of declaring it at the top of the method
- Replaced `printf` with `NSLog` in CoreAudio callback so log output goes to the system log instead of invisible stdout
- Removed redundant `[prefs synchronize]` calls (unnecessary since macOS 10.8)
- Removed unused `defaults` instance variable (a second `prefs` local was used instead)

### Added

- `CHANGELOG.md` to track project changes
- `.env.example` for Cloudflare R2 configuration
- Automatic appcast.xml upload to Cloudflare R2 in build script
- Build script automatically syncs `SUFeedURL` in Info.plist from `.env` configuration

### Infrastructure

- Build script (`bin/build-release.sh`) now loads R2 configuration from `.env` file
- Update feed URL changed to `https://mac-audio-input-locker.jesse.id/appcast.xml`
- Added `.env` to `.gitignore`
