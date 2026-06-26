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

// Notify-on-forced toggles, one per direction. The input key keeps its original
// name ("NotificationsEnabled") for backward compatibility with existing installs.
static NSString* const kPrefNotificationsEnabled = @"NotificationsEnabled";
static NSString* const kPrefOutputNotificationsEnabled = @"OutputNotificationsEnabled";

// NSUserDefaults keys for the forced device id/name, per direction. The input
// keys keep their original names ("Device"/"DeviceName") for backward compat.
static NSString* const kPrefInputDevice = @"Device";
static NSString* const kPrefInputDeviceName = @"DeviceName";
static NSString* const kPrefInputDeviceUID = @"DeviceUID";
static NSString* const kPrefOutputDevice = @"OutputDevice";
static NSString* const kPrefOutputDeviceName = @"OutputDeviceName";
static NSString* const kPrefOutputDeviceUID = @"OutputDeviceUID";

// Per-direction "show these options in the menu" toggles. When a direction is
// hidden its whole menu section is removed and its lock is paused; showing it
// again restores the lock's prior pause state. Input defaults ON (the common
// case); output defaults OFF (rare case — users opt in).
static NSString* const kPrefShowInputOptions = @"ShowInputOptions";
static NSString* const kPrefShowOutputOptions = @"ShowOutputOptions";

// Per-direction pause *preference*, persisted across launches. This is the
// user's intended pause state for a visible section; while a section is hidden
// its lock is force-paused at runtime but this preference is preserved so it
// returns to the right state when shown again.
static NSString* const kPrefInputPaused = @"InputPaused";
static NSString* const kPrefOutputPaused = @"OutputPaused";

// Persisted launch-at-login state. The app's actual login-item registration
// lives in SMAppService (queried live by GBLaunchAtLogin), but we also mirror
// it here so the preference is migratable across a future bundle-identifier
// change — the way the device preference is.
static NSString* const kPrefLaunchAtLogin = @"LaunchAtLogin";

// Bundle identifier of the app before the LockAudio rename. Used once, on first
// launch under the new identifier, to migrate the user's saved settings.
static NSString* const kLegacyBundleIdentifier = @"com.audio.locker";

// Minimum gap between forced-device notifications (per direction). Under this
// threshold we treat successive fires as CoreAudio churn (e.g. AirPods settling)
// and suppress; legitimate user-driven switches always exceed this easily.
static const NSTimeInterval kMinNotificationGap = 2.0;


@interface AppDelegate ( )
{
    NSMenu* menu;
    NSStatusItem* statusItem;
    AudioLock* inputLock;
    AudioLock* outputLock;
    NSMenuItem *startupItem;
    NSMenuItem *notificationsItem;
    NSMenuItem *outputNotificationsItem;
    NSMenuItem *showInputItem;
    NSMenuItem *showOutputItem;
    BOOL rebuildingMenu;
    // Suppress the next forced-device notification for a direction after a
    // user-initiated switch (the callback can briefly see the old default and
    // re-force, which would otherwise fire a misleading notification).
    BOOL suppressNextInputNotification;
    BOOL suppressNextOutputNotification;
    NSDate* lastInputNotificationTime;
    NSDate* lastOutputNotificationTime;
    BOOL notificationAuthGranted;
    BOOL screenLocked;
    NSWindow* aboutWindow;
}

@property (weak) IBOutlet NSWindow *window;
@property (strong) SPUStandardUpdaterController *updaterController;

@end


@implementation AppDelegate


