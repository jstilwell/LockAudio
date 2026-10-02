#import "AppDelegate.h"
#import "GBLaunchAtLogin.h"
#import "AudioLock.h"
#import <CoreAudio/CoreAudio.h>
#import <UserNotifications/UserNotifications.h>

@interface LinkCursorView : NSView
@end

@implementation LinkCursorView
- (void)resetCursorRects
{
    [self addCursorRect:self.bounds cursor:[NSCursor pointingHandCursor]];
}
@end

// Per-direction preference keys (device, show/hide, pause, notify) live in
// AudioLock. These are the app-wide ones.

// Persisted launch-at-login state. The app's actual login-item registration
// lives in SMAppService (queried live by GBLaunchAtLogin), but we also mirror
// it here so the preference is migratable across a future bundle-identifier
// change — the way the device preference is.
static NSString* const kPrefLaunchAtLogin = @"LaunchAtLogin";

// Bundle identifier of the app before the LockAudio rename, and the keys it
// used. Used once, on first launch under the new identifier, to migrate the
// user's saved settings.
static NSString* const kLegacyBundleIdentifier = @"com.audio.locker";
static NSString* const kLegacyPrefDevice = @"Device";
static NSString* const kLegacyPrefDeviceName = @"DeviceName";
static NSString* const kLegacyPrefNotificationsEnabled = @"NotificationsEnabled";

// Minimum gap between forced-device notifications (per direction). Under this
// threshold we treat successive fires as CoreAudio churn (e.g. AirPods settling)
// and suppress; legitimate user-driven switches always exceed this easily.
static const NSTimeInterval kMinNotificationGap = 2.0;

// After a user picks a device, its own echo through the listeners shouldn't
// read as "forced back", so notifications stay quiet this long.
static const NSTimeInterval kUserSwitchQuietPeriod = 1.0;

// When the forced device disconnects, fall back to the built-in device for this
// long — long enough to win against macOS's own reassignment, which can land
// after ours — then respect whatever the user picks until it reconnects.
static const NSTimeInterval kFallbackGraceInterval = 3.0;

// A failed force (e.g. a device still settling after connect) is retried a few
// times; after that we wait for the next device change.
static const NSTimeInterval kForceRetryDelay = 0.5;
static const NSUInteger kMaxForceRetries = 3;

// Overall state shown by the menu bar icon.
typedef NS_ENUM(NSUInteger, StatusIconState) {
    StatusIconStateActive,
    StatusIconStatePaused,
    StatusIconStateAttention,
};



@interface AppDelegate ( ) <UNUserNotificationCenterDelegate>
{
    NSMenu* menu;
    NSStatusItem* statusItem;
    AudioLock* inputLock;
    AudioLock* outputLock;
    BOOL menuOpen;
    BOOL screenLocked;
    NSWindow* aboutWindow;
    // Shared listener block for all three CoreAudio property listeners.
    AudioObjectPropertyListenerBlock deviceChangeListener;
}

@property (strong) SPUStandardUpdaterController *updaterController;

@end


@implementation AppDelegate


- ( NSArray<AudioLock*>* ) locks
{
    return @[ inputLock, outputLock ];
}


// Copies the user's settings from the pre-rename app (com.audio.locker) into
// this app's preferences the first time we launch under the new bundle
// identifier. Runs at most once: as soon as a "Device" value exists in our own
// domain, there is nothing to migrate. Reads the legacy domain with
// CFPreferencesCopyAppValue, which works across bundle identifiers.
- ( void ) migrateSettingsFromLegacyBundleIfNeeded
{
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];

    // If we already have a saved device, the user has used (or migrated into)
    // this app before — don't touch anything.
    if ( [prefs objectForKey:kLegacyPrefDevice] != nil )
    {
        return;
    }

    CFStringRef legacyID = (__bridge CFStringRef)kLegacyBundleIdentifier;

    id legacyDevice = (__bridge_transfer id)CFPreferencesCopyAppValue(
        (__bridge CFStringRef)kLegacyPrefDevice, legacyID);

    // No legacy device means this is a genuine fresh install, not an upgrade.
    if ( legacyDevice == nil )
    {
        return;
    }

    if ( ![legacyDevice isKindOfClass:[NSNumber class]] && ![legacyDevice isKindOfClass:[NSString class]] )
    {
        LAError("Legacy Device preference has unexpected type %{public}@; skipping migration", [legacyDevice class]);
        return;
    }

    [prefs setInteger:[legacyDevice integerValue] forKey:kLegacyPrefDevice];


    id legacyDeviceName = (__bridge_transfer id)CFPreferencesCopyAppValue(
        (__bridge CFStringRef)kLegacyPrefDeviceName, legacyID);
    if ( [legacyDeviceName isKindOfClass:[NSString class]] )
    {
        [prefs setObject:legacyDeviceName forKey:kLegacyPrefDeviceName];
    }

    id legacyNotifications = (__bridge_transfer id)CFPreferencesCopyAppValue(
        (__bridge CFStringRef)kLegacyPrefNotificationsEnabled, legacyID);
    if ( legacyNotifications != nil )
    {
        [prefs setBool:[legacyNotifications boolValue] forKey:kLegacyPrefNotificationsEnabled];
    }

    // Launch-at-login: the legacy app never persisted this preference (it read
    // SMAppService live), so there is usually nothing to read here. If a value
    // is present and on, re-register LockAudio once so the behaviour carries
    // over. From now on we persist the flag (see toggleStartupItem), so this is
    // the last rename that can lose it.
    id legacyLaunchAtLogin = (__bridge_transfer id)CFPreferencesCopyAppValue(
        (__bridge CFStringRef)kPrefLaunchAtLogin, legacyID);
    if ( [legacyLaunchAtLogin boolValue] && ![GBLaunchAtLogin isLoginItem] )
    {
        NSError *error = nil;
        if ( [GBLaunchAtLogin addAppAsLoginItem:&error] )
        {
            [prefs setBool:YES forKey:kPrefLaunchAtLogin];
        }
        else
        {
            LAError("Migrating launch-at-login failed: %{public}@", error);
        }
    }

    LADebug("Migrated settings from legacy bundle %{public}@: Device=%ld name=%{public}@",
          kLegacyBundleIdentifier, (long)[legacyDevice integerValue], legacyDeviceName);
}


