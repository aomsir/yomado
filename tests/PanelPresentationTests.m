#import "PanelPresentation.h"
#import <ApplicationServices/ApplicationServices.h>
#import <math.h>
#import <unistd.h>

static NSUInteger scenarios;
static void Check(BOOL condition, const char *message) {
    scenarios++;
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
}

@interface YMFixtureWindow : NSObject
@property BOOL visible;
@property BOOL miniaturized;
@property BOOL hidden;
@property BOOL attachedSheet;
@end
@implementation YMFixtureWindow
@end

@interface YMFixtureEnvironment : NSObject <YMPanelPresentationEnvironment>
@property NSApplicationActivationPolicy activationPolicy;
@property NSInteger rejectedPolicy;
@property BOOL falseAfterChange;
@property BOOL trueWithoutChange;
@property NSUInteger presentations;
@property NSUInteger hides;
@property NSUInteger failures;
@property NSWindow *lastWindow;
@property NSMutableArray<NSString *> *events;
@property NSMutableArray *pending;
- (void)drain;
@end

@implementation YMFixtureEnvironment
- (instancetype)init {
    if ((self = [super init])) {
        _activationPolicy = NSApplicationActivationPolicyAccessory;
        _rejectedPolicy = -1;
        _events = [NSMutableArray array];
        _pending = [NSMutableArray array];
    }
    return self;
}
- (BOOL)requestActivationPolicy:(NSApplicationActivationPolicy)policy {
    [self.events addObject:[NSString stringWithFormat:@"policy:%ld", (long)policy]];
    if (self.rejectedPolicy == policy) return NO;
    if (self.trueWithoutChange) return YES;
    self.activationPolicy = policy;
    return !self.falseAfterChange;
}
- (void)activateApplication { [self.events addObject:@"activate"]; }
- (void)deferUntilAfterMenuTracking:(dispatch_block_t)block {
    [self.events addObject:@"schedule"];
    [self.pending addObject:[block copy]];
}
- (BOOL)hasAttachedSheetForWindow:(NSWindow *)window {
    return ((YMFixtureWindow *)(id)window).attachedSheet;
}
- (void)presentWindow:(NSWindow *)window {
    self.presentations++;
    self.lastWindow = window;
    YMFixtureWindow *fixture = (YMFixtureWindow *)(id)window;
    fixture.visible = YES;
    fixture.hidden = fixture.miniaturized = NO;
    [self.events addObject:@"present"];
}
- (void)hideWindow:(NSWindow *)window {
    self.hides++;
    ((YMFixtureWindow *)(id)window).visible = NO;
    [self.events addObject:@"hide"];
}
- (void)reportActivationPolicyFailure:(NSApplicationActivationPolicy)requested
                        actualPolicy:(NSApplicationActivationPolicy)actual {
    (void)requested; (void)actual;
    self.failures++;
    [self.events addObject:@"failure"];
}
- (void)drain {
    while (self.pending.count) {
        dispatch_block_t block = self.pending.firstObject;
        [self.pending removeObjectAtIndex:0];
        block();
    }
}
@end

// Private adapter declaration: tests override only system-call boundaries.
// The public product API does not expose this test seam.
@interface YMCocoaPanelPresentationEnvironment : NSObject <YMPanelPresentationEnvironment>
- (BOOL)requestAppKitActivationPolicy:(NSApplicationActivationPolicy)policy;
- (OSStatus)transformCurrentProcessToAccessory;
- (void)reportAccessoryTransformFailure:(OSStatus)status;
@end

@interface YMFixtureCocoaEnvironment : YMCocoaPanelPresentationEnvironment
@property BOOL appKitAccepted;
@property OSStatus transformStatus;
@property NSApplicationActivationPolicy observedPolicy;
@property NSUInteger policyReads;
@property NSUInteger transformCalls;
@property NSUInteger transformFailures;
@property NSMutableArray<NSString *> *events;
@property NSMutableArray *pending;
- (void)drain;
@end

