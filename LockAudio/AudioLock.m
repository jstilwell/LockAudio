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

// NSUserDefaults keys. The input keys keep their original names ("Device",
// "DeviceName", "NotificationsEnabled") for backward compatibility.
static NSString* const kPrefInputDevice = @"Device";
static NSString* const kPrefInputDeviceName = @"DeviceName";
static NSString* const kPrefInputDeviceUID = @"DeviceUID";
static NSString* const kPrefInputNotificationsEnabled = @"NotificationsEnabled";
static NSString* const kPrefShowInputOptions = @"ShowInputOptions";
static NSString* const kPrefInputPaused = @"InputPaused";

static NSString* const kPrefOutputDevice = @"OutputDevice";
static NSString* const kPrefOutputDeviceName = @"OutputDeviceName";
static NSString* const kPrefOutputDeviceUID = @"OutputDeviceUID";
static NSString* const kPrefOutputNotificationsEnabled = @"OutputNotificationsEnabled";
static NSString* const kPrefShowOutputOptions = @"ShowOutputOptions";
static NSString* const kPrefOutputPaused = @"OutputPaused";

// Contention: this many forces inside the window means another app is setting
// the default device right back, so stop fighting it for a while. Ordinary
// churn (AirPods settling after connect) stays well under this.
static const NSUInteger kContestedForceCount = 8;
static const NSTimeInterval kContestedWindow = 10.0;
static const NSTimeInterval kContestedBackoff = 60.0;

@implementation AudioLock

{
    NSString *_defaultsKey;
    NSString *_defaultsNameKey;
    NSString *_defaultsUIDKey;
    NSString *_notificationsKey;
    NSString *_showOptionsKey;
    NSString *_pausedKey;
    NSMutableDictionary<NSNumber *, NSNumber *> *_participationCache;
    NSMutableArray<NSDate *> *_recentForces;
}


- (instancetype)initWithDirection:(AudioLockDirection)direction
{
    self = [super init];
    if (self) {
        BOOL isInput = (direction == AudioLockDirectionInput);
        _direction = direction;
        _defaultsKey = isInput ? kPrefInputDevice : kPrefOutputDevice;
        _defaultsNameKey = isInput ? kPrefInputDeviceName : kPrefOutputDeviceName;
        _defaultsUIDKey = isInput ? kPrefInputDeviceUID : kPrefOutputDeviceUID;
        _notificationsKey = isInput ? kPrefInputNotificationsEnabled : kPrefOutputNotificationsEnabled;
        _showOptionsKey = isInput ? kPrefShowInputOptions : kPrefShowOutputOptions;
        _pausedKey = isInput ? kPrefInputPaused : kPrefOutputPaused;
        _forcedID = UINT32_MAX;
        _forcedName = nil;
        _forcedUID = nil;
        _paused = NO;
        _participationCache = [NSMutableDictionary dictionary];
        _recentForces = [NSMutableArray array];
    }
    return self;
}

+ (void)registerDefaults
{
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
        // Output locking is opt-in: notifications default off and no output
        // device is forced until the user chooses one.
        kPrefInputNotificationsEnabled: @YES,
        kPrefOutputNotificationsEnabled: @NO,
        // Input options shown by default (common case); output options hidden
        // by default (rare case — users opt in via "Show Output Options").
        kPrefShowInputOptions: @YES,
        kPrefShowOutputOptions: @NO,
        kPrefInputPaused: @NO,
        kPrefOutputPaused: @NO,
    }];
}

- (NSString *)directionName
{
    return _direction == AudioLockDirectionInput ? @"input" : @"output";
}

- (NSString *)capitalizedDirectionName
{
    return _direction == AudioLockDirectionInput ? @"Input" : @"Output";
}

- (BOOL)showsOptions
{
    return [[NSUserDefaults standardUserDefaults] boolForKey:_showOptionsKey];
}

- (void)setShowsOptions:(BOOL)showsOptions
{
    [[NSUserDefaults standardUserDefaults] setBool:showsOptions forKey:_showOptionsKey];
}

- (BOOL)pausePreference
{
    return [[NSUserDefaults standardUserDefaults] boolForKey:_pausedKey];
}

- (void)setPausePreference:(BOOL)pausePreference
{
    [[NSUserDefaults standardUserDefaults] setBool:pausePreference forKey:_pausedKey];
}

- (BOOL)notificationsEnabled
{
    return [[NSUserDefaults standardUserDefaults] boolForKey:_notificationsKey];
}

- (void)setNotificationsEnabled:(BOOL)notificationsEnabled
{
    [[NSUserDefaults standardUserDefaults] setBool:notificationsEnabled forKey:_notificationsKey];
}

- (BOOL)hasSelection
{
    return _forcedID != UINT32_MAX || _forcedUID != nil || _forcedName != nil;
}

- (AudioLockStatus)status
{
    if (!self.showsOptions) {
        return AudioLockStatusHidden;
    }
    if (_paused) {
        return AudioLockStatusPaused;
    }
    if (!self.hasSelection) {
        return AudioLockStatusUnset;
    }
    if (self.backingOff) {
        return AudioLockStatusContested;
    }
    return _forcedDeviceAvailable ? AudioLockStatusActive : AudioLockStatusMissing;
}

