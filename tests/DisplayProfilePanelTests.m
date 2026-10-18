// Hidden whole-window layout fixture for the production control panel.
// Creates NSApplication with Prohibited policy, never orders windows front,
// never reads real displays/preferences, and never starts/stops virtual screens.
#define main YMIgnoredApplicationMain
#import "Yomado.m"
#undef main

@interface ADController (YMPreviewInstallTestDeclaration)
- (void)installPreviewProfilesForState:(NSString *)state;
- (NSArray<YMSavedDisplayProfileRow *> *)savedProfileRows;
@end

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

static BOOL PanelLabelEquals(NSView *view, NSString *text) {
    if (![view isKindOfClass:NSTextField.class]) return NO;
    return [((NSTextField *)view).stringValue isEqualToString:text];
}

static BOOL PanelTreeContainsLabel(NSView *view, NSString *text) {
    if (PanelLabelEquals(view, text)) return YES;
    for (NSView *child in view.subviews) {
        if (PanelTreeContainsLabel(child, text)) return YES;
    }
    return NO;
}

static void CollectAmbiguousViews(NSView *view, NSMutableArray<NSView *> *out) {
    if (view.hasAmbiguousLayout) [out addObject:view];
    for (NSView *child in view.subviews) CollectAmbiguousViews(child, out);
}

