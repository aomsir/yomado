#import "PanelPresentation.h"
#import "VDVirtualDisplay.h"
#import <dispatch/dispatch.h>
#import <math.h>

static BOOL YMPanelValidRect(NSRect rect) {
    return isfinite(rect.origin.x) && isfinite(rect.origin.y)
        && isfinite(rect.size.width) && isfinite(rect.size.height)
        && rect.size.width > 0 && rect.size.height > 0
        && isfinite(NSMaxX(rect)) && isfinite(NSMaxY(rect));
}

static NSRect YMPanelUsableFrame(YMPanelScreen screen) {
    if (!YMPanelValidRect(screen.frame)
        || !YMPanelValidRect(screen.visibleFrame)) return NSZeroRect;
    return NSIntersectionRect(screen.frame, screen.visibleFrame);
}

YMPanelPlacement YMControlPanelPlacement(NSRect panelFrame,
    const YMPanelScreen *screens, NSUInteger screenCount, NSPoint pointerLocation) {
    YMPanelPlacement result = {panelFrame, NSNotFound, NO};
    if (!screens || !screenCount) return result;

    // Headless use still needs an accessible control panel. Prefer physical
    // screens when any are usable; otherwise recover onto a virtual screen.
    BOOL requirePhysical = NO;
    for (NSUInteger index = 0; index < screenCount; index++) {
        if (!screens[index].isVirtual && YMPanelValidRect(YMPanelUsableFrame(screens[index]))) {
            requirePhysical = YES;
            break;
        }
    }
    NSInteger firstTarget = NSNotFound, mainTarget = NSNotFound;
    NSInteger pointerTarget = NSNotFound, dominant = NSNotFound;
    long double largestArea = 0;
    BOOL validPanel = YMPanelValidRect(panelFrame);
    BOOL validPointer = isfinite(pointerLocation.x) && isfinite(pointerLocation.y);
    for (NSUInteger index = 0; index < screenCount; index++) {
        YMPanelScreen screen = screens[index];
        NSRect usable = YMPanelUsableFrame(screen);
        if (YMPanelValidRect(usable) && (!requirePhysical || !screen.isVirtual)) {
            if (firstTarget == NSNotFound) firstTarget = (NSInteger)index;
            if (screen.isMain && mainTarget == NSNotFound) mainTarget = (NSInteger)index;
            // Use the full frame so a click on this screen's menu bar counts.
            if (validPointer && NSPointInRect(pointerLocation, screen.frame)
                && pointerTarget == NSNotFound) pointerTarget = (NSInteger)index;
        }
        if (!validPanel || !YMPanelValidRect(screen.frame)) continue;
        NSRect overlap = NSIntersectionRect(panelFrame, screen.frame);
        long double area = (long double)overlap.size.width * overlap.size.height;
        if (area > largestArea || (area > 0 && area == largestArea
            && dominant != NSNotFound && screens[dominant].isVirtual && !screen.isVirtual)) {
            largestArea = area;
            dominant = (NSInteger)index;
        }
    }
    if (firstTarget == NSNotFound) return result;

    BOOL keepPosition = dominant != NSNotFound
        && (!requirePhysical || !screens[dominant].isVirtual)
        && YMPanelValidRect(YMPanelUsableFrame(screens[dominant]));
    NSInteger target = keepPosition ? dominant
        : pointerTarget != NSNotFound ? pointerTarget
        : mainTarget != NSNotFound ? mainTarget : firstTarget;
    NSRect visible = YMPanelUsableFrame(screens[target]);
    NSSize size = validPanel ? panelFrame.size : NSMakeSize(1000, 440);
    size.width = MIN(size.width, visible.size.width);
    size.height = MIN(size.height, visible.size.height);
    NSPoint origin = keepPosition ? panelFrame.origin
        : NSMakePoint(NSMidX(visible) - size.width / 2, NSMidY(visible) - size.height / 2);
    origin.x = MAX(NSMinX(visible), MIN(origin.x, NSMaxX(visible) - size.width));
    origin.y = MAX(NSMinY(visible), MIN(origin.y, NSMaxY(visible) - size.height));
    result.frame = (NSRect){origin, size};
    result.screenIndex = target;
    result.shouldMove = !NSEqualRects(result.frame, panelFrame);
    return result;
}

