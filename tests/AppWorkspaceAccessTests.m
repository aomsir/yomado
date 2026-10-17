#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreGraphics/CoreGraphics.h>
#import <stdio.h>
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

static NSDictionary *Frame(double x, double y, double w, double h) {
    return @{@"x": @(x), @"y": @(y), @"width": @(w), @"height": @(h)};
}

static NSDictionary *Identity(pid_t pid, CGWindowID windowID, uint64_t startSeconds) {
    return @{@"pid": @(pid), @"windowID": @(windowID), @"startSeconds": @(startSeconds),
             @"startMicroseconds": @7, @"bundleID": @"test.fixture.app"};
}

static id AXPoint(CGPoint point) {
    return CFBridgingRelease(AXValueCreate(kAXValueCGPointType, &point));
}

static id AXSize(CGSize size) {
    return CFBridgingRelease(AXValueCreate(kAXValueCGSizeType, &size));
}

@interface YMSystemWorkspaceWindowAccess (Testing)
- (id)copyWindowsForApplication:(NSRunningApplication *)application;
- (id)copyAttribute:(CFStringRef)attribute element:(id)element;
- (NSNumber *)isAttributeSettable:(CFStringRef)attribute element:(id)element;
- (NSDictionary *)identityForElement:(id)element;
- (BOOL)writeAttribute:(CFStringRef)attribute value:(id)value element:(id)element;
- (NSTimeInterval)monotonicTime;
@end

@interface YMAccessAppStub : NSObject
@property(nonatomic) pid_t processIdentifier;
@property(nonatomic, getter=isTerminated) BOOL terminated;
@property(nonatomic, copy) NSString *bundleIdentifier;
@end
@implementation YMAccessAppStub
@end

@interface YMAccessFixture : YMSystemWorkspaceWindowAccess
@property(nonatomic, strong) YMAccessAppStub *application;
@property(nonatomic, strong) id element;
@property(nonatomic, strong) NSMutableArray<NSString *> *attributes;
@property(nonatomic) NSUInteger writeCount;
@property(nonatomic) NSUInteger windowCopyCount;
@property(nonatomic) NSTimeInterval clock;
@property(nonatomic) NSTimeInterval clockStep;
@property(nonatomic, strong) NSMutableArray *windowElements;
@property(nonatomic, strong) NSMutableDictionary *attributeValues;
@property(nonatomic, strong) NSMutableDictionary *settableValues;
@property(nonatomic, strong) NSMutableDictionary *identities;
@property(nonatomic) BOOL failWindowCopy;
@property(nonatomic) BOOL failAttribute;
@property(nonatomic, copy) NSString *failAttributeName;
@property(nonatomic) NSUInteger attributeFailAfter;
@property(nonatomic) NSUInteger attributeCalls;
@property(nonatomic) BOOL terminateAfterWindows;
@property(nonatomic, strong) NSMutableArray *visibleOverride;
@end

@implementation YMAccessFixture
- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _attributes = [NSMutableArray array];
    _windowElements = [NSMutableArray array];
    _attributeValues = [NSMutableDictionary dictionary];
    _settableValues = [NSMutableDictionary dictionary];
    _identities = [NSMutableDictionary dictionary];
    _clock = 0;
    _clockStep = 0;
    _application = [YMAccessAppStub new];
    _application.processIdentifier = 4242;
    _application.bundleIdentifier = @"test.fixture.app";
    _element = [NSString stringWithFormat:@"window-%p", self];
    return self;
}

- (void)installOrdinaryWindow:(id)element identity:(NSDictionary *)identity frame:(NSDictionary *)frame {
    [self.windowElements addObject:element];
    NSString *key = [NSString stringWithFormat:@"%p", element];
    self.identities[key] = identity;
    NSMutableDictionary *attrs = [NSMutableDictionary dictionary];
    attrs[(__bridge NSString *)kAXRoleAttribute] = (__bridge NSString *)kAXWindowRole;
    attrs[(__bridge NSString *)kAXSubroleAttribute] = (__bridge NSString *)kAXStandardWindowSubrole;
    attrs[(__bridge NSString *)kAXMinimizedAttribute] = @NO;
    attrs[(__bridge NSString *)kAXPositionAttribute] =
        AXPoint(CGPointMake([frame[@"x"] doubleValue], [frame[@"y"] doubleValue]));
    attrs[(__bridge NSString *)kAXSizeAttribute] =
        AXSize(CGSizeMake([frame[@"width"] doubleValue], [frame[@"height"] doubleValue]));
    self.attributeValues[key] = attrs;
    self.settableValues[key] = [@{
        (__bridge NSString *)kAXPositionAttribute: @YES,
        (__bridge NSString *)kAXSizeAttribute: @YES
    } mutableCopy];
}