OSStatus callbackFunction(  AudioObjectID inObjectID,
                            UInt32 inNumberAddresses,
                            const AudioObjectPropertyAddress inAddresses[],
                            void *inClientData)
{

    NSLog( @"default device changed" );
    AppDelegate *delegate = (__bridge AppDelegate *)inClientData;
    dispatch_async(dispatch_get_main_queue(), ^{
        [delegate listDevices];
    });

    return 0;
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
    if ( [prefs objectForKey:@"Device"] != nil )
    {
        return;
    }

    CFStringRef legacyID = (__bridge CFStringRef)kLegacyBundleIdentifier;

    id legacyDevice = (__bridge_transfer id)CFPreferencesCopyAppValue(
        CFSTR("Device"), legacyID);

    // No legacy device means this is a genuine fresh install, not an upgrade.
    if ( legacyDevice == nil )
    {
        return;
    }

    [prefs setInteger:[legacyDevice integerValue] forKey:@"Device"];

    id legacyDeviceName = (__bridge_transfer id)CFPreferencesCopyAppValue(
        CFSTR("DeviceName"), legacyID);
    if ( [legacyDeviceName isKindOfClass:[NSString class]] )
    {
        [prefs setObject:legacyDeviceName forKey:@"DeviceName"];
    }

    id legacyNotifications = (__bridge_transfer id)CFPreferencesCopyAppValue(
        (__bridge CFStringRef)kPrefNotificationsEnabled, legacyID);
    if ( legacyNotifications != nil )
    {
        [prefs setBool:[legacyNotifications boolValue] forKey:kPrefNotificationsEnabled];
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
        [GBLaunchAtLogin addAppAsLoginItem];
        [prefs setBool:YES forKey:kPrefLaunchAtLogin];
    }

    NSLog(@"Migrated settings from legacy bundle %@: Device=%ld name=%@",
          kLegacyBundleIdentifier, (long)[legacyDevice integerValue], legacyDeviceName);
}


