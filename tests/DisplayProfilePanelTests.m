// Hidden whole-window layout fixture for the production control panel.
// Creates NSApplication with Prohibited policy, never orders windows front,
// never reads real displays/preferences, and never starts/stops virtual screens.
#define main YMIgnoredApplicationMain
#import "Yomado.m"
#undef main

@interface YMPreviewProfileDisplay : VDVirtualDisplay
@property(nonatomic) BOOL live;
@property(nonatomic) CGDirectDisplayID fixtureID;
@end
@implementation YMPreviewProfileDisplay
- (BOOL)isCreated { return self.live; }
- (CGDirectDisplayID)displayID { return self.live ? self.fixtureID : 0; }
- (BOOL)createWithWidth:(NSUInteger)w height:(NSUInteger)h hiDPI:(BOOL)hiDPI name:(NSString *)name error:(NSError **)error {
    (void)w; (void)h; (void)hiDPI; (void)name; (void)error;
    return NO;
}
- (void)destroy {}
@end

static void Check(BOOL condition, const char *message) {
    if (!condition) {
        fprintf(stderr, "FAIL %s\n", message);
        exit(1);
    }
}

static NSArray<NSDictionary *> *PanelSnapshot(BOOL withVirtual) {
    NSMutableArray *displays = [NSMutableArray array];
    [displays addObject:@{@"displayID":@900, @"name":@"Studio Display 1", @"x":@0, @"y":@0,
        @"logicalWidth":@2560, @"logicalHeight":@1440, @"isMain":@YES, @"isVirtual":@NO,
        @"isActive":@YES, @"isOnline":@YES}];
    [displays addObject:@{@"displayID":@901, @"name":@"Studio Display 2", @"x":@2560, @"y":@0,
        @"logicalWidth":@2560, @"logicalHeight":@1440, @"isMain":@NO, @"isVirtual":@NO,
        @"isActive":@YES, @"isOnline":@YES}];
    if (withVirtual) {
        [displays addObject:@{@"displayID":@902, @"name":@"虚拟屏 1 · Codex", @"x":@5120, @"y":@0,
            @"logicalWidth":@1920, @"logicalHeight":@1080, @"isMain":@NO, @"isVirtual":@YES,
            @"isActive":@YES, @"isOnline":@YES}];
    }
    return displays;
}

static YMManagedDisplay *StoppedProfile(ADController *controller, NSUInteger ordinal, NSString *name) {
    YMManagedDisplay *profile = [controller newProfileWithOrdinal:ordinal name:name width:1920 height:1080 hiDPI:NO];
    YMPreviewProfileDisplay *display = [YMPreviewProfileDisplay new];
    display.fixtureID = (CGDirectDisplayID)(400 + ordinal);
    display.live = NO;
    profile.display = display;
    return profile;
}

static YMManagedDisplay *RunningProfile(ADController *controller, NSUInteger ordinal, NSString *name, CGDirectDisplayID displayID) {
    YMManagedDisplay *profile = [controller newProfileWithOrdinal:ordinal name:name width:1920 height:1080 hiDPI:NO];
    YMPreviewProfileDisplay *display = [YMPreviewProfileDisplay new];
    display.fixtureID = displayID;
    display.live = YES;
    profile.display = display;
    profile.topologyVerified = YES;
    return profile;
}