- ( void ) applicationDidFinishLaunching : ( NSNotification* ) aNotification
{
    // Initialize Sparkle updater
    self.updaterController = [[SPUStandardUpdaterController alloc] initWithStartingUpdater:YES updaterDelegate:nil userDriverDelegate:nil];

    screenLocked = NO;

    NSDistributedNotificationCenter *dnc = [NSDistributedNotificationCenter defaultCenter];
    [dnc addObserver:self
            selector:@selector(screenDidLock:)
                name:@"com.apple.screenIsLocked"
              object:nil];
    [dnc addObserver:self
            selector:@selector(screenDidUnlock:)
                name:@"com.apple.screenIsUnlocked"
              object:nil];


    // One-time migration of settings from the pre-rename app (com.audio.locker).
    // The rename to LockAudio changed the bundle identifier to com.lockaudio.app,
    // so NSUserDefaults starts empty for upgrading users. Seed it from the old
    // domain's values the first time we launch under the new identifier.
    [self migrateSettingsFromLegacyBundleIfNeeded];

    [AudioLock registerDefaults];

    inputLock = [[AudioLock alloc] initWithDirection:AudioLockDirectionInput];
    outputLock = [[AudioLock alloc] initWithDirection:AudioLockDirectionOutput];

    // Runtime pause state = persisted pause preference OR section hidden. A
    // hidden direction is always paused (so it doesn't force while hidden); a
    // visible one reflects the user's saved pause choice. Both survive relaunch.
    for ( AudioLock *lock in self.locks )
    {
        [lock loadFromDefaults];
        lock.paused = lock.pausePreference || !lock.showsOptions;
    }

    // Show our notifications as banners even while the About window is up.
    [UNUserNotificationCenter currentNotificationCenter].delegate = self;
    [self requestNotificationAuthorizationIfNeeded];

    LADebug("Loaded input lock: %d (%{public}@), output lock: %d (%{public}@)",
          inputLock.forcedID, inputLock.forcedName,
          outputLock.forcedID, outputLock.forcedName);

    statusItem = [ [ NSStatusBar systemStatusBar ] statusItemWithLength : NSVariableStatusItemLength ];

    // The menu is populated lazily in menuNeedsUpdate: (and refreshed in place
    // while open), so device changes only pay for enforcement, not menu
    // building.
    menu = [ [ NSMenu alloc ] init ];
    menu.delegate = self;
    statusItem.menu = menu;

    // Listen for changes to the default input and output devices, and for the
    // device list itself changing (devices added/removed). CoreAudio delivers
    // these on the main queue. Enforcement is cheap, so it runs on every
    // notification with no coalescing delay: the sooner a stolen default is
    // put back, the shorter the audible glitch (e.g. AirPods dropping into
    // call-quality mode).
    __weak AppDelegate *weakSelf = self;
    deviceChangeListener = ^( UInt32 inNumberAddresses, const AudioObjectPropertyAddress *inAddresses ) {
        LADebug("audio device change notification" );
        [weakSelf enforceLocks];
    };

    AudioObjectPropertyAddress inputDeviceAddress = [inputLock defaultDeviceListenerAddress];
    AudioObjectAddPropertyListenerBlock(
        kAudioObjectSystemObject,
        &inputDeviceAddress,
        dispatch_get_main_queue(),
        deviceChangeListener );

    AudioObjectPropertyAddress outputDeviceAddress = [outputLock defaultDeviceListenerAddress];
    AudioObjectAddPropertyListenerBlock(
        kAudioObjectSystemObject,
        &outputDeviceAddress,
        dispatch_get_main_queue(),
        deviceChangeListener );

    AudioObjectPropertyAddress devicesChangedAddress = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    AudioObjectAddPropertyListenerBlock(
        kAudioObjectSystemObject,
        &devicesChangedAddress,
        dispatch_get_main_queue(),
        deviceChangeListener );

    [ self enforceLocks ];
}


#pragma mark - Enforcement

// Re-resolves every shown lock's forced device and puts the default back where
// it belongs, then refreshes the status icon (and the menu, if it's open).
// Called from the CoreAudio listeners, on launch, and after any user action
// that changes a lock.
- ( void ) enforceLocks
{
    NSData *deviceData = [AudioLock connectedDeviceIDs];
    if ( deviceData == nil )
    {
        // CoreAudio unreachable (e.g. coreaudiod restarting). Acting on an empty
        // list would mark every forced device missing; wait for the next
        // notification instead.
        return;
    }
    const AudioDeviceID *devices = deviceData.bytes;
    int numberOfDevices = (int)( deviceData.length / sizeof( AudioDeviceID ) );
    LADebug("devices found : %i" , numberOfDevices );

    for ( AudioLock *lock in self.locks )
    {
        [ lock invalidateDeviceCache ];
        if ( lock.showsOptions )
        {
            [ self enforceLock : lock devices : devices count : numberOfDevices ];
        }
    }

    [ self updateStatusItem ];

    if ( menuOpen )
    {
        [ self populateMenu : menu ];
    }
}


