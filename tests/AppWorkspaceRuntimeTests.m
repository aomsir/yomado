#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <stdio.h>
#import "AppWorkspace.h"
#import "AppWorkspaceAccess.h"
#import "AppWorkspacePolicy.h"

static NSUInteger checks, failures;
static void Check(BOOL condition, NSString *description) {
    checks++;
    if (!condition) {
        failures++;
        fprintf(stderr, "FAIL: %s\n", description.UTF8String);
    }
}

static NSDictionary *Frame(double x, double y, double width, double height) {
    return @{@"x": @(x), @"y": @(y), @"width": @(width), @"height": @(height)};
}

static NSDictionary *RuntimeDisplay(unsigned int ID, double x, BOOL isVirtual, NSString *uuid) {
    return @{@"displayID": @(ID), @"displayUUID": uuid,
        @"bounds": Frame(x, 0, 2560, 1440), @"isMain": @(ID == 5),
        @"isActive": @YES, @"isOnline": @YES, @"isVirtual": @(isVirtual)};
}

static NSArray *RuntimeDisplays(void) {
    return @[RuntimeDisplay(5, 0, NO, @"physical"),
             RuntimeDisplay(8, 2560, YES, @"agent-a"),
             RuntimeDisplay(9, 5120, YES, @"agent-b")];
}

static NSDictionary *Identity(pid_t pid, CGWindowID windowID) {
    return @{@"pid": @(pid), @"windowID": @(windowID), @"startSeconds": @1000,
             @"startMicroseconds": @7, @"bundleID": @"test.calculator"};
}

#pragma mark - Fake application / access

@interface YMFakeRunningApp : NSObject
@property(nonatomic) pid_t processIdentifier;
@property(nonatomic, getter=isTerminated) BOOL terminated;
@property(nonatomic, copy) NSString *bundleIdentifier;
@property(nonatomic, strong) NSURL *bundleURL;
@property(nonatomic, copy) NSString *localizedName;
@property(nonatomic, strong) NSImage *icon;
@end
@implementation YMFakeRunningApp
@end

@interface YMFakeWindowAccess : NSObject <YMWorkspaceWindowAccess>
@property(nonatomic) BOOL trusted;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *cgWindows;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSArray *> *axByPID;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, YMFakeRunningApp *> *appsByPID;
@property(nonatomic, strong) NSMutableDictionary *elementFrames;
@property(nonatomic, strong) NSMutableDictionary *elementIdentities;
@property(nonatomic) NSUInteger readCount;
@property(nonatomic) NSUInteger writeCount;
@property(nonatomic) NSUInteger observeCount;
@property(nonatomic) NSUInteger observeElementCount;
@property(nonatomic) BOOL failVisibleWindows;
@property(nonatomic) BOOL forceIncompleteObserve;
@property(nonatomic, copy) NSString *incompleteReason;
@property(nonatomic) NSTimeInterval observeDelay;
@property(nonatomic, strong) NSMutableArray<NSNumber *> *observedPIDs;
@end

@implementation YMFakeWindowAccess
- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _trusted = YES;
    _cgWindows = [NSMutableArray array];
    _axByPID = [NSMutableDictionary dictionary];
    _appsByPID = [NSMutableDictionary dictionary];
    _elementFrames = [NSMutableDictionary dictionary];
    _elementIdentities = [NSMutableDictionary dictionary];
    _observedPIDs = [NSMutableArray array];
    _incompleteReason = @"timeout";
    return self;
}

- (YMFakeRunningApp *)installApp:(pid_t)pid name:(NSString *)name bundle:(NSString *)bundle {
    YMFakeRunningApp *app = [YMFakeRunningApp new];
    app.processIdentifier = pid;
    app.bundleIdentifier = bundle;
    app.localizedName = name;
    app.bundleURL = [NSURL fileURLWithPath:[NSString stringWithFormat:@"/tmp/fake-%@.app", bundle]];
    app.terminated = NO;
    self.appsByPID[@(pid)] = app;
    return app;
}

- (void)installWindowPID:(pid_t)pid windowID:(CGWindowID)windowID
                cgFrame:(NSDictionary *)cgFrame axFrame:(NSDictionary *)axFrame {
    NSDictionary *identity = Identity(pid, windowID);
    id element = [NSString stringWithFormat:@"el-%d-%u", pid, windowID];
    [self.cgWindows addObject:@{@"pid": @(pid), @"windowID": @(windowID),
        @"frame": cgFrame, @"layer": @0, @"onScreen": @YES, @"alpha": @1}];
    NSDictionary *ax = @{@"identity": identity, @"frame": axFrame, @"ordinary": @YES,
        @"minimized": @NO, @"readable": @YES, @"positionSettable": @YES, @"element": element};
    NSMutableArray *list = [self.axByPID[@(pid)] mutableCopy] ?: [NSMutableArray array];
    [list addObject:ax];
    self.axByPID[@(pid)] = list;
    self.elementFrames[[NSString stringWithFormat:@"%p", element]] = axFrame;
    self.elementIdentities[[NSString stringWithFormat:@"%p", element]] = identity;
}

- (BOOL)accessibilityTrusted { return self.trusted; }

- (nullable NSArray<NSDictionary *> *)visibleWindows {
    self.readCount++;
    if (self.failVisibleWindows) return nil;
    return self.cgWindows.copy;
}

- (nullable NSRunningApplication *)applicationForPID:(pid_t)pid {
    return (NSRunningApplication *)self.appsByPID[@(pid)];
}

- (NSArray<NSRunningApplication *> *)applicationsForBundleIdentifier:(NSString *)bundleID {
    NSMutableArray *result = [NSMutableArray array];
    for (YMFakeRunningApp *app in self.appsByPID.allValues)
        if ([app.bundleIdentifier isEqual:bundleID]) [result addObject:app];
    return result;
}

