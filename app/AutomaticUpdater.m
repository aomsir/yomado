#import "AutomaticUpdater.h"
#import <Sparkle/Sparkle.h>
#import <math.h>
#import <sys/stat.h>
#import <unistd.h>

NSString * const YMAutomaticUpdaterErrorDomain = @"dev.chekusu.yomado.automatic-update";

static NSError *YMUpdaterError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:YMAutomaticUpdaterErrorDomain code:code
                          userInfo:@{NSLocalizedDescriptionKey: message}];
}
static BOOL YMValidPOSIXIdentifier(id value) {
    if (![value isKindOfClass:NSNumber.class]) return NO;
    double number = [value doubleValue];
    return isfinite(number) && number >= 0 && number <= UINT32_MAX && floor(number) == number;
}

// Narrow engine boundary permits tests without starting Sparkle or NSApplication.
@protocol YMUpdaterEngine <NSObject>
@property(nonatomic) BOOL automaticallyChecksForUpdates;
@property(nonatomic) BOOL automaticallyDownloadsUpdates;
@property(nonatomic) BOOL sendsSystemProfile;
@property(nonatomic, readonly) BOOL canCheckForUpdates;
- (BOOL)startUpdater:(NSError **)error;
- (void)checkForUpdates;
@end

@class YMUpdateUserDriver;
@interface YMAutomaticUpdater () <SPUUpdaterDelegate>
@property(nonatomic, strong) NSBundle *hostBundle;
@property(nonatomic, strong) id<YMUpdaterEngine> engine;
@property(nonatomic, strong) YMUpdateUserDriver *userDriver;
@property(nonatomic, readwrite) BOOL busy;
@property(nonatomic, readwrite) BOOL userInitiated;
@property(nonatomic, readwrite) BOOL installationAuthorized;
@property(nonatomic, readwrite) BOOL installationPending;
@property(nonatomic, readwrite) YMAutomaticUpdateStatus status;
@property(nonatomic, readwrite) double progress;
@property(nonatomic, copy, readwrite) NSString *latestVersion;
@property(nonatomic, copy, readwrite) NSString *latestBuild;
@property(nonatomic, strong, readwrite) NSError *lastError;
@property(nonatomic) BOOL started;
@property(nonatomic) BOOL invalidated;
@property(nonatomic) BOOL cancellationRequested;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) uint64_t expectedBytes;
@property(nonatomic) uint64_t receivedBytes;
@property(nonatomic, copy) dispatch_block_t cancellation;
@property(nonatomic, copy) dispatch_block_t terminationRetry;
@property(nonatomic, copy) void (^installationReply)(SPUUserUpdateChoice);
- (instancetype)initWithHostBundle:(NSBundle *)bundle engine:(id<YMUpdaterEngine>)engine;
- (void)publishStatus:(YMAutomaticUpdateStatus)status progress:(double)progress;
- (void)recordError:(NSError *)error blocked:(BOOL)blocked;
- (NSError *)authorizationPreflightError;
- (NSDictionary *)installationPermissionMetadata;
- (NSError *)policyErrorForItem:(SUAppcastItem *)item;
- (void)foundItem:(SUAppcastItem *)item state:(SPUUserUpdateState *)state reply:(void (^)(SPUUserUpdateChoice))reply;
- (void)prepareWithReply:(void (^)(SPUUserUpdateChoice))reply;
- (void)resetPendingWork;
@end

@interface YMUpdateUserDriver : NSObject <SPUUserDriver>
@property(nonatomic, weak) YMAutomaticUpdater *owner;
@end

