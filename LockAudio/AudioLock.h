//
//  AudioLock.h
//  LockAudio
//
//  Encapsulates the state and CoreAudio plumbing for forcing the system's
//  default device in one direction (input or output) to a user-chosen device.
//  AppDelegate owns one AudioLock per direction.
//

#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, AudioLockDirection) {
    AudioLockDirectionInput,
    AudioLockDirectionOutput,
};

@interface AudioLock : NSObject

/// The direction this lock controls.
@property (nonatomic, readonly) AudioLockDirection direction;

/// AudioDeviceID currently being forced. UINT32_MAX means "built-in default"
/// has not been resolved to a concrete device yet (matches the legacy sentinel).
@property (nonatomic) AudioDeviceID forcedID;

/// Human-readable name of the forced device. Used as a *fallback* to recover
/// the ID across disconnect/reconnect for installs saved before `forcedUID`
/// existed. Prefer `forcedUID` — the display name can change (e.g. AirPods
/// codec-mode changes, localization), which is why output recovery was flaky.
@property (nonatomic, copy, nullable) NSString *forcedName;

/// Stable, persistent CoreAudio device UID (kAudioDevicePropertyDeviceUID) of
/// the forced device. Unlike the display name this is intended for persistence
/// and does not change across disconnect/reconnect, so it is the primary key
/// used to recover the AudioDeviceID (which *does* change).
@property (nonatomic, copy, nullable) NSString *forcedUID;

/// When YES, forcing is temporarily disabled for this direction. This is the
/// runtime state; the persisted pause *preference* lives in NSUserDefaults
/// (AppDelegate owns it, since it interacts with the show/hide toggles).
@property (nonatomic) BOOL paused;

/// Designated initializer. `defaultsKey` / `defaultsNameKey` / `defaultsUIDKey`
/// are the NSUserDefaults keys used to persist the device id, display name, and
/// stable UID respectively.
- (instancetype)initWithDirection:(AudioLockDirection)direction
                      defaultsKey:(NSString *)defaultsKey
                  defaultsNameKey:(NSString *)defaultsNameKey
                   defaultsUIDKey:(NSString *)defaultsUIDKey NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

/// The CoreAudio selector for this direction's default device
/// (kAudioHardwarePropertyDefaultInputDevice / …OutputDevice).
@property (nonatomic, readonly) AudioObjectPropertySelector defaultDeviceSelector;

/// The CoreAudio device-property scope for this direction's streams
/// (kAudioDevicePropertyScopeInput / …Output). Used to decide whether a device
/// participates in this direction.
@property (nonatomic, readonly) AudioObjectPropertyScope streamScope;

/// Loads forcedID/forcedName from NSUserDefaults. Returns the raw saved id.
- (void)loadFromDefaults;

/// Persists the current forcedID (and forcedName when non-nil) to NSUserDefaults.
- (void)saveToDefaults;

/// YES if `deviceID` has at least one stream in this lock's direction.
- (BOOL)deviceParticipates:(AudioDeviceID)deviceID;

/// Reads the stable persistent UID (kAudioDevicePropertyDeviceUID) for a device,
/// or nil if it can't be read. This UID survives disconnect/reconnect even
/// though the AudioDeviceID does not.
- (nullable NSString *)uidForDevice:(AudioDeviceID)deviceID;

/// Reads a device's display name (kAudioDevicePropertyDeviceName), or nil if it
/// can't be read.
- (nullable NSString *)nameForDevice:(AudioDeviceID)deviceID;

/// Reads the system's current default device for this direction.
- (AudioDeviceID)currentDefaultDevice;

/// Finds the built-in device (built-in speakers for output, built-in mic for
/// input) among `devices` that participates in this direction, identified by
/// CoreAudio transport type (kAudioDeviceTransportTypeBuiltIn) rather than its
/// localized name. Returns kAudioDeviceUnknown if there is no participating
/// built-in device. Used as the fallback target when the forced device
/// disconnects, so macOS doesn't pick an arbitrary other device.
- (AudioDeviceID)builtInDeviceInDevices:(AudioDeviceID *)devices
                                  count:(int)numberOfDevices;

/// Sets the system's default device for this direction. Returns the OSStatus.
- (OSStatus)applyForce:(AudioDeviceID)deviceID;

/// The CoreAudio property address for this direction's default device, suitable
/// for AudioObjectAddPropertyListener.
- (AudioObjectPropertyAddress)defaultDeviceListenerAddress;

@end

NS_ASSUME_NONNULL_END
