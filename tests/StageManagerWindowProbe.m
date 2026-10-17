#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dlfcn.h>
#import <errno.h>
#import <math.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>
#import "AppWorkspacePolicy.h"
#import "UpdateWorkspaceRecovery.h"

typedef struct {
    NSUInteger writes, restoreAttempts;
    BOOL passed, destinationVerified, originRestored, displayTopologyUnchanged;
} ProbeResult;

@protocol ProbeBackend <NSObject>
- (NSDictionary *)identity;
- (NSDictionary *)frame;
- (NSArray<NSDictionary *> *)visibleWindowRecords;
- (NSArray<NSDictionary *> *)displaySnapshot;
- (CGDirectDisplayID)targetDisplayID;
- (BOOL)writePosition:(CGPoint)position expectedIdentity:(NSDictionary *)identity;
- (void)waitForNextObservation;
@end

static ProbeResult RunProbeWithMode(NSString *mode, id<ProbeBackend> backend);

static NSUInteger gChecks = 0;
static void Check(BOOL value, NSString *name) {
    gChecks++;
    if (!value) {
        fprintf(stderr, "FAIL %s\n", name.UTF8String);
        exit(1);
    }
}

static NSDictionary *ProbeFrame(double x, double y, double w, double h) {
    return @{@"x": @(x), @"y": @(y), @"width": @(w), @"height": @(h)};
}

static NSDictionary *ProbeIdentity(pid_t pid, CGWindowID windowID, NSString *bundleID) {
    return @{@"pid": @(pid), @"windowID": @(windowID), @"startSeconds": @(1700000000),
             @"startMicroseconds": @(123456), @"bundleID": bundleID};
}

static NSDictionary *ProbeDisplay(CGDirectDisplayID displayID, BOOL isVirtual, double x, double y,
                                  double w, double h) {
    return @{@"displayID": @(displayID), @"displayUUID": [NSString stringWithFormat:@"uuid-%u", displayID],
             @"isMain": @(displayID == 1), @"isActive": @YES, @"isOnline": @YES,
             @"isVirtual": @(isVirtual), @"mirrorOf": @0, @"inMirrorSet": @NO,
             @"bounds": ProbeFrame(x, y, w, h),
             @"visibleBounds": ProbeFrame(x, y + 32, w, h - 32)};
}

static BOOL ProbeDisplaysEqual(NSArray<NSDictionary *> *a, NSArray<NSDictionary *> *b) {
    if (a.count != b.count) return NO;
    for (NSUInteger i = 0; i < a.count; i++) {
        NSDictionary *left = a[i], *right = b[i];
        if (![left[@"displayID"] isEqual:right[@"displayID"]] ||
            ![left[@"isVirtual"] isEqual:right[@"isVirtual"]] ||
            ![left[@"isActive"] isEqual:right[@"isActive"]] ||
            ![left[@"isOnline"] isEqual:right[@"isOnline"]] ||
            ![left[@"mirrorOf"] isEqual:right[@"mirrorOf"]] ||
            ![left[@"inMirrorSet"] isEqual:right[@"inMirrorSet"]] ||
            !YMWorkspaceSameFrame(left[@"bounds"], right[@"bounds"])) return NO;
    }
    return YES;
}

static NSDictionary *ProbeFindDisplay(NSArray<NSDictionary *> *displays, CGDirectDisplayID displayID) {
    for (NSDictionary *display in displays) {
        if ([display[@"displayID"] unsignedIntValue] == displayID) return display;
    }
    return nil;
}

static BOOL ProbeTargetDisplayUsable(NSDictionary *display, CGDirectDisplayID sourceID) {
    if (!YMWorkspaceUsableDisplay(display)) return NO;
    if ([display[@"displayID"] unsignedIntValue] == sourceID) return NO;
    if ([display[@"mirrorOf"] respondsToSelector:@selector(unsignedIntValue)] &&
        [display[@"mirrorOf"] unsignedIntValue] != 0) return NO;
    if ([display[@"inMirrorSet"] boolValue]) return NO;
    if (![display[@"isVirtual"] boolValue]) return NO;
    return YES;
}