- (BOOL)recordForceAttempt
{
    NSDate *now = [NSDate date];
    [_recentForces addObject:now];
    NSIndexSet *stale = [_recentForces indexesOfObjectsPassingTest:^BOOL(NSDate *date, NSUInteger idx, BOOL *stop) {
        return [now timeIntervalSinceDate:date] > kContestedWindow;
    }];
    [_recentForces removeObjectsAtIndexes:stale];

    if (_recentForces.count < kContestedForceCount) {
        return YES;
    }

    [_recentForces removeAllObjects];
    _backoffUntil = [now dateByAddingTimeInterval:kContestedBackoff];
    return NO;
}

- (BOOL)isBackingOff
{
    return _backoffUntil != nil && _backoffUntil.timeIntervalSinceNow > 0;
}

- (void)resetContention
{
    _backoffUntil = nil;
    [_recentForces removeAllObjects];
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

// Resolves the forced device to a currently-connected AudioDeviceID that
// participates in this direction. The forced AudioDeviceID can change across
// disconnect/reconnect, so we re-derive it on every enforcement pass:
//   1. If the saved `forcedID` is still present AND still identifies the same
//      device (its UID matches `forcedUID`), keep it. CoreAudio can recycle an
//      AudioDeviceID for a different physical device, so when we have a UID we
//      confirm it rather than trusting the bare id.
//   2. Otherwise match by stable UID (kAudioDevicePropertyDeviceUID) — this is
//      the reliable key and fixes output recovery, since a device's display
//      name can change (AirPods codec mode) but its UID does not.
//   3. Otherwise fall back to the display name (covers installs saved before
//      UIDs were persisted) and backfill the UID so future recovery is robust.
// Every match is filtered by `deviceParticipates:` so we never force a device
// that has no stream in this direction. On a successful re-match the new id is
// persisted. When the device isn't connected we keep the saved id/name/UID
// untouched so it can recover later.
- (BOOL)resolveForcedDeviceInDevices:(const AudioDeviceID *)devices
                               count:(int)numberOfDevices
{
    _forcedDeviceAvailable = [self findForcedDeviceInDevices:devices count:numberOfDevices];
    return _forcedDeviceAvailable;
}

- (BOOL)findForcedDeviceInDevices:(const AudioDeviceID *)devices
                            count:(int)numberOfDevices
{
    NSString *dirName = self.directionName;

    // Nothing forced yet (and no saved identity to recover from).
    if ( !self.hasSelection )
    {
        return NO;
    }

    // 1. Saved id still present, participating, and (when we have a UID) still
    //    the same physical device? Keep it.
    if ( _forcedID < UINT32_MAX )
    {
        for ( int index = 0; index < numberOfDevices; index++ )
        {
            if ( devices[index] != _forcedID )
            {
                continue;
            }
            if ( ![self deviceParticipates:devices[index]] )
            {
                break; // id present but not in our direction — try UID/name.
            }
            if ( _forcedUID != nil )
            {
                // We have a stable UID, so the bare id is only trustworthy if it
                // still identifies the same device. Require a positive UID match:
                // a mismatch (id recycled) OR an unreadable UID both fall through
                // to the authoritative UID search rather than risk the wrong one.
                NSString *uid = [self uidForDevice:devices[index]];
                if ( ![_forcedUID isEqualToString:uid] )
                {
                    LADebug("forced %{public}@ id %u no longer confirms UID %{public}@; re-resolving by UID",
                           dirName, (unsigned int)_forcedID, _forcedUID );
                    break; // fall through to UID search.
                }
            }
            else
            {
                // Install saved before UIDs were persisted. Backfill now so the
                // id gets UID-confirmed from here on, instead of waiting for a
                // disconnect to route through the name fallback.
                NSString *uid = [self uidForDevice:devices[index]];
                if ( uid != nil )
                {
                    LADebug("backfilling %{public}@ UID %{public}@ for device %u", dirName, uid, (unsigned int)_forcedID );
                    self.forcedUID = uid;
                    [self saveToDefaults];
                }
            }
            return YES;
        }
    }

    // 2. Match by stable UID.
    if ( _forcedUID != nil )
    {
        for ( int index = 0; index < numberOfDevices; index++ )
        {
            if ( ![self deviceParticipates:devices[index]] )
            {
                continue;
            }
            NSString *uid = [self uidForDevice:devices[index]];
            if ( uid != nil && [uid isEqualToString:_forcedUID] )
            {
                LADebug("forced %{public}@ recovered by UID: %{public}@ -> %u", dirName, uid, (unsigned int)devices[index] );
                _forcedID = devices[index];
                [self saveToDefaults];
                return YES;
            }
        }
    }

    // 3. Fall back to display name; backfill the UID for next time.
    if ( _forcedName != nil )
    {
        for ( int index = 0; index < numberOfDevices; index++ )
        {
            if ( ![self deviceParticipates:devices[index]] )
            {
                continue;
            }
            NSString *nameStr = [self nameForDevice:devices[index]];
            if ( nameStr != nil && [nameStr isEqualToString:_forcedName] )
            {
                LADebug("forced %{public}@ recovered by name: %{public}@ -> %u", dirName, nameStr, (unsigned int)devices[index] );
                _forcedID = devices[index];
                self.forcedUID = [self uidForDevice:devices[index]];
                [self saveToDefaults];
                return YES;
            }
        }
    }

    return NO;
}

@end