@implementation YMFixtureCocoaEnvironment
- (instancetype)init {
    if ((self = [super init])) {
        _events = [NSMutableArray array];
        _pending = [NSMutableArray array];
        _observedPolicy = NSApplicationActivationPolicyRegular;
    }
    return self;
}
- (NSApplicationActivationPolicy)activationPolicy { self.policyReads++; return self.observedPolicy; }
- (BOOL)requestAppKitActivationPolicy:(NSApplicationActivationPolicy)policy {
    [self.events addObject:[NSString stringWithFormat:@"appkit:%ld", (long)policy]];
    if (self.appKitAccepted) self.observedPolicy = policy;
    return self.appKitAccepted;
}
- (OSStatus)transformCurrentProcessToAccessory {
    self.transformCalls++;
    [self.events addObject:@"transform"];
    if (self.transformStatus == noErr) self.observedPolicy = NSApplicationActivationPolicyAccessory;
    return self.transformStatus;
}
- (void)reportAccessoryTransformFailure:(OSStatus)status {
    self.transformFailures++;
    [self.events addObject:@"transform-failure"];
    [super reportAccessoryTransformFailure:status];
}
- (void)activateApplication {}
- (void)deferUntilAfterMenuTracking:(dispatch_block_t)block { [self.pending addObject:[block copy]]; }
- (BOOL)hasAttachedSheetForWindow:(NSWindow *)window { return ((YMFixtureWindow *)(id)window).attachedSheet; }
- (void)presentWindow:(NSWindow *)window { ((YMFixtureWindow *)(id)window).visible = YES; }
- (void)hideWindow:(NSWindow *)window { ((YMFixtureWindow *)(id)window).visible = NO; }
- (void)reportActivationPolicyFailure:(NSApplicationActivationPolicy)requested actualPolicy:(NSApplicationActivationPolicy)actual {
    (void)requested; (void)actual;
}
- (void)drain {
    while (self.pending.count) {
        dispatch_block_t block = self.pending.firstObject;
        [self.pending removeObjectAtIndex:0];
        block();
    }
}
@end