static NSArray<NSDictionary *> *ProbeMatchingRecords(NSArray<NSDictionary *> *records, NSDictionary *identity) {
    NSMutableArray *matches = [NSMutableArray array];
    pid_t pid = [identity[@"pid"] intValue];
    CGWindowID windowID = [identity[@"windowID"] unsignedIntValue];
    for (NSDictionary *record in records) {
        if ([record[@"pid"] intValue] == pid && [record[@"windowID"] unsignedIntValue] == windowID)
            [matches addObject:record];
    }
    return matches;
}

static BOOL ProbeFrameOnTarget(NSDictionary *frame, NSDictionary *target) {
    if (!YMWorkspaceGeometry(frame) || !YMWorkspaceUsableDisplay(target)) return NO;
    NSDictionary *owner = YMWorkspaceDisplayForFrame(frame, @[target]);
    return owner && [owner[@"displayID"] isEqual:target[@"displayID"]] && YMWorkspaceFrameFits(frame, target);
}

static BOOL ProbeObserve(id<ProbeBackend> backend, BOOL (^predicate)(void)) {
    for (NSUInteger i = 0; i < 20; i++) {
        if (predicate()) return YES;
        [backend waitForNextObservation];
    }
    return predicate();
}

typedef NS_ENUM(NSInteger, ProbeFixtureKind) {
    ProbeFixtureNormal = 0,
    ProbeFixtureChangedIdentity,
    ProbeFixtureFailedDestination,
    ProbeFixtureFailedRestore,
    ProbeFixtureWrongApp,
    ProbeFixtureDuplicateCG,
    ProbeFixtureTargetMissing,
    ProbeFixtureTargetEqualsSource,
};

@interface ProbeFixture : NSObject <ProbeBackend>
@property(nonatomic) ProbeFixtureKind kind;
@property(nonatomic) NSUInteger identityReads;
@property(nonatomic) NSUInteger writeCalls;
@property(nonatomic, copy) NSDictionary *stableIdentity;
@property(nonatomic, copy) NSDictionary *currentFrame;
@property(nonatomic, copy) NSDictionary *originFrame;
@property(nonatomic, copy) NSArray<NSDictionary *> *displays;
@property(nonatomic, copy) NSArray<NSDictionary *> *records;
@property(nonatomic) CGDirectDisplayID targetID;
@property(nonatomic) BOOL changeIdentityBeforeWrite;
@property(nonatomic) BOOL keepOffTargetAfterWrite;
@property(nonatomic) BOOL keepOffOriginAfterRestore;
@end

@implementation ProbeFixture
+ (instancetype)fixture:(ProbeFixtureKind)kind {
    ProbeFixture *f = [ProbeFixture new];
    f.kind = kind;
    f.originFrame = ProbeFrame(100, 100, 230, 408);
    f.currentFrame = f.originFrame;
    f.stableIdentity = ProbeIdentity(4242, 100, @"com.apple.calculator");
    f.displays = @[ProbeDisplay(1, NO, 0, 0, 1280, 800), ProbeDisplay(99, YES, 1280, 0, 1920, 1080)];
    f.targetID = 99;
    f.records = @[@{@"pid": @4242, @"windowID": @100, @"frame": ProbeFrame(15, 500, 37, 102),
                    @"layer": @0, @"onscreen": @YES, @"alpha": @1.0}];
    switch (kind) {
        case ProbeFixtureChangedIdentity:
            f.changeIdentityBeforeWrite = YES;
            break;
        case ProbeFixtureFailedDestination:
            f.keepOffTargetAfterWrite = YES;
            break;
        case ProbeFixtureFailedRestore:
            f.keepOffOriginAfterRestore = YES;
            break;
        case ProbeFixtureWrongApp:
            f.stableIdentity = ProbeIdentity(4242, 100, @"com.apple.TextEdit");
            break;
        case ProbeFixtureDuplicateCG:
            f.records = @[
                @{@"pid": @4242, @"windowID": @100, @"frame": ProbeFrame(15, 500, 37, 102),
                  @"layer": @0, @"onscreen": @YES, @"alpha": @1.0},
                @{@"pid": @4242, @"windowID": @100, @"frame": ProbeFrame(20, 520, 40, 90),
                  @"layer": @0, @"onscreen": @YES, @"alpha": @1.0}
            ];
            break;
        case ProbeFixtureTargetMissing:
            f.displays = @[ProbeDisplay(1, NO, 0, 0, 1280, 800)];
            break;
        case ProbeFixtureTargetEqualsSource:
            f.targetID = 1;
            break;
        case ProbeFixtureNormal:
            break;
    }
    return f;
}
- (NSDictionary *)identity {
    self.identityReads++;
    if (self.changeIdentityBeforeWrite && self.identityReads > 1)
        return ProbeIdentity(4242, 100, @"com.apple.calculator.changed");
    return self.stableIdentity;
}
- (NSDictionary *)frame { return self.currentFrame; }
- (NSArray<NSDictionary *> *)visibleWindowRecords { return self.records; }
- (NSArray<NSDictionary *> *)displaySnapshot { return self.displays; }
- (CGDirectDisplayID)targetDisplayID { return self.targetID; }
- (void)waitForNextObservation {}
- (BOOL)writePosition:(CGPoint)position expectedIdentity:(NSDictionary *)identity {
    self.writeCalls++;
    if (![self.stableIdentity isEqual:identity]) return NO;
    if (self.changeIdentityBeforeWrite) return NO;
    NSDictionary *size = self.currentFrame;
    NSDictionary *next = ProbeFrame(position.x, position.y,
                                    [size[@"width"] doubleValue], [size[@"height"] doubleValue]);
    BOOL restoring = fabs(position.x - [self.originFrame[@"x"] doubleValue]) < 1 &&
        fabs(position.y - [self.originFrame[@"y"] doubleValue]) < 1;
    if (!restoring && self.keepOffTargetAfterWrite) {
        self.currentFrame = ProbeFrame(50, 50, 230, 408);
        return YES;
    }
    if (restoring && self.keepOffOriginAfterRestore) {
        self.currentFrame = ProbeFrame(1400, 100, 230, 408);
        return YES;
    }
    self.currentFrame = next;
    return YES;
}
@end