- ( void ) enforceLock : ( AudioLock* ) lock
               devices : ( const AudioDeviceID* ) devices
                 count : ( int ) numberOfDevices
{
    NSString *dirName = lock.directionName;

    // Resolve the forced device to a currently-connected AudioDeviceID. Prefers
    // the stable UID, falls back to the display name. This is what makes a
    // forced device survive disconnect/reconnect even though its AudioDeviceID
    // — and, for some devices like AirPods, its display name — can change.
    BOOL available = [ lock resolveForcedDeviceInDevices : devices count : numberOfDevices ];

    // Default the INPUT lock to the built-in microphone when nothing has ever
    // been saved. Output locking is opt-in, so it has no default device. The
    // built-in device is identified by CoreAudio transport type rather than by
    // name: Intel Macs call it "Built-in Microphone" but Apple Silicon Macs use
    // "MacBook Pro Microphone" / "Mac Studio Speakers", so a name heuristic
    // silently matched nothing on modern hardware.
    if ( lock.direction == AudioLockDirectionInput && !lock.hasSelection )
    {
        AudioDeviceID builtInID = [ lock builtInDeviceInDevices : devices count : numberOfDevices ];
        NSString *builtInName = ( builtInID != kAudioDeviceUnknown ) ? [ lock nameForDevice : builtInID ] : nil;

        if ( builtInName != nil )
        {
            LADebug("setting default forced %{public}@ : %{public}@  %u", dirName, builtInName, (unsigned int)builtInID );

            lock.forcedID = builtInID;
            lock.forcedName = builtInName;
            lock.forcedUID = [ lock uidForDevice : builtInID ];
            lock.forcedDeviceAvailable = YES;
            available = YES;
            [ lock saveToDefaults ];
        }
    }

    if ( available )
    {
        lock.missingSince = nil;
    }
    else if ( lock.hasSelection && lock.missingSince == nil )
    {
        LADebug("forced %{public}@ device '%{public}@' not connected; keeping saved selection for recovery", dirName, lock.forcedName );
        lock.missingSince = [ NSDate date ];
    }

    if ( lock.paused || lock.backingOff )
    {
        return;
    }

    AudioDeviceID currentID = [ lock currentDefaultDevice ];
    LADebug("default %{public}@ device is %u" , dirName, currentID );

    if ( available )
    {
        if ( currentID == lock.forcedID )
        {
            lock.consecutiveForceFailures = 0;
            return;
        }

        if ( ![ lock recordForceAttempt ] )
        {
            [ self handleContentionForLock : lock currentDevice : currentID ];
            return;
        }

        LADebug("forcing %{public}@ device for default : %u" , dirName, lock.forcedID );
        NSString *offendingName = [ lock nameForDevice : currentID ];
        OSStatus forceStatus = [ lock applyForce : lock.forcedID ];

        if ( forceStatus == noErr )
        {
            lock.consecutiveForceFailures = 0;
            [ self postForcedNotificationForLock : lock offendingName : offendingName ];
        }
        else
        {
            LAError("force %{public}@ failed: OSStatus %d", dirName, (int)forceStatus );
            [ self scheduleRetryAfterForceFailureForLock : lock ];
        }
        // The property listener will fire for the change we just made and
        // re-run enforcement, which then finds nothing to do.
    }
    else if ( lock.missingSince != nil
              && -lock.missingSince.timeIntervalSinceNow <= kFallbackGraceInterval )
    {
        // The forced device just disconnected. Don't leave the default to
        // macOS, which can land on an arbitrary device (e.g. a RØDE that's both
        // an input and output) instead of the built-in. Fall back to the
        // built-in device — but only for a short grace period after the
        // disconnect, so a device the user deliberately picks while the locked
        // one is away isn't overridden. The saved selection is untouched, so the
        // lock recovers the forced device the moment it reconnects.
        AudioDeviceID builtInID = [ lock builtInDeviceInDevices : devices count : numberOfDevices ];

        if ( builtInID != kAudioDeviceUnknown && currentID != builtInID )
        {
            LADebug("forced %{public}@ device '%{public}@' not connected; falling back to built-in %u",
                   dirName, lock.forcedName, (unsigned int)builtInID );

            OSStatus forceStatus = [ lock applyForce : builtInID ];
            if ( forceStatus != noErr )
            {
                LAError("fallback %{public}@ force failed: OSStatus %d", dirName, (int)forceStatus );
            }
            // No notification: a disconnect-driven fallback to built-in isn't the
            // same event as another device stealing the lock, and notifying on
            // every disconnect would be noisy.
        }
    }
}


- ( void ) scheduleRetryAfterForceFailureForLock : ( AudioLock* ) lock
{
    if ( lock.consecutiveForceFailures >= kMaxForceRetries )
    {
        LAError("giving up on forcing %{public}@ until the next device change", lock.directionName );
        return;
    }
    lock.consecutiveForceFailures++;

    __weak AppDelegate *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kForceRetryDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf enforceLocks];
    });
}