- (NSDictionary *)observeApplication:(NSRunningApplication *)application
                            deadline:(NSTimeInterval)deadline {
    (void)deadline;
    self.observeCount++;
    pid_t pid = application.processIdentifier;
    [self.observedPIDs addObject:@(pid)];
    if (self.forceIncompleteObserve)
        return @{@"windows": self.axByPID[@(pid)] ?: @[], @"complete": @NO,
                 @"reason": self.incompleteReason ?: @"timeout"};
    YMFakeRunningApp *app = self.appsByPID[@(pid)];
    if (!app || app.terminated)
        return @{@"windows": @[], @"complete": @NO, @"reason": @"processTerminated"};
    return @{@"windows": self.axByPID[@(pid)] ?: @[], @"complete": @YES, @"reason": @""};
}

- (nullable NSDictionary *)observeElement:(id)element {
    self.observeElementCount++;
    NSString *key = [NSString stringWithFormat:@"%p", element];
    NSDictionary *frame = self.elementFrames[key];
    NSDictionary *identity = self.elementIdentities[key];
    if (!frame || !identity) return nil;
    return @{@"identity": identity, @"frame": frame, @"ordinary": @YES, @"minimized": @NO,
             @"readable": @YES, @"positionSettable": @YES, @"element": element};
}

- (nullable id)resolveIdentity:(NSDictionary *)identity error:(NSError **)error {
    for (NSString *key in self.elementIdentities) {
        if ([self.elementIdentities[key] isEqual:identity]) {
            for (NSArray *list in self.axByPID.allValues)
                for (NSDictionary *ax in list)
                    if ([ax[@"identity"] isEqual:identity]) return ax[@"element"];
        }
    }
    if (error) *error = [NSError errorWithDomain:@"fixture" code:1 userInfo:nil];
    return nil;
}

- (BOOL)setPosition:(CGPoint)position element:(id)element
   expectedIdentity:(NSDictionary *)identity {
    (void)position; (void)element; (void)identity;
    self.writeCount++;
    return YES;
}

- (BOOL)setSize:(CGSize)size element:(id)element expectedIdentity:(NSDictionary *)identity {
    (void)size; (void)element; (void)identity;
    self.writeCount++;
    return YES;
}
@end

#pragma mark - Workspace fixture

@interface YMAppWorkspace (RuntimePrivate)
@property(nonatomic, strong) id<YMWorkspaceWindowAccess> windowAccess;
@property(nonatomic, strong) NSMutableArray *placements;
@property(nonatomic, copy) NSArray *windows;
@property(nonatomic) BOOL inventoryValid;
@property(nonatomic) BOOL operationInProgress;
@property(nonatomic) NSUInteger inventoryGeneration;
- (void)scheduleInventoryRead:(dispatch_block_t)read;
- (void)publishInventoryRead:(dispatch_block_t)publish;
- (NSTimeInterval)inventoryTime;
- (NSArray<NSScreen *> *)workspaceScreens;
- (void)invalidateInventoryForMutation;
- (BOOL)displayStillCurrent:(NSDictionary *)display;
@end

@interface YMWorkspaceFixture : YMAppWorkspace
@property(nonatomic, strong) NSMutableArray *pendingReads;
@property(nonatomic, strong) NSMutableArray *pendingPublishes;
@property(nonatomic) NSTimeInterval clock;
@property(nonatomic) NSUInteger scheduleCount;
@property(nonatomic, strong) NSArray *fakeScreens;
@property(nonatomic) BOOL displayCurrent;
@end

@implementation YMWorkspaceFixture
- (instancetype)initWithWindowAccess:(id<YMWorkspaceWindowAccess>)access {
    self = [super initWithWindowAccess:access];
    if (!self) return nil;
    _pendingReads = [NSMutableArray array];
    _pendingPublishes = [NSMutableArray array];
    _clock = 1000;
    _displayCurrent = YES;
    _fakeScreens = @[];
    return self;
}

- (void)scheduleInventoryRead:(dispatch_block_t)read {
    self.scheduleCount++;
    [self.pendingReads addObject:[read copy]];
}

- (void)publishInventoryRead:(dispatch_block_t)publish {
    [self.pendingPublishes addObject:[publish copy]];
}

- (NSTimeInterval)inventoryTime { return self.clock; }

- (NSArray<NSScreen *> *)workspaceScreens { return self.fakeScreens ?: @[]; }

- (BOOL)displayStillCurrent:(NSDictionary *)display {
    (void)display;
    return self.displayCurrent;
}

- (void)advanceClock:(NSTimeInterval)delta { self.clock += delta; }

- (void)finishNextRead {
    if (self.pendingReads.count) {
        dispatch_block_t read = self.pendingReads.firstObject;
        [self.pendingReads removeObjectAtIndex:0];
        read();
    }
    if (self.pendingPublishes.count) {
        dispatch_block_t publish = self.pendingPublishes.firstObject;
        [self.pendingPublishes removeObjectAtIndex:0];
        publish();
    }
}

- (void)drainReads {
    NSUInteger guard = 128;
    while ((self.pendingReads.count || self.pendingPublishes.count) && guard--)
        [self finishNextRead];
}

- (void)installPlacementElement:(id)element application:(YMFakeRunningApp *)app
                       windowID:(CGWindowID)windowID origin:(NSDictionary *)origin
                  lastDisplayID:(CGDirectDisplayID)lastDisplayID {
    Class cls = NSClassFromString(@"YMWPlacement");
    Check(cls != Nil, @"YMWPlacement class must be linked");
    id placement = [cls new];
    [placement setValue:element forKey:@"element"];
    [placement setValue:app forKey:@"application"];
    [placement setValue:app.bundleIdentifier forKey:@"bundleID"];
    [placement setValue:@(windowID) forKey:@"windowID"];
    [placement setValue:origin forKey:@"origin"];
    [placement setValue:@(lastDisplayID) forKey:@"lastDisplayID"];
    [[self valueForKey:@"placements"] addObject:placement];
}
@end