static ProbeResult RunProbeWithMode(NSString *mode, id<ProbeBackend> backend) {
    ProbeResult result = {0};
    BOOL checkOnly = [mode isEqualToString:@"--check"];
    BOOL mutate = [mode isEqualToString:@"--move-and-return"];
    if (!checkOnly && !mutate) return result;

    NSDictionary *identity = [backend identity];
    NSDictionary *originalFrame = YMWorkspaceGeometry([backend frame]);
    NSArray<NSDictionary *> *displays = [backend displaySnapshot] ?: @[];
    CGDirectDisplayID targetID = [backend targetDisplayID];
    if (![identity isKindOfClass:NSDictionary.class] || !originalFrame) return result;
    if (![identity[@"bundleID"] isEqualToString:@"com.apple.calculator"]) return result;
    if (![[identity[@"pid"] description] length] || [identity[@"pid"] intValue] <= 0) return result;
    if ([identity[@"windowID"] unsignedIntValue] == 0) return result;

    NSArray *matches = ProbeMatchingRecords([backend visibleWindowRecords], identity);
    if (matches.count != 1) return result;

    NSDictionary *sourceDisplay = YMWorkspaceDisplayForFrame(originalFrame, displays);
    if (!sourceDisplay) return result;
    CGDirectDisplayID sourceID = [sourceDisplay[@"displayID"] unsignedIntValue];
    NSDictionary *targetDisplay = ProbeFindDisplay(displays, targetID);
    if (!ProbeTargetDisplayUsable(targetDisplay, sourceID)) return result;

    result.displayTopologyUnchanged = YES;
    if (checkOnly) {
        result.passed = YES;
        return result;
    }

    NSDictionary *destination = YMWorkspaceFrameOnDisplay(originalFrame, nil, targetDisplay);
    if (!destination) return result;

    NSDictionary *liveIdentity = [backend identity];
    NSArray<NSDictionary *> *liveDisplays = [backend displaySnapshot] ?: @[];
    if (![liveIdentity isEqual:identity] || !ProbeDisplaysEqual(displays, liveDisplays) ||
        !ProbeFindDisplay(liveDisplays, targetID) || !ProbeFindDisplay(liveDisplays, sourceID)) {
        result.displayTopologyUnchanged = ProbeDisplaysEqual(displays, liveDisplays);
        return result;
    }

    CGPoint destinationPoint = CGPointMake([destination[@"x"] doubleValue], [destination[@"y"] doubleValue]);
    if (![backend writePosition:destinationPoint expectedIdentity:identity]) return result;
    result.writes++;

    result.destinationVerified = ProbeObserve(backend, ^{
        NSDictionary *frame = YMWorkspaceGeometry([backend frame]);
        NSDictionary *target = ProbeFindDisplay([backend displaySnapshot], targetID);
        return ProbeFrameOnTarget(frame, target);
    });

    result.restoreAttempts = 1;
    liveIdentity = [backend identity];
    liveDisplays = [backend displaySnapshot] ?: @[];
    result.displayTopologyUnchanged = ProbeDisplaysEqual(displays, liveDisplays);
    if (![liveIdentity isEqual:identity] || !result.displayTopologyUnchanged ||
        !ProbeFindDisplay(liveDisplays, sourceID)) {
        return result;
    }

    CGPoint originPoint = CGPointMake([originalFrame[@"x"] doubleValue], [originalFrame[@"y"] doubleValue]);
    if ([backend writePosition:originPoint expectedIdentity:identity]) result.writes++;
    else return result;

    result.originRestored = ProbeObserve(backend, ^{
        return YMWorkspaceSameFrame(YMWorkspaceGeometry([backend frame]), originalFrame);
    });
    liveIdentity = [backend identity];
    liveDisplays = [backend displaySnapshot] ?: @[];
    result.displayTopologyUnchanged = result.displayTopologyUnchanged && ProbeDisplaysEqual(displays, liveDisplays) &&
        [liveIdentity isEqual:identity];
    result.passed = result.destinationVerified && result.originRestored && result.displayTopologyUnchanged;
    return result;
}