- ( void ) applicationDidFinishLaunching : ( NSNotification* ) aNotification
{
    // Initialize Sparkle updater
    self.updaterController = [[SPUStandardUpdaterController alloc] initWithStartingUpdater:YES updaterDelegate:nil userDriverDelegate:nil];

    lastInputNotificationTime = nil;
    lastOutputNotificationTime = nil;
    notificationAuthGranted = NO;
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

    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    [prefs registerDefaults:@{
        kPrefNotificationsEnabled: @YES,
        // Output locking is opt-in: notifications default off and no output
        // device is forced until the user chooses one.
        kPrefOutputNotificationsEnabled: @NO,
        // Input options shown by default (common case); output options hidden by
        // default (rare case — users opt in via "Show Output Options").
        kPrefShowInputOptions: @YES,
        kPrefShowOutputOptions: @NO,
        // Neither lock paused by default.
        kPrefInputPaused: @NO,
        kPrefOutputPaused: @NO,
    }];

    inputLock = [[AudioLock alloc] initWithDirection:AudioLockDirectionInput
                                         defaultsKey:kPrefInputDevice
                                     defaultsNameKey:kPrefInputDeviceName
                                      defaultsUIDKey:kPrefInputDeviceUID];
    [inputLock loadFromDefaults];

    outputLock = [[AudioLock alloc] initWithDirection:AudioLockDirectionOutput
                                          defaultsKey:kPrefOutputDevice
                                      defaultsNameKey:kPrefOutputDeviceName
                                       defaultsUIDKey:kPrefOutputDeviceUID];
    [outputLock loadFromDefaults];

    // Runtime pause state = persisted pause preference OR section hidden. A
    // hidden direction is always paused (so it doesn't force while hidden); a
    // visible one reflects the user's saved pause choice. Both survive relaunch.
    inputLock.paused = [prefs boolForKey:kPrefInputPaused]
                       || ![prefs boolForKey:kPrefShowInputOptions];
    outputLock.paused = [prefs boolForKey:kPrefOutputPaused]
                        || ![prefs boolForKey:kPrefShowOutputOptions];

    [self requestNotificationAuthorizationIfNeeded];

    NSLog(@"Loaded input lock: %d (%@), output lock: %d (%@)",
          inputLock.forcedID, inputLock.forcedName,
          outputLock.forcedID, outputLock.forcedName);

    NSImage* image = [ NSImage imageNamed : @"airpods-icon" ];
    [ image setTemplate : YES ];

    statusItem = [ [ NSStatusBar systemStatusBar ] statusItemWithLength : NSVariableStatusItemLength ];
    statusItem.button.toolTip = @"LockAudio";
    statusItem.button.image = image;

    // Listen for changes to the default input and output devices.
    AudioObjectPropertyAddress inputDeviceAddress = [inputLock defaultDeviceListenerAddress];
    AudioObjectAddPropertyListener(
        kAudioObjectSystemObject,
        &inputDeviceAddress,
        &callbackFunction,
        (__bridge  void* ) self );

    AudioObjectPropertyAddress outputDeviceAddress = [outputLock defaultDeviceListenerAddress];
    AudioObjectAddPropertyListener(
        kAudioObjectSystemObject,
        &outputDeviceAddress,
        &callbackFunction,
        (__bridge  void* ) self );

    // Listen for device list changes (devices added/removed)
    AudioObjectPropertyAddress devicesChangedAddress = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    AudioObjectAddPropertyListener(
        kAudioObjectSystemObject,
        &devicesChangedAddress,
        &callbackFunction,
        (__bridge  void* ) self );

    // Set the runloop to the main runloop for CoreAudio callbacks
    AudioObjectPropertyAddress runLoopAddress = {
        kAudioHardwarePropertyRunLoop,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    CFRunLoopRef runLoop = CFRunLoopGetCurrent();

    UInt32 size = sizeof(CFRunLoopRef);

    AudioObjectSetPropertyData(
        kAudioObjectSystemObject,
        &runLoopAddress,
        0,
        NULL,
        size,
        &runLoop);

    [ self listDevices ];

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

    AudioLockDirection direction = (AudioLockDirection)[tag[0] unsignedIntegerValue];
    AudioDeviceID newId = (AudioDeviceID)[tag[1] unsignedIntValue];

    AudioLock *lock = (direction == AudioLockDirectionInput) ? inputLock : outputLock;

    NSLog( @"switching %@ to new device : %u",
           direction == AudioLockDirectionInput ? @"input" : @"output", newId );

    lock.forcedID = newId;
    lock.forcedName = item.title;
    // Capture the stable UID so we can recover this exact device across
    // disconnect/reconnect even if its display name changes.
    lock.forcedUID = [lock uidForDevice:newId];

    // User-initiated switch: suppress the next forced notification for this
    // direction (see suppressNext*Notification).
    if ( direction == AudioLockDirectionInput ) {
        suppressNextInputNotification = YES;
    } else {
        suppressNextOutputNotification = YES;
    }

    [lock saveToDefaults];
    NSLog(@"Saved %@ device: %d (name: %@)",
          direction == AudioLockDirectionInput ? @"input" : @"output",
          lock.forcedID, lock.forcedName);

    [lock applyForce:newId];

    // Rebuild menu to show updated selection
    dispatch_async(dispatch_get_main_queue(), ^{
        [self listDevices];
    });
}


- ( void ) listDevices
{
    // Prevent recursive calls while rebuilding menu
    if (rebuildingMenu) {
        return;
    }
    rebuildingMenu = YES;

    NSDictionary *bundleInfo = [ [ NSBundle mainBundle] infoDictionary];
    NSString *versionString = [ NSString stringWithFormat : @"Version %@",
                               bundleInfo[ @"CFBundleShortVersionString" ] ];

    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    BOOL showInput = [prefs boolForKey:kPrefShowInputOptions];
    BOOL showOutput = [prefs boolForKey:kPrefShowOutputOptions];

    menu = [ [ NSMenu alloc ] init ];
    menu.delegate = self;
    [ menu addItemWithTitle : versionString action : nil keyEquivalent : @"" ];
    [ menu addItem : [ NSMenuItem separatorItem ] ]; // A thin grey line

    // These per-section items only exist when their section is shown; they stay
    // nil otherwise (setting .image / .state on nil is a harmless no-op).
    NSMenuItem* pauseInput = nil;
    NSMenuItem* pauseOutput = nil;
    notificationsItem = nil;
    outputNotificationsItem = nil;

    // Input section (label, device list, per-direction pause) — only when shown.
    if ( showInput )
    {
        [ menu addItemWithTitle : @"Forced input:" action : nil keyEquivalent : @"" ];
        [ self appendDevicesForLock : inputLock toMenu : menu ];

        pauseInput = [ menu
                addItemWithTitle : @"Pause Input Lock"
                action : @selector(manualPauseInput:)
                keyEquivalent : @"" ];
        if ( inputLock.paused ) [ pauseInput setState : NSControlStateValueOn ];

        [ menu addItem : [ NSMenuItem separatorItem ] ]; // A thin grey line
    }

    // Output section (label, device list, per-direction pause) — only when shown.
    if ( showOutput )
    {
        [ menu addItemWithTitle : @"Forced output:" action : nil keyEquivalent : @"" ];
        [ self appendDevicesForLock : outputLock toMenu : menu ];

        pauseOutput = [ menu
                addItemWithTitle : @"Pause Output Lock"
                action : @selector(manualPauseOutput:)
                keyEquivalent : @"" ];
        if ( outputLock.paused ) [ pauseOutput setState : NSControlStateValueOn ];

        [ menu addItem : [ NSMenuItem separatorItem ] ]; // A thin grey line
    }

    startupItem = [ menu
        addItemWithTitle : @"Open at login"
        action : @selector(toggleStartupItem)
        keyEquivalent : @"" ];

    showInputItem = [ menu
        addItemWithTitle : @"Show Input Options"
        action : @selector(toggleShowInput)
        keyEquivalent : @"" ];

    showOutputItem = [ menu
        addItemWithTitle : @"Show Output Options"
        action : @selector(toggleShowOutput)
        keyEquivalent : @"" ];

    // Notify toggles only appear when their section is shown.
    if ( showInput )
    {
        notificationsItem = [ menu
            addItemWithTitle : @"Notify on forced input"
            action : @selector(toggleNotifications)
            keyEquivalent : @"" ];
    }

    if ( showOutput )
    {
        outputNotificationsItem = [ menu
            addItemWithTitle : @"Notify on forced output"
            action : @selector(toggleOutputNotifications)
            keyEquivalent : @"" ];
    }

    [ menu addItem : [ NSMenuItem separatorItem ] ]; // A thin grey line

    NSMenuItem *soundItem = [ menu
        addItemWithTitle : @"Sound settings…"
        action : @selector(openSoundSettings)
        keyEquivalent : @"" ];

    NSMenuItem *updateItem = [ menu
        addItemWithTitle : @"Check for updates"
        action : @selector(update)
        keyEquivalent : @"" ];

    NSMenuItem *aboutItem = [ menu
        addItemWithTitle : @"About"
        action : @selector(showAbout)
        keyEquivalent : @"" ];

    NSMenuItem *quitItem = [ menu
        addItemWithTitle : @"Quit"
        action : @selector(terminate)
        keyEquivalent : @"" ];

    if (@available(macOS 11.0, *)) {
        // App-control items carry SF Symbol icons; selectable device rows stay
        // icon-less (just a checkmark), so the icon vs no-icon contrast
        // distinguishes actions from device choices.
        pauseInput.image = [NSImage imageWithSystemSymbolName:@"pause.circle" accessibilityDescription:@"Pause Input Lock"];
        pauseOutput.image = [NSImage imageWithSystemSymbolName:@"pause.circle" accessibilityDescription:@"Pause Output Lock"];
        startupItem.image = [NSImage imageWithSystemSymbolName:@"power" accessibilityDescription:@"Open at login"];
        showInputItem.image = [NSImage imageWithSystemSymbolName:@"mic" accessibilityDescription:@"Show Input Options"];
        showOutputItem.image = [NSImage imageWithSystemSymbolName:@"speaker.wave.2" accessibilityDescription:@"Show Output Options"];
        notificationsItem.image = [NSImage imageWithSystemSymbolName:@"bell" accessibilityDescription:@"Notify on forced input"];
        outputNotificationsItem.image = [NSImage imageWithSystemSymbolName:@"bell" accessibilityDescription:@"Notify on forced output"];
        soundItem.image = [NSImage imageWithSystemSymbolName:@"gearshape" accessibilityDescription:@"Sound settings"];
        updateItem.image = [NSImage imageWithSystemSymbolName:@"arrow.triangle.2.circlepath" accessibilityDescription:@"Check for updates"];
        aboutItem.image = [NSImage imageWithSystemSymbolName:@"info.circle" accessibilityDescription:@"About"];
        quitItem.image = [NSImage imageWithSystemSymbolName:@"xmark.circle" accessibilityDescription:@"Quit"];
    }

    [ self updateToggleStates ];
    [ self updateStartupItemState ];

    [ statusItem setMenu : menu ];

    rebuildingMenu = NO;
    suppressNextInputNotification = NO;
    suppressNextOutputNotification = NO;
}


// Resolves `lock`'s forced device to a currently-connected AudioDeviceID that
// participates in this lock's direction, and returns whether it is available.
// The forced AudioDeviceID can change across disconnect/reconnect, so we
// re-derive it each rebuild:
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
- ( BOOL ) resolveForcedDeviceForLock : ( AudioLock* ) lock
                            inDevices : ( AudioDeviceID* ) devices
                                count : ( int ) numberOfDevices
{
    NSString *dirName = ( lock.direction == AudioLockDirectionInput ) ? @"input" : @"output";

    // Nothing forced yet (and no saved identity to recover from).
    if ( lock.forcedID == UINT32_MAX && lock.forcedUID == nil && lock.forcedName == nil )
    {
        return NO;
    }

    // 1. Saved id still present, participating, and (when we have a UID) still
    //    the same physical device? Keep it.
    if ( lock.forcedID < UINT32_MAX )
    {
        for ( int index = 0; index < numberOfDevices; index++ )
        {
            if ( devices[index] != lock.forcedID )
            {
                continue;
            }
            if ( ![lock deviceParticipates:devices[index]] )
            {
                break; // id present but not in our direction — try UID/name.
            }
            if ( lock.forcedUID != nil )
            {
                // We have a stable UID, so the bare id is only trustworthy if it
                // still identifies the same device. Require a positive UID match:
                // a mismatch (id recycled) OR an unreadable UID both fall through
                // to the authoritative UID search rather than risk the wrong one.
                NSString *uid = [lock uidForDevice:devices[index]];
                if ( ![lock.forcedUID isEqualToString:uid] )
                {
                    NSLog( @"forced %@ id %u no longer confirms UID %@; re-resolving by UID",
                           dirName, (unsigned int)lock.forcedID, lock.forcedUID );
                    break; // fall through to UID search.
                }
            }
            NSLog( @"forced %@ found in device list", dirName );
            return YES;
        }
    }

    // 2. Match by stable UID.
    if ( lock.forcedUID != nil )
    {
        for ( int index = 0; index < numberOfDevices; index++ )
        {
            if ( ![lock deviceParticipates:devices[index]] )
            {
                continue;
            }
            NSString *uid = [lock uidForDevice:devices[index]];
            if ( uid != nil && [uid isEqualToString:lock.forcedUID] )
            {
                NSLog( @"forced %@ recovered by UID: %@ -> %u", dirName, uid, (unsigned int)devices[index] );
                lock.forcedID = devices[index];
                [lock saveToDefaults];
                return YES;
            }
        }
    }

    // 3. Fall back to display name; backfill the UID for next time.
    if ( lock.forcedName != nil )
    {
        for ( int index = 0; index < numberOfDevices; index++ )
        {
            if ( ![lock deviceParticipates:devices[index]] )
            {
                continue;
            }
            NSString *nameStr = [lock nameForDevice:devices[index]];
            if ( nameStr != nil && [nameStr isEqualToString:lock.forcedName] )
            {
                NSLog( @"forced %@ recovered by name: %@ -> %u", dirName, nameStr, (unsigned int)devices[index] );
                lock.forcedID = devices[index];
                lock.forcedUID = [lock uidForDevice:devices[index]];
                [lock saveToDefaults];
                return YES;
            }
        }
    }

    NSLog( @"forced %@ device '%@' not connected; keeping saved selection for recovery", dirName, lock.forcedName );
    return NO;
}

// Resolves/recovers `lock`'s forced device, appends one menu item per
// participating device (checkmark on the forced one), and re-applies the force
// if another device has stolen the default. Ported from the original
// single-direction listDevices logic.
- ( void ) appendDevicesForLock : ( AudioLock* ) lock toMenu : ( NSMenu* ) targetMenu
{
    UInt32 propertySize;

    // Get device count dynamically
    AudioObjectPropertyAddress devicesAddress = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    AudioObjectGetPropertyDataSize(
        kAudioObjectSystemObject,
        &devicesAddress,
        0,
        NULL,
        &propertySize);

    int numberOfDevices = ( propertySize / sizeof( AudioDeviceID ) );
    AudioDeviceID *dev_array = (AudioDeviceID *)malloc(propertySize);

    AudioObjectGetPropertyData(
        kAudioObjectSystemObject,
        &devicesAddress,
        0,
        NULL,
        &propertySize,
        dev_array);

    NSLog( @"devices found : %i" , numberOfDevices );

    BOOL isInput = ( lock.direction == AudioLockDirectionInput );
    NSString *dirName = isInput ? @"input" : @"output";

    // Maps deviceID -> name for the participating devices, used to name the
    // "offending" device that stole the default.
    NSMutableDictionary<NSNumber *, NSString *> *idToName = [NSMutableDictionary dictionary];

    // Resolve the forced device to a currently-connected AudioDeviceID. Prefers
    // the stable UID, falls back to the display name (and backfills the UID for
    // installs saved before UIDs were persisted). This is what makes a forced
    // device survive disconnect/reconnect even though its AudioDeviceID — and,
    // for some devices like AirPods, its display name — can change.
    BOOL forcedDeviceAvailable = [self resolveForcedDeviceForLock:lock
                                                        inDevices:dev_array
                                                            count:numberOfDevices];


    for( int index = 0 ;
             index < numberOfDevices ;
             index++ )
    {

        AudioDeviceID oneDeviceID = dev_array[ index ];

        // Only list devices that participate in this lock's direction.
        if ( ![ lock deviceParticipates : oneDeviceID ] )
        {
            continue;
        }

        // Get the display name.
        NSString* nameStr = [ lock nameForDevice : oneDeviceID ];
        if ( nameStr == nil )
        {
            // Name unreadable. If this is the currently-forced device (e.g.
            // recovered by UID through a transient name-read failure), show a
            // *disabled* row under its saved name so the user still sees what's
            // locked and the checkmark stays put — but it isn't selectable, so a
            // placeholder can never be written back into forcedName. Any other
            // unreadable device is simply omitted (it was never useful to list).
            if ( oneDeviceID == lock.forcedID && lock.forcedName != nil )
            {
                NSMenuItem* forcedItem = [ targetMenu
                    addItemWithTitle : lock.forcedName
                    action : NULL
                    keyEquivalent : @"" ];
                [ forcedItem setEnabled : NO ];
                [ forcedItem setState : NSControlStateValueOn ];
                NSLog( @"%@ forced device name unreadable; showing saved name '%@' (%u)",
                       dirName, lock.forcedName, (unsigned int)oneDeviceID );
            }
            continue;
        }

        NSLog( @"found %@ device : %@  %u\n" , dirName, nameStr , (unsigned int)oneDeviceID );

        // Default the INPUT lock to the built-in device when nothing is saved.
        // Output locking is opt-in, so it has no default device.
        if ( isInput && [ [ nameStr lowercaseString ] containsString : @"built" ]
             && lock.forcedID == UINT32_MAX && lock.forcedName == nil )
        {
            NSLog( @"setting default forced %@ : %@  %u\n" , dirName, nameStr , (unsigned int)oneDeviceID );

            lock.forcedID = oneDeviceID;
            lock.forcedName = nameStr;
            lock.forcedUID = [lock uidForDevice:oneDeviceID];
            forcedDeviceAvailable = YES;
            [lock saveToDefaults];
        }

        NSMenuItem* item = [ targetMenu
            addItemWithTitle : nameStr
            action : @selector(deviceSelected:)
            keyEquivalent : @"" ];
        item.representedObject = @[ @(lock.direction), @((unsigned int)oneDeviceID) ];

        if ( oneDeviceID == lock.forcedID )
        {
            [ item setState : NSControlStateValueOn ];
            NSLog( @"%@ device selected : %@  %u\n" , dirName, nameStr , (unsigned int)oneDeviceID );
        }

        idToName[ @((unsigned int)oneDeviceID) ] = nameStr;
    }

    // Force the device if needed (the callback will trigger another listDevices)
    AudioDeviceID deviceID = [ lock currentDefaultDevice ];
    NSLog( @"default %@ device is %u" , dirName, deviceID );

    if ( !lock.paused && forcedDeviceAvailable && deviceID != lock.forcedID )
    {
        NSLog( @"forcing %@ device for default : %u" , dirName, lock.forcedID );

        NSString *offendingName = idToName[ @((unsigned int)deviceID) ];

        OSStatus forceStatus = [ lock applyForce : lock.forcedID ];

        BOOL suppress = isInput ? suppressNextInputNotification : suppressNextOutputNotification;

        if ( forceStatus == noErr )
        {
            if ( suppress )
            {
                NSLog( @"suppressing forced-%@ notification for user-initiated switch", dirName );
            }
            else
            {
                [ self handleForceAppliedForLock : lock
                                            name : lock.forcedName
                                   offendingName : offendingName ];
            }
        }
        else
        {
            NSLog( @"force %@ failed: OSStatus %d", dirName, (int)forceStatus );
        }

        // No need to dispatch listDevices here — the CoreAudio property
        // listener callback will fire and call listDevices for us.
    }
    else if ( !lock.paused && !forcedDeviceAvailable && lock.forcedName != nil )
    {
        // The forced device is disconnected. Don't leave the default to macOS,
        // which can land on an arbitrary device (e.g. a RØDE that's both an
        // input and output) instead of the built-in. Actively fall back to the
        // built-in device so output returns to the MacBook speakers (and input
        // to the built-in mic). The saved selection is untouched, so the lock
        // recovers the forced device the moment it reconnects.
        AudioDeviceID builtInID = [ lock builtInDeviceInDevices : dev_array
                                                          count : numberOfDevices ];

        if ( builtInID != kAudioDeviceUnknown && deviceID != builtInID )
        {
            NSLog( @"forced %@ device '%@' not connected; falling back to built-in %u",
                   dirName, lock.forcedName, (unsigned int)builtInID );

            OSStatus forceStatus = [ lock applyForce : builtInID ];
            if ( forceStatus != noErr )
            {
                NSLog( @"fallback %@ force failed: OSStatus %d", dirName, (int)forceStatus );
            }
            // No notification: a disconnect-driven fallback to built-in isn't the
            // same event as another device stealing the lock, and notifying on
            // every disconnect would be noisy. The property-listener callback
            // will fire and rebuild the menu.
        }
        else
        {
            NSLog( @"forced %@ device '%@' not connected; no built-in fallback applied (built-in %u, current default %u)",
                   dirName, lock.forcedName, (unsigned int)builtInID, (unsigned int)deviceID );
        }
    }

    free(dev_array);
}


- ( void ) manualPauseInput : ( NSMenuItem* ) item
{
    BOOL paused = !inputLock.paused;
    inputLock.paused = paused;
    // Persist the user's pause preference (the section is visible here).
    [[NSUserDefaults standardUserDefaults] setBool:paused forKey:kPrefInputPaused];
    [ self listDevices ];
}

- ( void ) manualPauseOutput : ( NSMenuItem* ) item
{
    BOOL paused = !outputLock.paused;
    outputLock.paused = paused;
    [[NSUserDefaults standardUserDefaults] setBool:paused forKey:kPrefOutputPaused];
    [ self listDevices ];
}

- ( void ) terminate
{
    [ NSApp terminate : nil ];
}

- ( void ) update
{
    [self.updaterController checkForUpdates:nil];
}

- ( void ) openSoundSettings
{
    NSURL *url;
    if (@available(macOS 13.0, *)) {
        // General Sound pane (app now manages both input and output).
        url = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.Sound-Settings.extension"];
    } else {
        url = [NSURL fileURLWithPath:@"/System/Library/PreferencePanes/Sound.prefPane"];
    }
    [[NSWorkspace sharedWorkspace] openURL:url];
}

- ( void ) showAbout
{
    if (aboutWindow == nil) {
        aboutWindow = [self buildAboutWindow];
    }
    [NSApp activateIgnoringOtherApps:YES];
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

- (void)toggleStartupItem
{
    if ( [GBLaunchAtLogin isLoginItem] )
    {
        [GBLaunchAtLogin removeAppFromLoginItems];
    }
    else
    {
        [GBLaunchAtLogin addAppAsLoginItem];
    }

    // Mirror the resulting state into preferences so it survives a future
    // bundle-identifier change (see migrateSettingsFromLegacyBundleIfNeeded).
    [[NSUserDefaults standardUserDefaults] setBool:[GBLaunchAtLogin isLoginItem]
                                            forKey:kPrefLaunchAtLogin];

    [self updateStartupItemState];
}

- (void)updateStartupItemState
{
    [startupItem setState: [GBLaunchAtLogin isLoginItem] ? NSControlStateValueOn : NSControlStateValueOff];
}

- (void)updateToggleStates
{
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    [notificationsItem setState: [prefs boolForKey:kPrefNotificationsEnabled] ? NSControlStateValueOn : NSControlStateValueOff];
    [outputNotificationsItem setState: [prefs boolForKey:kPrefOutputNotificationsEnabled] ? NSControlStateValueOn : NSControlStateValueOff];
    [showInputItem setState: [prefs boolForKey:kPrefShowInputOptions] ? NSControlStateValueOn : NSControlStateValueOff];
    [showOutputItem setState: [prefs boolForKey:kPrefShowOutputOptions] ? NSControlStateValueOn : NSControlStateValueOff];
}

- (void)toggleNotifications
{
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    BOOL enabled = ![prefs boolForKey:kPrefNotificationsEnabled];
    [prefs setBool:enabled forKey:kPrefNotificationsEnabled];
    [self updateToggleStates];
    if (enabled) {
        [self requestNotificationAuthorizationIfNeeded];
    }
}

- (void)toggleOutputNotifications
{
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    BOOL enabled = ![prefs boolForKey:kPrefOutputNotificationsEnabled];
    [prefs setBool:enabled forKey:kPrefOutputNotificationsEnabled];
    [self updateToggleStates];
    if (enabled) {
        [self requestNotificationAuthorizationIfNeeded];
    }
}

// Show/hide a direction's options. Hiding removes the section from the menu and
// force-pauses the lock so it stops forcing — but leaves the persisted pause
// *preference* untouched. Showing restores the lock to that preference. Both the
// show flag and the pause preference persist across launches.
- (void)setShowOptions:(BOOL)show forLock:(AudioLock *)lock
            showPrefKey:(NSString *)showPrefKey
           pausePrefKey:(NSString *)pausePrefKey
{
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    [prefs setBool:show forKey:showPrefKey];

    if (show) {
        // Restore the persisted pause preference for this direction.
        lock.paused = [prefs boolForKey:pausePrefKey];
    } else {
        // Force-pause at runtime to stop forcing; the persisted preference is
        // left as-is so showing again returns to the user's real choice.
        lock.paused = YES;
    }

    [self listDevices];
}

- (void)toggleShowInput
{
    BOOL show = ![[NSUserDefaults standardUserDefaults] boolForKey:kPrefShowInputOptions];
    [self setShowOptions:show forLock:inputLock
              showPrefKey:kPrefShowInputOptions
             pausePrefKey:kPrefInputPaused];
}

- (void)toggleShowOutput
{
    BOOL show = ![[NSUserDefaults standardUserDefaults] boolForKey:kPrefShowOutputOptions];
    [self setShowOptions:show forLock:outputLock
              showPrefKey:kPrefShowOutputOptions
             pausePrefKey:kPrefOutputPaused];
}

- (void)requestNotificationAuthorizationIfNeeded
{
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    if (![prefs boolForKey:kPrefNotificationsEnabled] &&
        ![prefs boolForKey:kPrefOutputNotificationsEnabled]) {
        return;
    }

    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
                          completionHandler:^(BOOL granted, NSError * _Nullable error) {
        if (error) {
            NSLog(@"Notification auth error: %@", error);
        }
        self->notificationAuthGranted = granted;
    }];
}

- (void)handleForceAppliedForLock:(AudioLock *)lock
                             name:(NSString *)deviceName
                    offendingName:(NSString *)offendingName
{
    BOOL isInput = (lock.direction == AudioLockDirectionInput);
    NSString *dirWord = isInput ? @"input" : @"output";

    // Per-direction minimum-gap throttle.
    NSDate *now = [NSDate date];
    NSDate *last = isInput ? lastInputNotificationTime : lastOutputNotificationTime;
    if (last != nil && [now timeIntervalSinceDate:last] < kMinNotificationGap) {
        return;
    }
    if (isInput) {
        lastInputNotificationTime = now;
    } else {
        lastOutputNotificationTime = now;
    }

    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    NSString *enabledKey = isInput ? kPrefNotificationsEnabled : kPrefOutputNotificationsEnabled;

    if ([prefs boolForKey:enabledKey] && notificationAuthGranted && !screenLocked) {
        UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
        content.title = isInput ? @"Forced input active" : @"Forced output active";

        NSString *forcedName = deviceName ?: @"selected device";
        if (offendingName != nil) {
            content.body = [NSString stringWithFormat:@"%@ took %@ control. Forced %@ back to %@.", offendingName, dirWord, dirWord, forcedName];
        } else {
            content.body = [NSString stringWithFormat:@"Another device took %@ control. Forced %@ back to %@.", dirWord, dirWord, forcedName];
        }

        UNNotificationRequest *request = [UNNotificationRequest
            requestWithIdentifier:[[NSUUID UUID] UUIDString]
                          content:content
                          trigger:nil];

        [[UNUserNotificationCenter currentNotificationCenter]
            addNotificationRequest:request
             withCompletionHandler:^(NSError * _Nullable error) {
                 if (error) {
                     NSLog(@"Failed to post notification: %@", error);
                 }
             }];
    }
}

- (void)screenDidLock:(NSNotification *)note
{
    screenLocked = YES;
}

- (void)screenDidUnlock:(NSNotification *)note
{
    screenLocked = NO;
}

- (void)menuWillOpen:(NSMenu *)menu
{
    [self updateStartupItemState];
    [self updateToggleStates];
}

@end