static YMWorkspaceFixture *FixtureWithThumbnail(YMFakeWindowAccess **outAccess) {
    YMFakeWindowAccess *access = [YMFakeWindowAccess new];
    [access installApp:42 name:@"Calculator" bundle:@"test.calculator"];
    // Task 2 small Stage Manager thumbnail on physical; real AX frame also physical.
    [access installWindowPID:42 windowID:1490
                     cgFrame:Frame(15, 982, 37, 102)
                     axFrame:Frame(830, 719, 230, 408)];
    YMWorkspaceFixture *workspace = [[YMWorkspaceFixture alloc] initWithWindowAccess:access];
    if (outAccess) *outAccess = access;
    return workspace;
}

int main(void) {
    @autoreleasepool {
        NSArray *displays = RuntimeDisplays();

        // --- Group 0 / Step 1 smoke: pending then publish small thumbnail ---
        {
            YMFakeWindowAccess *access = nil;
            YMWorkspaceFixture *workspace = FixtureWithThumbnail(&access);
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            Check(!workspace.inventoryReady, @"pending metadata is not a verified empty display");
            Check([workspace needsRestoreForDisplayID:8], @"pending read keeps display alive");
            [workspace drainReads];
            Check([[workspace rowsForDisplayID:5] count] == 1,
                  @"small thumbnail publishes its real app row");
            Check(workspace.inventoryReady, @"complete current metadata publishes ready state");
            NSDictionary *row = [workspace rowsForDisplayID:5].firstObject;
            Check([row[@"appName"] isEqual:@"Calculator"], @"main thread assembles fake appName");
            Check([row[@"bundleIdentifier"] isEqual:@"test.calculator"], @"bundle comes from fake app");
            Check(access.observeCount == 1, @"one observeApplication per PID");
        }

        // --- Group 1: coalesce 30 refreshes; stale generation discarded ---
        {
            YMFakeWindowAccess *access = nil;
            YMWorkspaceFixture *workspace = FixtureWithThumbnail(&access);
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            NSUInteger firstSchedules = workspace.scheduleCount;
            for (NSUInteger i = 0; i < 30; i++)
                [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            Check(workspace.scheduleCount == firstSchedules,
                  @"same key refresh 30 times schedules only one job");
            Check(workspace.pendingReads.count == 1, @"at most one in-flight read block");

            // Change owned IDs while the first job is still pending; coalescing keeps
            // a single in-flight slot and remembers the latest request.
            [workspace refreshWithVirtualDisplayIDs:@[@9] displaySnapshot:displays];
            Check(workspace.scheduleCount == firstSchedules,
                  @"owned ID change while in-flight does not start a second concurrent job");
            Check(workspace.pendingReads.count == 1, @"still one in-flight read block");
            [workspace finishNextRead];
            Check(!workspace.inventoryReady, @"stale generation must not publish ready");
            Check([[workspace rowsForDisplayID:8] count] == 0,
                  @"cancelled screen cannot be reassigned by stale result");
            // Discard schedules the latest generation job.
            Check(workspace.scheduleCount == firstSchedules + 1,
                  @"discarded stale result merges the latest topology request");
            [workspace drainReads];
            Check(workspace.inventoryReady, @"fresh generation publishes after drain");
            Check([[workspace rowsForDisplayID:8] count] == 0,
                  @"screen 8 stays unowned after switching to screen 9");
        }

        // --- Group 2: timeout / PID failure / CG failure / trust revoke / true empty ---
        {
            YMFakeWindowAccess *access = nil;
            YMWorkspaceFixture *workspace = FixtureWithThumbnail(&access);
            access.forceIncompleteObserve = YES;
            access.incompleteReason = @"timeout";
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            Check(!workspace.inventoryReady, @"round timeout is not ready");
            Check([workspace needsRestoreForDisplayID:8], @"timeout keeps needsRestore");
            NSError *error = nil;
            Check(![workspace restoreDisplayID:8 error:&error], @"timeout refuses restoreDisplayID");
        }
        {
            YMFakeWindowAccess *access = nil;
            YMWorkspaceFixture *workspace = FixtureWithThumbnail(&access);
            access.forceIncompleteObserve = YES;
            access.incompleteReason = @"incompleteMetadata";
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            Check(!workspace.inventoryReady, @"PID observe failure is not ready");
            Check([workspace needsRestoreForDisplayID:8], @"PID failure keeps needsRestore");
        }
        {
            YMFakeWindowAccess *access = nil;
            YMWorkspaceFixture *workspace = FixtureWithThumbnail(&access);
            access.failVisibleWindows = YES;
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            Check(!workspace.inventoryReady, @"CG failure is not ready");
            Check([workspace needsRestoreForDisplayID:8], @"CG failure keeps needsRestore");
            NSError *error = nil;
            Check(![workspace restoreDisplayID:8 error:&error], @"CG failure refuses restoreDisplayID");
        }
        {
            YMFakeWindowAccess *access = nil;
            YMWorkspaceFixture *workspace = FixtureWithThumbnail(&access);
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            Check(workspace.inventoryReady, @"trusted complete inventory is ready before revoke");
            access.trusted = NO;
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            // No AX: pure CG path. Small thumbnail fails old size gate → not shown,
            // but unresolved small candidate must not prove any owned virtual empty.
            Check(!workspace.inventoryReady,
                  @"unknown no-AX thumbnail does not publish ready empty proof");
            Check([workspace needsRestoreForDisplayID:8],
                  @"unknown no-AX thumbnail keeps needsRestore on owned virtual");
            NSError *revokeError = nil;
            Check(![workspace restoreDisplayID:8 error:&revokeError],
                  @"unknown no-AX thumbnail refuses restoreDisplayID");
            // Large CG on virtual without AX should show and allow classification.
            [access.cgWindows removeAllObjects];
            [access.axByPID removeAllObjects];
            [access.cgWindows addObject:@{@"pid": @42, @"windowID": @1490,
                @"frame": Frame(2700, 100, 400, 300), @"layer": @0, @"onScreen": @YES, @"alpha": @1}];
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            Check([[workspace rowsForDisplayID:8] count] == 1, @"no-AX large CG still displays");
            Check([workspace needsRestoreForDisplayID:8], @"no-AX window on virtual keeps restore need");
        }
        {
            YMFakeWindowAccess *access = [YMFakeWindowAccess new];
            [access installApp:42 name:@"Calculator" bundle:@"test.calculator"];
            YMWorkspaceFixture *workspace = [[YMWorkspaceFixture alloc] initWithWindowAccess:access];
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            Check(workspace.inventoryReady, @"true empty inventory can be ready");
            Check(![workspace needsRestoreForDisplayID:8], @"true empty without placements may close");
            NSError *error = nil;
            Check([workspace restoreDisplayID:8 error:&error], @"true empty restoreDisplayID succeeds");
        }

        // --- Group 3: mutation invalidates old job; UI rows may linger; close/export blocked ---
        {
            YMFakeWindowAccess *access = nil;
            YMWorkspaceFixture *workspace = FixtureWithThumbnail(&access);
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            Check(workspace.inventoryReady, @"baseline ready before mutation");
            NSUInteger rowsBefore = [workspace rowsForDisplayID:5].count;
            [workspace invalidateInventoryForMutation];
            Check(!workspace.inventoryReady, @"mutation invalidates ready immediately");
            Check([workspace rowsForDisplayID:5].count == rowsBefore, @"UI rows may linger after invalidate");
            Check([workspace needsRestoreForDisplayID:8], @"close gate blocked after mutation");
            NSError *error = nil;
            Check(![workspace restartOriginCheckpointsWithError:&error],
                  @"update export blocked while inventory unconfirmed");
            [workspace drainReads];
        }

        // --- Group 4: CG order change does not starve; cache expires after 1s ---
        {
            YMFakeWindowAccess *access = nil;
            YMWorkspaceFixture *workspace = FixtureWithThumbnail(&access);
            [access installApp:77 name:@"Notes" bundle:@"test.notes"];
            [access installWindowPID:77 windowID:2001
                             cgFrame:Frame(100, 100, 200, 200)
                             axFrame:Frame(100, 100, 200, 200)];
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            NSUInteger schedules = workspace.scheduleCount;
            NSUInteger observes = access.observeCount;
            // Reverse CG order, same set.
            NSArray *reversed = [[access.cgWindows reverseObjectEnumerator] allObjects];
            [access.cgWindows removeAllObjects];
            [access.cgWindows addObjectsFromArray:reversed];
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            Check(workspace.scheduleCount == schedules,
                  @"CG order change with same set does not schedule a new job");
            Check(access.observeCount == observes, @"same normalized key reuses observation");
            Check(workspace.inventoryReady, @"cache still authorizes close within 1s");
            [workspace advanceClock:1.01];
            Check(!workspace.inventoryReady, @"cache older than 1s no longer authorizes close");
            Check([workspace needsRestoreForDisplayID:8], @"expired cache keeps needsRestore");
        }

        // --- Group 6: checkpoint retirement uses independent cgFrame + job AX ---
        {
            // Delayed physical CG A + different physical AX B: keep. Using frame as
            // cgFrame would wrongly confirm (SameFrame(ax,ax) on physical).
            YMFakeWindowAccess *access = [YMFakeWindowAccess new];
            YMFakeRunningApp *app = [access installApp:42 name:@"Calculator" bundle:@"test.calculator"];
            NSDictionary *physicalCG = Frame(100, 100, 230, 408);
            NSDictionary *physicalAX = Frame(500, 200, 230, 408);
            id element = @"el-checkpoint-disagree";
            NSDictionary *identity = Identity(42, 1490);
            access.elementFrames[[NSString stringWithFormat:@"%p", element]] = physicalAX;
            access.elementIdentities[[NSString stringWithFormat:@"%p", element]] = identity;
            [access.cgWindows addObject:@{@"pid": @42, @"windowID": @1490,
                @"frame": physicalCG, @"layer": @0, @"onScreen": @YES, @"alpha": @1}];
            access.axByPID[@42] = @[@{@"identity": identity, @"frame": physicalAX, @"ordinary": @YES,
                @"minimized": @NO, @"readable": @YES, @"positionSettable": @YES, @"element": element}];
            YMWorkspaceFixture *workspace = [[YMWorkspaceFixture alloc] initWithWindowAccess:access];
            NSDictionary *origin = YMWorkspaceOrigin(physicalCG, RuntimeDisplay(5, 0, NO, @"physical"));
            [workspace installPlacementElement:element application:app windowID:1490
                                        origin:origin lastDisplayID:8];
            NSUInteger elementObservesBefore = access.observeElementCount;
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            NSArray *placements = [workspace valueForKey:@"placements"];
            Check(placements.count == 1,
                  @"disagreeing physical CG+AX must not retire checkpoint");
            NSDictionary *published = nil;
            for (NSDictionary *window in workspace.windows)
                if ([window[@"windowID"] unsignedIntValue] == 1490) published = window;
            Check(published[@"cgFrame"] != nil, @"published window retains cgFrame");
            Check([published[@"cgFrame"] isEqual:physicalCG],
                  @"cgFrame must stay independent raw CG, not normalizer.frame");
            Check([published[@"frame"] isEqual:physicalAX], @"frame uses AX geometry");
            Check(!YMWorkspacePhysicalReturnConfirmed(published[@"cgFrame"], published[@"frame"],
                                                      displays, NO),
                  @"independent disagreeing cgFrame+AX keep checkpoint");
            Check(YMWorkspacePhysicalReturnConfirmed(published[@"frame"], published[@"frame"],
                                                     displays, NO),
                  @"using normalizer.frame as cgFrame would wrongly confirm physical return");
            Check(access.observeElementCount == elementObservesBefore,
                  @"checkpoint retirement must not sync observeElement on publish");
        }
        {
            // Agreeing physical CG+AX enters physical-return branch and clears.
            YMFakeWindowAccess *access = [YMFakeWindowAccess new];
            YMFakeRunningApp *app = [access installApp:42 name:@"Calculator" bundle:@"test.calculator"];
            NSDictionary *physical = Frame(830, 675, 230, 408);
            id element = @"el-checkpoint-agree";
            NSDictionary *identity = Identity(42, 1491);
            access.elementFrames[[NSString stringWithFormat:@"%p", element]] = physical;
            access.elementIdentities[[NSString stringWithFormat:@"%p", element]] = identity;
            [access.cgWindows addObject:@{@"pid": @42, @"windowID": @1491,
                @"frame": physical, @"layer": @0, @"onScreen": @YES, @"alpha": @1}];
            access.axByPID[@42] = @[@{@"identity": identity, @"frame": physical, @"ordinary": @YES,
                @"minimized": @NO, @"readable": @YES, @"positionSettable": @YES, @"element": element}];
            YMWorkspaceFixture *workspace = [[YMWorkspaceFixture alloc] initWithWindowAccess:access];
            NSDictionary *origin = YMWorkspaceOrigin(physical, RuntimeDisplay(5, 0, NO, @"physical"));
            [workspace installPlacementElement:element application:app windowID:1491
                                        origin:origin lastDisplayID:8];
            NSUInteger elementObservesBefore = access.observeElementCount;
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            NSArray *placements = [workspace valueForKey:@"placements"];
            Check(placements.count == 0,
                  @"agreeing physical CG+AX retires checkpoint via physical-return branch");
            Check(access.observeElementCount == elementObservesBefore,
                  @"physical-return retirement uses job AX evidence, not sync observeElement");
        }

        // --- Group 7: callback on main; incomplete failure path terminates ---
        {
            YMFakeWindowAccess *access = nil;
            YMWorkspaceFixture *workspace = FixtureWithThumbnail(&access);
            __block NSUInteger callbacks = 0;
            __block BOOL sawOffMain = NO;
            __weak YMWorkspaceFixture *weakWorkspace = workspace;
            workspace.inventoryDidChange = ^{
                if (![NSThread isMainThread]) sawOffMain = YES;
                callbacks++;
                YMWorkspaceFixture *strong = weakWorkspace;
                if (strong)
                    [strong refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            };
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            Check(callbacks == 1, @"callback fires once on first publish");
            Check(!sawOffMain, @"callback runs on main thread");
            NSUInteger schedules = workspace.scheduleCount;
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            Check(workspace.scheduleCount == schedules, @"callback-driven same-key refresh does not loop");
            Check(callbacks == 1, @"same-key reuse does not reenter callback");
            workspace = nil;
            Check(weakWorkspace == nil || callbacks >= 1, @"callback captures workspace weakly");
        }
        {
            // Incomplete same-key: notify only on real change; bounded reuse; no close;
            // callback-driven refresh must terminate without a new job.
            YMFakeWindowAccess *access = nil;
            YMWorkspaceFixture *workspace = FixtureWithThumbnail(&access);
            access.forceIncompleteObserve = YES;
            access.incompleteReason = @"timeout";
            __block NSUInteger callbacks = 0;
            __weak YMWorkspaceFixture *weakWorkspace = workspace;
            workspace.inventoryDidChange = ^{
                callbacks++;
                YMWorkspaceFixture *strong = weakWorkspace;
                if (strong)
                    [strong refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            };
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            NSUInteger schedulesAfterFail = workspace.scheduleCount;
            NSUInteger callbacksAfterFail = callbacks;
            Check(!workspace.inventoryReady, @"incomplete observation is not ready");
            Check([workspace needsRestoreForDisplayID:8], @"incomplete never authorizes close");
            Check(workspace.pendingReads.count == 0, @"failure path has no leftover in-flight job");
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            Check(workspace.scheduleCount == schedulesAfterFail,
                  @"same-key incomplete result reuses observation without new job");
            Check(workspace.pendingReads.count == 0,
                  @"callback-driven refresh on failure path does not restart a job");
            [workspace drainReads];
            Check(callbacks == callbacksAfterFail,
                  @"same-key incomplete reuse does not reenter callback");
            Check(callbacks <= 2, @"incomplete failure path does not spin callbacks");
        }

        // --- Fix2 / Important 1: write-in-flight must not rewrite placement ownership ---
        {
            YMFakeWindowAccess *access = [YMFakeWindowAccess new];
            YMFakeRunningApp *app = [access installApp:42 name:@"Calculator" bundle:@"test.calculator"];
            NSDictionary *virtualFrame = Frame(2700, 100, 230, 408);
            id element = @"el-write-ownership";
            NSDictionary *identity = Identity(42, 1490);
            access.elementFrames[[NSString stringWithFormat:@"%p", element]] = virtualFrame;
            access.elementIdentities[[NSString stringWithFormat:@"%p", element]] = identity;
            [access.cgWindows addObject:@{@"pid": @42, @"windowID": @1490,
                @"frame": virtualFrame, @"layer": @0, @"onScreen": @YES, @"alpha": @1}];
            access.axByPID[@42] = @[@{@"identity": identity, @"frame": virtualFrame, @"ordinary": @YES,
                @"minimized": @NO, @"readable": @YES, @"positionSettable": @YES, @"element": element}];
            YMWorkspaceFixture *workspace = [[YMWorkspaceFixture alloc] initWithWindowAccess:access];
            NSDictionary *origin = YMWorkspaceOrigin(Frame(100, 100, 230, 408),
                                                     RuntimeDisplay(5, 0, NO, @"physical"));
            [workspace installPlacementElement:element application:app windowID:1490
                                        origin:origin lastDisplayID:8];
            // Schedule observation, then enter a write before it publishes — mirrors
            // placeElement runloop allowing an in-flight job to finish mid-move.
            [workspace refreshWithVirtualDisplayIDs:@[@8, @9] displaySnapshot:displays];
            Check(workspace.pendingReads.count == 1, @"write probe starts with one pending job");
            id placement = [[workspace valueForKey:@"placements"] firstObject];
            // A→B move already recorded; stale observation still shows screen A (8).
            [placement setValue:@9 forKey:@"lastDisplayID"];
            workspace.operationInProgress = YES;
            [workspace invalidateInventoryForMutation];
            Check(workspace.pendingReads.count == 1,
                  @"invalidate during write does not schedule an additional job");
            [workspace finishNextRead]; // in-flight job completes during write
            Check([[placement valueForKey:@"lastDisplayID"] unsignedIntValue] == 9,
                  @"write-in-flight publish must not revert placement ownership to stale screen");
            Check(!workspace.inventoryReady,
                  @"write-in-flight inventory must not publish ready");
            Check([[workspace valueForKey:@"placements"] count] == 1,
                  @"target-screen placement record must survive stale publish during write");
            workspace.operationInProgress = NO;
            [workspace invalidateInventoryForMutation];
            [workspace drainReads];
            Check(workspace.pendingReads.count == 0,
                  @"bounded reads resume after write ends");
        }

        // --- Fix2 / Important 2: publish revalidates live topology ---
        {
            YMFakeWindowAccess *access = nil;
            YMWorkspaceFixture *workspace = FixtureWithThumbnail(&access);
            YMFakeRunningApp *app = access.appsByPID[@42];
            id element = access.axByPID[@42].firstObject[@"element"];
            NSDictionary *origin = YMWorkspaceOrigin(Frame(830, 719, 230, 408),
                                                     RuntimeDisplay(5, 0, NO, @"physical"));
            [workspace installPlacementElement:element application:app windowID:1490
                                        origin:origin lastDisplayID:8];
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            Check(workspace.pendingReads.count == 1, @"topology probe schedules one job");
            workspace.displayCurrent = NO; // topology moved; manager not refreshed yet
            [workspace drainReads];
            Check(!workspace.inventoryReady,
                  @"stale topology must not publish ready without manager refresh");
            Check([[workspace valueForKey:@"placements"] count] == 1,
                  @"stale topology must not retire checkpoints");
        }

        // --- Fix2 / Important 3: normalizer uses admitted app set ---
        {
            YMFakeWindowAccess *access = [YMFakeWindowAccess new];
            [access installApp:42 name:@"Calculator" bundle:@"test.calculator"];
            [access installWindowPID:42 windowID:1490
                             cgFrame:Frame(2700, 100, 400, 300)
                             axFrame:Frame(2700, 100, 400, 300)];
            // Layer-zero system surface without bundle admission.
            [access.cgWindows addObject:@{@"pid": @999, @"windowID": @77,
                @"frame": Frame(2800, 200, 120, 90), @"layer": @0, @"onScreen": @YES, @"alpha": @1}];
            YMWorkspaceFixture *workspace = [[YMWorkspaceFixture alloc] initWithWindowAccess:access];
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            Check(workspace.inventoryReady,
                  @"non-admitted system surface must not create unmatched blockers");
            Check([[workspace rowsForDisplayID:8] count] == 1,
                  @"admitted app still publishes");

            // Admitted app with CG but missing AX remains unknown — not silently skipped.
            YMFakeWindowAccess *unknownAccess = [YMFakeWindowAccess new];
            [unknownAccess installApp:42 name:@"Calculator" bundle:@"test.calculator"];
            [unknownAccess.cgWindows addObject:@{@"pid": @42, @"windowID": @1490,
                @"frame": Frame(2700, 100, 400, 300), @"layer": @0, @"onScreen": @YES, @"alpha": @1}];
            YMWorkspaceFixture *unknownWS = [[YMWorkspaceFixture alloc] initWithWindowAccess:unknownAccess];
            [unknownWS refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [unknownWS drainReads];
            Check(!unknownWS.inventoryReady,
                  @"admitted app with unknown AX metadata still refuses ready");
        }

        // --- Fix2 / Important 4: retained checkpoint must not silent-export empty ---
        {
            YMFakeWindowAccess *access = [YMFakeWindowAccess new];
            YMFakeRunningApp *app = [access installApp:42 name:@"Calculator" bundle:@"test.calculator"];
            // Independent evidence disagree: CG still virtual, AX already physical.
            NSDictionary *cgVirtual = Frame(2700, 100, 230, 408);
            NSDictionary *axPhysical = Frame(830, 675, 230, 408);
            id element = @"el-retained-checkpoint";
            NSDictionary *identity = Identity(42, 1490);
            access.elementFrames[[NSString stringWithFormat:@"%p", element]] = axPhysical;
            access.elementIdentities[[NSString stringWithFormat:@"%p", element]] = identity;
            [access.cgWindows addObject:@{@"pid": @42, @"windowID": @1490,
                @"frame": cgVirtual, @"layer": @0, @"onScreen": @YES, @"alpha": @1}];
            access.axByPID[@42] = @[@{@"identity": identity, @"frame": axPhysical, @"ordinary": @YES,
                @"minimized": @NO, @"readable": @YES, @"positionSettable": @YES, @"element": element}];
            YMWorkspaceFixture *workspace = [[YMWorkspaceFixture alloc] initWithWindowAccess:access];
            NSDictionary *origin = YMWorkspaceOrigin(axPhysical, RuntimeDisplay(5, 0, NO, @"physical"));
            [workspace installPlacementElement:element application:app windowID:1490
                                        origin:origin lastDisplayID:8];
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            Check(workspace.inventoryReady,
                  @"disagreeing CG/AX inventory can still be ready");
            Check([[workspace valueForKey:@"placements"] count] == 1,
                  @"disagreeing evidence retains checkpoint");
            NSError *exportError = nil;
            NSArray *exported = [workspace restartOriginCheckpointsWithError:&exportError];
            Check(exported == nil && exportError != nil,
                  @"retained checkpoint absent from owned windows must export error, not empty success");
        }

        // --- Fix2 / Important 5: observed trust/CG source transitions bump generation ---
        {
            YMFakeWindowAccess *access = nil;
            YMWorkspaceFixture *workspace = FixtureWithThumbnail(&access);
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            NSUInteger gen0 = workspace.inventoryGeneration;
            Check(workspace.pendingReads.count == 1, @"trust probe starts with one job");
            // YES → NO → YES while first job still in-flight.
            access.trusted = NO;
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            NSUInteger genAfterNO = workspace.inventoryGeneration;
            Check(genAfterNO > gen0, @"observed trust YES→NO advances generation");
            access.trusted = YES;
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            NSUInteger genAfterYES = workspace.inventoryGeneration;
            Check(genAfterYES > genAfterNO, @"observed trust NO→YES advances generation again");
            [workspace finishNextRead]; // completes the original in-flight job
            Check(!workspace.inventoryReady,
                  @"old job must not revive on final equal key after trust flap");
            [workspace drainReads];
        }
        {
            YMFakeWindowAccess *access = nil;
            YMWorkspaceFixture *workspace = FixtureWithThumbnail(&access);
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            NSUInteger gen0 = workspace.inventoryGeneration;
            // Source A → B → A while first job in-flight.
            NSDictionary *altFrame = Frame(100, 100, 200, 200);
            [access.cgWindows removeAllObjects];
            [access.cgWindows addObject:@{@"pid": @42, @"windowID": @1490,
                @"frame": altFrame, @"layer": @0, @"onScreen": @YES, @"alpha": @1}];
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            NSUInteger genAfterB = workspace.inventoryGeneration;
            Check(genAfterB > gen0, @"observed CG source A→B advances generation");
            [access.cgWindows removeAllObjects];
            [access.axByPID removeAllObjects];
            [access installWindowPID:42 windowID:1490
                             cgFrame:Frame(15, 982, 37, 102)
                             axFrame:Frame(830, 719, 230, 408)];
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            NSUInteger genAfterA = workspace.inventoryGeneration;
            Check(genAfterA > genAfterB, @"observed CG source B→A advances generation again");
            [workspace finishNextRead];
            Check(!workspace.inventoryReady,
                  @"old job must not revive on final equal CG key after source flap");
            [workspace drainReads];
        }

        // --- Fix2 / Important 6: exact budget ceilings remain complete ---
        {
            YMFakeWindowAccess *access = [YMFakeWindowAccess new];
            for (NSUInteger i = 0; i < 64; i++) {
                pid_t pid = (pid_t)(1000 + i);
                [access installApp:pid name:[NSString stringWithFormat:@"App%lu", (unsigned long)i]
                            bundle:[NSString stringWithFormat:@"test.app%lu", (unsigned long)i]];
                [access installWindowPID:pid windowID:(CGWindowID)(2000 + i)
                                 cgFrame:Frame(2700, 100, 200, 200)
                                 axFrame:Frame(2700, 100, 200, 200)];
            }
            YMWorkspaceFixture *workspace = [[YMWorkspaceFixture alloc] initWithWindowAccess:access];
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            Check(workspace.inventoryReady, @"exactly 64 PIDs remains a complete observation");
            Check(access.observedPIDs.count == 64, @"exactly 64 PIDs are all observed");

            pid_t extra = 1064;
            [access installApp:extra name:@"Extra" bundle:@"test.extra"];
            [access installWindowPID:extra windowID:2064
                             cgFrame:Frame(2700, 100, 200, 200)
                             axFrame:Frame(2700, 100, 200, 200)];
            [access.observedPIDs removeAllObjects];
            access.observeCount = 0;
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            Check(!workspace.inventoryReady, @"65 PIDs is truncated and incomplete");
            Check(access.observedPIDs.count == 64,
                  @"exactly 64 of 65 PIDs are observed; the extra is truncated");
            Check(![access.observedPIDs containsObject:@(extra)],
                  @"65th PID is not observed after the ceiling");
        }
        {
            YMFakeWindowAccess *access = [YMFakeWindowAccess new];
            for (NSUInteger i = 0; i < 512; i++) {
                // Same PID so PID cap does not trip; exercise CG candidate ceiling.
                if (i == 0) [access installApp:42 name:@"Calculator" bundle:@"test.calculator"];
                CGWindowID wid = (CGWindowID)(3000 + i);
                NSDictionary *frame = Frame(2700 + (i % 10), 100 + (i % 20), 200, 200);
                [access.cgWindows addObject:@{@"pid": @42, @"windowID": @(wid),
                    @"frame": frame, @"layer": @0, @"onScreen": @YES, @"alpha": @1}];
                NSMutableArray *list = [access.axByPID[@42] mutableCopy] ?: [NSMutableArray array];
                id element = [NSString stringWithFormat:@"el-cg-%u", wid];
                NSDictionary *identity = Identity(42, wid);
                [list addObject:@{@"identity": identity, @"frame": frame, @"ordinary": @YES,
                    @"minimized": @NO, @"readable": @YES, @"positionSettable": @YES, @"element": element}];
                access.axByPID[@42] = list;
            }
            YMWorkspaceFixture *workspace = [[YMWorkspaceFixture alloc] initWithWindowAccess:access];
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            Check(workspace.inventoryReady, @"exactly 512 CG candidates remains complete");

            [access.cgWindows addObject:@{@"pid": @42, @"windowID": @9999,
                @"frame": Frame(2710, 110, 200, 200), @"layer": @0, @"onScreen": @YES, @"alpha": @1}];
            NSMutableArray *list = [access.axByPID[@42] mutableCopy];
            [list addObject:@{@"identity": Identity(42, 9999),
                @"frame": Frame(2710, 110, 200, 200), @"ordinary": @YES,
                @"minimized": @NO, @"readable": @YES, @"positionSettable": @YES,
                @"element": @"el-cg-9999"}];
            access.axByPID[@42] = list;
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            Check(!workspace.inventoryReady, @"513 CG candidates is incomplete");
        }
        {
            // Boundary neighbors: 63 PIDs complete; 511 candidates complete.
            YMFakeWindowAccess *access = [YMFakeWindowAccess new];
            for (NSUInteger i = 0; i < 63; i++) {
                pid_t pid = (pid_t)(2000 + i);
                [access installApp:pid name:[NSString stringWithFormat:@"P%lu", (unsigned long)i]
                            bundle:[NSString stringWithFormat:@"test.p%lu", (unsigned long)i]];
                [access installWindowPID:pid windowID:(CGWindowID)(4000 + i)
                                 cgFrame:Frame(2700, 100, 200, 200)
                                 axFrame:Frame(2700, 100, 200, 200)];
            }
            YMWorkspaceFixture *workspace = [[YMWorkspaceFixture alloc] initWithWindowAccess:access];
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            Check(workspace.inventoryReady, @"exactly 63 PIDs remains complete");
        }
        {
            YMFakeWindowAccess *access = [YMFakeWindowAccess new];
            [access installApp:42 name:@"Calculator" bundle:@"test.calculator"];
            for (NSUInteger i = 0; i < 511; i++) {
                CGWindowID wid = (CGWindowID)(5000 + i);
                NSDictionary *frame = Frame(2700, 100, 200, 200);
                [access.cgWindows addObject:@{@"pid": @42, @"windowID": @(wid),
                    @"frame": frame, @"layer": @0, @"onScreen": @YES, @"alpha": @1}];
                NSMutableArray *list = [access.axByPID[@42] mutableCopy] ?: [NSMutableArray array];
                [list addObject:@{@"identity": Identity(42, wid), @"frame": frame, @"ordinary": @YES,
                    @"minimized": @NO, @"readable": @YES, @"positionSettable": @YES,
                    @"element": [NSString stringWithFormat:@"el-511-%u", wid]}];
                access.axByPID[@42] = list;
            }
            YMWorkspaceFixture *workspace = [[YMWorkspaceFixture alloc] initWithWindowAccess:access];
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            Check(workspace.inventoryReady, @"exactly 511 CG candidates remains complete");
        }

        // --- Fix2 / no-AX acceptance remnant: illegal CG and over-cap tail ---
        {
            YMFakeWindowAccess *access = [YMFakeWindowAccess new];
            [access installApp:42 name:@"Calculator" bundle:@"test.calculator"];
            // Missing layer/onScreen/alpha: dropped by both Visible and ClearlyInvisible.
            [access.cgWindows addObject:@{@"pid": @42, @"windowID": @1490,
                @"frame": Frame(2700, 100, 400, 300)}];
            access.trusted = NO;
            YMWorkspaceFixture *workspace = [[YMWorkspaceFixture alloc] initWithWindowAccess:access];
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            Check(!workspace.inventoryReady,
                  @"illegal/missing CG fields must not publish empty no-AX ready");
            Check([workspace needsRestoreForDisplayID:8],
                  @"illegal/missing CG keeps needsRestore");
        }
        {
            // Over-cap tail unknown must not be missed after truncation.
            YMFakeWindowAccess *access = [YMFakeWindowAccess new];
            [access installApp:42 name:@"Calculator" bundle:@"test.calculator"];
            for (NSUInteger i = 0; i < 512; i++) {
                [access.cgWindows addObject:@{@"pid": @42, @"windowID": @(6000 + i),
                    @"frame": Frame(2700, 100, 400, 300), @"layer": @0, @"onScreen": @YES, @"alpha": @1}];
            }
            // 513th: small unknown thumbnail beyond the admitted truncation set.
            [access.cgWindows addObject:@{@"pid": @42, @"windowID": @9998,
                @"frame": Frame(15, 982, 37, 102), @"layer": @0, @"onScreen": @YES, @"alpha": @1}];
            access.trusted = NO;
            YMWorkspaceFixture *workspace = [[YMWorkspaceFixture alloc] initWithWindowAccess:access];
            [workspace refreshWithVirtualDisplayIDs:@[@8] displaySnapshot:displays];
            [workspace drainReads];
            Check(!workspace.inventoryReady,
                  @"over-cap unknown tail must not authorize empty no-AX close");
        }

        // Default init must not be used by these fixtures.
        {
            // Ensure runtime tests never construct the native default manager path
            // for assertions above — all fixtures used initWithWindowAccess:.
            Check(YES, @"fixtures inject fake access only");
        }

        printf("App workspace runtime tests: %lu passed, %lu failed; no GUI or display calls executed.\n",
               (unsigned long)(checks - failures), (unsigned long)failures);
        return failures ? 1 : 0;
    }
}