#pragma mark - Native backend

static BOOL ProbeDisplayIsVirtual(CGDirectDisplayID displayID) {
    typedef bool (*VirtualDisplayFunction)(CGDirectDisplayID);
    static VirtualDisplayFunction function = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        function = (VirtualDisplayFunction)dlsym(RTLD_DEFAULT, "CGDisplayIsVirtual");
    });
    if (function) return function(displayID);
    return CGDisplayModelNumber(displayID) == 0x76697274 ||
           (CGDisplayVendorNumber(displayID) == 505 && CGDisplayModelNumber(displayID) == 0x5644);
}

static NSArray<NSDictionary *> *ProbeNativeDisplaySnapshot(void) {
    CGDirectDisplayID ids[64] = {0};
    uint32_t count = 0;
    if (CGGetOnlineDisplayList(64, ids, &count) != kCGErrorSuccess || !count) return @[];
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:count];
    for (uint32_t i = 0; i < count; i++) {
        CGDirectDisplayID displayID = ids[i];
        CFUUIDRef uuidRef = CGDisplayCreateUUIDFromDisplayID(displayID);
        NSString *uuid = uuidRef ? CFBridgingRelease(CFUUIDCreateString(NULL, uuidRef)) : @"";
        if (uuidRef) CFRelease(uuidRef);
        CGRect rect = CGDisplayBounds(displayID);
        NSDictionary *bounds = YMWorkspaceGeometry(@{@"x": @(rect.origin.x), @"y": @(rect.origin.y),
                                                     @"width": @(rect.size.width), @"height": @(rect.size.height)});
        if (!bounds) continue;
        [result addObject:@{@"displayID": @(displayID), @"displayUUID": uuid ?: @"",
                            @"isMain": @(CGDisplayIsMain(displayID)),
                            @"isActive": @(CGDisplayIsActive(displayID)),
                            @"isOnline": @(CGDisplayIsOnline(displayID)),
                            @"isVirtual": @(ProbeDisplayIsVirtual(displayID)),
                            @"mirrorOf": @(CGDisplayMirrorsDisplay(displayID)),
                            @"inMirrorSet": @(CGDisplayIsInMirrorSet(displayID)),
                            @"bounds": bounds}];
    }
    return result;
}

static NSDictionary *ProbeNativeAXFrame(id element) {
    CFTypeRef rawPosition = NULL, rawSize = NULL;
    AXUIElementRef ref = (__bridge AXUIElementRef)element;
    if (AXUIElementCopyAttributeValue(ref, kAXPositionAttribute, &rawPosition) != kAXErrorSuccess ||
        AXUIElementCopyAttributeValue(ref, kAXSizeAttribute, &rawSize) != kAXErrorSuccess ||
        !rawPosition || !rawSize ||
        CFGetTypeID(rawPosition) != AXValueGetTypeID() || CFGetTypeID(rawSize) != AXValueGetTypeID()) {
        if (rawPosition) CFRelease(rawPosition);
        if (rawSize) CFRelease(rawSize);
        return nil;
    }
    CGPoint point = CGPointZero;
    CGSize size = CGSizeZero;
    BOOL ok = AXValueGetValue((AXValueRef)rawPosition, kAXValueCGPointType, &point) &&
              AXValueGetValue((AXValueRef)rawSize, kAXValueCGSizeType, &size);
    CFRelease(rawPosition);
    CFRelease(rawSize);
    if (!ok) return nil;
    return YMWorkspaceGeometry(@{@"x": @(point.x), @"y": @(point.y), @"width": @(size.width), @"height": @(size.height)});
}

