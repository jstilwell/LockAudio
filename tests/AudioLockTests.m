//
//  AudioLockTests.m
//
//  Self-checking tests for the AudioLock logic that has regressed before:
//  recovering the locked device across reconnects, and contention back-off.
//  Built and run by bin/test.sh with plain clang (no Xcode test target).
//

#import "AudioLock.h"

static int failures = 0;
#define CHECK(condition) \
    do { if (!(condition)) { failures++; printf("FAIL %s:%d: %s\n", __func__, __LINE__, #condition); } } while (0)

// An AudioLock whose devices come from dictionaries instead of CoreAudio.
@interface FakeLock : AudioLock
@property (nonatomic, copy) NSDictionary<NSNumber *, NSString *> *uids;   // device id -> UID
@property (nonatomic, copy) NSDictionary<NSNumber *, NSString *> *names;  // device id -> name
@property (nonatomic, copy) NSSet<NSNumber *> *otherDirection;            // ids with no stream this way
@end

@implementation FakeLock
- (BOOL)deviceParticipates:(AudioDeviceID)deviceID { return ![self.otherDirection containsObject:@(deviceID)]; }
- (NSString *)uidForDevice:(AudioDeviceID)deviceID { return self.uids[@(deviceID)]; }
- (NSString *)nameForDevice:(AudioDeviceID)deviceID { return self.names[@(deviceID)]; }
- (void)saveToDefaults {} // keep the tests out of NSUserDefaults
@end

static FakeLock *lockedTo(AudioDeviceID deviceID, NSString *uid, NSString *name)
{
    FakeLock *lock = [[FakeLock alloc] initWithDirection:AudioLockDirectionInput];
    lock.forcedID = deviceID;
    lock.forcedUID = uid;
    lock.forcedName = name;
    return lock;
}

static void testKeepsConfirmedID(void)
{
    FakeLock *lock = lockedTo(10, @"uid-mic", @"Mic");
    lock.uids = @{ @10: @"uid-mic", @11: @"uid-other" };
    const AudioDeviceID devices[] = { 10, 11 };
    CHECK([lock resolveForcedDeviceInDevices:devices count:2]);
    CHECK(lock.forcedID == 10);
}

// CoreAudio can hand a disconnected device's id to a different device.
static void testRecycledIDFollowsUID(void)
{
    FakeLock *lock = lockedTo(10, @"uid-mic", @"Mic");
    lock.uids = @{ @10: @"uid-airpods", @12: @"uid-mic" };
    const AudioDeviceID devices[] = { 10, 12 };
    CHECK([lock resolveForcedDeviceInDevices:devices count:2]);
    CHECK(lock.forcedID == 12);
}

static void testRecoversByUIDAfterReconnect(void)
{
    FakeLock *lock = lockedTo(10, @"uid-mic", @"Mic");
    lock.uids = @{ @11: @"uid-other", @42: @"uid-mic" };
    lock.names = @{ @11: @"Mic" }; // a same-named device must not win over the UID
    const AudioDeviceID devices[] = { 11, 42 };
    CHECK([lock resolveForcedDeviceInDevices:devices count:2]);
    CHECK(lock.forcedID == 42);
}

// Selections saved before UIDs were stored only have a name.
static void testRecoversByNameAndBackfillsUID(void)
{
    FakeLock *lock = lockedTo(10, nil, @"Mic");
    lock.uids = @{ @42: @"uid-mic" };
    lock.names = @{ @11: @"Other", @42: @"Mic" };
    const AudioDeviceID devices[] = { 11, 42 };
    CHECK([lock resolveForcedDeviceInDevices:devices count:2]);
    CHECK(lock.forcedID == 42);
    CHECK([lock.forcedUID isEqualToString:@"uid-mic"]);
}

static void testMissingDeviceKeepsSavedSelection(void)
{
    FakeLock *lock = lockedTo(10, @"uid-mic", @"Mic");
    lock.uids = @{ @11: @"uid-other" };
    lock.names = @{ @11: @"Other" };
    const AudioDeviceID devices[] = { 11 };
    CHECK(![lock resolveForcedDeviceInDevices:devices count:1]);
    CHECK(!lock.forcedDeviceAvailable);
    CHECK(lock.forcedID == 10);
    CHECK([lock.forcedUID isEqualToString:@"uid-mic"]);
    CHECK([lock.forcedName isEqualToString:@"Mic"]);
}

// The locked device is present but only has streams in the other direction.
static void testIgnoresDeviceInOtherDirection(void)
{
    FakeLock *lock = lockedTo(10, @"uid-mic", @"Mic");
    lock.uids = @{ @10: @"uid-mic" };
    lock.names = @{ @10: @"Mic" };
    lock.otherDirection = [NSSet setWithObject:@10];
    const AudioDeviceID devices[] = { 10 };
    CHECK(![lock resolveForcedDeviceInDevices:devices count:1]);
}

static void testNothingChosenResolvesToNothing(void)
{
    FakeLock *lock = lockedTo(UINT32_MAX, nil, nil);
    lock.uids = @{ @10: @"uid-mic" };
    const AudioDeviceID devices[] = { 10 };
    CHECK(!lock.hasSelection);
    CHECK(![lock resolveForcedDeviceInDevices:devices count:1]);
}

// 8 forces inside 10 s means another app is fighting the lock.
static void testContentionBacksOffOnEighthForce(void)
{
    FakeLock *lock = lockedTo(10, @"uid-mic", @"Mic");
    for (int attempt = 0; attempt < 7; attempt++) {
        CHECK([lock recordForceAttempt]);
    }
    CHECK(!lock.backingOff);
    CHECK(![lock recordForceAttempt]);
    CHECK(lock.backingOff);

    [lock resetContention];
    CHECK(!lock.backingOff);
    CHECK([lock recordForceAttempt]);
}

int main(void)
{
    @autoreleasepool {
        testKeepsConfirmedID();
        testRecycledIDFollowsUID();
        testRecoversByUIDAfterReconnect();
        testRecoversByNameAndBackfillsUID();
        testMissingDeviceKeepsSavedSelection();
        testIgnoresDeviceInOtherDirection();
        testNothingChosenResolvesToNothing();
        testContentionBacksOffOnEighthForce();
    }
    printf(failures == 0 ? "AudioLock tests passed\n" : "%d check(s) failed\n", failures);
    return failures == 0 ? 0 : 1;
}
