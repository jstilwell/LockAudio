# Implementation Plan: Output Locking (2.0.0)

Goal: add independent **output** device locking alongside the existing **input**
locking, plus a "Notify on forced output" option, and refresh the app/menu-bar
icon away from the earbuds theme.

Decisions (locked):
- Independent input + output locks (each: device picker, force, notify).
- Refactor input logic into a reusable `AudioLock` abstraction first, then add
  output as a second instance.
- Icon redesigned from an SF Symbol (glyph TBD), rendered to a full AppIcon set
  + template menu-bar icon.

---

## Stage 1: Extract `AudioLock` abstraction (input only, behavior unchanged)
**Goal**: Move per-device locking state + logic out of AppDelegate into a small
reusable object parameterized by direction (input/output), with no behavior
change for input.
**Scope of `AudioLock`**: forcedID, forcedName, the CoreAudio scope constants
(`kAudioHardwarePropertyDefaultInputDevice` vs `…OutputDevice`,
`kAudioDevicePropertyScopeInput` vs `…Output`), NSUserDefaults keys (namespaced),
enumerate-matching-devices, recover-by-name, read-current-default, apply-force.
**Success Criteria**: Input locking behaves exactly as before; defaults still
read/written under the existing `Device`/`DeviceName` keys (no migration break).
**Tests**: Manual via `./bin/test-build.sh` — built-in default selected on fresh
run; switching device forces correctly; reconnect recovers by name; pause works.
**Status**: Not Started

## Stage 2: Add output `AudioLock` instance
**Goal**: Instantiate a second `AudioLock` for output; register its property
listener; wire its prefs keys (`OutputDevice`/`OutputDeviceName`).
**Success Criteria**: Selecting a forced output device forces system output to
it and re-forces when another device steals output; independent of input lock.
**Tests**: Manual — lock output to built-in while input locked to built-in;
plug in AirPods, confirm output is forced back per setting; confirm input lock
still independent.
**Status**: Not Started

## Stage 3: Menu + notifications wiring
**Goal**: Add "Forced output:" device section, output pause, and "Notify on
forced output" toggle (mirrors input). Notification copy distinguishes
input vs output. Keep menu readable.
**Success Criteria**: Both sections render; toggles persist; output notification
fires (respecting the screen-lock + min-gap suppression already in place);
existing input notify unchanged.
**Tests**: Manual — toggle each notify independently; trigger a forced output and
confirm a correctly-worded notification; verify gap/lock suppression.
**Status**: Not Started

## Stage 4: Icon refresh
**Goal**: Replace earbuds app icon + menu-bar template image with an
SF-Symbol-derived design (glyph chosen by user). Generate full `AppIcon` png set
(1024→16) in the asset catalog and a template menu-bar png (@1x/@2x).
**Success Criteria**: App icon shows in Finder/Dock-less About window; menu-bar
glyph renders crisply in light/dark menu bar as a template image.
**Tests**: Visual — About window icon; menu-bar icon in light & dark mode.
**Status**: Not Started

---
Remove this file when all stages are complete.
