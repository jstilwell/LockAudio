# Mac Audio Input Locker

This is a fork of the very useful AirPods Sound Quality Fixer And Battery Life Enhancer For MacOS by [milgra](https://github.com/milgra/) that they no longer maintain. I decided to change the name of the app because A) it was too long and B) it didn't make it clear what the best feature of the app was.

I will try to maintain this fork as long as I use the app or until Apple adds their own feature to accomplish the same thing.

## Original Features

- Fixes sound quality drops when using AirPods with Macs
- Uses Mac's default audio input and locks it in so that Bluetooth devices don't auto-switch it.
- Increases battery life on Bluetooth devices because this stops them from broadcasting at all times.

## My Updates

- Switched to semantic versioning
- Signed release so the app can be installed without headaches
- Added a build script to release .dmg files instead of .zip
- Added full Mac Sequoia 15.x compatibility 
- Added automatic updates
- Squashed some bugs
- Fixed all deprecation notices