static void CocoaAdapterTests(void) {
    Check(NSApp == nil, "adapter routing starts without a real application");
    for (NSNumber *policyNumber in @[@(NSApplicationActivationPolicyRegular), @(NSApplicationActivationPolicyAccessory)]) {
        NSApplicationActivationPolicy policy = policyNumber.integerValue;
        for (NSNumber *acceptedNumber in @[@NO, @YES]) {
            YMFixtureCocoaEnvironment *e = [YMFixtureCocoaEnvironment new];
            e.appKitAccepted = acceptedNumber.boolValue;
            e.observedPolicy = policy; // Matching observations cannot skip the request or fallback.
            BOOL result = [e requestActivationPolicy:policy];
            BOOL needsFallback = policy == NSApplicationActivationPolicyAccessory && !e.appKitAccepted;
            NSArray *expected = needsFallback ? @[@"appkit:1", @"transform"]
                : @[[NSString stringWithFormat:@"appkit:%ld", (long)policy]];
            Check([e.events isEqualToArray:expected], "adapter requests AppKit first and only failed Accessory reaches transform");
            Check(e.transformCalls == (needsFallback ? 1 : 0), "adapter has at most one bounded transform attempt");
            Check(result == (e.appKitAccepted || needsFallback), "adapter preserves normal results and returns transform success");
            Check(e.policyReads == 0 && e.pending.count == 0, "adapter neither gates on cached policy nor schedules retry polling");
        }
    }
    {
        YMFixtureCocoaEnvironment *e = [YMFixtureCocoaEnvironment new];
        e.observedPolicy = NSApplicationActivationPolicyRegular;
        Check([e requestActivationPolicy:NSApplicationActivationPolicyAccessory] && e.transformCalls == 1 &&
              e.observedPolicy == NSApplicationActivationPolicyAccessory, "failed Accessory request also transforms when getter is not the target");
    }
    {
        YMFixtureCocoaEnvironment *e = [YMFixtureCocoaEnvironment new];
        e.observedPolicy = NSApplicationActivationPolicyAccessory;
        e.transformStatus = -50;
        FILE *capture = tmpfile();
        Check(capture != NULL, "create process-local diagnostic capture");
        fflush(stderr);
        int savedError = dup(STDERR_FILENO);
        Check(savedError >= 0, "preserve process-local stderr");
        Check(dup2(fileno(capture), STDERR_FILENO) >= 0, "capture only this test process stderr");
        BOOL result = [e requestActivationPolicy:NSApplicationActivationPolicyAccessory];
        fflush(stderr);
        int restored = dup2(savedError, STDERR_FILENO);
        close(savedError);
        Check(restored >= 0, "restore process-local stderr");
        rewind(capture);
        char bytes[256] = {0};
        size_t count = fread(bytes, 1, sizeof(bytes) - 1, capture);
        fclose(capture);
        NSString *diagnostic = [[NSString alloc] initWithBytes:bytes length:count encoding:NSUTF8StringEncoding];
        Check(!result && e.transformCalls == 1 && e.transformFailures == 1,
              "transform failure returns false and reports once despite a matching getter");
        Check([diagnostic isEqualToString:@"Accessory process conversion failed (OSStatus -50).\n"],
              "production diagnostic preserves the raw transform status without private data");
        Check(e.pending.count == 0 && e.policyReads == 0, "failed transform does not poll or trust an immediate cached getter");
    }
    for (NSUInteger scenario = 0; scenario < 5; scenario++) {
        YMFixtureWindow *w = [YMFixtureWindow new];
        YMFixtureCocoaEnvironment *e = [YMFixtureCocoaEnvironment new];
        e.appKitAccepted = YES;
        YMControlPanelPresenter *p = [[YMControlPanelPresenter alloc] initWithWindow:(NSWindow *)(id)w environment:e];
        [p open]; [e drain];
        e.appKitAccepted = NO;
        [e.events removeAllObjects];
        if (scenario == 0) { [p closeWindow:(NSWindow *)(id)w]; [p open]; }
        if (scenario == 1) { [p closeWindow:(NSWindow *)(id)w]; [p invalidate]; }
        if (scenario == 2) { w.attachedSheet = YES; [p closeWindow:(NSWindow *)(id)w]; }
        if (scenario == 3) { [p closeWindow:(NSWindow *)(id)[YMFixtureWindow new]]; }
        if (scenario == 4) { [p closeWindow:(NSWindow *)(id)w]; p = nil; }
        [e drain];
        Check(e.transformCalls == 0 && ![e.events containsObject:@"appkit:1"],
              "cancelled or blocked close reaches neither accessory primitive");
        Check(e.pending.count == 0, "cancelled adapter close leaves no retry work");
    }
    {
        YMFixtureWindow *w = [YMFixtureWindow new];
        YMFixtureCocoaEnvironment *e = [YMFixtureCocoaEnvironment new];
        e.appKitAccepted = YES;
        YMControlPanelPresenter *p = [[YMControlPanelPresenter alloc] initWithWindow:(NSWindow *)(id)w environment:e];
        [p open]; [e drain];
        e.appKitAccepted = NO;
        [p closeWindow:(NSWindow *)(id)w]; [p closeWindow:(NSWindow *)(id)w];
        Check(e.transformCalls == 0, "actual adapter fallback waits for the valid deferred close");
        [e drain]; [e drain];
        Check(e.transformCalls == 1 && !w.visible && !p.panelOpen && e.pending.count == 0,
              "repeated close executes one adapter fallback without residual polling");
        e.appKitAccepted = YES;
        [p open]; [e drain];
        Check(e.transformCalls == 1 && e.observedPolicy == NSApplicationActivationPolicyRegular && w.visible,
              "reopen after fallback returns to the ordinary AppKit path on the same window");
    }
    Check(NSApp == nil, "adapter routing leaves NSApp unset and never executes real system primitives");
}

