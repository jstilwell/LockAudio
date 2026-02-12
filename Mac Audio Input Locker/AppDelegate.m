#import "AppDelegate.h"
#import "GBLaunchAtLogin.h"
#import <CoreAudio/CoreAudio.h>


@interface AppDelegate ( )
{
    BOOL paused;
    NSMenu* menu;
    NSStatusItem* statusItem;
    AudioDeviceID forcedInputID;
    NSMutableDictionary* itemsToIDS;
    NSMenuItem *startupItem;
    BOOL rebuildingMenu;
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

    NSLog( @"default input device changed" );
    // check default input
    [ ( (__bridge  AppDelegate* ) inClientData ) listDevices ];

    return 0;
}


- ( void ) applicationDidFinishLaunching : ( NSNotification* ) aNotification
{
    // Initialize Sparkle updater
    self.updaterController = [[SPUStandardUpdaterController alloc] initWithStartingUpdater:YES updaterDelegate:nil userDriverDelegate:nil];

    itemsToIDS = [ NSMutableDictionary dictionary ];


    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    NSInteger readenId = [prefs integerForKey: @"Device"];

    if (readenId == 0) {
        [prefs setInteger:UINT32_MAX forKey: @"Device"];
    }

    forcedInputID = (AudioDeviceID)readenId;

    NSLog(@"Loaded device from UserDefaults: %d", forcedInputID);

    NSImage* image = [ NSImage imageNamed : @"airpods-icon" ];
    [ image setTemplate : YES ];

    statusItem = [ [ NSStatusBar systemStatusBar ] statusItemWithLength : NSVariableStatusItemLength ];
    statusItem.button.toolTip = @"Mac Audio Input Locker";
    statusItem.button.image = image;

    // add listener for detecting when input device is changed

    AudioObjectPropertyAddress inputDeviceAddress = {
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    AudioObjectAddPropertyListener(
        kAudioObjectSystemObject,
        &inputDeviceAddress,
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

    NSNumber* number = itemsToIDS[ item.title ];

    if ( number != nil )
    {

        AudioDeviceID newId = [ number unsignedIntValue ];

        NSLog( @"switching to new device : %u" , newId );

        forcedInputID = newId;

        NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
        [prefs setInteger:newId forKey: @"Device"];
        NSLog(@"Saved device from UserDefaults: %d", forcedInputID);

        AudioObjectPropertyAddress propertyAddress = {
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        };
        UInt32 propertySize = sizeof(AudioDeviceID);
        AudioObjectSetPropertyData(
            kAudioObjectSystemObject,
            &propertyAddress,
            0,
            NULL,
            propertySize,
            &forcedInputID);

        // Rebuild menu to show updated selection
        dispatch_async(dispatch_get_main_queue(), ^{
            [self listDevices];
        });

    }

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

    menu = [ [ NSMenu alloc ] init ];
    menu.delegate = self;
    [ menu addItemWithTitle : versionString action : nil keyEquivalent : @"" ];
    [ menu addItem : [ NSMenuItem separatorItem ] ]; // A thin grey line

    NSMenuItem* item =  [ menu
            addItemWithTitle : NSLocalizedString(@"Pause", @"Pause")
            action : @selector(manualPause:)
            keyEquivalent : @"" ];

    if ( paused ) [ item setState : NSControlStateValueOn ];

    [ menu addItem : [ NSMenuItem separatorItem ] ]; // A thin grey line
    [ menu addItemWithTitle : @"Forced input:" action : nil keyEquivalent : @"" ];

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

    if ( forcedInputID < UINT32_MAX )
    {

        char found = 0;

        for( int index = 0 ;
                 index < numberOfDevices ;
                 index++ )
        {

            if ( dev_array[ index] == forcedInputID ) found = 1;

        }

        if ( found == 0 )
        {
            NSLog( @"force input not found in device list" );
            forcedInputID = UINT32_MAX;
        }
        else NSLog( @"force input found in device list" );

    }


    for( int index = 0 ;
             index < numberOfDevices ;
             index++ )
    {

        AudioDeviceID oneDeviceID = dev_array[ index ];

        propertySize = 0;

        AudioObjectPropertyAddress streamsAddress = {
            kAudioDevicePropertyStreams,
            kAudioDevicePropertyScopeInput,
            kAudioObjectPropertyElementMain
        };

        AudioObjectGetPropertyDataSize(
            oneDeviceID,
            &streamsAddress,
            0,
            NULL,
            &propertySize);

        // if there are any input streams, then it is an input

        if ( propertySize > 0 )
        {

            // get name
            char deviceName[256];
            propertySize = 256;

            AudioObjectPropertyAddress nameAddress = {
                kAudioDevicePropertyDeviceName,
                kAudioObjectPropertyScopeGlobal,
                kAudioObjectPropertyElementMain
            };

            AudioObjectGetPropertyData(
                oneDeviceID,
                &nameAddress,
                0,
                NULL,
                &propertySize,
                deviceName);

            NSLog( @"found input device : %s  %u\n" , deviceName , (unsigned int)oneDeviceID );

            NSString* nameStr = [ NSString stringWithUTF8String : deviceName ];

            if ( [ [ nameStr lowercaseString ] containsString : @"built" ] && forcedInputID == UINT32_MAX )
            {

                // if there is no forced device yet, select "built-in" by default

                NSLog( @"setting forced device : %s  %u\n" , deviceName , (unsigned int)oneDeviceID );

                forcedInputID = oneDeviceID;

            }

            NSMenuItem* item = [ menu
                addItemWithTitle : [ NSString stringWithUTF8String : deviceName ]
                action : @selector(deviceSelected:)
                keyEquivalent : @"" ];

            if ( oneDeviceID == forcedInputID )
            {
                [ item setState : NSControlStateValueOn ];
                NSLog( @"setting device selected : %s  %u\n" , deviceName , (unsigned int)oneDeviceID );
            }

            itemsToIDS[ nameStr ] = [ NSNumber numberWithUnsignedInt : oneDeviceID];

        }

    }

    free(dev_array);

    [ statusItem setMenu : menu ];

    // Force input device if needed (the callback will trigger another listDevices)

    AudioDeviceID deviceID = kAudioDeviceUnknown;
    propertySize = sizeof( deviceID );

    AudioObjectPropertyAddress defaultInputAddress = {
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    AudioObjectGetPropertyData(
        kAudioObjectSystemObject,
        &defaultInputAddress,
        0,
        NULL,
        &propertySize,
        &deviceID);

    NSLog( @"default input device is %u" , deviceID );

    if ( !paused && deviceID != forcedInputID )
    {

        NSLog( @"forcing input device for default : %u" , forcedInputID );

        AudioObjectPropertyAddress forceInputAddress = {
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        };
        UInt32 forceSize = sizeof(AudioDeviceID);
        AudioObjectSetPropertyData(
            kAudioObjectSystemObject,
            &forceInputAddress,
            0,
            NULL,
            forceSize,
            &forcedInputID);

        // No need to dispatch listDevices here — the CoreAudio property
        // listener callback will fire and call listDevices for us.

    }

    [ menu addItem : [ NSMenuItem separatorItem ] ]; // A thin grey line

    startupItem = [ menu
        addItemWithTitle : @"Open at login"
        action : @selector(toggleStartupItem)
        keyEquivalent : @"" ];

    [ menu addItem : [ NSMenuItem separatorItem ] ]; // A thin grey line

    [ menu addItemWithTitle : @"Check for updates"
           action : @selector(update)
           keyEquivalent : @"" ];

    [ menu addItemWithTitle : @"Hide"
           action : @selector(hide)
           keyEquivalent : @"" ];

    [ menu addItemWithTitle : @"Quit"
           action : @selector(terminate)
           keyEquivalent : @"" ];

    rebuildingMenu = NO;

}

- ( void ) manualPause : ( NSMenuItem* ) item
{
    paused = !paused;
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

- ( void ) hide
{
    [statusItem setVisible:false];
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

    [self updateStartupItemState];
}

- (void)updateStartupItemState
{
    [startupItem setState: [GBLaunchAtLogin isLoginItem] ? NSControlStateValueOn : NSControlStateValueOff];
}

- (void)menuWillOpen:(NSMenu *)menu
{
    [self updateStartupItemState];
}

@end
