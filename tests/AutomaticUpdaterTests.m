#import "AutomaticUpdater.h"
#import <Sparkle/Sparkle.h>
#import <AppKit/AppKit.h>

static NSUInteger checks;
static void Check(BOOL ok, const char *message) {
    checks++;
    if (!ok) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
}
static NSError *Failure(void) { return [NSError errorWithDomain:@"test" code:9 userInfo:@{NSLocalizedDescriptionKey:@"Workspace changed"}]; }

// Private injected boundaries: no real updater, network, installer, windows or
// preferences are started. The actual production SPUUserDriver is exercised.
@interface YMAutomaticUpdater (Tests)
- (instancetype)initWithHostBundle:(NSBundle *)bundle engine:(id)engine;
- (NSError *)authorizationPreflightError;
- (NSDictionary *)installationPermissionMetadata;
@property(nonatomic, readonly) id<SPUUserDriver> userDriver;
@end
@interface FixturePermissionUpdater : YMAutomaticUpdater
@property(copy) NSDictionary *permissionMetadata;
@end
@implementation FixturePermissionUpdater
- (NSDictionary *)installationPermissionMetadata { return self.permissionMetadata; }
@end
@interface FixtureUpdater : YMAutomaticUpdater
@property NSError *preflightError;
@end
@implementation FixtureUpdater
- (NSError *)authorizationPreflightError { return self.preflightError; }
@end
@interface FixtureEngine : NSObject
@property BOOL automaticallyChecksForUpdates;
@property BOOL automaticallyDownloadsUpdates;
@property BOOL sendsSystemProfile;
@property BOOL canCheckForUpdates;
@property BOOL startOK;
@property NSUInteger starts;
@property NSUInteger manualChecks;
@end
@implementation FixtureEngine
- (instancetype)init {
    if ((self=[super init])) { _canCheckForUpdates=YES; _startOK=YES; _automaticallyChecksForUpdates=YES; }
    return self;
}
- (BOOL)startUpdater:(NSError **)error { self.starts++; if (!self.startOK && error) *error=Failure(); return self.startOK; }
- (void)checkForUpdates { self.manualChecks++; }
@end
@interface FixtureItem : NSObject
@property NSString *displayVersionString;
@property NSString *versionString;
@property NSString *installationType;
@property NSString *channel;
@property NSURL *fileURL;
@property(getter=isInformationOnlyUpdate) BOOL informationOnlyUpdate;
@property BOOL minimumOperatingSystemVersionIsOK;
@property BOOL maximumOperatingSystemVersionIsOK;
@property BOOL minimumUpdateVersionIsOK;
@property BOOL arm64HardwareRequirementIsOK;
@end
@implementation FixtureItem
- (instancetype)init {
    if ((self=[super init])) {
        _displayVersionString=@"0.4.0"; _versionString=@"20";
        _installationType=@"application";
        _fileURL=[NSURL URLWithString:@"https://example.invalid/yomado.zip"];
        _minimumOperatingSystemVersionIsOK=_maximumOperatingSystemVersionIsOK=_minimumUpdateVersionIsOK=_arm64HardwareRequirementIsOK=YES;
    } return self;
}
@end
@interface FixtureState : NSObject
@property SPUUserUpdateStage stage;
@property BOOL userInitiated;
@end
@implementation FixtureState
@end