// A policy getter can report the requested identity while the process still
// needs an explicit policy request. Keep observation and effective state apart.
@interface YMStalePolicyEnvironment : YMFixtureEnvironment
@property BOOL overrideObservedPolicy;
@property NSApplicationActivationPolicy reportedPolicy;
@property(nonatomic, readonly) NSApplicationActivationPolicy effectivePolicy;
@end

@implementation YMStalePolicyEnvironment
- (NSApplicationActivationPolicy)activationPolicy {
    return self.overrideObservedPolicy ? self.reportedPolicy : [super activationPolicy];
}
- (NSApplicationActivationPolicy)effectivePolicy { return [super activationPolicy]; }
@end

static void StalePolicyTests(void) {
    YMFixtureWindow *openWindow = [YMFixtureWindow new];
    YMStalePolicyEnvironment *openEnvironment = [YMStalePolicyEnvironment new];
    openEnvironment.overrideObservedPolicy = YES;
    openEnvironment.reportedPolicy = NSApplicationActivationPolicyRegular;
    YMControlPanelPresenter *openPresenter = [[YMControlPanelPresenter alloc]
        initWithWindow:(NSWindow *)(id)openWindow environment:openEnvironment];
    Check(openEnvironment.activationPolicy == NSApplicationActivationPolicyRegular &&
          openEnvironment.effectivePolicy == NSApplicationActivationPolicyAccessory,
          "open fixture separates reported and effective policy");
    [openPresenter open]; [openEnvironment drain];
    BOOL submittedOpen = [openEnvironment.events isEqualToArray:
        @[@"policy:0", @"activate", @"schedule", @"present"]];

    YMFixtureWindow *closeWindow = [YMFixtureWindow new];
    YMStalePolicyEnvironment *closeEnvironment = [YMStalePolicyEnvironment new];
    YMControlPanelPresenter *closePresenter = [[YMControlPanelPresenter alloc]
        initWithWindow:(NSWindow *)(id)closeWindow environment:closeEnvironment];
    [closePresenter open]; [closeEnvironment drain];
    [closeEnvironment.events removeAllObjects];
    closeEnvironment.overrideObservedPolicy = YES;
    closeEnvironment.reportedPolicy = NSApplicationActivationPolicyAccessory;
    Check(closeEnvironment.activationPolicy == NSApplicationActivationPolicyAccessory &&
          closeEnvironment.effectivePolicy == NSApplicationActivationPolicyRegular,
          "close fixture separates reported and effective policy");
    [closePresenter closeWindow:(NSWindow *)(id)closeWindow];
    Check(closeEnvironment.effectivePolicy == NSApplicationActivationPolicyRegular,
          "stale policy does not bypass deferred-close timing");
    [closeEnvironment drain];
    BOOL submittedClose = [closeEnvironment.events isEqualToArray:@[@"hide", @"schedule", @"policy:1"]];
    if (!submittedOpen || !submittedClose) {
        fprintf(stderr, "Stale-policy requests: open=%d close=%d\n", submittedOpen, submittedClose);
    }
    Check(submittedOpen, "explicit open requests Regular despite a matching stale getter");
    Check(openEnvironment.effectivePolicy == NSApplicationActivationPolicyRegular &&
          openEnvironment.failures == 0, "explicit open repairs effective policy without a false error");
    Check(submittedClose, "valid deferred close requests Accessory despite a matching stale getter");
    Check(closeEnvironment.effectivePolicy == NSApplicationActivationPolicyAccessory &&
          closeEnvironment.failures == 0, "explicit close repairs effective policy without a false error");
}

