# Changelog

All notable changes to this project will be documented in this file.

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