- (NSTimeInterval)monotonicTime {
    return self.clock;
}

- (id)copyWindowsForApplication:(NSRunningApplication *)application {
    (void)application;
    self.windowCopyCount++;
    if (self.failWindowCopy) return nil;
    if (self.terminateAfterWindows) self.application.terminated = YES;
    self.clock += self.clockStep;
    return self.windowElements.copy;
}

- (id)copyAttribute:(CFStringRef)attribute element:(id)element {
    NSString *name = (__bridge NSString *)attribute;
    [self.attributes addObject:name];
    static NSSet *allowed;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        allowed = [NSSet setWithArray:@[
            (__bridge NSString *)kAXRoleAttribute,
            (__bridge NSString *)kAXSubroleAttribute,
            (__bridge NSString *)kAXMinimizedAttribute,
            (__bridge NSString *)kAXPositionAttribute,
            (__bridge NSString *)kAXSizeAttribute
        ]];
    });
    if (![allowed containsObject:name]) {
        Check(NO, [NSString stringWithFormat:@"attribute whitelist violated: %@", name]);
        return nil;
    }
    self.attributeCalls++;
    self.clock += self.clockStep;
    if (self.failAttribute &&
        (!self.failAttributeName.length || [self.failAttributeName isEqual:name]) &&
        (!self.attributeFailAfter || self.attributeCalls >= self.attributeFailAfter))
        return nil;
    NSString *key = [NSString stringWithFormat:@"%p", element];
    return self.attributeValues[key][name];
}

- (NSNumber *)isAttributeSettable:(CFStringRef)attribute element:(id)element {
    NSString *name = (__bridge NSString *)attribute;
    [self.attributes addObject:[@"settable:" stringByAppendingString:name]];
    self.clock += self.clockStep;
    NSString *key = [NSString stringWithFormat:@"%p", element];
    NSNumber *value = self.settableValues[key][name];
    return value;
}

- (NSDictionary *)identityForElement:(id)element {
    self.clock += self.clockStep;
    if (self.application.terminated) return nil;
    NSString *key = [NSString stringWithFormat:@"%p", element];
    return self.identities[key];
}

- (BOOL)writeAttribute:(CFStringRef)attribute value:(id)value element:(id)element {
    (void)attribute;
    (void)value;
    (void)element;
    self.writeCount++;
    self.clock += self.clockStep;
    return YES;
}

- (BOOL)accessibilityTrusted { return YES; }

- (nullable NSArray<NSDictionary *> *)visibleWindows {
    return self.visibleOverride;
}

- (nullable id)resolveIdentity:(NSDictionary *)identity error:(NSError **)error {
    for (id element in self.windowElements) {
        NSString *key = [NSString stringWithFormat:@"%p", element];
        if ([self.identities[key] isEqual:identity]) return element;
    }
    if (error) *error = [NSError errorWithDomain:@"fixture" code:1
                                       userInfo:@{NSLocalizedDescriptionKey: @"missing"}];
    return nil;
}
@end

static YMAccessFixture *OrdinaryFixture(void) {
    YMAccessFixture *fixture = [YMAccessFixture new];
    NSDictionary *identity = Identity(4242, 1490, 1000);
    [fixture installOrdinaryWindow:fixture.element identity:identity frame:Frame(100, 200, 400, 300)];
    return fixture;
}