static void LifecycleTests(void) {
    Check(NSApp == nil, "lifecycle tests start without NSApp");
    CocoaAdapterTests();
    StalePolicyTests();

    YMFixtureWindow *w = [YMFixtureWindow new];
    YMFixtureEnvironment *e = [YMFixtureEnvironment new];
    YMControlPanelPresenter *p = [[YMControlPanelPresenter alloc]
        initWithWindow:(NSWindow *)(id)w environment:e];
    [p open];
    Check(p.panelOpen && e.activationPolicy == NSApplicationActivationPolicyRegular,
          "open promotes before presentation");
    Check([e.events isEqualToArray:@[@"policy:0", @"activate", @"schedule"]],
          "activation stays in the explicit open action");
    Check(e.presentations == 0, "presentation waits until menu tracking ends");
    [e drain];
    Check(e.presentations == 1 && e.lastWindow == (NSWindow *)(id)w,
          "presentation reuses the bound window");
    Check([p closeWindow:(NSWindow *)(id)w] && !p.panelOpen && e.hides == 1,
          "close hides without destroying the window");
    Check(e.activationPolicy == NSApplicationActivationPolicyRegular,
          "demotion waits for the deferred close");
    [e drain];
    Check(e.activationPolicy == NSApplicationActivationPolicyAccessory,
          "completed close removes regular application identity");

    {
        YMFixtureWindow *w = [YMFixtureWindow new];
        YMFixtureEnvironment *e = [YMFixtureEnvironment new];
        YMControlPanelPresenter *p = [[YMControlPanelPresenter alloc]
            initWithWindow:(NSWindow *)(id)w environment:e];
        [p open]; [p closeWindow:(NSWindow *)(id)w]; [e drain];
        Check(!p.panelOpen && e.presentations == 0 && e.activationPolicy == 1,
              "close cancels a queued open");
        [p open]; [p closeWindow:(NSWindow *)(id)w]; [p open]; [e drain];
        Check(p.panelOpen && e.presentations == 1 && e.activationPolicy == 0,
              "latest recovery/open defeats stale close and stale presentation");
        [p open]; [p open]; [e drain];
        Check(e.presentations == 2, "repeated opens coalesce to the latest queued presentation");
        NSUInteger hides = e.hides;
        [p closeWindow:(NSWindow *)(id)w]; [p closeWindow:(NSWindow *)(id)w]; [e drain];
        Check(e.hides == hides + 1 && e.activationPolicy == 1,
              "repeated close is idempotent");
    }
    {
        YMFixtureWindow *w = [YMFixtureWindow new];
        YMFixtureEnvironment *e = [YMFixtureEnvironment new];
        YMControlPanelPresenter *p = [[YMControlPanelPresenter alloc]
            initWithWindow:(NSWindow *)(id)w environment:e];
        [p open]; [e drain];
        NSUInteger count = e.events.count;
        w.visible = NO; w.hidden = YES; w.miniaturized = YES;
        [e drain];
        Check(p.panelOpen && e.activationPolicy == 0 && e.events.count == count,
              "visibility/minimization changes do not imply close");
        w.attachedSheet = YES;
        Check(![p closeWindow:(NSWindow *)(id)w] && p.panelOpen && e.hides == 0,
              "attached sheet blocks closing and demotion");
        w.attachedSheet = NO;
        NSWindow *other = (NSWindow *)(id)[YMFixtureWindow new];
        Check(![p closeWindow:other] && ![p closeWindow:nil] && e.hides == 0,
              "unrelated and nil windows cannot demote the application");
        [p open]; [e drain];
        Check(w.visible && !w.hidden && !w.miniaturized && e.lastWindow == (NSWindow *)(id)w,
              "open delegates restoration to presentation on the original window");
    }
    {
        YMFixtureEnvironment *e = [YMFixtureEnvironment new];
        YMControlPanelPresenter *p = [[YMControlPanelPresenter alloc] initWithWindow:nil environment:e];
        [p open]; [p closeWindow:nil]; [e drain];
        Check(!p.panelOpen && e.events.count == 0, "nil-bound presenter is inert");
        YMFixtureWindow *w = [YMFixtureWindow new];
        p = [[YMControlPanelPresenter alloc] initWithWindow:(NSWindow *)(id)w environment:e];
        [p open]; [p invalidate]; [e drain];
        Check(e.presentations == 0, "termination cancels queued presentation");
        NSUInteger count = e.events.count;
        [p open]; Check(![p closeWindow:(NSWindow *)(id)w], "invalidated presenter rejects close");
        [e drain]; Check(e.events.count == count, "invalidated presenter produces no new effects");
    }
    {
        YMFixtureWindow *w = [YMFixtureWindow new];
        YMFixtureEnvironment *e = [YMFixtureEnvironment new];
        YMControlPanelPresenter *p = [[YMControlPanelPresenter alloc]
            initWithWindow:(NSWindow *)(id)w environment:e];
        [p open]; [e drain];
        [p closeWindow:(NSWindow *)(id)w]; [p invalidate]; [e drain];
        Check(e.activationPolicy == 0, "termination also cancels a pending demotion");
        p = [[YMControlPanelPresenter alloc] initWithWindow:(NSWindow *)(id)w environment:e];
        NSUInteger presentations = e.presentations;
        [p open];
        __weak YMControlPanelPresenter *weakPresenter = p;
        p = nil;
        Check(weakPresenter == nil, "deferred work does not retain the presenter through its environment");
        [e drain];
        Check(e.presentations == presentations, "queued callback tolerates a released owner");
    }
    for (NSInteger scenario = 0; scenario < 4; scenario++) {
        YMFixtureWindow *w = [YMFixtureWindow new];
        YMFixtureEnvironment *e = [YMFixtureEnvironment new];
        if (scenario == 0) e.activationPolicy = NSApplicationActivationPolicyRegular;
        if (scenario == 1) e.falseAfterChange = YES;
        if (scenario == 2) e.rejectedPolicy = NSApplicationActivationPolicyRegular;
        if (scenario == 3) e.trueWithoutChange = YES;
        YMControlPanelPresenter *p = [[YMControlPanelPresenter alloc]
            initWithWindow:(NSWindow *)(id)w environment:e];
        [p open]; [e drain];
        Check(e.presentations == 1, "policy failure does not remove panel access");
        Check(e.failures == (scenario >= 2 ? 1 : 0), "actual policy, not BOOL return, decides failure");
        if (scenario == 0) Check([e.events containsObject:@"policy:0"],
                                "already-regular still submits the explicit open request without an error");
    }
    {
        YMFixtureWindow *w = [YMFixtureWindow new];
        YMFixtureEnvironment *e = [YMFixtureEnvironment new];
        YMControlPanelPresenter *p = [[YMControlPanelPresenter alloc]
            initWithWindow:(NSWindow *)(id)w environment:e];
        [p open]; [e drain]; e.rejectedPolicy = NSApplicationActivationPolicyAccessory;
        [p closeWindow:(NSWindow *)(id)w]; [e drain];
        Check(!p.panelOpen && !w.visible && e.activationPolicy == 0 && e.failures == 1,
              "failed demotion leaves a hidden panel and accessible live application");
        Check(e.pending.count == 0, "failed demotion does not schedule retry polling");
    }

    Check(NSApp == nil, "lifecycle tests leave NSApp unset");
}