// Another app keeps setting the default right back. Stop the tug-of-war for a
// while (the lock is backing off), tell the user, and try again afterwards.
- ( void ) handleContentionForLock : ( AudioLock* ) lock
                     currentDevice : ( AudioDeviceID ) currentID
{
    NSString *dirName = lock.directionName;
    NSString *otherName = [ lock nameForDevice : currentID ] ?: @"another device";
    LAError("%{public}@ lock contested (default keeps moving to %{public}@); backing off", dirName, otherName );

    [ self postNotificationForLock : lock
                              kind : @"contested"
                             title : [ NSString stringWithFormat : @"%@ lock paused for a minute", lock.capitalizedDirectionName ]
                              body : [ NSString stringWithFormat :
                                       @"Something keeps switching your %@ to %@, so LockAudio stopped switching it back. It will try again in a minute. To stop this, quit the other app or pause the lock.",
                                       dirName, otherName ] ];

    NSTimeInterval delay = MAX( lock.backoffUntil.timeIntervalSinceNow, 0 ) + 0.1;
    __weak AppDelegate *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf enforceLocks];
    });
}


#pragma mark - Status item

- ( void ) updateStatusItem
{
    BOOL anyActive = NO;
    BOOL anyPaused = NO;
    BOOL anyAttention = NO;
    NSMutableArray<NSString*> *lines = [ NSMutableArray arrayWithObject : @"LockAudio" ];

    for ( AudioLock *lock in self.locks )
    {
        NSString *dir = lock.capitalizedDirectionName;
        switch ( lock.status )
        {
            case AudioLockStatusHidden:
                break;
            case AudioLockStatusUnset:
                [ lines addObject : [ NSString stringWithFormat : @"%@: no device chosen", dir ] ];
                break;
            case AudioLockStatusActive:
                anyActive = YES;
                [ lines addObject : [ NSString stringWithFormat : @"%@ locked to %@", dir, lock.forcedName ?: @"selected device" ] ];
                break;
            case AudioLockStatusPaused:
                anyPaused = YES;
                [ lines addObject : [ NSString stringWithFormat : @"%@ lock paused", dir ] ];
                break;
            case AudioLockStatusMissing:
                anyAttention = YES;
                [ lines addObject : [ NSString stringWithFormat : @"%@: %@ not connected", dir, lock.forcedName ?: @"locked device" ] ];
                break;
            case AudioLockStatusContested:
                anyAttention = YES;
                [ lines addObject : [ NSString stringWithFormat : @"%@: another app keeps changing it; retrying soon", dir ] ];
                break;
        }
    }

    // Attention wins (the lock isn't holding), then paused, then active. With
    // nothing shown or chosen nothing is enforced, which reads as paused.
    StatusIconState state = anyAttention ? StatusIconStateAttention
                          : ( anyPaused || !anyActive ) ? StatusIconStatePaused
                          : StatusIconStateActive;

    statusItem.button.image = [ self statusImageForState : state ];
    statusItem.button.toolTip = [ lines componentsJoinedByString : @"\n" ];
}


- ( NSImage* ) statusImageForState : ( StatusIconState ) state
{
    NSString *name;
    NSString *description;
    switch ( state )
    {
        case StatusIconStateActive:
            name = @"status-active";
            description = @"LockAudio, locked";
            break;
        case StatusIconStatePaused:
            name = @"status-paused";
            description = @"LockAudio, paused";
            break;
        case StatusIconStateAttention:
            name = @"status-attention";
            description = @"LockAudio, needs attention";
            break;
    }

    NSImage *image = [ [ NSImage imageNamed : name ] copy ] ?: [ [ NSImage imageNamed : @"airpods-icon" ] copy ];
    image.template = YES;
    image.accessibilityDescription = description;
    return image;
}


#pragma mark - Menu

- ( void ) menuNeedsUpdate : ( NSMenu* ) aMenu
{
    [ self populateMenu : aMenu ];
}

- ( void ) menuWillOpen : ( NSMenu* ) aMenu
{
    menuOpen = YES;
}

- ( void ) menuDidClose : ( NSMenu* ) aMenu
{
    menuOpen = NO;
}


- ( NSMenuItem* ) addItemTo : ( NSMenu* ) target
                      title : ( NSString* ) title
                     action : ( SEL ) action
                     symbol : ( NSString* ) symbol
{
    NSMenuItem *item = [ target addItemWithTitle : title action : action keyEquivalent : @"" ];
    item.target = self;
    // App-control items carry SF Symbol icons; selectable device rows stay
    // icon-less (just a checkmark), so the icon vs no-icon contrast
    // distinguishes actions from device choices.
    if ( symbol != nil )
    {
        item.image = [ NSImage imageWithSystemSymbolName : symbol accessibilityDescription : nil ];
    }
    return item;
}


- ( NSMenuItem* ) sectionHeaderWithTitle : ( NSString* ) title
{
    if ( @available( macOS 14.0, * ) )
    {
        return [ NSMenuItem sectionHeaderWithTitle : title ];
    }
    return [ [ NSMenuItem alloc ] initWithTitle : title action : nil keyEquivalent : @"" ];
}