static NSArray<NSDictionary *> *ProbeNativeVisibleWindowRecords(pid_t pid) {
    CFArrayRef rawList = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
                                                    kCGNullWindowID);
    if (!rawList) return @[];
    NSArray *raw = CFBridgingRelease(rawList);
    NSMutableArray *records = [NSMutableArray array];
    for (NSDictionary *entry in raw) {
        NSNumber *owner = entry[(__bridge NSString *)kCGWindowOwnerPID];
        NSNumber *windowID = entry[(__bridge NSString *)kCGWindowNumber];
        if (![owner isKindOfClass:NSNumber.class] || owner.intValue != pid) continue;
        if (![windowID isKindOfClass:NSNumber.class] || windowID.unsignedIntValue == 0) continue;
        CGRect rect = CGRectZero;
        id bounds = entry[(__bridge NSString *)kCGWindowBounds];
        if (![bounds isKindOfClass:NSDictionary.class] ||
            !CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)bounds, &rect)) continue;
        NSDictionary *frame = YMWorkspaceGeometry(@{@"x": @(rect.origin.x), @"y": @(rect.origin.y),
                                                    @"width": @(rect.size.width), @"height": @(rect.size.height)});
        if (!frame) continue;
        [records addObject:@{@"pid": owner, @"windowID": windowID, @"frame": frame,
                             @"layer": entry[(__bridge NSString *)kCGWindowLayer] ?: @0,
                             @"onscreen": entry[(__bridge NSString *)kCGWindowIsOnscreen] ?: @NO,
                             @"alpha": entry[(__bridge NSString *)kCGWindowAlpha] ?: @0}];
    }
    return records;
}

@interface ProbeNativeBackend : NSObject <ProbeBackend>
@property(nonatomic, copy) NSDictionary *expectedIdentity;
@property(nonatomic) CGDirectDisplayID targetID;
@property(nonatomic, strong) id element;
@end

@implementation ProbeNativeBackend
- (NSDictionary *)identity {
    return self.element ? YMUpdateIdentityForWindowElement(self.element) : nil;
}
- (NSDictionary *)frame {
    return self.element ? ProbeNativeAXFrame(self.element) : nil;
}
- (NSArray<NSDictionary *> *)visibleWindowRecords {
    return ProbeNativeVisibleWindowRecords([self.expectedIdentity[@"pid"] intValue]);
}
- (NSArray<NSDictionary *> *)displaySnapshot {
    return ProbeNativeDisplaySnapshot();
}
- (CGDirectDisplayID)targetDisplayID {
    return self.targetID;
}
- (void)waitForNextObservation {
    usleep(100000);
}
- (BOOL)writePosition:(CGPoint)position expectedIdentity:(NSDictionary *)identity {
    if (!self.element) return NO;
    NSDictionary *live = YMUpdateIdentityForWindowElement(self.element);
    if (![live isEqual:identity]) return NO;
    Boolean settable = false;
    AXUIElementRef ref = (__bridge AXUIElementRef)self.element;
    if (AXUIElementIsAttributeSettable(ref, kAXPositionAttribute, &settable) != kAXErrorSuccess || !settable)
        return NO;
    AXValueRef value = AXValueCreate(kAXValueCGPointType, &position);
    if (!value) return NO;
    AXError error = AXUIElementSetAttributeValue(ref, kAXPositionAttribute, value);
    CFRelease(value);
    return error == kAXErrorSuccess;
}
@end

