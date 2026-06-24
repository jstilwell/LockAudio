# LockAudio

A lightweight macOS menu bar app that locks your audio input and output to the devices you choose — so macOS (and Bluetooth devices like AirPods) can't switch them out from under you.

When AirPods connect, macOS often routes the microphone to them too, which drops your audio quality to a low-bandwidth call mode and drains AirPods battery faster. LockAudio keeps your input on the device you actually want (e.g. the built-in mic), so output stays in high-quality mode. It can do the same for output.

## Features

- **Input locking** — pin the system audio input to a device of your choice. If something switches it away, LockAudio forces it right back.
- **Output locking** — optionally pin the system audio output the same way (off by default; turn on "Show Output Options" to enable).
- **Independent locks** — input and output are controlled separately, so you can keep your mic on the built-in input while locking output wherever you like.
- **Survives reconnects** — your choice is remembered and restored automatically when a device disconnects and comes back, even if macOS reassigns it a new internal ID.
- **Optional notifications** — get notified when a lock forces a device back, per direction.
- **Pause anytime** — temporarily disable either lock without losing your settings.
- **Stays out of the way** — menu bar only (no Dock icon), launches at login if you want, and updates itself automatically.

Your settings — locked devices, pause state, and which options are shown — persist across quitting the app and rebooting.

## Installation

Download the latest DMG from the [releases page](https://github.com/jstilwell/LockAudio/releases), open it, and drag **LockAudio** to your Applications folder. The app is signed and notarized, and updates itself from then on.

Requires macOS 10.14 or later.

---

LockAudio began as a fork of the AirPods Sound Quality Fixer And Battery Life Enhancer for macOS by [milgra](https://github.com/milgra/) — thanks to them for the original codebase.
