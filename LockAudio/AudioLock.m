//
//  AudioLock.m
//  LockAudio
//

#import "AudioLock.h"

os_log_t LockAudioLog(void)
{
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("com.lockaudio.app", "audio");
    });
    return log;
}

@implementation AudioLock

{
    NSString *_defaultsKey;
    NSString *_defaultsNameKey;
    NSString *_defaultsUIDKey;
    NSMutableDictionary<NSNumber *, NSNumber *> *_participationCache;
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
        _participationCache = [NSMutableDictionary dictionary];
    }
    return self;
}

+ (NSData *)connectedDeviceIDs
{
    AudioObjectPropertyAddress devicesAddress = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    UInt32 propertySize = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(
        kAudioObjectSystemObject,
        &devicesAddress,
        0,
        NULL,
        &propertySize);

    if (status != noErr) {
        LAError("connectedDeviceIDs: size read failed (OSStatus %d)", (int)status);
        return nil;
    }
    if (propertySize == 0) {
        return [NSData data];
    }

    NSMutableData *data = [NSMutableData dataWithLength:propertySize];
    status = AudioObjectGetPropertyData(
        kAudioObjectSystemObject,
        &devicesAddress,
        0,
        NULL,
        &propertySize,
        data.mutableBytes);

    if (status != noErr) {
        LAError("connectedDeviceIDs: device list read failed (OSStatus %d)", (int)status);
        return nil;
    }

    // The read reports how many bytes it actually filled; a device can vanish
    // between the size query and the read, so trust the returned size.
    data.length = propertySize - (propertySize % sizeof(AudioDeviceID));
    return data;
}

- (void)invalidateDeviceCache
{
    [_participationCache removeAllObjects];
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
    NSNumber *cached = _participationCache[@(deviceID)];
    if (cached != nil) {
        return cached.boolValue;
    }

    BOOL participates = [self readDeviceParticipates:deviceID];
    _participationCache[@(deviceID)] = @(participates);
    return participates;
}

- (BOOL)readDeviceParticipates:(AudioDeviceID)deviceID
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
        LAError("deviceParticipates: stream-size read failed for device %u (OSStatus %d); treating as non-participating",
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
    // kAudioObjectPropertyName is the CFString form of the deprecated
    // kAudioDevicePropertyDeviceName (same value, so names persisted by older
    // versions still match); it has no 256-byte truncation or encoding caveats.
    AudioObjectPropertyAddress nameAddress = {
        kAudioObjectPropertyName,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    CFStringRef name = NULL;
    UInt32 propertySize = sizeof(name);

    OSStatus status = AudioObjectGetPropertyData(
        deviceID,
        &nameAddress,
        0,
        NULL,
        &propertySize,
        &name);

    if (status != noErr || name == NULL) {
        return nil;
    }

    NSString *result = (__bridge_transfer NSString *)name;

    // An empty name can't identify or label a device; treat it as unreadable so
    // it never matches a forced selection or appears as a blank menu row.
    return result.length > 0 ? result : nil;
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

- (AudioDeviceID)builtInDeviceInDevices:(const AudioDeviceID *)devices

                                  count:(int)numberOfDevices
{
    AudioObjectPropertyAddress transportAddress = {
        kAudioDevicePropertyTransportType,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    for ( int index = 0; index < numberOfDevices; index++ )
    {
        AudioDeviceID deviceID = devices[index];

        // Only consider devices that have a stream in this direction, so the
        // output fallback lands on built-in *speakers* and the input fallback on
        // the built-in *mic* (these are distinct CoreAudio devices).
        if ( ![self deviceParticipates:deviceID] )
        {
            continue;
        }

        UInt32 transportType = 0;
        UInt32 propertySize = sizeof(transportType);
        OSStatus status = AudioObjectGetPropertyData(
            deviceID,
            &transportAddress,
            0,
            NULL,
            &propertySize,
            &transportType);

        if ( status == noErr && transportType == kAudioDeviceTransportTypeBuiltIn )
        {
            return deviceID;
        }
    }

    return kAudioDeviceUnknown;
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