static void YMPresentControlPanelOnMainThread(NSWindow *window) {
    NSCAssert(NSThread.isMainThread, @"Panel presentation must run on the main thread.");
    // The regular application identity and primary window role let Stage
    // Manager give the panel its own group. MoveToActiveSpace keeps a window
    // in the current center stage, so it must not accompany Primary.
    // Keep the existing window; user-created groups remain managed by macOS.
    NSWindowCollectionBehavior groupingFlags = NSWindowCollectionBehaviorCanJoinAllSpaces
        | NSWindowCollectionBehaviorMoveToActiveSpace
        | NSWindowCollectionBehaviorAuxiliary | NSWindowCollectionBehaviorCanJoinAllApplications;
    window.collectionBehavior = (window.collectionBehavior & ~groupingFlags)
        | NSWindowCollectionBehaviorPrimary;
    window.hidesOnDeactivate = NO;

    NSArray<NSScreen *> *screens = NSScreen.screens;
    NSMutableData *geometry = [NSMutableData dataWithLength:sizeof(YMPanelScreen) * screens.count];
    YMPanelScreen *values = geometry.mutableBytes;
    CGDirectDisplayID mainDisplay = CGMainDisplayID();
    for (NSUInteger index = 0; index < screens.count; index++) {
        NSScreen *screen = screens[index];
        CGDirectDisplayID displayID = [screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
        values[index] = (YMPanelScreen){screen.frame, screen.visibleFrame,
            !displayID || [VDVirtualDisplay isVirtualDisplay:displayID], displayID == mainDisplay};
    }
    YMPanelPlacement placement = YMControlPanelPlacement(window.frame, values, screens.count, NSEvent.mouseLocation);
    // Change only our panel, before making a previously hidden window visible.
    if (placement.shouldMove) [window setFrame:placement.frame display:NO];
    if (window.miniaturized) [window deminiaturize:nil];
    if (NSApp.hidden) [NSApp unhideWithoutActivation];
    [NSApp activate];
    [window makeKeyAndOrderFront:nil];
    // Activation is cooperative/asynchronous on recent macOS. Explicit opening
    // should still reveal the panel at normal level, without a focus-poll timer.
    [window orderFrontRegardless];
}

@interface YMCocoaPanelPresentationEnvironment : NSObject <YMPanelPresentationEnvironment>
@end

@implementation YMCocoaPanelPresentationEnvironment
- (NSApplicationActivationPolicy)activationPolicy { return NSApp.activationPolicy; }
- (BOOL)requestActivationPolicy:(NSApplicationActivationPolicy)policy {
    return [NSApp setActivationPolicy:policy];
}
- (void)activateApplication { [NSApp activate]; }
- (void)deferUntilAfterMenuTracking:(dispatch_block_t)block {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSRunLoop.mainRunLoop performInModes:@[NSDefaultRunLoopMode] block:block];
    });
}
- (BOOL)hasAttachedSheetForWindow:(NSWindow *)window { return window.attachedSheet != nil; }
- (void)presentWindow:(NSWindow *)window { YMPresentControlPanelOnMainThread(window); }
- (void)hideWindow:(NSWindow *)window { [window orderOut:nil]; }
- (void)reportActivationPolicyFailure:(NSApplicationActivationPolicy)requested
                        actualPolicy:(NSApplicationActivationPolicy)actual {
    fprintf(stderr, "Control panel activation policy request %ld did not reach target (actual %ld).\n",
            (long)requested, (long)actual);
}
@end

@interface YMControlPanelPresenter ()
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) id<YMPanelPresentationEnvironment> environment;
@property(nonatomic, readwrite) BOOL panelOpen;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) BOOL invalidated;
@end

@implementation YMControlPanelPresenter
- (instancetype)initWithWindow:(NSWindow *)window {
    return [self initWithWindow:window environment:[YMCocoaPanelPresentationEnvironment new]];
}
- (instancetype)initWithWindow:(NSWindow *)window
                  environment:(id<YMPanelPresentationEnvironment>)environment {
    if ((self = [super init])) {
        _window = window;
        _environment = environment;
    }
    return self;
}
- (void)ensurePolicy:(NSApplicationActivationPolicy)requested {
    // Submit explicit lifecycle transitions even when the getter already
    // reports the target; that observation can precede the effective change.
    (void)[self.environment requestActivationPolicy:requested];
    NSApplicationActivationPolicy actual = self.environment.activationPolicy;
    if (actual != requested) {
        [self.environment reportActivationPolicyFailure:requested actualPolicy:actual];
    }
}
- (void)open {
    NSCAssert(NSThread.isMainThread, @"Panel lifecycle requires the main thread.");
    if (self.invalidated || !self.window) return;
    self.panelOpen = YES;
    NSUInteger generation = ++self.generation;
    [self ensurePolicy:NSApplicationActivationPolicyRegular];
    [self.environment activateApplication];
    __weak YMControlPanelPresenter *weakSelf = self;
    [self.environment deferUntilAfterMenuTracking:^{
        YMControlPanelPresenter *strongSelf = weakSelf;
        if (!strongSelf || strongSelf.invalidated ||
            strongSelf.generation != generation || !strongSelf.panelOpen) return;
        [strongSelf.environment presentWindow:strongSelf.window];
    }];
}
- (BOOL)closeWindow:(NSWindow *)window {
    NSCAssert(NSThread.isMainThread, @"Panel lifecycle requires the main thread.");
    if (self.invalidated || !window || window != self.window ||
        [self.environment hasAttachedSheetForWindow:window]) return NO;
    if (!self.panelOpen) return YES;
    self.panelOpen = NO;
    NSUInteger generation = ++self.generation;
    [self.environment hideWindow:window];
    __weak YMControlPanelPresenter *weakSelf = self;
    [self.environment deferUntilAfterMenuTracking:^{
        YMControlPanelPresenter *strongSelf = weakSelf;
        if (!strongSelf || strongSelf.invalidated ||
            strongSelf.generation != generation || strongSelf.panelOpen) return;
        [strongSelf ensurePolicy:NSApplicationActivationPolicyAccessory];
    }];
    return YES;
}
- (void)invalidate {
    NSCAssert(NSThread.isMainThread, @"Panel lifecycle requires the main thread.");
    self.invalidated = YES;
    self.panelOpen = NO;
    ++self.generation;
}
@end
