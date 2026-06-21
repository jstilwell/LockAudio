//
//  AudioLock.m
//  LockAudio
//

#import "AudioLock.h"

@implementation AudioLock
{
    NSString *_defaultsKey;
    NSString *_defaultsNameKey;
}

- (instancetype)initWithDirection:(AudioLockDirection)direction
                      defaultsKey:(NSString *)defaultsKey
                  defaultsNameKey:(NSString *)defaultsNameKey
{
    self = [super init];
    if (self) {
        _direction = direction;
        _defaultsKey = [defaultsKey copy];
        _defaultsNameKey = [defaultsNameKey copy];
        _forcedID = UINT32_MAX;
        _forcedName = nil;
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
}

- (void)saveToDefaults
{
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    [prefs setInteger:_forcedID forKey:_defaultsKey];
    if (_forcedName != nil) {
        [prefs setObject:_forcedName forKey:_defaultsNameKey];
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

    AudioObjectGetPropertyDataSize(
        deviceID,
        &streamsAddress,
        0,
        NULL,
        &propertySize);

    return propertySize > 0;
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