- ( void ) populateMenu : ( NSMenu* ) target
{
    [ target removeAllItems ];

    // Enumerate devices once and share the list between both sections; each
    // lock memoizes its per-device stream check for the duration of the build.
    NSData *deviceData = [ AudioLock connectedDeviceIDs ];
    const AudioDeviceID *devices = deviceData.bytes;
    int numberOfDevices = (int)( deviceData.length / sizeof( AudioDeviceID ) );

    NSString *version = [ [ NSBundle mainBundle ] infoDictionary ][ @"CFBundleShortVersionString" ];
    [ target addItemWithTitle : [ NSString stringWithFormat : @"Version %@", version ] action : nil keyEquivalent : @"" ];
    [ target addItem : [ NSMenuItem separatorItem ] ];

    for ( AudioLock *lock in self.locks )
    {
        [ lock invalidateDeviceCache ];
        if ( lock.showsOptions )
        {
            [ self appendSectionForLock : lock toMenu : target devices : devices count : numberOfDevices ];
        }
    }

    NSMenuItem *startupItem = [ self addItemTo : target title : @"Open at Login" action : @selector(toggleStartupItem) symbol : @"power" ];
    // Mixed (a dash) when registered but switched off in System Settings.
    startupItem.state = [ GBLaunchAtLogin isLoginItem ] ? NSControlStateValueOn
                      : [ GBLaunchAtLogin loginItemRequiresApproval ] ? NSControlStateValueMixed
                      : NSControlStateValueOff;

    for ( AudioLock *lock in self.locks )
    {
        NSString *title = [ NSString stringWithFormat : @"Show %@ Options", lock.capitalizedDirectionName ];
        NSString *symbol = ( lock.direction == AudioLockDirectionInput ) ? @"mic" : @"speaker.wave.2";
        NSMenuItem *item = [ self addItemTo : target title : title action : @selector(toggleShowOptions:) symbol : symbol ];
        item.representedObject = @( lock.direction );
        item.state = lock.showsOptions ? NSControlStateValueOn : NSControlStateValueOff;
    }

    // Notify toggles only appear when their section is shown.
    for ( AudioLock *lock in self.locks )
    {
        if ( !lock.showsOptions )
        {
            continue;
        }
        NSString *title = [ NSString stringWithFormat : @"Notify on Forced %@", lock.capitalizedDirectionName ];
        NSMenuItem *item = [ self addItemTo : target title : title action : @selector(toggleNotifications:) symbol : @"bell" ];
        item.representedObject = @( lock.direction );
        item.state = lock.notificationsEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    }

    [ target addItem : [ NSMenuItem separatorItem ] ];

    [ self addItemTo : target title : @"Sound Settings…" action : @selector(openSoundSettings) symbol : @"gearshape" ];

    // Targeting Sparkle's controller lets it disable the item while a check
    // is already running.
    NSMenuItem *updateItem = [ self addItemTo : target title : @"Check for Updates…" action : @selector(checkForUpdates:) symbol : @"arrow.triangle.2.circlepath" ];
    updateItem.target = self.updaterController;

    [ self addItemTo : target title : @"About LockAudio" action : @selector(showAbout) symbol : @"info.circle" ];

    NSMenuItem *quitItem = [ self addItemTo : target title : @"Quit LockAudio" action : @selector(terminate:) symbol : @"xmark.circle" ];
    quitItem.target = NSApp;
    quitItem.keyEquivalent = @"q";
}


// Appends one direction's section: header, one row per participating device
// (checkmark on the forced one), status rows, and the pause toggle.
- ( void ) appendSectionForLock : ( AudioLock* ) lock
                         toMenu : ( NSMenu* ) targetMenu
                        devices : ( const AudioDeviceID* ) devices
                          count : ( int ) numberOfDevices
{
    NSString *dirName = lock.directionName;
    [ targetMenu addItem : [ self sectionHeaderWithTitle : [ NSString stringWithFormat : @"Forced %@", lock.capitalizedDirectionName ] ] ];

    BOOL listedForced = NO;

    for ( int index = 0; index < numberOfDevices; index++ )
    {
        AudioDeviceID oneDeviceID = devices[ index ];

        // Only list devices that participate in this lock's direction.
        if ( ![ lock deviceParticipates : oneDeviceID ] )
        {
            continue;
        }

        BOOL isForced = lock.forcedDeviceAvailable && oneDeviceID == lock.forcedID;

        NSString* nameStr = [ lock nameForDevice : oneDeviceID ];
        if ( nameStr == nil )
        {
            // Name unreadable. If this is the currently-forced device (e.g.
            // recovered by UID through a transient name-read failure), show a
            // *disabled* row under its saved name so the user still sees what's
            // locked and the checkmark stays put — but it isn't selectable, so a
            // placeholder can never be written back into forcedName. Any other
            // unreadable device is simply omitted (it was never useful to list).
            if ( isForced && lock.forcedName != nil )
            {
                NSMenuItem* forcedItem = [ targetMenu addItemWithTitle : lock.forcedName action : NULL keyEquivalent : @"" ];
                forcedItem.state = NSControlStateValueOn;
                listedForced = YES;
                LADebug("%{public}@ forced device name unreadable; showing saved name '%{public}@' (%u)",
                       dirName, lock.forcedName, (unsigned int)oneDeviceID );
            }
            continue;
        }

        NSMenuItem* item = [ targetMenu addItemWithTitle : nameStr action : @selector(deviceSelected:) keyEquivalent : @"" ];
        item.target = self;
        item.representedObject = @[ @(lock.direction), @((unsigned int)oneDeviceID) ];

        if ( isForced )
        {
            item.state = NSControlStateValueOn;
            listedForced = YES;
        }
    }

    // Keep the locked device visible while it's disconnected, so it's clear
    // what the lock is waiting for.
    if ( !listedForced && lock.hasSelection && !lock.forcedDeviceAvailable && lock.forcedName != nil )
    {
        NSString *title = [ NSString stringWithFormat : @"%@ (not connected)", lock.forcedName ];
        NSMenuItem *missingItem = [ targetMenu addItemWithTitle : title action : NULL keyEquivalent : @"" ];
        missingItem.state = NSControlStateValueOn;
    }

    if ( lock.status == AudioLockStatusContested )
    {
        [ targetMenu addItemWithTitle : @"Another app keeps changing it; retrying soon" action : NULL keyEquivalent : @"" ];
    }

    NSString *pauseTitle = [ NSString stringWithFormat : @"Pause %@ Lock", lock.capitalizedDirectionName ];
    NSMenuItem *pauseItem = [ self addItemTo : targetMenu title : pauseTitle action : @selector(togglePause:) symbol : @"pause.circle" ];
    pauseItem.representedObject = @( lock.direction );
    pauseItem.state = lock.paused ? NSControlStateValueOn : NSControlStateValueOff;

    [ targetMenu addItem : [ NSMenuItem separatorItem ] ];
}