static void AssertBasics(ADController *controller, NSUInteger savedCount) {
    Check(controller.addDisplayButton != nil, "new display entry is present");
    Check(controller.addDisplayButton.action == @selector(addDisplay:), "new button opens editor action");
    Check([controller.addDisplayButton.title containsString:@"新建屏幕"], "new button uses create label");
    Check(NSEqualSizes(controller.window.contentMinSize, NSMakeSize(760, 520)), "minimum content size");
    Check(controller.savedProfilesView != nil, "saved profiles section exists");
    Check(controller.savedProfilesView.hidden == (savedCount == 0), "saved section empty behavior");
    Check(controller.profileActivityLabel != nil, "activity label exists");
    Check(PanelTreeContainsLabel(controller.window.contentView, @"为视觉 Agent 留一块工作屏。"),
          "tagline matches Spec short sentence");
    Check(!PanelTreeContainsLabel(controller.window.contentView, @"为视觉 Agent 留一块工作屏，让实体屏可以休息。"),
          "tagline drops the unverified resting claim");
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

static BOOL FramesOverlap(NSRect a, NSRect b) {
    return NSIntersectsRect(NSInsetRect(a, 0.5, 0.5), NSInsetRect(b, 0.5, 0.5));
}

static void AssertSavedSection(ADController *controller) {
    YMSavedDisplayProfilesView *view = controller.savedProfilesView;
    if (view.hidden) return;
    Check(!view.hasAmbiguousLayout, "saved section layout is unambiguous");
    NSMutableArray<NSView *> *ambiguous = [NSMutableArray array];
    CollectAmbiguousViews(view, ambiguous);
    Check(ambiguous.count == 0, "saved section subtree has no ambiguous layout");
    NSRect frame = view.frame;
    Check(frame.size.width > 100 && frame.size.height > 40, "saved section has measurable frame");

    NSScrollView *viewport = nil;
    for (NSView *child in view.subviews) {
        if ([child isKindOfClass:NSStackView.class]) {
            for (NSView *arranged in ((NSStackView *)child).arrangedSubviews) {
                if ([arranged isKindOfClass:NSScrollView.class]) viewport = (NSScrollView *)arranged;
            }
        }
    }
    Check(viewport != nil, "saved section exposes a scroll viewport");
    CGFloat viewportHeight = viewport.bounds.size.height;
    Check(viewportHeight >= 55.5 && viewportHeight <= 184.5, "saved viewport stays within 56-184");

    NSView *document = viewport.documentView;
    NSRect visibleDoc = [viewport documentVisibleRect];
    NSArray<NSView *> *rows = [document isKindOfClass:NSStackView.class]
        ? ((NSStackView *)document).arrangedSubviews : document.subviews;
    NSUInteger completeRows = 0;
    for (NSView *row in rows) {
        NSRect rowInDoc = [row convertRect:row.bounds toView:document];
        NSRect visiblePart = NSIntersectionRect(visibleDoc, rowInDoc);
        BOOL fullyVisible = visiblePart.size.height >= MAX(1.0, rowInDoc.size.height - 1.0)
            && visiblePart.size.width >= MAX(1.0, rowInDoc.size.width - 1.0);
        if (fullyVisible) completeRows++;
        NSButton *start = nil;
        NSButton *edit = nil;
        NSMutableArray<NSButton *> *buttons = [NSMutableArray array];
        NSMutableArray<NSView *> *stack = [NSMutableArray arrayWithObject:row];
        while (stack.count) {
            NSView *node = stack.lastObject;
            [stack removeLastObject];
            if ([node isKindOfClass:NSButton.class]) [buttons addObject:(NSButton *)node];
            for (NSView *child in node.subviews) [stack addObject:child];
        }
        for (NSButton *button in buttons) {
            if ([button.title containsString:@"启动"]) start = button;
            if ([button.title isEqualToString:@"编辑"]) edit = button;
        }
        Check(start != nil && edit != nil, "saved row keeps start and edit buttons");
        NSRect startInRow = [start convertRect:start.bounds toView:row];
        NSRect editInRow = [edit convertRect:edit.bounds toView:row];
        Check(NSContainsRect(row.bounds, startInRow), "start button stays inside row");
        Check(NSContainsRect(row.bounds, editInRow), "edit button stays inside row");
        Check(!FramesOverlap(startInRow, editInRow), "start and edit do not overlap");

        NSImageView *icon = nil;
        NSMutableArray<NSTextField *> *labels = [NSMutableArray array];
        NSMutableArray<NSView *> *walk = [NSMutableArray arrayWithObject:row];
        while (walk.count) {
            NSView *node = walk.lastObject;
            [walk removeLastObject];
            if ([node isKindOfClass:NSImageView.class] && icon == nil) icon = (NSImageView *)node;
            if ([node isKindOfClass:NSTextField.class]) [labels addObject:(NSTextField *)node];
            for (NSView *child in node.subviews) [walk addObject:child];
        }
        Check(icon != nil, "saved row keeps display icon");
        Check(labels.count >= 2, "saved row keeps name and detail labels");
        NSRect iconInRow = [icon convertRect:icon.bounds toView:row];
        NSMutableArray<NSTextField *> *visibleLabels = [NSMutableArray array];
        for (NSTextField *label in labels) {
            if (!label.hidden) [visibleLabels addObject:label];
        }
        [visibleLabels sortUsingComparator:^NSComparisonResult(NSTextField *a, NSTextField *b) {
            CGFloat ay = NSMaxY([a convertRect:a.bounds toView:row]);
            CGFloat by = NSMaxY([b convertRect:b.bounds toView:row]);
            if (ay > by) return NSOrderedAscending;
            if (ay < by) return NSOrderedDescending;
            return NSOrderedSame;
        }];
        Check(visibleLabels.count >= 1, "saved row exposes a visible name label");
        NSTextField *nameLabel = visibleLabels[0];
        NSRect nameInRow = [nameLabel convertRect:nameLabel.bounds toView:row];
        CGFloat nameAfterIcon = NSMinX(nameInRow) - NSMaxX(iconInRow);
        Check(nameAfterIcon >= 4.0 && nameAfterIcon <= 14.0,
              "name label leading edge follows icon by ~10pt");
        Check(NSMinX(editInRow) - NSMinX(nameInRow) > 80.0,
              "name stays near icon rather than trailing against edit");
        Check(nameLabel.alignment == NSTextAlignmentLeft,
              "name label uses explicit left text alignment");
        if (visibleLabels.count >= 2) {
            NSTextField *detailLabel = visibleLabels[1];
            NSRect detailInRow = [detailLabel convertRect:detailLabel.bounds toView:row];
            CGFloat detailAfterIcon = NSMinX(detailInRow) - NSMaxX(iconInRow);
            Check(detailAfterIcon >= 4.0 && detailAfterIcon <= 14.0,
                  "detail label leading edge follows icon by ~10pt");
            Check(detailLabel.alignment == NSTextAlignmentLeft,
                  "detail label uses explicit left text alignment");
        }
        for (NSTextField *label in labels) {
            Check(label.alignment == NSTextAlignmentLeft,
                  "saved row text fields use explicit left text alignment");
        }

        if (fullyVisible) {
            NSRect startInDoc = [start convertRect:start.bounds toView:document];
            NSRect editInDoc = [edit convertRect:edit.bounds toView:document];
            Check(NSContainsRect(visibleDoc, startInDoc), "visible row keeps start reachable");
            Check(NSContainsRect(visibleDoc, editInDoc), "visible row keeps edit reachable");
        }
    }
    if (rows.count > 0 && completeRows < 1) {
        fprintf(stderr, "FAIL complete saved row missing (rows=%lu viewportH=%.1f visibleDoc=%s)\n",
                (unsigned long)rows.count, viewportHeight, NSStringFromRect(visibleDoc).UTF8String);
        for (NSUInteger i = 0; i < MIN(rows.count, 3); i++) {
            NSView *row = rows[i];
            NSRect rowInDoc = [row convertRect:row.bounds toView:document];
            fprintf(stderr, "  row[%lu] doc=%s intersect=%s\n", (unsigned long)i,
                    NSStringFromRect(rowInDoc).UTF8String,
                    NSStringFromRect(NSIntersectionRect(visibleDoc, rowInDoc)).UTF8String);
        }
        exit(1);
    }
}

static void AssertContentSize(ADController *controller, NSSize requested) {
    NSSize actual = controller.window.contentView.bounds.size;
    Check(fabs(actual.width - requested.width) <= 0.5
          && fabs(actual.height - requested.height) <= 0.5,
          "contentView bounds match requested content size");
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
            AssertContentSize(controller, size);
            AssertCanvas(controller);
            AssertSavedSection(controller);
            if (savedCount == 30) {
                NSMutableArray<NSView *> *ambiguous = [NSMutableArray array];
                CollectAmbiguousViews(controller.window.contentView, ambiguous);
                Check(ambiguous.count == 0, "30-row whole window subtree has no ambiguous layout");
            }
            [controller.window close];
            printf("PASS panel size %.0fx%.0f saved=%lu\n", size.width, size.height, (unsigned long)savedCount);
        }
    }
}