@implementation YMAutomaticUpdater
- (instancetype)initWithHostBundle:(NSBundle *)bundle {
    return [self initWithHostBundle:bundle engine:nil];
}
- (instancetype)initWithHostBundle:(NSBundle *)bundle engine:(id<YMUpdaterEngine>)engine {
    NSCAssert(NSThread.isMainThread, @"Updater requires the main thread.");
    if ((self = [super init])) {
        _hostBundle = bundle;
        _progress = -1;
        _userDriver = [YMUpdateUserDriver new];
        _userDriver.owner = self;
        _engine = engine ?: (id<YMUpdaterEngine>)[[SPUUpdater alloc]
            initWithHostBundle:bundle applicationBundle:bundle userDriver:_userDriver delegate:self];
    }
    return self;
}
- (BOOL)automaticUpdatesEnabled { return self.engine.automaticallyChecksForUpdates; }
- (void)setAutomaticUpdatesEnabled:(BOOL)enabled {
    NSCAssert(NSThread.isMainThread, @"Updater requires the main thread.");
    if (self.invalidated) return;
    self.engine.automaticallyChecksForUpdates = enabled;
    if (!enabled && self.busy && !self.userInitiated) [self cancel];
    if (self.stateDidChange) self.stateDidChange();
}
- (BOOL)canCheck {
    if (!self.started || self.invalidated) return NO;
    if (self.installationPending) return self.status == YMAutomaticUpdateBlocked && self.terminationRetry != nil;
    return !self.busy && self.engine.canCheckForUpdates;
}
- (BOOL)canCancel { return self.busy && !self.installationPending && !self.invalidated; }
- (BOOL)startWithError:(NSError **)error {
    NSCAssert(NSThread.isMainThread, @"Updater requires the main thread.");
    if (self.started) return YES;
    if (self.invalidated) {
        if (error) *error = YMUpdaterError(1, @"The updater has stopped.");
        return NO;
    }
    // Always use our gated install path. Sparkle's unattended installation path
    // can install on ordinary quit, before the workspace gate is consulted.
    self.engine.automaticallyDownloadsUpdates = NO;
    self.engine.sendsSystemProfile = NO;
    NSError *failure = nil;
    self.started = [self.engine startUpdater:&failure];
    if (!self.started) {
        failure = failure ?: YMUpdaterError(2, @"The update service could not start.");
        [self recordError:failure blocked:NO];
        if (error) *error = failure;
    }
    return self.started;
}
- (void)checkNow {
    NSCAssert(NSThread.isMainThread, @"Updater requires the main thread.");
    if (!self.canCheck) return;
    self.userInitiated = YES;
    if (self.installationPending) {
        dispatch_block_t retry = self.terminationRetry;
        [self prepareWithReply:^(SPUUserUpdateChoice choice) {
            if (choice == SPUUserUpdateChoiceInstall) retry();
        }];
        return;
    }
    self.cancellationRequested = NO;
    self.lastError = nil;
    self.busy = YES;
    [self publishStatus:YMAutomaticUpdateChecking progress:-1];
    if (!self.invalidated && !self.cancellationRequested) [self.engine checkForUpdates];
}
- (void)publishStatus:(YMAutomaticUpdateStatus)status progress:(double)progress {
    self.status = status;
    self.progress = isfinite(progress) && progress >= 0 ? MIN(1, progress) : -1;
    if (!self.invalidated && self.stateDidChange) self.stateDidChange();
}
- (void)recordError:(NSError *)error blocked:(BOOL)blocked {
    BOOL duplicate = [self.lastError isEqual:error];
    self.lastError = error;
    [self publishStatus:blocked ? YMAutomaticUpdateBlocked : YMAutomaticUpdateFailed progress:-1];
    if (!duplicate && !self.invalidated && self.errorHandler) self.errorHandler(error, self.userInitiated);
}
- (void)resetPendingWork {
    ++self.generation;
    self.cancellation = nil;
    self.installationReply = nil;
}
- (void)cancel {
    NSCAssert(NSThread.isMainThread, @"Updater requires the main thread.");
    if (!self.canCancel) return;
    self.cancellationRequested = YES;
    ++self.generation;
    dispatch_block_t cancellation = self.cancellation;
    void (^reply)(SPUUserUpdateChoice) = self.installationReply;
    self.cancellation = nil;
    self.installationReply = nil;
    [self publishStatus:YMAutomaticUpdateCancelled progress:-1];
    // At ready/installing, Skip cancels installation instead of leaving it
    // armed for ordinary app termination. It does not skip a ready version.
    if (reply) reply(SPUUserUpdateChoiceSkip);
    else if (cancellation) cancellation();
    // Extraction has no cancellation callback; ready-to-install checks the
    // flag again and cancels before requesting application termination.
}
- (void)installationWasDeferredWithError:(NSError *)error {
    NSCAssert(NSThread.isMainThread, @"Updater requires the main thread.");
    if (!self.installationPending) return;
    self.installationAuthorized = NO;
    [self recordError:error blocked:YES];
}
- (void)invalidate {
    NSCAssert(NSThread.isMainThread, @"Updater requires the main thread.");
    [self cancel];
    self.invalidated = YES;
    [self resetPendingWork];
    self.stateDidChange = nil;
    self.errorHandler = nil;
    self.prepareForInstallation = nil;
}
- (NSDictionary *)installationPermissionMetadata {
    NSString *path = self.hostBundle.bundlePath;
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *parent = path.stringByDeletingLastPathComponent;
    struct stat appInfo, parentInfo;
    if (!path.length || lstat(path.fileSystemRepresentation, &appInfo) != 0 ||
        lstat(parent.fileSystemRepresentation, &parentInfo) != 0) return nil;
    int count = getgroups(0, NULL);
    if (count < 0 || count > 2048) return nil;
    gid_t *groups = count ? calloc((size_t)count, sizeof(gid_t)) : NULL;
    if (count && !groups) return nil;
    int actualCount = count ? getgroups(count, groups) : 0;
    if (actualCount < 0) { free(groups); return nil; }
    NSMutableArray *memberships = [NSMutableArray arrayWithCapacity:(NSUInteger)actualCount];
    for (int i = 0; i < actualCount; i++) [memberships addObject:@(groups[i])];
    free(groups);
    return @{@"applicationBundle":@([path.pathExtension.lowercaseString isEqualToString:@"app"]),
        @"bundleDirectory":@(S_ISDIR(appInfo.st_mode)), @"parentDirectory":@(S_ISDIR(parentInfo.st_mode)),
        @"bundleWritable":@([files isWritableFileAtPath:path]), @"parentWritable":@([files isWritableFileAtPath:parent]),
        @"restrictedFlags":@(((appInfo.st_flags | parentInfo.st_flags) & (UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND)) != 0),
        @"ownerUID":@(appInfo.st_uid), @"ownerGID":@(appInfo.st_gid),
        @"realUID":@(getuid()), @"effectiveUID":@(geteuid()), @"effectiveGID":@(getegid()),
        @"supplementaryGIDs":memberships.copy};
}
- (NSError *)authorizationPreflightError {
    NSDictionary *permissions = [self installationPermissionMetadata];
    if (![permissions isKindOfClass:NSDictionary.class]) permissions = nil;
    BOOL allowed = permissions != nil;
    for (NSString *key in @[@"applicationBundle",@"bundleDirectory",@"parentDirectory",@"bundleWritable",@"parentWritable"])
        allowed = allowed && [permissions[key] isEqual:@YES];
    allowed = allowed && [permissions[@"restrictedFlags"] isEqual:@NO];
    for (NSString *key in @[@"ownerUID",@"ownerGID",@"realUID",@"effectiveUID",@"effectiveGID"])
        allowed = allowed && YMValidPOSIXIdentifier(permissions[key]);
    NSArray *groups = permissions[@"supplementaryGIDs"];
    allowed = allowed && [groups isKindOfClass:NSArray.class];
    if (allowed) {
        for (id group in groups) if (!YMValidPOSIXIdentifier(group)) { allowed = NO; break; }
    }
    if (allowed) {
        // Sparkle also preserves the old bundle's owner/group. Writability
        // alone would admit root:admin installations and prompt for a password.
        // Read-only credentials provide a conservative gate; never chown or
        // ask for authorization while deciding whether an update is safe.
        allowed = [permissions[@"effectiveUID"] unsignedIntValue] != 0 &&
            [permissions[@"realUID"] isEqual:permissions[@"effectiveUID"]] &&
            [permissions[@"ownerUID"] isEqual:permissions[@"effectiveUID"]] &&
            ([permissions[@"ownerGID"] isEqual:permissions[@"effectiveGID"]] || [groups containsObject:permissions[@"ownerGID"]]);
    }
    if (!allowed) {
        return YMUpdaterError(3, @"This copy cannot be updated without system authorization. Keep the app running and move an owned copy to Applications before retrying.");
    }
    return nil;
}
- (NSError *)policyErrorForItem:(SUAppcastItem *)item {
    if (item.informationOnlyUpdate || ![item.installationType isEqualToString:@"application"] ||
        (item.channel.length && ![item.channel isEqualToString:@"stable"])) {
        return YMUpdaterError(4, @"This release is not an installable stable application update.");
    }
    if (!item.minimumOperatingSystemVersionIsOK || !item.maximumOperatingSystemVersionIsOK ||
        !item.minimumUpdateVersionIsOK || !item.arm64HardwareRequirementIsOK) {
        return YMUpdaterError(8, @"This update is not compatible with the current application or system.");
    }
    // The public feed must contain stable releases. Reject an accidentally
    // unchannelled beta too, rather than treating a prerelease as production.
    static NSRegularExpression *stable;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        stable = [NSRegularExpression regularExpressionWithPattern:@"^[0-9]+(?:\\.[0-9]+){1,3}$" options:0 error:NULL];
    });
    NSString *version = item.displayVersionString;
    NSTextCheckingResult *match = [stable firstMatchInString:version options:0 range:NSMakeRange(0, version.length)];
    if (!match || !NSEqualRanges(match.range, NSMakeRange(0, version.length))) {
        return YMUpdaterError(4, @"Automatic installation is limited to stable releases.");
    }
    if (![item.fileURL.scheme.lowercaseString isEqualToString:@"https"] || item.fileURL.user || item.fileURL.password) {
        return YMUpdaterError(5, @"The update archive must use a secure download address.");
    }
    return [self authorizationPreflightError];
}
- (void)foundItem:(SUAppcastItem *)item state:(SPUUserUpdateState *)state reply:(void (^)(SPUUserUpdateChoice))reply {
    self.userInitiated = state.userInitiated;
    self.cancellation = nil;
    self.latestVersion = item.displayVersionString;
    self.latestBuild = item.versionString;
    if (self.invalidated || self.cancellationRequested || (!state.userInitiated && !self.automaticUpdatesEnabled)) {
        reply(state.stage == SPUUserUpdateStageInstalling ? SPUUserUpdateChoiceSkip : SPUUserUpdateChoiceDismiss);
        return;
    }
    NSError *error = [self policyErrorForItem:item];
    if (error) {
        [self recordError:error blocked:YES];
        reply(state.stage == SPUUserUpdateStageInstalling ? SPUUserUpdateChoiceSkip : SPUUserUpdateChoiceDismiss);
        return;
    }
    self.busy = YES;
    if (state.stage == SPUUserUpdateStageInstalling) [self prepareWithReply:reply];
    else {
        [self publishStatus:YMAutomaticUpdateDownloading progress:-1];
        reply(self.invalidated || self.cancellationRequested || (!self.userInitiated && !self.automaticUpdatesEnabled)
              ? SPUUserUpdateChoiceDismiss : SPUUserUpdateChoiceInstall);
    }
}
- (void)prepareWithReply:(void (^)(SPUUserUpdateChoice))reply {
    if (self.invalidated || self.cancellationRequested || (!self.userInitiated && !self.automaticUpdatesEnabled)) {
        reply(SPUUserUpdateChoiceSkip);
        return;
    }
    NSError *preflight = [self authorizationPreflightError];
    if (preflight || !self.prepareForInstallation) {
        [self recordError:preflight ?: YMUpdaterError(6, @"Workspace preparation is unavailable. The running app has been kept open.") blocked:YES];
        reply(SPUUserUpdateChoiceSkip);
        return;
    }
    // Sparkle issues one ready callback. If an unexpected duplicate arrives,
    // cancel the newer callback without invalidating the first preparation.
    if (self.installationReply) { reply(SPUUserUpdateChoiceSkip); return; }
    NSUInteger generation = ++self.generation;
    self.installationReply = reply;
    [self publishStatus:YMAutomaticUpdatePreparing progress:-1];
    // Status callbacks may synchronously cancel or invalidate the owner.
    if (self.invalidated || self.generation != generation || !self.installationReply) return;
    __weak YMAutomaticUpdater *weakSelf = self;
    self.prepareForInstallation(^(BOOL ready, NSError *error) {
        dispatch_block_t finish = ^{
            YMAutomaticUpdater *owner = weakSelf;
            if (!owner || owner.invalidated || owner.generation != generation || !owner.installationReply) return;
            void (^decision)(SPUUserUpdateChoice) = owner.installationReply;
            owner.installationReply = nil;
            if (!ready || error || owner.cancellationRequested || (!owner.userInitiated && !owner.automaticUpdatesEnabled)) {
                [owner recordError:error ?: YMUpdaterError(7, @"The workspace is not ready to restart. The running app has been kept open; try again when it is safe.") blocked:YES];
                decision(SPUUserUpdateChoiceSkip);
                return;
            }
            NSError *latePreflight = [owner authorizationPreflightError];
            if (latePreflight) {
                [owner recordError:latePreflight blocked:YES];
                decision(SPUUserUpdateChoiceSkip);
                return;
            }
            owner.installationAuthorized = YES;
            owner.installationPending = YES;
            owner.status = YMAutomaticUpdateInstalling;
            owner.progress = -1;
            // Publish only after committing the decision, so a reentrant UI
            // callback cannot mistake an unsubmitted update for an armed one.
            decision(SPUUserUpdateChoiceInstall);
            if (!owner.invalidated && owner.stateDidChange) owner.stateDidChange();
        };
        if (NSThread.isMainThread) finish();
        else dispatch_async(dispatch_get_main_queue(), finish);
    });
}