int main(void) {
    @autoreleasepool {
        // Step 1 red-light assertions against a failure shell / incomplete impl.
        YMAccessFixture *fixture = OrdinaryFixture();
        NSDictionary *replacement = Identity(4242, 1490, 1001);
        NSDictionary *observation = [fixture observeApplication:(id)fixture.application deadline:1.0];
        Check([observation[@"windows"] count] == 1, @"metadata adapter returns one ordinary identity");
        Check([observation[@"complete"] boolValue], @"all metadata was confirmed");
        Check(![fixture.attributes containsObject:(__bridge NSString *)kAXTitleAttribute],
              @"never read titles");
        Check(![fixture setPosition:CGPointMake(10, 20) element:fixture.element expectedIdentity:replacement],
              @"writer refuses a changed lifecycle identity");
        Check(fixture.writeCount == 0, @"identity failure causes no native write");

        // Budget: stop before the next AX call once the deadline is reached.
        // Enumeration + eight first-window primitives cost exactly 0.18 with step 0.02.
        YMAccessFixture *budget = OrdinaryFixture();
        id second = @"window-second";
        [budget installOrdinaryWindow:second identity:Identity(4242, 1491, 1000) frame:Frame(10, 10, 200, 200)];
        budget.clockStep = 0.02;
        NSDictionary *timed = [budget observeApplication:(id)budget.application deadline:0.18];
        Check(![timed[@"complete"] boolValue], @"budget exhaustion marks incomplete");
        Check([timed[@"windows"] count] == 1, @"budget exhaustion keeps earlier windows");
        Check([timed[@"windows"] count] < 2, @"budget exhaustion stops before later windows");

        // Window cap: the 129th window is never read.
        YMAccessFixture *capped = [YMAccessFixture new];
        for (NSUInteger i = 0; i < 129; i++) {
            id element = [NSString stringWithFormat:@"cap-%lu", (unsigned long)i];
            [capped installOrdinaryWindow:element identity:Identity(4242, (CGWindowID)(2000 + i), 1000)
                                    frame:Frame(10, 10, 200, 200)];
        }
        NSUInteger attrsBefore = capped.attributes.count;
        NSDictionary *over = [capped observeApplication:(id)capped.application deadline:100.0];
        Check(![over[@"complete"] boolValue], @"more than 128 windows is incomplete");
        Check([over[@"windows"] count] == 0, @"never pretend a truncated list is complete");
        Check(capped.attributes.count == attrsBefore, @"129th window is not read");

        // One enumeration per observeApplication.
        YMAccessFixture *once = OrdinaryFixture();
        [once observeApplication:(id)once.application deadline:10.0];
        Check(once.windowCopyCount == 1, @"observeApplication enumerates AXWindows once");

        // Enumeration failure is not an empty success.
        YMAccessFixture *enumFail = OrdinaryFixture();
        enumFail.failWindowCopy = YES;
        NSDictionary *failedEnum = [enumFail observeApplication:(id)enumFail.application deadline:10.0];
        Check(![failedEnum[@"complete"] boolValue], @"enumeration failure is incomplete");
        Check([failedEnum[@"windows"] count] == 0, @"enumeration failure yields no windows");
        Check([failedEnum[@"reason"] length] > 0, @"enumeration failure exposes a reason");

        YMAccessFixture *empty = [YMAccessFixture new];
        NSDictionary *emptyObs = [empty observeApplication:(id)empty.application deadline:10.0];
        Check([emptyObs[@"complete"] boolValue], @"true empty enumeration can be complete");
        Check([emptyObs[@"windows"] count] == 0, @"true empty enumeration returns no windows");

        // Missing role / minimized / frame → incomplete, not false defaults.
        YMAccessFixture *missingRole = OrdinaryFixture();
        NSString *roleKey = [NSString stringWithFormat:@"%p", missingRole.element];
        [missingRole.attributeValues[roleKey] removeObjectForKey:(__bridge NSString *)kAXRoleAttribute];
        missingRole.failAttribute = YES;
        missingRole.failAttributeName = (__bridge NSString *)kAXRoleAttribute;
        NSDictionary *noRole = [missingRole observeApplication:(id)missingRole.application deadline:10.0];
        Check(![noRole[@"complete"] boolValue], @"missing role is incomplete");

        YMAccessFixture *missingMin = OrdinaryFixture();
        missingMin.failAttribute = YES;
        missingMin.failAttributeName = (__bridge NSString *)kAXMinimizedAttribute;
        NSDictionary *noMin = [missingMin observeApplication:(id)missingMin.application deadline:10.0];
        Check(![noMin[@"complete"] boolValue], @"missing minimized is incomplete");
        Check([noMin[@"windows"] count] == 0, @"missing minimized does not invent not-minimized");

        YMAccessFixture *missingFrame = OrdinaryFixture();
        missingFrame.failAttribute = YES;
        missingFrame.failAttributeName = (__bridge NSString *)kAXPositionAttribute;
        NSDictionary *noFrame = [missingFrame observeApplication:(id)missingFrame.application deadline:10.0];
        Check(![noFrame[@"complete"] boolValue], @"missing frame is incomplete");

        // Private identity unavailable.
        YMAccessFixture *noID = OrdinaryFixture();
        [noID.identities removeAllObjects];
        NSDictionary *noIdentity = [noID observeApplication:(id)noID.application deadline:10.0];
        Check(![noIdentity[@"complete"] boolValue], @"unavailable private window ID is incomplete");

        // Duplicate identities.
        YMAccessFixture *dup = OrdinaryFixture();
        id dupElement = @"window-dup";
        [dup installOrdinaryWindow:dupElement identity:Identity(4242, 1490, 1000) frame:Frame(1, 1, 100, 100)];
        NSDictionary *dupObs = [dup observeApplication:(id)dup.application deadline:10.0];
        Check(![dupObs[@"complete"] boolValue], @"duplicate identities are incomplete");

        // Process exit during enumeration.
        YMAccessFixture *died = OrdinaryFixture();
        died.terminateAfterWindows = YES;
        NSDictionary *diedObs = [died observeApplication:(id)died.application deadline:10.0];
        Check(![diedObs[@"complete"] boolValue], @"process exit during enumeration is incomplete");

        // setSize also refuses a changed identity with no write.
        YMAccessFixture *sizeFixture = OrdinaryFixture();
        Check(![sizeFixture setSize:CGSizeMake(10, 20) element:sizeFixture.element expectedIdentity:replacement],
              @"setSize refuses a changed lifecycle identity");
        Check(sizeFixture.writeCount == 0, @"setSize identity failure causes no native write");

        // Successful identity write path records a write without claiming landing.
        YMAccessFixture *writer = OrdinaryFixture();
        NSDictionary *okIdentity = Identity(4242, 1490, 1000);
        Check([writer setPosition:CGPointMake(11, 22) element:writer.element expectedIdentity:okIdentity],
              @"matching identity allows position write API");
        Check(writer.writeCount == 1, @"matching identity performs one native write");
        Check(![writer.attributes containsObject:(__bridge NSString *)kAXTitleAttribute],
              @"writer never reads titles");

        // observeElement returns a full record or nil.
        YMAccessFixture *one = OrdinaryFixture();
        NSDictionary *record = [one observeElement:one.element];
        Check(record != nil, @"observeElement returns a record");
        Check([record[@"ordinary"] boolValue], @"observeElement marks ordinary");
        Check([record[@"readable"] boolValue], @"observeElement marks readable");
        Check(record[@"element"] == one.element, @"observeElement retains element");
        Check(YMWorkspaceIdentityValid(record[@"identity"]), @"observeElement supplies valid identity");
        Check(YMWorkspaceGeometry(record[@"frame"]) != nil, @"observeElement supplies frame");

        YMAccessFixture *bad = OrdinaryFixture();
        bad.failAttribute = YES;
        bad.failAttributeName = (__bridge NSString *)kAXMinimizedAttribute;
        Check([bad observeElement:bad.element] == nil, @"observeElement fails closed on missing minimized");

        if (failures) {
            fprintf(stderr, "%u of %u App workspace access checks failed.\n",
                    (unsigned)failures, (unsigned)checks);
            return 1;
        }
        printf("Passed %u App workspace access checks; no displays, applications or GUI were accessed.\n",
               (unsigned)checks);
        return 0;
    }
}