static NSDictionary *ProbeReceipt(ProbeResult result, NSDictionary *identity, NSDictionary *originalFrame,
                                  CGDirectDisplayID targetID, NSString *failureReason) {
    return @{
        @"identity": identity ?: @{},
        @"originalFrame": originalFrame ?: @{},
        @"targetDisplayID": @(targetID),
        @"destinationVerified": @(result.destinationVerified),
        @"originRestored": @(result.originRestored),
        @"displayTopologyUnchanged": @(result.displayTopologyUnchanged),
        @"activationRequested": @NO,
        @"failureReason": failureReason ?: @"",
        @"writes": @(result.writes),
        @"restoreAttempts": @(result.restoreAttempts),
        @"passed": @(result.passed)
    };
}

static BOOL ProbeWriteReceipt(NSDictionary *receipt, NSString *path, NSString **errorText) {
    if (!path.length) {
        if (errorText) *errorText = @"missing receipt path";
        return NO;
    }
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:receipt options:NSJSONWritingPrettyPrinted error:&error];
    if (!data) {
        if (errorText) *errorText = error.localizedDescription ?: @"receipt encode failed";
        return NO;
    }
    if (![data writeToFile:path options:NSDataWritingAtomic error:&error]) {
        if (errorText) *errorText = error.localizedDescription ?: @"receipt write failed";
        return NO;
    }
    return YES;
}