#pragma mark - Actions

- ( AudioLock* ) lockForDirection : ( NSNumber* ) direction
{
    return ( direction.unsignedIntegerValue == AudioLockDirectionInput ) ? inputLock : outputLock;
}


- ( void ) deviceSelected : ( NSMenuItem* ) item
{
    // Each device menu item is tagged with @[ @(direction), @(deviceID) ] so we
    // know which lock the click targets (a device like AirPods can appear in
    // both the input and output lists).
    NSArray *tag = item.representedObject;
    if ( ![tag isKindOfClass:[NSArray class]] || tag.count != 2 )
    {
        return;
    }

    AudioLock *lock = [ self lockForDirection : tag[0] ];
    AudioDeviceID newId = (AudioDeviceID)[tag[1] unsignedIntValue];

    LADebug("switching %{public}@ to new device : %u", lock.directionName, newId );

    OSStatus status = [ lock applyForce : newId ];
    if ( status != noErr )
    {
        // Leave the lock on its previous device rather than lock onto one macOS
        // won't make the default.
        LAError("switching %{public}@ to %u failed: OSStatus %d", lock.directionName, newId, (int)status );
        [ self showAlertWithMessage : [ NSString stringWithFormat : @"Couldn’t switch %@ to “%@”", lock.directionName, item.title ]
                        information : [ NSString stringWithFormat : @"macOS didn’t accept it as the default %@ device (error %d). The lock is unchanged.", lock.directionName, (int)status ] ];
        return;
    }

    lock.forcedID = newId;
    lock.forcedName = item.title;
    // Capture the stable UID so we can recover this exact device across
    // disconnect/reconnect even if its display name changes.
    lock.forcedUID = [ lock uidForDevice : newId ];
    lock.forcedDeviceAvailable = YES;
    lock.missingSince = nil;
    lock.suppressNotificationsUntil = [ NSDate dateWithTimeIntervalSinceNow : kUserSwitchQuietPeriod ];
    [ lock resetContention ];
    [ lock saveToDefaults ];

    [ self enforceLocks ];
}


- ( void ) togglePause : ( NSMenuItem* ) item
{
    AudioLock *lock = [ self lockForDirection : item.representedObject ];
    lock.paused = !lock.paused;
    // Persist the user's pause preference (the section is visible here).
    lock.pausePreference = lock.paused;
    [ lock resetContention ];
    [ self enforceLocks ];
}


// Show/hide a direction's options. Hiding removes the section from the menu and
// force-pauses the lock so it stops forcing — but leaves the persisted pause
// *preference* untouched. Showing restores the lock to that preference. Both the
// show flag and the pause preference persist across launches.
- ( void ) toggleShowOptions : ( NSMenuItem* ) item
{
    AudioLock *lock = [ self lockForDirection : item.representedObject ];
    BOOL show = !lock.showsOptions;
    lock.showsOptions = show;
    lock.paused = show ? lock.pausePreference : YES;
    [ lock resetContention ];
    [ self enforceLocks ];
}


- ( void ) toggleNotifications : ( NSMenuItem* ) item
{
    AudioLock *lock = [ self lockForDirection : item.representedObject ];
    BOOL enabled = !lock.notificationsEnabled;
    lock.notificationsEnabled = enabled;
    if ( !enabled )
    {
        return;
    }

    // Prompts the first time; afterwards it reports the current permission
    // without prompting. If notifications are off for LockAudio the toggle
    // would otherwise do nothing visible, so say so.
    [ [ UNUserNotificationCenter currentNotificationCenter ]
        requestAuthorizationWithOptions : UNAuthorizationOptionAlert
                      completionHandler : ^( BOOL granted, NSError * _Nullable error ) {
        if ( error != nil )
        {
            LAError("Notification auth error: %{public}@", error );
        }
        if ( !granted )
        {
            dispatch_async( dispatch_get_main_queue(), ^{
                [ self showNotificationsDeniedAlert ];
            });
        }
    }];
}


