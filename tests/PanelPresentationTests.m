#import "PanelPresentation.h"
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
@property NSMutableArray *settling;
@property NSUInteger settleSchedules;
- (void)drain;
- (void)drainSettling;
@end

@implementation YMFixtureEnvironment
- (instancetype)init {
    if ((self = [super init])) {
        _activationPolicy = NSApplicationActivationPolicyAccessory;
        _rejectedPolicy = -1;
        _events = [NSMutableArray array];
        _pending = [NSMutableArray array];
        _settling = [NSMutableArray array];
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
- (void)deferUntilPolicySettles:(dispatch_block_t)block {
    self.settleSchedules++;
    [self.settling addObject:[block copy]];
}
- (BOOL)isWindowVisible:(NSWindow *)window { return ((YMFixtureWindow *)(id)window).visible; }
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
- (void)drainSettling {
    NSArray *blocks = [self.settling copy];
    [self.settling removeAllObjects];
    for (dispatch_block_t block in blocks) block();
}
@end

// Exercise the real Cocoa scheduler with only its clock and menu-mode boundary
// replaced. No NSApplication, window, timer or process-policy call is created.
@interface YMCocoaPanelPresentationEnvironment : NSObject <YMPanelPresentationEnvironment>
- (void)scheduleAfterInterval:(NSTimeInterval)interval block:(dispatch_block_t)block;
@end

@interface YMFixtureCocoaScheduler : YMCocoaPanelPresentationEnvironment
@property NSTimeInterval interval;
@property NSMutableArray *delays;
@property NSMutableArray *defaults;
@end
@implementation YMFixtureCocoaScheduler
- (instancetype)init {
    if ((self = [super init])) {
        _delays = [NSMutableArray array];
        _defaults = [NSMutableArray array];
    }
    return self;
}
- (void)scheduleAfterInterval:(NSTimeInterval)interval block:(dispatch_block_t)block {
    self.interval = interval;
    [self.delays addObject:[block copy]];
}
- (void)deferUntilAfterMenuTracking:(dispatch_block_t)block {
    [self.defaults addObject:[block copy]];
}
@end

static void CocoaSchedulerTests(void) {
    Check(NSApp == nil, "Cocoa scheduler test starts without a real application");
    YMFixtureCocoaScheduler *e = [YMFixtureCocoaScheduler new];
    __block NSUInteger calls = 0;
    [e deferUntilPolicySettles:^{ calls++; }];
    Check(e.interval == 1.0 && e.delays.count == 1 && e.defaults.count == 0 && calls == 0,
          "production scheduler queues one grace period before any retry");
    dispatch_block_t timer = e.delays.firstObject;
    [e.delays removeAllObjects];
    timer();
    Check(calls == 0 && e.defaults.count == 1,
          "settled callback still waits for the normal menu-tracking boundary");
    dispatch_block_t normalMode = e.defaults.firstObject;
    [e.defaults removeAllObjects];
    normalMode();
    Check(calls == 1 && e.delays.count == 0 && e.defaults.count == 0,
          "production scheduler invokes once with no repeating timer");
    Check(NSApp == nil, "Cocoa scheduler test never initializes the real application");
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

static NSString *CaptureDiagnostic(dispatch_block_t block) {
    FILE *capture = tmpfile();
    Check(capture != NULL, "create process-local retry diagnostic capture");
    fflush(stderr);
    int savedError = dup(STDERR_FILENO);
    Check(savedError >= 0, "preserve process-local stderr");
    Check(dup2(fileno(capture), STDERR_FILENO) >= 0, "capture only this test process stderr");
    block();
    fflush(stderr);
    int restored = dup2(savedError, STDERR_FILENO);
    close(savedError);
    Check(restored >= 0, "restore process-local stderr after retry");
    rewind(capture);
    char bytes[512] = {0};
    size_t count = fread(bytes, 1, sizeof(bytes) - 1, capture);
    fclose(capture);
    return [[NSString alloc] initWithBytes:bytes length:count encoding:NSUTF8StringEncoding];
}

static void SettledRetryTests(void) {
    {
        YMFixtureWindow *w = [YMFixtureWindow new];
        YMFixtureEnvironment *e = [YMFixtureEnvironment new];
        YMControlPanelPresenter *p = [[YMControlPanelPresenter alloc]
            initWithWindow:(NSWindow *)(id)w environment:e];
        [p open]; [e drain];
        e.activationPolicy = NSApplicationActivationPolicyAccessory;
        e.rejectedPolicy = NSApplicationActivationPolicyAccessory;
        [p closeWindow:(NSWindow *)(id)w]; [e drain];
        Check(e.settleSchedules == 1 && e.settling.count == 1 && e.failures == 0,
              "rejected close schedules once even when its transient getter already says Accessory");
        e.activationPolicy = NSApplicationActivationPolicyRegular;
        e.rejectedPolicy = -1;
        [e.events removeAllObjects];
        NSString *diagnostic = CaptureDiagnostic(^{ [e drainSettling]; });
        Check([e.events isEqualToArray:@[@"policy:1"]] && e.activationPolicy == 1,
              "settled retry repairs a later Regular state by submitting one AppKit request");
        Check(!w.visible && !p.panelOpen && e.settleSchedules == 1 && e.settling.count == 0,
              "successful retry leaves the panel hidden and no remaining retry work");
        NSRegularExpression *format = [NSRegularExpression regularExpressionWithPattern:
            @"^Control panel Accessory retry at [0-9]+\\.[0-9]{6}: accepted=1 actual=1\\.\\n$"
            options:0 error:NULL];
        Check([format numberOfMatchesInString:diagnostic options:0 range:NSMakeRange(0, diagnostic.length)] == 1,
              "retry log has only monotonic time, accepted flag and actual policy");
    }
    for (NSUInteger scenario = 0; scenario < 3; scenario++) {
        YMFixtureWindow *w = [YMFixtureWindow new];
        YMFixtureEnvironment *e = [YMFixtureEnvironment new];
        YMControlPanelPresenter *p = [[YMControlPanelPresenter alloc]
            initWithWindow:(NSWindow *)(id)w environment:e];
        [p open]; [e drain];
        e.falseAfterChange = scenario == 1;
        e.trueWithoutChange = scenario == 2;
        [p closeWindow:(NSWindow *)(id)w]; [e drain];
        Check(e.settleSchedules == (scenario == 0 ? 0 : 1),
              "retry needs rejection or observed mismatch; a successful target transition schedules none");
        [p invalidate]; [e drainSettling];
    }
    for (NSUInteger scenario = 0; scenario < 6; scenario++) {
        YMFixtureWindow *w = [YMFixtureWindow new];
        YMFixtureEnvironment *e = [YMFixtureEnvironment new];
        YMControlPanelPresenter *p = [[YMControlPanelPresenter alloc]
            initWithWindow:(NSWindow *)(id)w environment:e];
        [p open]; [e drain];
        e.rejectedPolicy = NSApplicationActivationPolicyAccessory;
        [p closeWindow:(NSWindow *)(id)w]; [e drain];
        Check(e.settling.count == 1, "cancellation scenario starts with one pending settled retry");
        if (scenario == 0) { [p open]; [e drain]; }
        if (scenario == 1) [p invalidate];
        if (scenario == 2) {
            __weak YMControlPanelPresenter *weakPresenter = p;
            p = nil;
            Check(weakPresenter == nil, "settled retry does not retain its presenter");
        }
        if (scenario == 3) w.attachedSheet = YES;
        if (scenario == 4) w.visible = YES;
        if (scenario == 5) [p setValue:(NSWindow *)(id)[YMFixtureWindow new] forKey:@"window"];
        NSUInteger events = e.events.count;
        NSString *diagnostic = CaptureDiagnostic(^{ [e drainSettling]; });
        Check(e.events.count == events && diagnostic.length == 0 && e.settling.count == 0,
              "open, invalidation, release, new sheet, visible panel or different bound window cancels late retry");
    }
    {
        YMFixtureWindow *w = [YMFixtureWindow new];
        YMFixtureEnvironment *e = [YMFixtureEnvironment new];
        YMControlPanelPresenter *p = [[YMControlPanelPresenter alloc]
            initWithWindow:(NSWindow *)(id)w environment:e];
        [p open]; [e drain];
        e.rejectedPolicy = NSApplicationActivationPolicyAccessory;
        [p closeWindow:(NSWindow *)(id)w]; [e drain];
        [p open]; [e drain];
        [p closeWindow:(NSWindow *)(id)w]; [e drain];
        Check(e.settling.count == 2, "close-open-close creates retries belonging to two distinct generations");
        NSUInteger events = e.events.count;
        dispatch_block_t stale = e.settling.firstObject;
        [e.settling removeObjectAtIndex:0];
        NSString *cancelledLog = CaptureDiagnostic(stale);
        Check(e.events.count == events && cancelledLog.length == 0,
              "older close retry cannot write even while the latest generation is closed");
        e.rejectedPolicy = -1;
        (void)CaptureDiagnostic(^{ [e drainSettling]; });
        Check(e.events.count == events + 1 && e.activationPolicy == 1 && e.settling.count == 0,
              "only the latest close generation can issue its one settled request");
    }
    {
        YMFixtureWindow *w = [YMFixtureWindow new];
        YMFixtureEnvironment *e = [YMFixtureEnvironment new];
        YMControlPanelPresenter *p = [[YMControlPanelPresenter alloc]
            initWithWindow:(NSWindow *)(id)w environment:e];
        [p open]; [e drain];
        e.rejectedPolicy = NSApplicationActivationPolicyAccessory;
        [p closeWindow:(NSWindow *)(id)w]; [p closeWindow:(NSWindow *)(id)w]; [e drain];
        NSString *diagnostic = CaptureDiagnostic(^{ [e drainSettling]; });
        Check([diagnostic containsString:@"accepted=0 actual=0."] && e.failures == 2,
              "failed retry reports its rejected request and observed state");
        Check(e.settleSchedules == 1 && e.settling.count == 0 && e.pending.count == 0,
              "a second failure and repeated close never create recursive retry polling");
        NSUInteger events = e.events.count;
        [e drain]; [e drainSettling];
        Check(e.events.count == events, "no delayed policy changes survive the single failed retry");
        e.rejectedPolicy = -1;
        [p open]; [e drain];
        Check(p.panelOpen && w.visible && e.activationPolicy == 0,
              "manual reopening remains usable after the bounded retry fails");
    }
    Check(NSApp == nil, "settled retries never initialize NSApplication or touch real windows");
}

static void LifecycleTests(void) {
    Check(NSApp == nil, "lifecycle tests start without NSApp");
    CocoaSchedulerTests();
    StalePolicyTests();
    SettledRetryTests();

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
