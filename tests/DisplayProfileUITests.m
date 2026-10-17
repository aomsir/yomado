#import <AppKit/AppKit.h>
#import <stdio.h>
#import <stdlib.h>

#import "DisplayProfileEditor.m"

@interface YMMarkedTextFixture : NSTextView
@property(nonatomic) BOOL fixtureMarked;
@end
@implementation YMMarkedTextFixture
- (BOOL)hasMarkedText { return self.fixtureMarked; }
@end

@interface YMNameFieldFixture : NSTextField
@property(nonatomic, strong) YMMarkedTextFixture *fixtureEditor;
@end
@implementation YMNameFieldFixture
- (NSText *)currentEditor { return self.fixtureEditor; }
- (void)setStringValue:(NSString *)stringValue {
    [super setStringValue:stringValue];
    self.fixtureEditor.string = [stringValue copy] ?: @"";
}
- (NSString *)stringValue {
    if (self.fixtureEditor) return [self.fixtureEditor.string copy] ?: @"";
    return [super stringValue];
}
@end

static void Check(BOOL condition, const char *message) {
    if (!condition) {
        fprintf(stderr, "FAIL %s\n", message);
        exit(1);
    }
}

static YMNameFieldFixture *InstallNameFixture(YMDisplayProfileEditor *editor) {
    YMNameFieldFixture *field = [[YMNameFieldFixture alloc] initWithFrame:NSZeroRect];
    field.delegate = editor;
    field.fixtureEditor = [[YMMarkedTextFixture alloc] init];
    field.stringValue = editor.nameField.stringValue ?: @"";
    editor.nameField = field;
    return field;
}

static void DraftValidation(void) {
    NSError *error = nil;
    YMDisplayProfileDraft *source = [[YMDisplayProfileDraft alloc]
        initWithName:@"  Codex · Blender  " width:1920 hiDPI:YES];
    YMDisplayProfileDraft *value = [source normalizedCopyValidatingDisplaySettings:YES error:&error];
    Check(value != nil && error == nil, "valid draft accepted");
    Check([value.name isEqualToString:@"Codex · Blender"], "name normalized");
    source.name = @"changed";
    Check([value.name isEqualToString:@"Codex · Blender"], "accepted draft is a copy");
    for (NSString *name in @[@"", @" \n ", @"a\nb", @"a\tb",
                             [@"x" stringByPaddingToLength:61 withString:@"x" startingAtIndex:0]]) {
        YMDisplayProfileDraft *bad = [[YMDisplayProfileDraft alloc] initWithName:name width:1920 hiDPI:NO];
        error = nil;
        Check([bad normalizedCopyValidatingDisplaySettings:YES error:&error] == nil && error != nil,
              "invalid name rejected with error");
    }
    YMDisplayProfileDraft *legacy = [[YMDisplayProfileDraft alloc] initWithName:@"Name" width:800 hiDPI:NO];
    Check([legacy normalizedCopyValidatingDisplaySettings:YES error:&error] == nil, "new settings reject unknown size");
    Check([legacy normalizedCopyValidatingDisplaySettings:NO error:&error] != nil, "rename does not rewrite legacy dimensions");
}

static void EditorAcceptance(void) {
    YMDisplayProfileDraft *draft = [[YMDisplayProfileDraft alloc] initWithName:@"" width:1920 hiDPI:NO];
    YMDisplayProfileEditor *editor = [[YMDisplayProfileEditor alloc] initWithMode:YMDisplayProfileEditorModeCreate draft:draft];
    (void)editor.window;
    __block NSUInteger submits = 0, ends = 0;
    __block BOOL permit = NO;
    editor.submitHandler = ^BOOL(YMDisplayProfileDraft *value, NSError **error) {
        submits++;
        Check([value.name isEqualToString:@"Codex"], "handler receives normalized value");
        if (!permit && error) {
            *error = [NSError errorWithDomain:@"fixture" code:1
                                    userInfo:@{NSLocalizedDescriptionKey:@"正在恢复显示排列，请稍后重试。"}];
        }
        return permit;
    };
    editor.endHandler = ^(BOOL accepted) {
        Check(accepted, "accepted result");
        ends++;
    };
    editor.nameField.stringValue = @"   ";
    [editor submit:nil];
    Check(submits == 0 && ends == 0, "invalid value never reaches controller");
    editor.nameField.stringValue = @" Codex ";
    [editor submit:nil];
    Check(submits == 1 && ends == 0 && !editor.errorLabel.hidden, "rejected request keeps form");
    Check([editor.nameField.stringValue isEqualToString:@" Codex "], "rejection preserves draft");
    permit = YES;
    [editor submit:nil];
    [editor submit:nil];
    [editor cancel:nil];
    Check(submits == 2 && ends == 1, "accepted form finishes exactly once");
}