static ADController *PanelController(NSUInteger savedCount, NSSize contentSize, BOOL withRunningVirtual) {
    ADController *controller = [[ADController alloc] init];
    controller.previewMode = YES;
    controller.previewState = @"multi";
    controller.previewSnapshot = PanelSnapshot(withRunningVirtual);
    controller.displayProfiles = [NSMutableArray array];
    if (withRunningVirtual) {
        [controller.displayProfiles addObject:RunningProfile(controller, 1, @"Codex", 902)];
    }
    for (NSUInteger index = 0; index < savedCount; index++) {
        NSUInteger ordinal = withRunningVirtual ? index + 2 : index + 1;
        NSString *name = (index == 0)
            ? [@"" stringByPaddingToLength:60 withString:@"N" startingAtIndex:0]
            : [NSString stringWithFormat:@"Saved %lu", (unsigned long)ordinal];
        [controller.displayProfiles addObject:StoppedProfile(controller, ordinal, name)];
    }
    [controller buildWindow];
    [controller.window setContentSize:contentSize];
    [controller updateInventory];
    NSView *content = controller.window.contentView;
    for (NSUInteger pass = 0; pass < 3; pass++) {
        [content layoutSubtreeIfNeeded];
        [content displayIfNeeded];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    return controller;
}

static void AssertBasics(ADController *controller, NSUInteger savedCount) {
    Check(controller.addDisplayButton != nil, "new display entry is present");
    Check(controller.addDisplayButton.action == @selector(addDisplay:), "new button opens editor action");
    Check([controller.addDisplayButton.title containsString:@"新建屏幕"], "new button uses create label");
    Check(NSEqualSizes(controller.window.contentMinSize, NSMakeSize(760, 520)), "minimum content size");
    Check(controller.savedProfilesView != nil, "saved profiles section exists");
    Check(controller.savedProfilesView.hidden == (savedCount == 0), "saved section empty behavior");
    Check(controller.profileActivityLabel != nil, "activity label exists");
    Check(!controller.window.visible, "fixture never reveals a window");
    Check(NSApp.activationPolicy == NSApplicationActivationPolicyProhibited, "fixture never activates app");
}

static void AssertCanvas(ADController *controller) {
    Check(controller.workspaceViews.count > 0, "workspace tiles exist");
    NSView *document = controller.applicationCards;
    CGFloat top = -CGFLOAT_MAX;
    for (NSNumber *key in controller.workspaceViews) {
        YMAppWorkspaceView *tile = controller.workspaceViews[key];
        Check(tile.bounds.size.width >= 140, "workspace tile meets minimum width");
        BOOL correctRatio = fabs(tile.bounds.size.height -
            tile.bounds.size.width / MAX(0.1, tile.displayAspectRatio)) <= 1.5;
        Check(correctRatio, "workspace tile keeps aspect ratio");
        NSRect screenInDocument = [tile convertRect:tile.bounds toView:document];
        if (top < -1e11) top = NSMaxY(screenInDocument);
        Check(fabs(NSMaxY(screenInDocument) - top) <= 1.5, "workspace tiles stay top aligned");
        if (!tile.physicalDisplay) {
            Check(tile.onManageDisplay != nil, "manage action present on virtual tiles");
        }
    }
}

static void AssertSavedSection(ADController *controller) {
    YMSavedDisplayProfilesView *view = controller.savedProfilesView;
    if (view.hidden) return;
    Check(!view.hasAmbiguousLayout, "saved section layout is unambiguous");
    NSRect frame = view.frame;
    Check(frame.size.width > 100 && frame.size.height > 40, "saved section has measurable frame");
    // Long names must not shove action buttons out of the row.
    for (NSView *subview in view.subviews) {
        (void)subview;
    }
}

static void RunSizeMatrix(void) {
    NSArray<NSValue *> *sizes = @[
        [NSValue valueWithSize:NSMakeSize(1000, 620)],
        [NSValue valueWithSize:NSMakeSize(760, 520)],
        [NSValue valueWithSize:NSMakeSize(1200, 800)]
    ];
    NSArray<NSNumber *> *counts = @[ @0, @1, @2, @30 ];
    for (NSValue *sizeValue in sizes) {
        NSSize size = sizeValue.sizeValue;
        for (NSNumber *countValue in counts) {
            NSUInteger savedCount = countValue.unsignedIntegerValue;
            ADController *controller = PanelController(savedCount, size, YES);
            AssertBasics(controller, savedCount);
            AssertCanvas(controller);
            AssertSavedSection(controller);
            [controller.window close];
            printf("PASS panel size %.0fx%.0f saved=%lu\n", size.width, size.height, (unsigned long)savedCount);
        }
    }
}

static void RunAppearanceAndRefresh(void) {
    ADController *controller = PanelController(2, NSMakeSize(1000, 620), YES);
    AssertBasics(controller, 2);
    NSArray *appearances = @[
        [NSAppearance appearanceNamed:NSAppearanceNameAqua],
        [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua],
        [NSAppearance appearanceNamed:NSAppearanceNameAqua]
    ];
    for (NSAppearance *appearance in appearances) {
        NSApp.appearance = appearance;
        controller.window.appearance = appearance;
        [controller updateInventory];
        [controller.window.contentView layoutSubtreeIfNeeded];
        AssertBasics(controller, 2);
        AssertCanvas(controller);
    }
    [controller.savedProfilesView toggleCollapsed:nil];
    Check(controller.savedProfilesView.collapsed, "collapse toggles saved section");
    controller.pendingProfileRevealOrdinal = @(controller.displayProfiles.lastObject.ordinal);
    for (NSUInteger pass = 0; pass < 40; pass++) [controller updateInventory];
    Check(!controller.savedProfilesView.collapsed, "failed reveal expands collapsed section");
    Check(controller.pendingProfileRevealOrdinal == nil, "reveal ordinal consumed after update");

    YMManagedDisplay *starting = controller.displayProfiles.lastObject;
    starting.starting = YES;
    [controller updateInventory];
    Check(!controller.profileActivityLabel.hidden
          && [controller.profileActivityLabel.stringValue containsString:@"启动中"],
          "activity label shows starting feedback");
    starting.starting = NO;
    YMPreviewProfileDisplay *display = (YMPreviewProfileDisplay *)starting.display;
    display.live = YES;
    starting.topologyVerified = NO;
    starting.starting = YES;
    [controller updateInventory];
    Check([controller.profileActivityLabel.stringValue containsString:@"核验"],
          "activity label shows verification feedback");
    starting.starting = NO;
    display.live = NO;

    controller.topologyRecoverySnapshot = [YMDisplayTopologySnapshot new];
    [controller updateInventory];
    Check(!controller.addDisplayButton.enabled, "recovery blocks new display button");
    NSArray<YMSavedDisplayProfileRow *> *rows = [controller savedProfileRows];
    for (YMSavedDisplayProfileRow *row in rows) {
        Check(!row.canStart && !row.canEdit, "recovery disables saved actions");
    }
    controller.topologyRecoverySnapshot = nil;
    [controller updateInventory];
    [controller.window close];
    printf("PASS appearance refresh collapse reveal activity\n");
}

static void RunEntryActions(void) {
    ADController *controller = PanelController(1, NSMakeSize(1000, 620), NO);
    AssertBasics(controller, 1);
    Check(controller.addDisplayButton.action == @selector(addDisplay:), "create button action");
    // previewMode blocks present; verify the button still points at the form entry.
    Check([controller respondsToSelector:@selector(presentProfileEditorForOrdinal:mode:)],
          "present entry exists on production controller");
    Check([controller respondsToSelector:@selector(makeDisplayProfileEditorWithMode:draft:)],
          "factory exists on production controller");
    YMDisplayProfileDraft *draft = [[YMDisplayProfileDraft alloc] initWithName:@"Probe" width:1920 hiDPI:NO];
    YMDisplayProfileEditor *editor = [controller makeDisplayProfileEditorWithMode:YMDisplayProfileEditorModeCreate draft:draft];
    Check(editor != nil && editor.mode == YMDisplayProfileEditorModeCreate, "factory builds create editor");
    (void)editor.window;
    [controller window];
    [controller.window close];
    printf("PASS entry actions and factory\n");
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        Check(NSApp.activationPolicy == NSApplicationActivationPolicyProhibited, "starts prohibited");
        RunSizeMatrix();
        RunAppearanceAndRefresh();
        RunEntryActions();
        Check(!NSApp.isActive, "fixture never activates");
        printf("Display profile panel tests passed.\n");
        return 0;
    }
}
