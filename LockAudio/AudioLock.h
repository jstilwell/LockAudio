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

/// Human-readable name of the forced device, used to recover the ID across
/// disconnect/reconnect (the AudioDeviceID can change).
@property (nonatomic, copy, nullable) NSString *forcedName;

/// When YES, forcing is temporarily disabled for this direction.
@property (nonatomic) BOOL paused;

/// Designated initializer. `defaultsKey` / `defaultsNameKey` are the
/// NSUserDefaults keys used to persist the device id and name.
- (instancetype)initWithDirection:(AudioLockDirection)direction
                      defaultsKey:(NSString *)defaultsKey
                  defaultsNameKey:(NSString *)defaultsNameKey NS_DESIGNATED_INITIALIZER;

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

/// Reads the system's current default device for this direction.
- (AudioDeviceID)currentDefaultDevice;

/// Sets the system's default device for this direction. Returns the OSStatus.
- (OSStatus)applyForce:(AudioDeviceID)deviceID;

/// The CoreAudio property address for this direction's default device, suitable
/// for AudioObjectAddPropertyListener.
- (AudioObjectPropertyAddress)defaultDeviceListenerAddress;

@end

NS_ASSUME_NONNULL_END