static int ProbeRunNative(NSString *mode, pid_t pid, CGWindowID windowID, CGDirectDisplayID targetID,
                          NSString *receiptPath) {
    if (pid <= 0 || windowID == 0 || targetID == 0) {
        fprintf(stderr, "pid, window-id and target-display-id must be positive integers\n");
        return 2;
    }
    if (!AXIsProcessTrusted()) {
        fprintf(stderr, "Accessibility permission unavailable\n");
        return 3;
    }
    NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    if (!app || app.terminated || ![app.bundleIdentifier isEqualToString:@"com.apple.calculator"]) {
        fprintf(stderr, "target process is not a live Calculator instance\n");
        return 4;
    }
    // Resolve requires the full identity; seed with process fields via a temporary AX walk.
    AXUIElementRef appElement = AXUIElementCreateApplication(pid);
    if (!appElement) {
        fprintf(stderr, "cannot create application AX element\n");
        return 5;
    }
    CFTypeRef windowsValue = NULL;
    AXError windowsError = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute, &windowsValue);
    CFRelease(appElement);
    if (windowsError != kAXErrorSuccess || !windowsValue || CFGetTypeID(windowsValue) != CFArrayGetTypeID()) {
        if (windowsValue) CFRelease(windowsValue);
        fprintf(stderr, "cannot enumerate Calculator windows\n");
        return 5;
    }
    NSArray *windows = CFBridgingRelease(windowsValue);
    id match = nil;
    NSDictionary *identity = nil;
    for (id window in windows) {
        NSDictionary *candidate = YMUpdateIdentityForWindowElement(window);
        if (!candidate) continue;
        if ([candidate[@"windowID"] unsignedIntValue] != windowID) continue;
        if (match) {
            fprintf(stderr, "window identity is ambiguous\n");
            return 6;
        }
        match = window;
        identity = candidate;
    }
    if (!match || !identity || [identity[@"pid"] intValue] != pid ||
        ![identity[@"bundleID"] isEqualToString:@"com.apple.calculator"]) {
        fprintf(stderr, "exact Calculator window identity unavailable\n");
        return 6;
    }
    NSError *exactError = nil;
    id resolved = YMUpdateResolveWindowIdentity(identity, &exactError);
    if (!resolved) {
        fprintf(stderr, "resolve failed: %s\n", exactError.localizedDescription.UTF8String ?: "unknown");
        return 6;
    }

    ProbeNativeBackend *backend = [ProbeNativeBackend new];
    backend.expectedIdentity = identity;
    backend.targetID = targetID;
    backend.element = resolved;

    NSDictionary *originalFrame = [backend frame];
    NSArray *displays = [backend displaySnapshot];
    pid_t frontPID = NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
    fprintf(stderr, "DISCOVERY frontPID=%d axTrusted=1 calculatorPID=%d windowID=%u targetDisplayID=%u displays=%lu\n",
            frontPID, pid, windowID, targetID, (unsigned long)displays.count);
    for (NSDictionary *display in displays) {
        NSDictionary *b = display[@"bounds"];
        fprintf(stderr, "DISPLAY id=%u virtual=%d main=%d active=%d online=%d mirror=%u x=%.1f y=%.1f w=%.1f h=%.1f\n",
                [display[@"displayID"] unsignedIntValue], [display[@"isVirtual"] boolValue] ? 1 : 0,
                [display[@"isMain"] boolValue] ? 1 : 0, [display[@"isActive"] boolValue] ? 1 : 0,
                [display[@"isOnline"] boolValue] ? 1 : 0, [display[@"mirrorOf"] unsignedIntValue],
                [b[@"x"] doubleValue], [b[@"y"] doubleValue], [b[@"width"] doubleValue], [b[@"height"] doubleValue]);
    }
    if (originalFrame) {
        fprintf(stderr, "AX_FRAME x=%.1f y=%.1f w=%.1f h=%.1f\n",
                [originalFrame[@"x"] doubleValue], [originalFrame[@"y"] doubleValue],
                [originalFrame[@"width"] doubleValue], [originalFrame[@"height"] doubleValue]);
    }
    NSArray *cgMatches = ProbeMatchingRecords([backend visibleWindowRecords], identity);
    fprintf(stderr, "CG_MATCHES count=%lu\n", (unsigned long)cgMatches.count);
    for (NSDictionary *record in cgMatches) {
        NSDictionary *f = record[@"frame"];
        fprintf(stderr, "CG_FRAME id=%u x=%.1f y=%.1f w=%.1f h=%.1f layer=%ld onscreen=%d\n",
                [record[@"windowID"] unsignedIntValue], [f[@"x"] doubleValue], [f[@"y"] doubleValue],
                [f[@"width"] doubleValue], [f[@"height"] doubleValue],
                (long)[record[@"layer"] integerValue], [record[@"onscreen"] boolValue] ? 1 : 0);
    }
    fprintf(stderr, "IDENTITY pid=%d windowID=%u start=%llu.%06u bundleID=%s\n",
            [identity[@"pid"] intValue], [identity[@"windowID"] unsignedIntValue],
            [identity[@"startSeconds"] unsignedLongLongValue],
            [identity[@"startMicroseconds"] unsignedIntValue],
            [identity[@"bundleID"] UTF8String]);

    ProbeResult result = RunProbeWithMode(mode, backend);
    NSString *failure = @"";
    if ([mode isEqualToString:@"--check"]) {
        if (!result.passed) failure = @"check-failed";
    } else if (!result.passed) {
        if (!result.destinationVerified) failure = @"destination-unverified";
        else if (!result.originRestored) failure = @"origin-unrestored";
        else if (!result.displayTopologyUnchanged) failure = @"topology-changed";
        else failure = @"probe-failed";
    }
    NSString *receiptError = nil;
    NSDictionary *receipt = ProbeReceipt(result, identity, originalFrame, targetID, failure);
    if (!ProbeWriteReceipt(receipt, receiptPath, &receiptError)) {
        fprintf(stderr, "receipt error: %s\n", receiptError.UTF8String ?: "unknown");
        return 7;
    }
    fprintf(stderr, "RECEIPT writes=%lu restoreAttempts=%lu passed=%d destinationVerified=%d originRestored=%d topology=%d activationRequested=0\n",
            (unsigned long)result.writes, (unsigned long)result.restoreAttempts, result.passed ? 1 : 0,
            result.destinationVerified ? 1 : 0, result.originRestored ? 1 : 0,
            result.displayTopologyUnchanged ? 1 : 0);
    if ([mode isEqualToString:@"--check"]) return result.passed && result.writes == 0 ? 0 : 1;
    return result.passed ? 0 : 1;
}