int main(void) {
    @autoreleasepool {
        // Geometry only: no NSApplication, NSWindow, NSScreen enumeration,
        // display bridge call, desktop capture or keyboard/mouse input.
        const YMPanelScreen screens[] = {
            {NSMakeRect(-2560, 0, 2560, 1440), NSMakeRect(-2560, 0, 2560, 1415), NO, NO},
            {NSMakeRect(0, 0, 2560, 1440), NSMakeRect(0, 60, 2560, 1355), NO, YES},
            {NSMakeRect(2560, 0, 1920, 1080), NSMakeRect(2560, 0, 1920, 1055), YES, NO}
        };
        NSRect existing = NSMakeRect(-2100, 300, 1000, 440);
        YMPanelPlacement p = YMControlPanelPlacement(existing, screens, 3, NSMakePoint(300, 400));
        Check(p.screenIndex == 0 && !p.shouldMove && NSEqualRects(p.frame, existing),
              "opening preserves a reachable physical-panel position despite pointer on another screen");

        p = YMControlPanelPlacement(NSMakeRect(3000, 120, 1000, 440), screens, 3, NSMakePoint(-1200, 1430));
        Check(p.screenIndex == 0 && p.shouldMove && NSContainsRect(screens[0].visibleFrame, p.frame),
              "virtual panel returns to physical screen under menu-bar pointer");
        Check(fabs(NSMidX(p.frame) - NSMidX(screens[0].visibleFrame)) < 0.001,
              "virtual-panel recovery centers within chosen physical screen");

        p = YMControlPanelPlacement(NSMakeRect(6000, -3000, 1000, 440), screens, 3, NSMakePoint(2700, 300));
        Check(p.screenIndex == 1 && NSContainsRect(screens[1].visibleFrame, p.frame),
              "offscreen panel and virtual pointer fall back to physical main screen");

        p = YMControlPanelPlacement(NSMakeRect(100, 1300, 1000, 440), screens, 3, NSMakePoint(-300, 500));
        Check(p.screenIndex == 1 && p.frame.origin.x == 100 && NSMaxY(p.frame) == NSMaxY(screens[1].visibleFrame),
              "partially clipped physical panel clamps locally instead of jumping to pointer screen");

        p = YMControlPanelPlacement(NSMakeRect(100, 0, 1000, 440), screens, 3, NSMakePoint(200, 100));
        Check(p.frame.origin.y == 60 && p.frame.origin.x == 100,
              "physical panel clears Dock-excluded visible frame without changing horizontal position");

        p = YMControlPanelPlacement(NSMakeRect(2500, 200, 1000, 440), screens, 3, NSMakePoint(-500, 100));
        Check(p.screenIndex == 0 && NSContainsRect(screens[0].visibleFrame, p.frame),
              "tiny physical overlap does not keep a predominantly virtual panel hidden");

        const YMPanelScreen small[] = {
            {NSMakeRect(0, 0, 640, 480), NSMakeRect(0, 20, 640, 435), NO, YES}
        };
        p = YMControlPanelPlacement(NSMakeRect(5000, 0, 1000, 700), small, 1, NSMakePoint(10, 10));
        Check(NSEqualRects(p.frame, small[0].visibleFrame), "oversized panel fits small physical display");

        const YMPanelScreen vertical[] = {
            {NSMakeRect(0, 1440, 1440, 2560), NSMakeRect(0, 1490, 1440, 2485), NO, NO},
            screens[2]
        };
        p = YMControlPanelPlacement(NSMakeRect(3100, 200, 900, 500), vertical, 2, NSMakePoint(100, 2000));
        Check(p.screenIndex == 0 && NSContainsRect(vertical[0].visibleFrame, p.frame),
              "portrait display above main uses upward AppKit coordinates without Y conversion");

        const YMPanelScreen virtualMain[] = {screens[0], {screens[2].frame, screens[2].visibleFrame, YES, YES}};
        p = YMControlPanelPlacement(NSMakeRect(3000, 0, 1000, 440), virtualMain, 2, NSMakePoint(NAN, NAN));
        Check(p.screenIndex == 0, "virtual main never selected over available physical display");

        p = YMControlPanelPlacement(existing, &screens[2], 1, NSMakePoint(2700, 300));
        Check(p.screenIndex == 0 && p.shouldMove && NSContainsRect(screens[2].visibleFrame, p.frame),
              "headless opening recovers stale physical coordinates into remaining virtual display");

        const YMPanelScreen headless[] = {
            screens[2],
            {NSMakeRect(4480, 0, 1920, 1080), NSMakeRect(4480, 20, 1920, 1035), YES, YES}
        };
        NSRect headlessExisting = NSMakeRect(2800, 200, 1000, 440);
        p = YMControlPanelPlacement(headlessExisting, headless, 2, NSMakePoint(4700, 300));
        Check(p.screenIndex == 0 && !p.shouldMove && NSEqualRects(p.frame, headlessExisting),
              "headless opening preserves an already reachable virtual-screen position");
        p = YMControlPanelPlacement(existing, headless, 2, NSMakePoint(NAN, NAN));
        Check(p.screenIndex == 1 && NSContainsRect(headless[1].visibleFrame, p.frame),
              "headless offscreen recovery falls back to virtual main screen");
        p = YMControlPanelPlacement(existing, headless, 2, NSMakePoint(2700, 1070));
        Check(p.screenIndex == 0 && NSContainsRect(headless[0].visibleFrame, p.frame),
              "headless explicit opening prefers pointer screen including its menu bar");
        const YMPanelScreen unusablePhysical[] = {
            {screens[1].frame, NSZeroRect, NO, YES}, screens[2]
        };
        p = YMControlPanelPlacement(existing, unusablePhysical, 2, NSZeroPoint);
        Check(p.screenIndex == 1 && NSContainsRect(screens[2].visibleFrame, p.frame),
              "unusable physical screen does not block virtual recovery");
        p = YMControlPanelPlacement(existing, NULL, 0, NSZeroPoint);
        Check(p.screenIndex == NSNotFound && !p.shouldMove, "empty display list is a safe no-op");

        const YMPanelScreen invalid[] = {
            {NSMakeRect(0, 0, 100, 100), NSMakeRect(NAN, 0, 100, 100), NO, YES},
            {NSMakeRect(0, 0, 100, 100), NSZeroRect, NO, YES},
            screens[0]
        };
        p = YMControlPanelPlacement(NSMakeRect(NAN, INFINITY, -20, 0), invalid, 3, NSMakePoint(20, 20));
        Check(p.screenIndex == 2 && NSContainsRect(screens[0].visibleFrame, p.frame),
              "invalid frames cannot override a usable physical fallback");

        const YMPanelScreen badVisible[] = {
            {NSMakeRect(0, 0, 100, 100), NSMakeRect(200, 200, 100, 100), NO, YES}
        };
        p = YMControlPanelPlacement(existing, badVisible, 1, NSZeroPoint);
        Check(p.screenIndex == NSNotFound && !p.shouldMove,
              "nonintersecting visible area does not become a target");

        // Repeated explicit opening must converge rather than walking the panel.
        for (NSUInteger index = 0; index < 300; index++) {
            CGFloat x = (CGFloat)((NSInteger)(index * 431 % 13000) - 6500);
            CGFloat y = (CGFloat)((NSInteger)(index * 317 % 6000) - 3000);
            NSRect sample = NSMakeRect(x, y, 100 + index * 13 % 3000, 80 + index * 7 % 1800);
            p = YMControlPanelPlacement(sample, screens, 3, NSMakePoint(-500, 300));
            Check(p.screenIndex != NSNotFound && !screens[p.screenIndex].isVirtual
                && NSContainsRect(screens[p.screenIndex].visibleFrame, p.frame),
                "varied geometry remains entirely within physical visible area");
            YMPanelPlacement second = YMControlPanelPlacement(p.frame, screens, 3, NSMakePoint(800, 300));
            Check(!second.shouldMove && NSEqualRects(second.frame, p.frame),
                "repeated presentation is geometrically idempotent");
        }

        LifecycleTests();
        printf("PASS: %lu panel geometry + lifecycle assertions; no GUI or display operations\n",
               (unsigned long)scenarios);
    }
    return 0;
}