#pragma mark - Sparkle policy and scheduled checks
- (NSSet<NSString *> *)allowedChannelsForUpdater:(SPUUpdater *)updater { (void)updater; return [NSSet setWithObject:@"stable"]; }
- (BOOL)updaterShouldPromptForPermissionToCheckForUpdates:(SPUUpdater *)updater { (void)updater; return NO; }
- (NSArray<NSString *> *)allowedSystemProfileKeysForUpdater:(SPUUpdater *)updater { (void)updater; return @[]; }
- (NSArray *)feedParametersForUpdater:(SPUUpdater *)updater sendingSystemProfile:(BOOL)sendingProfile {
    (void)updater; (void)sendingProfile; return @[];
}
- (BOOL)updater:(SPUUpdater *)updater mayPerformUpdateCheck:(SPUUpdateCheck)updateCheck error:(NSError **)error {
    (void)updater;
    if (self.invalidated || self.installationPending || (updateCheck != SPUUpdateCheckUpdates && !self.automaticUpdatesEnabled)) {
        if (error) *error = YMUpdaterError(1, @"Automatic updates are paused.");
        return NO;
    }
    self.userInitiated = updateCheck == SPUUpdateCheckUpdates;
    self.cancellationRequested = NO;
    self.installationAuthorized = NO;
    self.lastError = nil;
    self.busy = YES;
    [self publishStatus:YMAutomaticUpdateChecking progress:-1];
    return YES;
}
- (BOOL)updater:(SPUUpdater *)updater shouldProceedWithUpdate:(SUAppcastItem *)item updateCheck:(SPUUpdateCheck)check error:(NSError **)error {
    (void)updater; (void)check;
    NSError *failure = [self policyErrorForItem:item];
    if (!failure && (self.invalidated || self.cancellationRequested)) failure = YMUpdaterError(1, @"The update was cancelled.");
    if (failure) {
        [self recordError:failure blocked:YES];
        if (error) *error = failure;
    }
    return failure == nil;
}
- (void)updaterDidNotFindUpdate:(SPUUpdater *)updater error:(NSError *)error {
    (void)updater;
    NSNumber *reason = error.userInfo[SPUNoUpdateFoundReasonKey];
    if (reason && reason.integerValue == SPUNoUpdateFoundReasonOnLatestVersion) {
        [self publishStatus:YMAutomaticUpdateUpToDate progress:1];
    } else [self recordError:error blocked:YES];
}
- (void)updater:(SPUUpdater *)updater didFinishUpdateCycleForUpdateCheck:(SPUUpdateCheck)check error:(NSError *)error {
    (void)updater; (void)check;
    [self resetPendingWork];
    if (!self.installationPending) self.busy = NO;
    BOOL failedPendingInstall = error && self.installationPending;
    if (failedPendingInstall) {
        self.installationPending = self.installationAuthorized = NO;
        self.terminationRetry = nil;
        self.busy = NO;
    }
    if (error && (failedPendingInstall || (self.status != YMAutomaticUpdateUpToDate && self.status != YMAutomaticUpdateBlocked && self.status != YMAutomaticUpdateCancelled))) {
        [self recordError:error blocked:NO];
    }
    // Sparkle can update canCheckForUpdates after this delegate callback.
    __weak YMAutomaticUpdater *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        YMAutomaticUpdater *owner = weakSelf;
        if (!owner.invalidated && owner.stateDidChange) owner.stateDidChange();
    });
}
@end