- ( void ) toggleStartupItem
{
    NSError *error = nil;
    BOOL ok;

    if ( [ GBLaunchAtLogin isLoginItem ] )
    {
        ok = [ GBLaunchAtLogin removeAppFromLoginItems : &error ];
    }
    else if ( [ GBLaunchAtLogin loginItemRequiresApproval ] )
    {
        // Registered, but switched off in System Settings. Only the user can
        // turn it back on there.
        [ self showLoginItemNeedsApprovalAlert ];
        return;
    }
    else
    {
        ok = [ GBLaunchAtLogin addAppAsLoginItem : &error ];
    }

    // Mirror the resulting state into preferences so it survives a future
    // bundle-identifier change (see migrateSettingsFromLegacyBundleIfNeeded).
    [ [ NSUserDefaults standardUserDefaults ] setBool : [ GBLaunchAtLogin isLoginItem ]
                                               forKey : kPrefLaunchAtLogin ];

    if ( !ok )
    {
        LAError("Changing login item failed: %{public}@", error );
        if ( [ GBLaunchAtLogin loginItemRequiresApproval ] )
        {
            [ self showLoginItemNeedsApprovalAlert ];
        }
        else
        {
            [ self showAlertWithMessage : @"Couldn’t change Open at Login"
                            information : error.localizedDescription ?: @"An unknown error occurred." ];
        }
    }
}


- ( void ) openSoundSettings
{
    // General Sound pane (app manages both input and output).
    NSURL *url = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.Sound-Settings.extension"];
    [[NSWorkspace sharedWorkspace] openURL:url];
}


#pragma mark - Alerts

- ( void ) activateApp
{
    if (@available(macOS 14.0, *)) {
        [NSApp activate];
    } else {
        [NSApp activateIgnoringOtherApps:YES];
    }
}


- ( void ) showAlertWithMessage : ( NSString* ) message information : ( NSString* ) information
{
    NSAlert *alert = [ [ NSAlert alloc ] init ];
    alert.messageText = message;
    alert.informativeText = information;
    [ self activateApp ];
    [ alert runModal ];
}


- ( void ) showNotificationsDeniedAlert
{
    NSAlert *alert = [ [ NSAlert alloc ] init ];
    alert.messageText = @"Notifications are turned off for LockAudio";
    alert.informativeText = @"LockAudio can’t tell you when it switches a device back until notifications are allowed in System Settings.";
    [ alert addButtonWithTitle : @"Open Notification Settings" ];
    [ alert addButtonWithTitle : @"Not Now" ];
    [ self activateApp ];
    if ( [ alert runModal ] == NSAlertFirstButtonReturn )
    {
        NSString *bundleID = [ NSBundle mainBundle ].bundleIdentifier;
        NSString *urlString = [ NSString stringWithFormat : @"x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=%@", bundleID ];
        [ [ NSWorkspace sharedWorkspace ] openURL : [ NSURL URLWithString : urlString ] ];
    }
}


- ( void ) showLoginItemNeedsApprovalAlert
{
    NSAlert *alert = [ [ NSAlert alloc ] init ];
    alert.messageText = @"LockAudio is turned off in Login Items";
    alert.informativeText = @"To open LockAudio at login, turn it on under “Open at Login” in System Settings → General → Login Items.";
    [ alert addButtonWithTitle : @"Open Login Items Settings" ];
    [ alert addButtonWithTitle : @"Cancel" ];
    [ self activateApp ];
    if ( [ alert runModal ] == NSAlertFirstButtonReturn )
    {
        [ GBLaunchAtLogin openLoginItemsSettings ];
    }
}


#pragma mark - About

- ( void ) showAbout
{
    if (aboutWindow == nil) {
        aboutWindow = [self buildAboutWindow];
    }
    [ self activateApp ];

    [aboutWindow center];
    [aboutWindow makeKeyAndOrderFront:nil];
}

- (NSWindow *)buildAboutWindow
{
    CGFloat W = 460;
    CGFloat H = 330;
    NSRect frame = NSMakeRect(0, 0, W, H);
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:frame
                  styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                    backing:NSBackingStoreBuffered
                      defer:NO];
    window.title = @"";
    window.releasedWhenClosed = NO;
    window.titlebarAppearsTransparent = YES;

    NSView *content = window.contentView;

    // App icon
    CGFloat iconSize = 96;
    NSImage *iconImage = [NSImage imageNamed:@"AppIcon"];
    if (iconImage == nil) {
        iconImage = [NSImage imageNamed:@"airpods-icon"];
    }
    NSImageView *iconView = [[NSImageView alloc] initWithFrame:NSMakeRect((W - iconSize) / 2, H - 28 - iconSize, iconSize, iconSize)];
    iconView.image = iconImage;
    iconView.imageScaling = NSImageScaleProportionallyUpOrDown;
    [content addSubview:iconView];

    // App name
    NSTextField *nameLabel = [NSTextField labelWithString:@"LockAudio"];
    nameLabel.font = [NSFont systemFontOfSize:22 weight:NSFontWeightBold];
    nameLabel.alignment = NSTextAlignmentCenter;
    nameLabel.frame = NSMakeRect(0, H - 160, W, 28);
    [content addSubview:nameLabel];

    // Version
    NSString *version = [[NSBundle mainBundle] infoDictionary][@"CFBundleShortVersionString"];
    NSTextField *versionLabel = [NSTextField labelWithString:[NSString stringWithFormat:@"Version %@", version]];
    versionLabel.font = [NSFont systemFontOfSize:12];
    versionLabel.textColor = [NSColor secondaryLabelColor];
    versionLabel.alignment = NSTextAlignmentCenter;
    versionLabel.frame = NSMakeRect(0, H - 182, W, 18);
    [content addSubview:versionLabel];

    // Links — URLs verbatim, centered
    NSArray *links = @[
        @[@"https://www.lockaudio.com", @"https://www.lockaudio.com"],
        @[@"https://github.com/jstilwell/LockAudio", @"https://github.com/jstilwell/LockAudio"],
        @[@"contact@lockaudio.com", @"mailto:contact@lockaudio.com"],
    ];
    CGFloat linksTop = H - 215;
    CGFloat linkHeight = 20;
    CGFloat linkSpacing = 2;
    for (NSUInteger i = 0; i < links.count; i++) {
        CGFloat y = linksTop - (i * (linkHeight + linkSpacing));
        NSView *linkView = [self linkViewWithTitle:links[i][0]
                                                url:links[i][1]
                                              frame:NSMakeRect(20, y, W - 40, linkHeight)];
        [content addSubview:linkView];
    }

    // Copyright
    NSString *copyright = [[NSBundle mainBundle] infoDictionary][@"NSHumanReadableCopyright"] ?: @"";
    NSTextField *copyrightLabel = [NSTextField labelWithString:copyright];
    copyrightLabel.font = [NSFont systemFontOfSize:11];
    copyrightLabel.textColor = [NSColor tertiaryLabelColor];
    copyrightLabel.alignment = NSTextAlignmentCenter;
    copyrightLabel.frame = NSMakeRect(20, 36, W - 40, 16);
    [content addSubview:copyrightLabel];

    return window;
}