static void EditorCancel(void) {
    YMDisplayProfileDraft *draft = [[YMDisplayProfileDraft alloc] initWithName:@"Original" width:2560 hiDPI:YES];
    YMDisplayProfileEditor *editor = [[YMDisplayProfileEditor alloc] initWithMode:YMDisplayProfileEditorModeEdit draft:draft];
    (void)editor.window;
    __block NSUInteger submits = 0, ends = 0;
    __block BOOL endAccepted = YES;
    editor.submitHandler = ^BOOL(YMDisplayProfileDraft *value, NSError **error) {
        (void)value;
        (void)error;
        submits++;
        return YES;
    };
    editor.endHandler = ^(BOOL accepted) {
        endAccepted = accepted;
        ends++;
    };
    editor.nameField.stringValue = @" Changed ";
    for (NSButton *button in editor.resolutionButtons) {
        button.state = (button.tag == 1920) ? NSControlStateValueOn : NSControlStateValueOff;
    }
    editor.hiDPIButton.state = NSControlStateValueOff;
    [editor cancel:nil];
    Check(submits == 0, "cancel never submits");
    Check(ends == 1 && endAccepted == NO, "cancel ends once with NO");
    Check([editor.initialDraft.name isEqualToString:@"Original"], "cancel leaves initial draft untouched");
    Check(editor.initialDraft.width == 2560 && editor.initialDraft.hiDPI == YES, "cancel leaves display settings untouched");
}

static void EditorRenameMode(void) {
    YMDisplayProfileDraft *draft = [[YMDisplayProfileDraft alloc] initWithName:@"Running" width:800 hiDPI:NO];
    YMDisplayProfileEditor *editor = [[YMDisplayProfileEditor alloc] initWithMode:YMDisplayProfileEditorModeRename draft:draft];
    (void)editor.window;
    __block YMDisplayProfileDraft *submitted = nil;
    __block NSUInteger ends = 0;
    editor.submitHandler = ^BOOL(YMDisplayProfileDraft *value, NSError **error) {
        (void)error;
        submitted = value;
        return YES;
    };
    editor.endHandler = ^(BOOL accepted) {
        Check(accepted, "rename accepted");
        ends++;
    };
    for (NSButton *button in editor.resolutionButtons) {
        Check(button.hidden, "rename hides resolution");
    }
    Check(editor.hiDPIButton.hidden && editor.pixelNote.hidden, "rename hides display settings");
    editor.nameField.stringValue = @" Renamed ";
    editor.hiDPIButton.state = NSControlStateValueOn;
    for (NSButton *button in editor.resolutionButtons) {
        button.state = (button.tag == 2560) ? NSControlStateValueOn : NSControlStateValueOff;
    }
    [editor submit:nil];
    Check(submitted != nil, "rename submits");
    Check([submitted.name isEqualToString:@"Renamed"], "rename normalizes name");
    Check(submitted.width == 800 && submitted.hiDPI == NO, "rename does not rewrite width or hiDPI");
    Check(ends == 1, "rename finishes once");
}

