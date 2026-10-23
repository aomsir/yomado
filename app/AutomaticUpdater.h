#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const YMAutomaticUpdaterErrorDomain;

typedef NS_ENUM(NSInteger, YMAutomaticUpdateStatus) {
    YMAutomaticUpdateIdle,
    YMAutomaticUpdateChecking,
    YMAutomaticUpdateDownloading,
    YMAutomaticUpdateExtracting,
    YMAutomaticUpdatePreparing,
    YMAutomaticUpdateInstalling,
    YMAutomaticUpdateUpToDate,
    YMAutomaticUpdateBlocked,
    YMAutomaticUpdateFailed,
    YMAutomaticUpdateCancelled,
    YMAutomaticUpdateInstalled,
};

typedef void (^YMUpdatePreparationCompletion)(BOOL ready, NSError * _Nullable error);
typedef void (^YMUpdatePreparationHandler)(YMUpdatePreparationCompletion completion);

// Main-thread interface. Both scheduled and manual checks use the same stable
// appcast and download/install path; no browser or additional updater windows.
// The owner presents status/progress in its existing panel and menu.
@interface YMAutomaticUpdater : NSObject
- (instancetype)initWithHostBundle:(NSBundle *)bundle;
@property(nonatomic) BOOL automaticUpdatesEnabled; // Persisted by Sparkle.
@property(nonatomic, readonly) BOOL canCheck;
@property(nonatomic, readonly) BOOL busy;
@property(nonatomic, readonly) BOOL canCancel;
@property(nonatomic, readonly) BOOL userInitiated;
@property(nonatomic, readonly) BOOL installationAuthorized;
@property(nonatomic, readonly) BOOL installationPending; // Installer armed; every subsequent quit must still validate.
@property(nonatomic, readonly) YMAutomaticUpdateStatus status;
@property(nonatomic, readonly) double progress; // -1: indeterminate, otherwise 0...1.
@property(nonatomic, copy, readonly, nullable) NSString *latestVersion;
@property(nonatomic, copy, readonly, nullable) NSString *latestBuild;
@property(nonatomic, strong, readonly, nullable) NSError *lastError;
@property(nonatomic, copy, nullable) void (^stateDidChange)(void);
@property(nonatomic, copy, nullable) void (^errorHandler)(NSError *error, BOOL userInitiated);
// Required. Save and validate the workspace without withdrawing its displays.
// Call completion exactly once. May finish on any queue; stale replies cannot
// install after cancellation. A missing/failed gate cancels this installation.
@property(nonatomic, copy, nullable) YMUpdatePreparationHandler prepareForInstallation;
- (BOOL)startWithError:(NSError * _Nullable * _Nullable)error;
- (void)checkNow;
// Call if applicationShouldTerminate refuses Sparkle termination after final
// workspace validation. checkNow can prepare again and retry once when ready.
- (void)installationWasDeferredWithError:(NSError *)error;
- (void)cancel;
- (void)invalidate;
@end

NS_ASSUME_NONNULL_END
