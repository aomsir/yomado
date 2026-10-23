// Disposable hosted-macOS acceptance fixture. Never launch on a user's desktop.
#import <AppKit/AppKit.h>
#import "AutomaticUpdater.h"
#import "UpdateWorkspaceRecovery.h"
#import "UpdateRuntimeWorkspace.h"
#import <fcntl.h>
#import <unistd.h>

@interface YMUpdateRuntimeFixture : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) NSTextField *label;
@property(nonatomic, strong) YMAutomaticUpdater *updater;
@property(nonatomic, strong) YMUpdateWorkspaceRecovery *recovery;
@property(nonatomic, copy) NSString *directory;
@property(nonatomic, copy) NSString *scenario;
@property(nonatomic, copy) NSString *build;
@property(nonatomic) BOOL cancellationSent;
@property(nonatomic, strong) YMUpdateRuntimeWorkspace *workspace;
- (void)beginUpdate;
- (void)completeRecovery:(NSArray<NSDictionary *> *)profiles;
- (void)record:(NSString *)event values:(NSDictionary *)values;
@end

@implementation YMUpdateRuntimeFixture
- (void)record:(NSString *)event values:(NSDictionary *)values {
    NSMutableDictionary *record = [@{@"event":event, @"build":self.build,
        @"pid":@(getpid()), @"time":@(NSDate.date.timeIntervalSince1970)} mutableCopy];
    [record addEntriesFromDictionary:values ?: @{}];
    NSData *json = [NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:NULL];
    NSMutableData *line = json.mutableCopy; [line appendBytes:"\n" length:1];
    int descriptor = open([self.directory stringByAppendingPathComponent:@"events.jsonl"].fileSystemRepresentation,
                          O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (descriptor < 0 || write(descriptor, line.bytes, line.length) != (ssize_t)line.length) _exit(4);
    close(descriptor);
    self.label.stringValue = [NSString stringWithFormat:@"yomado update fixture\nBuild %@ · %@\n%@", self.build, self.scenario, event];
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    NSBundle *bundle = NSBundle.mainBundle;
    self.directory = [bundle objectForInfoDictionaryKey:@"YMFixtureEvidenceDirectory"];
    self.scenario = [bundle objectForInfoDictionaryKey:@"YMFixtureScenario"];
    self.build = [bundle objectForInfoDictionaryKey:@"CFBundleVersion"];
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(120, 180, 720, 360)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"Isolated yomado update acceptance";
    self.window.releasedWhenClosed = NO;
    self.label = [NSTextField labelWithString:@"Starting isolated updater fixture"];
    self.label.frame = NSMakeRect(30, 60, 660, 250);
    self.label.font = [NSFont systemFontOfSize:28 weight:NSFontWeightMedium];
    self.label.maximumNumberOfLines = 5;
    [self.window.contentView addSubview:self.label];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    Class backendClass = NSClassFromString(@"YMNativeUpdateWorkspaceBackend");
    id<YMUpdateWorkspaceRecoveryBackend> backend = [backendClass new];
    if (!backend) { [self record:@"fixture-failure" values:@{@"reason":@"native backend missing"}]; return; }
    self.recovery = [[YMUpdateWorkspaceRecovery alloc]
        initWithDirectoryURL:[NSURL fileURLWithPath:[self.directory stringByAppendingPathComponent:@"journal"]]
        backend:backend];
    [self record:@"launched" values:@{@"bundleID":bundle.bundleIdentifier,
        @"windowID":@(self.window.windowNumber), @"ownedDisplayCount":@0}];
    if ([self.scenario isEqualToString:@"occupied"]) {
        __weak YMUpdateRuntimeFixture *owner=self;
        self.workspace=[[YMUpdateRuntimeWorkspace alloc] initWithDirectory:self.directory
            workPID:[[bundle objectForInfoDictionaryKey:@"YMFixtureWorkPID"] intValue]
            probePID:[[bundle objectForInfoDictionaryKey:@"YMFixtureProbePID"] intValue]
            backend:backend record:^(NSString *event,NSDictionary *values) { [owner record:event values:values]; }];
    }
    if ([self.build isEqualToString:@"2"]) {
        NSError *error=nil;
        NSArray *profiles=[self.recovery pendingProfilesWithError:&error];
        if (!profiles || error || (!self.workspace && profiles.count)) {
            [self record:@"recovery-failed" values:@{@"errorDomain":error.domain ?: @"",@"errorCode":@(error.code)}]; return;
        }
        if (self.workspace) {
            [self.workspace recreateProfiles:profiles completion:^(BOOL ready,NSError *failure) {
                if (ready) [self completeRecovery:self.workspace.profiles];
                else [self record:@"recovery-failed" values:@{@"errorDomain":failure.domain ?: @"",@"errorCode":@(failure.code)}];
            }];
        } else [self completeRecovery:profiles];
        return;
    }
    if (self.workspace) {
        [self.workspace prepareOccupiedWorkspace:^(BOOL ready,NSError *failure) {
            if (ready) [self beginUpdate];
            else [self record:@"fixture-failure" values:@{@"errorDomain":failure.domain ?: @"",@"errorCode":@(failure.code)}];
        }];
    } else [self beginUpdate];
}
- (void)completeRecovery:(NSArray<NSDictionary *> *)profiles {
    NSError *error=nil;
    NSString *phase=@"production-restore";
    BOOL restored=[self.recovery restoreWithProfiles:profiles error:&error];
    if (restored) {
        phase=@"fixture-verification";
        restored=!self.workspace || [self.workspace verifyRestoredWorkspace:&error];
    }
    if (restored) {
        phase=@"complete-restoration";
        restored=[self.recovery completeRestoration:&error];
    }
    if (!restored) [self.workspace recordRecoveryFailureDiagnostic];
    BOOL consumed=![NSFileManager.defaultManager fileExistsAtPath:
        [self.directory stringByAppendingPathComponent:@"journal/restart.json"]];
    [self record:restored && consumed ? @"updated-and-recovered" : @"recovery-failed"
        values:@{@"restored":@(restored),@"journalConsumed":@(consumed),@"phase":phase,
            @"errorDomain":error.domain ?: @"",@"errorCode":@(error.code),
            @"errorDescription":[error.domain isEqual:YMUpdateWorkspaceRecoveryErrorDomain] ? error.localizedDescription : @""}];
}
- (void)beginUpdate {
    NSBundle *bundle=NSBundle.mainBundle;
    self.updater = [[YMAutomaticUpdater alloc] initWithHostBundle:bundle];
    __weak YMUpdateRuntimeFixture *weakSelf = self;
    self.updater.stateDidChange = ^{
        YMUpdateRuntimeFixture *owner = weakSelf;
        [owner record:@"updater-state" values:@{@"status":@(owner.updater.status),
            @"progress":@(owner.updater.progress), @"busy":@(owner.updater.busy),
            @"authorized":@(owner.updater.installationAuthorized), @"userInitiated":@(owner.updater.userInitiated)}];
        if ([owner.scenario isEqualToString:@"cancel"] && !owner.cancellationSent && owner.updater.canCancel &&
            owner.updater.status == YMAutomaticUpdateDownloading && owner.updater.progress > 0) {
            owner.cancellationSent = YES;
            [owner record:@"cancel-requested" values:@{}];
            [owner.updater cancel];
        }
    };
    self.updater.errorHandler = ^(NSError *error, BOOL initiated) {
        NSMutableArray *chain = [NSMutableArray array];
        for (NSError *current = error; current && chain.count < 8; current = current.userInfo[NSUnderlyingErrorKey])
            [chain addObject:@{@"domain":current.domain ?: @"", @"code":@(current.code)}];
        [weakSelf record:@"updater-error" values:@{@"domain":error.domain ?: @"", @"code":@(error.code),
            @"chain":chain, @"userInitiated":@(initiated)}];
    };
    self.updater.prepareForInstallation = ^(YMUpdatePreparationCompletion completion) {
        YMUpdateRuntimeFixture *owner = weakSelf;
        [owner record:@"prepare-requested" values:@{}];
        if ([owner.scenario isEqualToString:@"gate-veto"]) {
            [owner record:@"gate-veto" values:@{}];
            completion(NO, [NSError errorWithDomain:@"fixture.workspace-busy" code:1 userInfo:nil]);
            return;
        }
        NSError *error = nil;
        BOOL ready = [owner.recovery prepareRestartWithProfiles:owner.workspace ? owner.workspace.profiles : @[] targetVersion:owner.updater.latestVersion
            targetBuild:owner.updater.latestBuild originCheckpoints:@[] error:&error];
        if (!ready) [owner.workspace recordSurfaceInventoryDiagnostic];
        [owner record:@"workspace-prepared" values:@{@"ready":@(ready), @"errorCode":@(error.code)}];
        completion(ready, error);
    };
    NSError *error = nil;
    if (![self.updater startWithError:&error]) {
        [self record:@"start-failed" values:@{@"domain":error.domain ?: @"", @"code":@(error.code)}];
        return;
    }
    if ([self.scenario isEqualToString:@"automatic"]) {
        [self record:@"automatic-scheduler-armed" values:@{@"enabled":@(self.updater.automaticUpdatesEnabled)}];
        // Let Sparkle's real automatic scheduler start its first cycle. This
        // scenario never calls checkNow or directly invokes a delegate callback.
    } else {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(), ^{
            [weakSelf record:@"manual-check-requested" values:@{}]; [weakSelf.updater checkNow];
        });
    }
}
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    (void)sender;
    if (!self.updater.installationAuthorized) {
        [self record:@"ordinary-termination" values:@{}];
        return NSTerminateNow;
    }
    NSError *error = nil;
    BOOL committed = [self.recovery commitPreparedRestart:&error];
    [self record:@"termination-gate" values:@{@"committed":@(committed), @"errorCode":@(error.code)}];
    if (!committed) [self.updater installationWasDeferredWithError:error];
    return committed ? NSTerminateNow : NSTerminateCancel;
}
@end

int main(void) {
    @autoreleasepool {
        NSDictionary *environment = NSProcessInfo.processInfo.environment;
        // Relaunched apps do not necessarily inherit the shell environment;
        // the fixture bundle also carries an explicit disposable-runner marker.
        if (![[NSBundle.mainBundle objectForInfoDictionaryKey:@"YMHostedDisposableFixture"] boolValue] ||
            ![[NSFileManager defaultManager] fileExistsAtPath:@"/Users/runner"]) return 3;
        (void)environment;
        [NSApplication sharedApplication];
        NSApp.activationPolicy = NSApplicationActivationPolicyRegular;
        YMUpdateRuntimeFixture *delegate = [YMUpdateRuntimeFixture new];
        NSApp.delegate = delegate;
        [NSApp run];
    }
    return 0;
}