- (NSView *)linkViewWithTitle:(NSString *)title url:(NSString *)url frame:(NSRect)frame
{
    NSMutableParagraphStyle *centered = [[NSMutableParagraphStyle alloc] init];
    centered.alignment = NSTextAlignmentCenter;

    NSAttributedString *attr = [[NSAttributedString alloc] initWithString:title
        attributes:@{
            NSFontAttributeName: [NSFont systemFontOfSize:12],
            NSForegroundColorAttributeName: [NSColor linkColor],
            NSLinkAttributeName: [NSURL URLWithString:url],
            NSParagraphStyleAttributeName: centered,
        }];

    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, frame.size.height)];
    field.editable = NO;
    field.bordered = NO;
    field.drawsBackground = NO;
    field.selectable = YES;
    field.allowsEditingTextAttributes = YES;
    field.alignment = NSTextAlignmentCenter;
    field.attributedStringValue = attr;

    LinkCursorView *wrapper = [[LinkCursorView alloc] initWithFrame:frame];
    [wrapper addSubview:field];
    return wrapper;
}


#pragma mark - Notifications

// Asks for permission at launch only when a notify toggle is on (the input one
// is by default), so the prompt appears in context of a feature that uses it.
- (void)requestNotificationAuthorizationIfNeeded
{
    if (!inputLock.notificationsEnabled && !outputLock.notificationsEnabled) {
        return;
    }

    [[UNUserNotificationCenter currentNotificationCenter]
        requestAuthorizationWithOptions:UNAuthorizationOptionAlert
                      completionHandler:^(BOOL granted, NSError * _Nullable error) {
        if (error) {
            LAError("Notification auth error: %{public}@", error);
        }
    }];
}

- (void)postForcedNotificationForLock:(AudioLock *)lock
                        offendingName:(NSString *)offendingName
{
    NSDate *now = [NSDate date];

    // User-initiated switch: its echo through the listeners isn't news.
    if (lock.suppressNotificationsUntil != nil && [now compare:lock.suppressNotificationsUntil] == NSOrderedAscending) {
        LADebug("suppressing forced-%{public}@ notification for user-initiated switch", lock.directionName);
        return;
    }

    // Per-direction minimum-gap throttle.
    if (lock.lastNotificationTime != nil && [now timeIntervalSinceDate:lock.lastNotificationTime] < kMinNotificationGap) {
        return;
    }
    lock.lastNotificationTime = now;

    NSString *dirWord = lock.directionName;
    NSString *forcedName = lock.forcedName ?: @"selected device";
    NSString *body = (offendingName != nil)
        ? [NSString stringWithFormat:@"%@ took %@ control. Forced %@ back to %@.", offendingName, dirWord, dirWord, forcedName]
        : [NSString stringWithFormat:@"Another device took %@ control. Forced %@ back to %@.", dirWord, dirWord, forcedName];

    [self postNotificationForLock:lock
                             kind:@"forced"
                            title:[NSString stringWithFormat:@"Forced %@ active", dirWord]
                             body:body];
}

// Posts if the lock's notify toggle is on and the screen isn't locked. The
// identifier is fixed per kind and direction, so a new notification replaces
// the previous one instead of piling up in Notification Center. If the user
// has turned notifications off in System Settings, the system drops it.
- (void)postNotificationForLock:(AudioLock *)lock
                           kind:(NSString *)kind
                          title:(NSString *)title
                           body:(NSString *)body
{
    if (!lock.notificationsEnabled || screenLocked) {
        return;
    }

    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = title;
    content.body = body;

    NSString *identifier = [NSString stringWithFormat:@"com.lockaudio.%@.%@", kind, lock.directionName];
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:identifier
                                                                          content:content
                                                                          trigger:nil];

    [[UNUserNotificationCenter currentNotificationCenter]
        addNotificationRequest:request
         withCompletionHandler:^(NSError * _Nullable error) {
             if (error) {
                 LAError("Failed to post notification: %{public}@", error);
             }
         }];
}

// Without this, notifications are silently dropped while LockAudio is the
// active app (e.g. the About window or an alert is up).
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler
{
    completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionList);
}

- (void)screenDidLock:(NSNotification *)note
{
    screenLocked = YES;
}

- (void)screenDidUnlock:(NSNotification *)note
{
    screenLocked = NO;
}

@end
