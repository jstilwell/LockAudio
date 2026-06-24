//
//  AudioLock.m
//  LockAudio
//

#import "AudioLock.h"

@implementation AudioLock
{
    NSString *_defaultsKey;
    NSString *_defaultsNameKey;
    NSString *_defaultsUIDKey;
}

- (instancetype)initWithDirection:(AudioLockDirection)direction
                      defaultsKey:(NSString *)defaultsKey
                  defaultsNameKey:(NSString *)defaultsNameKey
                   defaultsUIDKey:(NSString *)defaultsUIDKey
{
    self = [super init];
    if (self) {
        _direction = direction;
        _defaultsKey = [defaultsKey copy];
        _defaultsNameKey = [defaultsNameKey copy];
        _defaultsUIDKey = [defaultsUIDKey copy];
        _forcedID = UINT32_MAX;
        _forcedName = nil;
        _forcedUID = nil;
        _paused = NO;
    }
    return self;
}

- (AudioObjectPropertySelector)defaultDeviceSelector
{
    return _direction == AudioLockDirectionInput
        ? kAudioHardwarePropertyDefaultInputDevice
        : kAudioHardwarePropertyDefaultOutputDevice;
}

- (AudioObjectPropertyScope)streamScope
{
    return _direction == AudioLockDirectionInput
        ? kAudioDevicePropertyScopeInput
        : kAudioDevicePropertyScopeOutput;
}

- (void)loadFromDefaults
{
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];

    NSInteger savedId = [prefs integerForKey:_defaultsKey];

    // 0 is the "never set" sentinel — initialise to the built-in-default marker.
    if (savedId == 0) {
        [prefs setInteger:UINT32_MAX forKey:_defaultsKey];
        savedId = UINT32_MAX;
    }

    _forcedID = (AudioDeviceID)savedId;
    _forcedName = [prefs stringForKey:_defaultsNameKey];
    _forcedUID = [prefs stringForKey:_defaultsUIDKey];
}

- (void)saveToDefaults
{
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    [prefs setInteger:_forcedID forKey:_defaultsKey];

    // Mirror nil -> remove so a new selection can't be shadowed by the previous
    // device's leftover identity. If a freshly chosen device's UID read fails
    // (forcedUID nil) we must clear the old UID, otherwise recovery would match
    // the device the user just switched away from.
    if (_forcedName != nil) {
        [prefs setObject:_forcedName forKey:_defaultsNameKey];
    } else {
        [prefs removeObjectForKey:_defaultsNameKey];
    }
    if (_forcedUID != nil) {
        [prefs setObject:_forcedUID forKey:_defaultsUIDKey];
    } else {
        [prefs removeObjectForKey:_defaultsUIDKey];
    }
}

- (BOOL)deviceParticipates:(AudioDeviceID)deviceID
{
    UInt32 propertySize = 0;

    AudioObjectPropertyAddress streamsAddress = {
        kAudioDevicePropertyStreams,
        self.streamScope,
        kAudioObjectPropertyElementMain
    };

    OSStatus status = AudioObjectGetPropertyDataSize(
        deviceID,
        &streamsAddress,
        0,
        NULL,
        &propertySize);

    // Fail closed: only report participation when we positively read at least
    // one stream in this direction. A read failure returns NO so we never
    // force/auto-pick/list a device we can't confirm has streams here; a
    // transiently-failed forced device simply recovers on the next rebuild.
    if (status != noErr) {
        NSLog(@"deviceParticipates: stream-size read failed for device %u (OSStatus %d); treating as non-participating",
              (unsigned int)deviceID, (int)status);
        return NO;
    }

    return propertySize > 0;
}

- (NSString *)uidForDevice:(AudioDeviceID)deviceID
{
    AudioObjectPropertyAddress uidAddress = {
        kAudioDevicePropertyDeviceUID,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    CFStringRef uid = NULL;
    UInt32 propertySize = sizeof(uid);

    OSStatus status = AudioObjectGetPropertyData(
        deviceID,
        &uidAddress,
        0,
        NULL,
        &propertySize,
        &uid);

    if (status != noErr || uid == NULL) {
        return nil;
    }

    return (__bridge_transfer NSString *)uid;
}

- (NSString *)nameForDevice:(AudioDeviceID)deviceID
{
    char deviceName[256] = {0};
    UInt32 nameSize = sizeof(deviceName);

    AudioObjectPropertyAddress nameAddr = {
        kAudioDevicePropertyDeviceName,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    OSStatus status = AudioObjectGetPropertyData(
        deviceID,
        &nameAddr,
        0,
        NULL,
        &nameSize,
        deviceName);

    if (status != noErr) {
        return nil;
    }

    // Bound the length to the buffer in case CoreAudio ever returns 256 bytes
    // with no NUL terminator (stringWithUTF8String: would over-read).
    NSUInteger len = strnlen(deviceName, sizeof(deviceName));

    // Prefer UTF-8, but fall back to a lossy decode so a device whose name has
    // non-UTF8 bytes still yields a stable string (name matching is only a
    // legacy fallback to UID recovery; a consistent string is what matters).
    NSString *name = [[NSString alloc] initWithBytes:deviceName
                                              length:len
                                            encoding:NSUTF8StringEncoding];
    if (name == nil) {
        name = [[NSString alloc] initWithBytes:deviceName
                                        length:len
                                      encoding:NSISOLatin1StringEncoding];
    }

    // An empty name can't identify or label a device; treat it as unreadable so
    // it never matches a forced selection or appears as a blank menu row.
    if (name.length == 0) {
        return nil;
    }

    return name;
}

- (AudioDeviceID)currentDefaultDevice
{
    AudioDeviceID deviceID = kAudioDeviceUnknown;
    UInt32 propertySize = sizeof(deviceID);

    AudioObjectPropertyAddress address = {
        self.defaultDeviceSelector,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    AudioObjectGetPropertyData(
        kAudioObjectSystemObject,
        &address,
        0,
        NULL,
        &propertySize,
        &deviceID);

    return deviceID;
}

- (OSStatus)applyForce:(AudioDeviceID)deviceID
{
    AudioObjectPropertyAddress address = {
        self.defaultDeviceSelector,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 size = sizeof(AudioDeviceID);
    return AudioObjectSetPropertyData(
        kAudioObjectSystemObject,
        &address,
        0,
        NULL,
        size,
        &deviceID);
}

- (AudioObjectPropertyAddress)defaultDeviceListenerAddress
{
    AudioObjectPropertyAddress address = {
        self.defaultDeviceSelector,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    return address;
}

@end