static void RunSelfTests(void) {
    ProbeFixture *normal = [ProbeFixture fixture:ProbeFixtureNormal];
    Check(RunProbeWithMode(@"--check", normal).writes == 0,
          @"read-only mode never writes a window");

    ProbeFixture *changedIdentity = [ProbeFixture fixture:ProbeFixtureChangedIdentity];
    Check(RunProbeWithMode(@"--move-and-return", changedIdentity).writes == 0,
          @"identity changed before mutation refuses the probe");

    ProbeFixture *failedDestination = [ProbeFixture fixture:ProbeFixtureFailedDestination];
    Check(RunProbeWithMode(@"--move-and-return", failedDestination).restoreAttempts == 1,
          @"failed destination still makes one guarded origin restore attempt");

    ProbeFixture *failedRestore = [ProbeFixture fixture:ProbeFixtureFailedRestore];
    Check(!RunProbeWithMode(@"--move-and-return", failedRestore).passed,
          @"unverified origin restore cannot pass");

    ProbeFixture *wrongApp = [ProbeFixture fixture:ProbeFixtureWrongApp];
    Check(RunProbeWithMode(@"--move-and-return", wrongApp).writes == 0,
          @"non-calculator bundle refuses writes");

    ProbeFixture *duplicateCG = [ProbeFixture fixture:ProbeFixtureDuplicateCG];
    Check(RunProbeWithMode(@"--move-and-return", duplicateCG).writes == 0,
          @"duplicate CG identity refuses writes");

    ProbeFixture *missingTarget = [ProbeFixture fixture:ProbeFixtureTargetMissing];
    Check(RunProbeWithMode(@"--move-and-return", missingTarget).writes == 0,
          @"missing target display refuses writes");

    ProbeFixture *sameDisplay = [ProbeFixture fixture:ProbeFixtureTargetEqualsSource];
    Check(RunProbeWithMode(@"--move-and-return", sameDisplay).writes == 0,
          @"target equal to source refuses writes");

    ProbeResult success = RunProbeWithMode(@"--move-and-return", [ProbeFixture fixture:ProbeFixtureNormal]);
    Check(success.passed && success.destinationVerified && success.originRestored &&
              success.displayTopologyUnchanged && success.writes >= 2 && success.restoreAttempts == 1,
          @"normal move-and-return verifies destination and origin");

    fprintf(stderr, "PASS %u self-test checks\n", (unsigned)gChecks);
}

static void PrintUsage(void) {
    fprintf(stderr,
            "Usage:\n"
            "  probe-stage-manager.sh --self-test\n"
            "  probe-stage-manager.sh --check --pid N --window-id N --target-display-id N --receipt PATH\n"
            "  probe-stage-manager.sh --move-and-return --pid N --window-id N --target-display-id N --receipt PATH\n"
            "Default (no mode) refuses to run and never moves a window.\n");
}

static BOOL ProbeParseUInt(const char *text, unsigned long long *outValue) {
    if (!text || !*text) return NO;
    char *end = NULL;
    errno = 0;
    unsigned long long value = strtoull(text, &end, 10);
    if (errno || !end || *end || value == 0) return NO;
    *outValue = value;
    return YES;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            PrintUsage();
            return 2;
        }
        NSString *mode = [NSString stringWithUTF8String:argv[1]];
        if ([mode isEqualToString:@"--self-test"]) {
            RunSelfTests();
            return 0;
        }
        if (![mode isEqualToString:@"--check"] && ![mode isEqualToString:@"--move-and-return"]) {
            PrintUsage();
            return 2;
        }
        pid_t pid = 0;
        CGWindowID windowID = 0;
        CGDirectDisplayID targetID = 0;
        NSString *receiptPath = nil;
        for (int i = 2; i < argc; i++) {
            NSString *arg = [NSString stringWithUTF8String:argv[i]];
            if ([arg isEqualToString:@"--pid"] && i + 1 < argc) {
                unsigned long long value = 0;
                if (!ProbeParseUInt(argv[++i], &value) || value > (unsigned long long)INT_MAX) {
                    fprintf(stderr, "invalid --pid\n");
                    return 2;
                }
                pid = (pid_t)value;
            } else if ([arg isEqualToString:@"--window-id"] && i + 1 < argc) {
                unsigned long long value = 0;
                if (!ProbeParseUInt(argv[++i], &value) || value > UINT32_MAX) {
                    fprintf(stderr, "invalid --window-id\n");
                    return 2;
                }
                windowID = (CGWindowID)value;
            } else if ([arg isEqualToString:@"--target-display-id"] && i + 1 < argc) {
                unsigned long long value = 0;
                if (!ProbeParseUInt(argv[++i], &value) || value > UINT32_MAX) {
                    fprintf(stderr, "invalid --target-display-id\n");
                    return 2;
                }
                targetID = (CGDirectDisplayID)value;
            } else if ([arg isEqualToString:@"--receipt"] && i + 1 < argc) {
                receiptPath = [NSString stringWithUTF8String:argv[++i]];
            } else {
                PrintUsage();
                return 2;
            }
        }
        if (!pid || !windowID || !targetID || !receiptPath.length) {
            PrintUsage();
            return 2;
        }
        return ProbeRunNative(mode, pid, windowID, targetID, receiptPath);
    }
}