static void EditorCommandsAndMarkedText(void) {
    YMDisplayProfileDraft *draft = [[YMDisplayProfileDraft alloc] initWithName:@"Base" width:1920 hiDPI:NO];
    YMDisplayProfileEditor *editor = [[YMDisplayProfileEditor alloc] initWithMode:YMDisplayProfileEditorModeEdit draft:draft];
    (void)editor.window;
    YMNameFieldFixture *field = InstallNameFixture(editor);
    __block NSUInteger submits = 0, ends = 0;
    __block BOOL endAccepted = YES;
    editor.submitHandler = ^BOOL(YMDisplayProfileDraft *value, NSError **error) {
        (void)error;
        submits++;
        Check([value.name isEqualToString:@"Entered"], "newline submit normalizes");
        return YES;
    };
    editor.endHandler = ^(BOOL accepted) {
        endAccepted = accepted;
        ends++;
    };

    field.fixtureEditor.fixtureMarked = YES;
    field.stringValue = @"Codex";
    Check([editor control:field textView:field.fixtureEditor doCommandBySelector:@selector(cancelOperation:)] == NO,
          "marked text leaves cancel to the field editor");
    Check([editor control:field textView:field.fixtureEditor doCommandBySelector:@selector(insertNewline:)] == NO,
          "marked text leaves newline to the field editor");
    [editor submit:nil];
    Check(submits == 0 && ends == 0, "marked text blocks submit action");

    field.fixtureEditor.fixtureMarked = NO;
    Check([editor control:field textView:field.fixtureEditor doCommandBySelector:@selector(deleteBackward:)] == NO,
          "unrelated commands stay unhandled");
    Check([editor control:field textView:field.fixtureEditor doCommandBySelector:@selector(cancelOperation:)] == YES,
          "clear cancelOperation is handled");
    Check(submits == 0 && ends == 1 && endAccepted == NO, "cancelOperation ends once without submit");

    YMDisplayProfileEditor *enterEditor =
        [[YMDisplayProfileEditor alloc] initWithMode:YMDisplayProfileEditorModeCreate
                                               draft:[[YMDisplayProfileDraft alloc] initWithName:@"" width:1920 hiDPI:NO]];
    (void)enterEditor.window;
    YMNameFieldFixture *enterField = InstallNameFixture(enterEditor);
    __block NSUInteger enterSubmits = 0, enterEnds = 0;
    enterEditor.submitHandler = ^BOOL(YMDisplayProfileDraft *value, NSError **error) {
        (void)error;
        enterSubmits++;
        Check([value.name isEqualToString:@"Entered"], "insertNewline reaches normalized gate");
        return YES;
    };
    enterEditor.endHandler = ^(BOOL accepted) {
        Check(accepted, "insertNewline accepted");
        enterEnds++;
    };
    enterField.fixtureEditor.fixtureMarked = NO;
    enterField.stringValue = @"  Entered  ";
    Check([enterEditor control:enterField textView:enterField.fixtureEditor
        doCommandBySelector:@selector(insertNewline:)] == YES, "insertNewline handled when clear");
    Check(enterSubmits == 1 && enterEnds == 1, "insertNewline submits through the same gate");
}

static void EditorPixelNote(void) {
    YMDisplayProfileDraft *draft = [[YMDisplayProfileDraft alloc] initWithName:@"Note" width:1920 hiDPI:NO];
    YMDisplayProfileEditor *editor = [[YMDisplayProfileEditor alloc] initWithMode:YMDisplayProfileEditorModeCreate draft:draft];
    (void)editor.window;

    void (^assertNote)(NSUInteger, BOOL, NSUInteger, NSUInteger) =
        ^(NSUInteger width, BOOL hiDPI, NSUInteger logicH, NSUInteger scale) {
            for (NSButton *button in editor.resolutionButtons) {
                button.state = (button.tag == (NSInteger)width) ? NSControlStateValueOn : NSControlStateValueOff;
            }
            editor.hiDPIButton.state = hiDPI ? NSControlStateValueOn : NSControlStateValueOff;
            [editor refreshPixelNote];
            NSString *note = editor.pixelNote.stringValue;
            NSString *logic = [NSString stringWithFormat:@"%lu × %lu", (unsigned long)width, (unsigned long)logicH];
            NSString *pixels = [NSString stringWithFormat:@"%lu × %lu",
                                (unsigned long)(width * scale), (unsigned long)(logicH * scale)];
            Check([note containsString:logic], "pixel note includes logical size");
            Check([note containsString:pixels], "pixel note includes render size");
        };

    assertNote(1920, NO, 1080, 1);
    assertNote(1920, YES, 1080, 2);
    assertNote(2560, NO, 1440, 1);
    assertNote(2560, YES, 1440, 2);
}

int main(void) {
    @autoreleasepool {
        // Hidden AppKit fixture: ActivationPolicyProhibited, never orderFront/activate.
        // Does not claim coverage of real hardware keyboards or input methods.
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        DraftValidation();
        printf("PASS draft validation\n");
        EditorAcceptance();
        printf("PASS editor acceptance\n");
        EditorCancel();
        printf("PASS editor cancel\n");
        EditorRenameMode();
        printf("PASS editor rename mode\n");
        EditorCommandsAndMarkedText();
        printf("PASS editor commands and marked text\n");
        EditorPixelNote();
        printf("PASS editor pixel note\n");
        return 0;
    }
}