static void RunAppearanceAndRefresh(void) {
    for (NSAppearance *appearance in @[
        [NSAppearance appearanceNamed:NSAppearanceNameAqua],
        [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua]
    ]) {
        NSApp.appearance = appearance;
        ADController *longNames = PanelController(30, NSMakeSize(760, 520), YES);
        longNames.window.appearance = appearance;
        [longNames.window.contentView layoutSubtreeIfNeeded];
        AssertContentSize(longNames, NSMakeSize(760, 520));
        AssertSavedSection(longNames);
        NSMutableArray<NSView *> *ambiguous = [NSMutableArray array];
        CollectAmbiguousViews(longNames.window.contentView, ambiguous);
        Check(ambiguous.count == 0, "30-row min window is unambiguous in both appearances");
        [longNames.window close];
    }

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

static void RunPreviewIdentity(void) {
    Check([ADController instancesRespondToSelector:@selector(installPreviewProfilesForState:)],
          "preview profile installer exists");
    ADController *controller = [[ADController alloc] init];
    controller.previewMode = YES;
    controller.previewState = @"multi";
    controller.previewSnapshot = PanelSnapshot(YES);
    NSMutableArray *snapshot = [controller.previewSnapshot mutableCopy];
    [snapshot addObject:@{@"displayID":@903, @"name":@"虚拟屏 2 · GrokBot", @"x":@7040, @"y":@0,
        @"logicalWidth":@1920, @"logicalHeight":@1080, @"isMain":@NO, @"isVirtual":@YES,
        @"isActive":@YES, @"isOnline":@YES}];
    controller.previewSnapshot = snapshot;
    [controller installPreviewProfilesForState:@"multi"];
    [controller buildWindow];
    [controller.window setContentSize:NSMakeSize(1000, 620)];
    [controller updateInventory];
    NSArray<YMSavedDisplayProfileRow *> *rows = [controller savedProfileRows];
    NSMutableSet<NSString *> *savedNames = [NSMutableSet set];
    for (YMSavedDisplayProfileRow *row in rows) [savedNames addObject:row.name];
    BOOL savedCodex = NO, savedGrok = NO, savedBlender = NO;
    for (NSString *name in savedNames) {
        if ([name containsString:@"Codex · Blender"]) savedBlender = YES;
        else if ([name containsString:@"Codex"]) savedCodex = YES;
        else if ([name containsString:@"GrokBot"]) savedGrok = YES;
    }
    Check(!savedCodex, "running Codex is not listed as stopped");
    Check(!savedGrok, "running GrokBot is not listed as stopped");
    Check(savedBlender, "stopped preview sibling stays in saved list");
    BOOL foundCodex = NO, foundGrok = NO;
    for (YMManagedDisplay *profile in controller.displayProfiles) {
        if ([profile.friendlyName isEqualToString:@"Codex"]) {
            foundCodex = profile.display.isCreated && profile.display.displayID == 902;
        }
        if ([profile.friendlyName isEqualToString:@"GrokBot"]) {
            foundGrok = profile.display.isCreated && profile.display.displayID == 903;
        }
    }
    Check(foundCodex, "preview Codex uses owned fake running display 902");
    Check(foundGrok, "preview GrokBot uses owned fake running display 903");
    [controller.window close];
    printf("PASS preview running/stopped identity\n");
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        Check(NSApp.activationPolicy == NSApplicationActivationPolicyProhibited, "starts prohibited");
        RunSizeMatrix();
        RunAppearanceAndRefresh();
        RunEntryActions();
        RunPreviewIdentity();
        Check(!NSApp.isActive, "fixture never activates");
        printf("Display profile panel tests passed.\n");
        return 0;
    }
}
