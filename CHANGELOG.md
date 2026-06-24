# Changelog

All notable changes to this project will be documented in this file.

## 2.0.1 - 06-24-2026

### Fixed

- Forced output is now reliably restored after the locked device disconnects and reconnects. Previously a forced output device (e.g. AirPods) could be forgotten on reconnect because recovery matched on the device's display name, which some devices change between connections. Recovery now keys on the device's stable system identifier, so the lock re-applies to the right device every time. Forced input is restored the same way.
- A device whose name is momentarily unreadable while it reconnects no longer disappears from the menu — if it's the one you've locked, it stays listed and checked so you can always see what's forced.

## 2.0.0 - 06-21-2026

### Added

- Output locking: in addition to forcing the input device, you can now lock the system's audio output to a device of your choice. Input and output locks are fully independent, so you can keep your mic on the built-in input while locking output wherever you like. Output options are hidden by default (input locking is the common case) — turn on "Show Output Options" to reveal the "Forced output:" section and pick a device.
- "Show Input Options" and "Show Output Options" toggles let you hide the controls for a direction you don't use. Hiding a direction also pauses its lock; showing it again restores it.
- "Notify on forced output" toggle (off by default), mirroring the existing input notification. When the locked output is taken over by another device, the app forces it back and — if enabled — posts a notification naming both devices.
- Per-lock pause: "Pause Input Lock" and "Pause Output Lock" let you temporarily disable forcing in each direction independently. Pause state, device choices, and the show/hide toggles all persist across quitting the app and rebooting.

### Changed

- The app is now called LockAudio (formerly Mac Audio Input Locker). The website has moved to lockaudio.com and support is now contact@lockaudio.com.
- Menu controls (pause, notifications, open-at-login) now show icons, so app actions are easy to tell apart from the selectable device rows.
- "Sound settings…" now opens the general Sound pane (covering both input and output) instead of the Input tab.

## 1.1.3 - 05-15-2026

### Fixed

- Suppress forced-input notifications while the screen is locked. Forcing the input still happens — only the user-visible notification is suppressed.

## 1.1.2 - 04-22-2026

### Fixed

- Suppress misleading "Forced input active" notifications when the selected forced input is not connected. The app now tracks whether the forced device is present in the current device list and skips the force-set call (and its notification) when it isn't, instead of silently no-op'ing the CoreAudio set and still firing the notification. When the device reconnects, the existing name-recovery path restores forcing automatically.
- Only post the forced-input notification when `AudioObjectSetPropertyData` actually returns `noErr`, so other silent-failure cases can't produce a misleading notification either
- Don't post a forced-input notification when the user picks a device from the menu. Previously the CoreAudio property listener could see the old default briefly after a user switch and re-force the new selection, firing a "Forced input active" notification as if an external device had taken control. User-initiated switches now set a one-shot suppression flag consumed by the next `listDevices` rebuild.

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