@implementation YMUpdateUserDriver
- (void)showUpdatePermissionRequest:(SPUUpdatePermissionRequest *)request reply:(void (^)(SUUpdatePermissionResponse *))reply {
    (void)request;
    reply([[SUUpdatePermissionResponse alloc] initWithAutomaticUpdateChecks:self.owner.automaticUpdatesEnabled
                                               automaticUpdateDownloading:@NO sendSystemProfile:NO]);
}
- (void)showUserInitiatedUpdateCheckWithCancellation:(void (^)(void))cancellation {
    YMAutomaticUpdater *owner = self.owner;
    if (!owner || owner.invalidated || owner.cancellationRequested) { cancellation(); return; }
    owner.userInitiated = YES;
    owner.cancellation = cancellation;
    [owner publishStatus:YMAutomaticUpdateChecking progress:-1];
}
- (void)showUpdateFoundWithAppcastItem:(SUAppcastItem *)item state:(SPUUserUpdateState *)state reply:(void (^)(SPUUserUpdateChoice))reply {
    YMAutomaticUpdater *owner = self.owner;
    if (owner) [owner foundItem:item state:state reply:reply];
    else reply(state.stage == SPUUserUpdateStageInstalling ? SPUUserUpdateChoiceSkip : SPUUserUpdateChoiceDismiss);
}
- (void)showUpdateReleaseNotesWithDownloadData:(SPUDownloadData *)data { (void)data; }
- (void)showUpdateReleaseNotesFailedToDownloadWithError:(NSError *)error { (void)error; }
- (void)showUpdateNotFoundWithError:(NSError *)error acknowledgement:(void (^)(void))acknowledgement {
    if (!self.owner.invalidated && !self.owner.cancellationRequested) [self.owner updaterDidNotFindUpdate:(SPUUpdater *)self.owner.engine error:error];
    acknowledgement();
}
- (void)showUpdaterError:(NSError *)error acknowledgement:(void (^)(void))acknowledgement {
    YMAutomaticUpdater *owner = self.owner;
    BOOL failedPendingInstall = owner.installationPending;
    owner.installationAuthorized = owner.installationPending = NO;
    owner.terminationRetry = nil;
    if (failedPendingInstall || (owner.status != YMAutomaticUpdateBlocked && owner.status != YMAutomaticUpdateCancelled)) [owner recordError:error blocked:NO];
    acknowledgement();
}
- (void)showDownloadInitiatedWithCancellation:(void (^)(void))cancellation {
    YMAutomaticUpdater *owner = self.owner;
    if (!owner || owner.invalidated || owner.cancellationRequested) { cancellation(); return; }
    owner.cancellation = cancellation;
    owner.receivedBytes = owner.expectedBytes = 0;
    [owner publishStatus:YMAutomaticUpdateDownloading progress:-1];
}
- (void)showDownloadDidReceiveExpectedContentLength:(uint64_t)length {
    if (self.owner.invalidated || self.owner.cancellationRequested) return;
    self.owner.expectedBytes = length;
    [self.owner publishStatus:YMAutomaticUpdateDownloading progress:length ? (double)self.owner.receivedBytes / length : -1];
}
- (void)showDownloadDidReceiveDataOfLength:(uint64_t)length {
    YMAutomaticUpdater *owner = self.owner;
    if (owner.invalidated || owner.cancellationRequested) return;
    owner.receivedBytes = UINT64_MAX - owner.receivedBytes < length ? UINT64_MAX : owner.receivedBytes + length;
    [owner publishStatus:YMAutomaticUpdateDownloading progress:owner.expectedBytes ? (double)owner.receivedBytes / owner.expectedBytes : -1];
}
- (void)showDownloadDidStartExtractingUpdate {
    self.owner.cancellation = nil;
    if (!self.owner.invalidated && !self.owner.cancellationRequested) [self.owner publishStatus:YMAutomaticUpdateExtracting progress:-1];
}
- (void)showExtractionReceivedProgress:(double)progress {
    if (!self.owner.invalidated && !self.owner.cancellationRequested) [self.owner publishStatus:YMAutomaticUpdateExtracting progress:progress];
}
- (void)showReadyToInstallAndRelaunch:(void (^)(SPUUserUpdateChoice))reply {
    YMAutomaticUpdater *owner = self.owner;
    if (owner) [owner prepareWithReply:reply]; else reply(SPUUserUpdateChoiceSkip);
}
- (void)showInstallingUpdateWithApplicationTerminated:(BOOL)terminated retryTerminatingApplication:(void (^)(void))retry {
    YMAutomaticUpdater *owner = self.owner;
    owner.terminationRetry = terminated ? nil : retry;
    // Preserve a final workspace veto that may arrive before this callback.
    // A user-triggered retry must pass preparation again; never force quit.
    if (owner.status != YMAutomaticUpdateBlocked) [owner publishStatus:YMAutomaticUpdateInstalling progress:-1];
    else if (owner.stateDidChange && !owner.invalidated) owner.stateDidChange();
}
- (void)showUpdateInstalledAndRelaunched:(BOOL)relaunched acknowledgement:(void (^)(void))acknowledgement {
    (void)relaunched;
    self.owner.busy = NO;
    self.owner.installationAuthorized = self.owner.installationPending = NO;
    self.owner.terminationRetry = nil;
    [self.owner publishStatus:YMAutomaticUpdateInstalled progress:1];
    acknowledgement();
}
- (void)dismissUpdateInstallation {
    YMAutomaticUpdater *owner = self.owner;
    [owner resetPendingWork];
    if (!owner.installationPending) owner.busy = NO;
    if (owner.stateDidChange && !owner.invalidated) owner.stateDidChange();
}
- (void)showUpdateInFocus {
    if (self.owner.stateDidChange && !self.owner.invalidated) self.owner.stateDidChange();
}
@end