static FixtureUpdater *Make(FixtureEngine **engine) {
    FixtureEngine *e=[FixtureEngine new];
    FixtureUpdater *u=[[FixtureUpdater alloc] initWithHostBundle:NSBundle.mainBundle engine:e];
    if (engine) *engine=e;
    Check([u startWithError:NULL], "injected updater starts");
    return u;
}
static void Found(YMAutomaticUpdater *u, FixtureItem *item, BOOL manual, SPUUserUpdateStage stage, void (^reply)(SPUUserUpdateChoice)) {
    FixtureState *state=[FixtureState new]; state.stage=stage; state.userInitiated=manual;
    [u.userDriver showUpdateFoundWithAppcastItem:(id)item state:(id)state reply:reply];
}
static void Finish(FixtureUpdater *u, NSError *error) {
    [(id<SPUUpdaterDelegate>)u updater:(id)[NSObject new] didFinishUpdateCycleForUpdateCheck:SPUUpdateCheckUpdates error:error];
}
static void Begin(YMAutomaticUpdater *u, BOOL manual) {
    NSError *error=nil;
    Check([(id<SPUUpdaterDelegate>)u updater:(id)[NSObject new] mayPerformUpdateCheck:manual?SPUUpdateCheckUpdates:SPUUpdateCheckUpdatesInBackground error:&error], "allowed check enters same driver lifecycle");
}
static NSMutableDictionary *OwnedInstallation(void) {
    return [@{@"applicationBundle":@YES,@"bundleDirectory":@YES,@"parentDirectory":@YES,
        @"bundleWritable":@YES,@"parentWritable":@YES,@"restrictedFlags":@NO,
        @"ownerUID":@501,@"ownerGID":@20,@"realUID":@501,@"effectiveUID":@501,
        @"effectiveGID":@20,@"supplementaryGIDs":@[@20,@80]} mutableCopy];
}
static void AuthorizationOwnershipGuards(void) {
    FixturePermissionUpdater *u=[[FixturePermissionUpdater alloc] initWithHostBundle:NSBundle.mainBundle engine:[FixtureEngine new]];
    NSMutableDictionary *metadata=OwnedInstallation(); u.permissionMetadata=metadata;
    Check([u authorizationPreflightError]==nil,"owned writable application has non-interactive ownership");
    metadata[@"ownerUID"]=@0; metadata[@"ownerGID"]=@80; u.permissionMetadata=metadata;
    Check([u authorizationPreflightError]!=nil,"root-owned group-writable app is blocked before Sparkle can request administrator authorization");
    for (NSUInteger scenario=0;scenario<19;scenario++) {
        metadata=OwnedInstallation(); BOOL expected=NO;
        switch(scenario) {
            case 0: metadata[@"ownerGID"]=@80; expected=YES; break;
            case 1: metadata[@"supplementaryGIDs"]=@[]; expected=YES; break;
            case 2: metadata[@"ownerUID"]=@502; break;
            case 3: metadata[@"ownerGID"]=@999; break;
            case 4: metadata[@"realUID"]=@502; break;
            case 5: metadata[@"realUID"]=@0; metadata[@"effectiveUID"]=@0; metadata[@"ownerUID"]=@0; break;
            case 6: [metadata removeObjectForKey:@"ownerUID"]; break;
            case 7: metadata[@"ownerUID"]=@"501"; break;
            case 8: metadata[@"ownerGID"]=@20.5; break;
            case 9: metadata[@"ownerGID"]=@(-1); break;
            case 10: metadata[@"effectiveUID"]=@(UINT64_MAX); break;
            case 11: metadata[@"supplementaryGIDs"]=@[@"80"]; break;
            case 12: [metadata removeObjectForKey:@"supplementaryGIDs"]; break;
            case 13: metadata[@"bundleDirectory"]=@NO; break;
            case 14: metadata[@"parentDirectory"]=@NO; break;
            case 15: metadata[@"bundleWritable"]=@NO; break;
            case 16: metadata[@"parentWritable"]=@NO; break;
            case 17: metadata[@"restrictedFlags"]=@YES; break;
            case 18: metadata[@"applicationBundle"]=@NO; break;
        }
        u.permissionMetadata=metadata;
        Check(([u authorizationPreflightError]==nil)==expected,"read-only owner/group/type/writability policy matches non-interactive installation boundary");
    }
    u.permissionMetadata=nil;
    Check([u authorizationPreflightError]!=nil,"missing file or process metadata fails closed");
    for(NSNumber *manual in @[@NO,@YES]) {
        u=[[FixturePermissionUpdater alloc] initWithHostBundle:NSBundle.mainBundle engine:[FixtureEngine new]];
        Check([u startWithError:NULL],"permission-policy driver starts without real engine"); Begin(u,manual.boolValue);
        metadata=OwnedInstallation(); metadata[@"ownerUID"]=@0; metadata[@"ownerGID"]=@80; u.permissionMetadata=metadata;
        __block NSUInteger replies=0, preparations=0;
        u.prepareForInstallation=^(YMUpdatePreparationCompletion completion){ preparations++; completion(YES,nil); };
        Found(u,[FixtureItem new],manual.boolValue,SPUUserUpdateStageNotDownloaded,^(SPUUserUpdateChoice choice) {
            replies++; Check(choice==SPUUserUpdateChoiceDismiss,"ownership requiring authorization blocks both download origins");
        });
        Check(replies==1 && preparations==0 && u.status==YMAutomaticUpdateBlocked && !u.installationPending,
            "authorization block keeps running app intact without workspace preparation");
        Check(u.lastError.code==3 && ![u.lastError.localizedDescription containsString:@"501"],"authorization status contains no account identifier");
    }
    u=[[FixturePermissionUpdater alloc] initWithHostBundle:NSBundle.mainBundle engine:[FixtureEngine new]];
    Check([u startWithError:NULL],"late-ownership fixture starts"); Begin(u,YES);
    u.permissionMetadata=OwnedInstallation();
    __block YMUpdatePreparationCompletion completion; __block NSUInteger decisions=0;
    u.prepareForInstallation=^(YMUpdatePreparationCompletion finish){ completion=[finish copy]; };
    [u.userDriver showReadyToInstallAndRelaunch:^(SPUUserUpdateChoice choice) {
        decisions++; Check(choice==SPUUserUpdateChoiceSkip,"ownership changed during preparation cancels before installation");
    }];
    Check(completion!=nil && decisions==0,"owned installation reaches asynchronous workspace preparation");
    metadata=OwnedInstallation(); metadata[@"ownerGID"]=@999; u.permissionMetadata=metadata;
    completion(YES,nil);
    Check(decisions==1 && !u.installationPending && !u.installationAuthorized && u.status==YMAutomaticUpdateBlocked,
        "late group mismatch cannot arm the installer or authorize app termination");
}
int main(void) { @autoreleasepool {
    Check(NSApp==nil, "tests begin without NSApplication");
    AuthorizationOwnershipGuards();
    {
        FixtureEngine *e; FixtureUpdater *u=Make(&e);
        Check(e.starts==1 && !e.automaticallyDownloadsUpdates && !e.sendsSystemProfile, "start disables ungated install-on-quit and system profile");
        Check(u.canCheck && u.automaticUpdatesEnabled, "initial setting is supplied by persistent Sparkle preference");
        u.automaticUpdatesEnabled=NO;
        Check(!e.automaticallyChecksForUpdates && u.canCheck, "disabling schedule preserves manual check");
        [u checkNow]; [u checkNow];
        Check(e.manualChecks==1 && u.userInitiated && u.busy, "manual path checks once without browser action");
        Finish(u,nil);
        Check(!u.busy && u.canCheck, "finished cycle permits another check");
        [u invalidate]; [u checkNow];
        Check(!u.canCheck && e.manualChecks==1, "invalidated updater stays stopped");
    }
    for (NSNumber *manual in @[@NO,@YES]) {
        FixtureUpdater *u=Make(NULL); Begin(u,manual.boolValue);
        __block NSUInteger replies=0; __block YMUpdatePreparationCompletion completion;
        u.prepareForInstallation=^(YMUpdatePreparationCompletion finish) { completion=[finish copy]; };
        Found(u,[FixtureItem new],manual.boolValue,SPUUserUpdateStageNotDownloaded,^(SPUUserUpdateChoice choice) {
            replies++; Check(choice==SPUUserUpdateChoiceInstall, "manual and scheduled stable updates both start download");
        });
        Check(replies==1 && [u.latestVersion isEqual:@"0.4.0"] && [u.latestBuild isEqual:@"20"], "version and build track exact feed item");
        [u.userDriver showReadyToInstallAndRelaunch:^(SPUUserUpdateChoice choice) {
            replies++; Check(choice==SPUUserUpdateChoiceInstall, "prepared update installs and relaunches");
        }];
        Check(replies==1 && u.status==YMAutomaticUpdatePreparing && !u.installationAuthorized, "ready waits for async workspace preparation");
        completion(YES,nil); completion(YES,nil);
        Check(replies==2 && u.installationAuthorized && u.installationPending && !u.canCancel, "gate success authorizes exactly once and marks installer pending");
    }
    for (NSUInteger scenario=0;scenario<11;scenario++) {
        FixtureUpdater *u=Make(NULL); Begin(u,YES); FixtureItem *item=[FixtureItem new];
        if(scenario==0) item.displayVersionString=@"0.4.0-beta.1";
        if(scenario==1) item.channel=@"beta";
        if(scenario==2) item.informationOnlyUpdate=YES;
        if(scenario==3) item.installationType=@"package";
        if(scenario==4) item.fileURL=[NSURL URLWithString:@"http://example.invalid/yomado.zip"];
        if(scenario==5) item.fileURL=[NSURL URLWithString:@"https://user:pass@example.invalid/yomado.zip"];
        if(scenario==6) item.minimumOperatingSystemVersionIsOK=NO;
        if(scenario==7) item.maximumOperatingSystemVersionIsOK=NO;
        if(scenario==8) item.minimumUpdateVersionIsOK=NO;
        if(scenario==9) item.arm64HardwareRequirementIsOK=NO;
        if(scenario==10) u.preflightError=Failure();
        __block BOOL dismissed=NO;
        Found(u,item,YES,SPUUserUpdateStageNotDownloaded,^(SPUUserUpdateChoice choice) { dismissed=choice==SPUUserUpdateChoiceDismiss; });
        Check(dismissed && u.status==YMAutomaticUpdateBlocked && !u.installationPending, "unsafe/incompatible/prerelease/auth-required item does not download or install");
    }
    {
        FixtureUpdater *u=Make(NULL); Begin(u,YES);
        __block NSUInteger replies=0; __block YMUpdatePreparationCompletion completion;
        u.prepareForInstallation=^(YMUpdatePreparationCompletion finish){ completion=[finish copy]; };
        Found(u,[FixtureItem new],YES,SPUUserUpdateStageInstalling,^(SPUUserUpdateChoice choice){ replies++; Check(choice==SPUUserUpdateChoiceSkip,"unsafe resumed installer is cancelled, not dismissed for install-on-quit"); });
        Check(replies==0 && u.status==YMAutomaticUpdatePreparing, "resumed Installing state cannot bypass preparation");
        completion(NO,Failure()); completion(YES,nil);
        Check(replies==1 && !u.installationAuthorized && !u.installationPending && u.status==YMAutomaticUpdateBlocked,"failed preparation remains retryable and never later authorizes");
    }
    for(NSUInteger scenario=0;scenario<5;scenario++) {
        FixtureUpdater *u=Make(NULL); Begin(u,scenario==1?NO:YES);
        __block YMUpdatePreparationCompletion completion; __block NSUInteger replies=0;
        u.prepareForInstallation=^(YMUpdatePreparationCompletion finish){ completion=[finish copy]; };
        [u.userDriver showReadyToInstallAndRelaunch:^(SPUUserUpdateChoice choice){ replies++; Check(choice==SPUUserUpdateChoiceSkip,"cancelled gate cancels installer without quitting"); }];
        if(scenario==0) [u cancel];
        if(scenario==1) u.automaticUpdatesEnabled=NO;
        if(scenario==2) [u invalidate];
        if(scenario==3) u.preflightError=Failure();
        if(scenario==4) completion(YES,Failure());
        completion(YES,nil);
        Check(replies==1 && !u.installationAuthorized && !u.installationPending,"cancel/invalidation/late permission change/error rejects stale gate completion");
    }
    {
        FixtureUpdater *u=Make(NULL); Begin(u,YES); __block NSUInteger replies=0;
        [u.userDriver showReadyToInstallAndRelaunch:^(SPUUserUpdateChoice choice){ replies++; Check(choice==SPUUserUpdateChoiceSkip,"missing preparation cancels update"); }];
        Check(replies==1 && u.status==YMAutomaticUpdateBlocked,"missing preparation is fail closed");
    }
    {
        FixtureUpdater *u=Make(NULL); Begin(u,YES); __block NSUInteger cancelled=0;
        [u.userDriver showDownloadInitiatedWithCancellation:^{cancelled++;}];
        [u.userDriver showDownloadDidReceiveExpectedContentLength:100];
        [u.userDriver showDownloadDidReceiveDataOfLength:25]; Check(u.progress==0.25,"download progress uses received/expected bytes");
        [u.userDriver showDownloadDidReceiveExpectedContentLength:10]; Check(u.progress==1,"misreported length is clamped");
        [u.userDriver showDownloadDidReceiveDataOfLength:UINT64_MAX]; Check(u.progress==1,"byte count does not overflow");
        [u cancel]; [u.userDriver showDownloadDidReceiveDataOfLength:1];
        Check(cancelled==1 && u.status==YMAutomaticUpdateCancelled,"late progress cannot undo cancellation");
        [u.userDriver showDownloadDidStartExtractingUpdate];
        [u.userDriver showReadyToInstallAndRelaunch:^(SPUUserUpdateChoice choice){Check(choice==SPUUserUpdateChoiceSkip,"cancelled extraction never installs");}];
    }
    {
        FixtureUpdater *u=Make(NULL); Begin(u,YES);
        u.prepareForInstallation=^(YMUpdatePreparationCompletion finish){ finish(YES,nil); };
        __block NSUInteger retries=0;
        [u.userDriver showReadyToInstallAndRelaunch:^(SPUUserUpdateChoice choice){ Check(choice==SPUUserUpdateChoiceInstall,"first ready request commits installer"); }];
        [u installationWasDeferredWithError:Failure()];
        [u.userDriver showInstallingUpdateWithApplicationTerminated:NO retryTerminatingApplication:^{ retries++; }];
        Check(u.installationPending && !u.installationAuthorized && u.canCheck && !u.canCancel,"termination veto leaves an explicit pending update with manual retry");
        u.automaticUpdatesEnabled=NO; [u cancel];
        Check(u.installationPending && u.status==YMAutomaticUpdateBlocked,"turning off automation does not falsely cancel an armed installer");
        __block YMUpdatePreparationCompletion completion;
        u.prepareForInstallation=^(YMUpdatePreparationCompletion finish){ completion=[finish copy]; };
        [u checkNow]; Check(retries==0 && !u.canCheck,"manual retry waits for a fresh preparation");
        completion(YES,nil); completion(YES,nil);
        Check(retries==1 && u.installationAuthorized && u.installationPending,"retry submits termination once after renewed preparation");
        [u.userDriver showUpdaterError:Failure() acknowledgement:^{}]; Finish(u,Failure());
        Check(!u.installationPending && !u.installationAuthorized && !u.busy,"real Sparkle failure clears pending install state");
    }
    {
        FixtureUpdater *u=Make(NULL); Begin(u,YES);
        NSError *unknown=[NSError errorWithDomain:@"fixture" code:1 userInfo:@{}];
        [u.userDriver showUpdateNotFoundWithError:unknown acknowledgement:^{}];
        Check(u.status==YMAutomaticUpdateBlocked,"unknown no-update reason is not falsely up to date");
        NSError *latest=[NSError errorWithDomain:@"fixture" code:1 userInfo:@{SPUNoUpdateFoundReasonKey:@(SPUNoUpdateFoundReasonOnLatestVersion)}];
        [u.userDriver showUpdateNotFoundWithError:latest acknowledgement:^{}];
        Check(u.status==YMAutomaticUpdateUpToDate,"known latest-version result is reported accurately");
    }
    for (NSNumber *invalidate in @[@NO,@YES]) {
        FixtureUpdater *u=Make(NULL); Begin(u,YES);
        __block NSUInteger preparations=0, decisions=0;
        u.prepareForInstallation=^(YMUpdatePreparationCompletion finish){ (void)finish; preparations++; };
        __weak FixtureUpdater *weak=u;
        u.stateDidChange=^{
            if(weak.status==YMAutomaticUpdatePreparing) {
                if(invalidate.boolValue) [weak invalidate]; else [weak cancel];
            }
        };
        [u.userDriver showReadyToInstallAndRelaunch:^(SPUUserUpdateChoice choice){ decisions++; Check(choice==SPUUserUpdateChoiceSkip,"reentrant cancellation prevents ready install"); }];
        Check(preparations==0 && decisions==1 && !u.installationPending,"cancel/invalidate inside status callback never invokes a cleared preparation handler");
    }
    {
        FixtureUpdater *u=Make(NULL); Begin(u,NO); __weak FixtureUpdater *weak=u;
        u.stateDidChange=^{ if(weak.status==YMAutomaticUpdateDownloading) weak.automaticUpdatesEnabled=NO; };
        Found(u,[FixtureItem new],NO,SPUUserUpdateStageNotDownloaded,^(SPUUserUpdateChoice choice){
            Check(choice==SPUUserUpdateChoiceDismiss,"disabling automatic updates in state callback cannot still start download");
        });
    }
    {
        FixtureUpdater *u=Make(NULL); Begin(u,YES);
        __block YMUpdatePreparationCompletion completion; __block NSUInteger decisions=0;
        u.prepareForInstallation=^(YMUpdatePreparationCompletion finish){completion=[finish copy];};
        [u.userDriver showReadyToInstallAndRelaunch:^(SPUUserUpdateChoice choice){ decisions++; Check(choice==SPUUserUpdateChoiceSkip,"cancel beats queued background preparation result"); }];
        dispatch_semaphore_t scheduled=dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{completion(YES,nil);dispatch_semaphore_signal(scheduled);});
        Check(dispatch_semaphore_wait(scheduled,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))==0,"background fixture queues its completion in bounded time");
        [u cancel];
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.03]];
        Check(decisions==1 && !u.installationAuthorized && !u.installationPending,"stale main-thread completion cannot install after cancellation");
    }
    {
        FixtureEngine *e=[FixtureEngine new]; e.startOK=NO;
        FixtureUpdater *u=[[FixtureUpdater alloc] initWithHostBundle:NSBundle.mainBundle engine:e];
        NSError *error=nil;
        Check(![u startWithError:&error] && error && u.status==YMAutomaticUpdateFailed && !u.canCheck,"configuration/start failure remains explicit and non-operational");
        NSSet *channels=[(id<SPUUpdaterDelegate>)u allowedChannelsForUpdater:(id)e];
        Check([channels isEqual:[NSSet setWithObject:@"stable"]],"only stable plus Sparkle default channel is allowed");
        Check([[(id<SPUUpdaterDelegate>)u allowedSystemProfileKeysForUpdater:(id)e] count]==0,"system-profile allowlist is empty");
    }
    {
        __block NSUInteger calls=0; id<SPUUserDriver> retainedDriver;
        @autoreleasepool { FixtureUpdater *u=Make(NULL); retainedDriver=u.userDriver; }
        [retainedDriver showReadyToInstallAndRelaunch:^(SPUUserUpdateChoice choice){calls++;Check(choice==SPUUserUpdateChoiceSkip,"orphaned driver cannot install");}];
        Check(calls==1,"driver owner is weak and missing owner fails closed");
    }
    Check(NSApp==nil,"all user-driver tests leave NSApp unset and perform no GUI/network/install");
    printf("PASS: %lu automatic updater assertions; injected Sparkle driver, no GUI/network/install\n",(unsigned long)checks);
} return 0; }
