#import <Foundation/Foundation.h>
#import <sys/types.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const YMUpdateWorkspaceRecoveryErrorDomain;
typedef NS_ENUM(NSInteger, YMUpdateOwnedWindowRelation) {
    YMUpdateWindowOutsideOwned = 0,
    YMUpdateWindowContainedInOwned = 1,
    YMUpdateWindowCrossesOwnedBoundary = 2,
};
/// Pure geometry classification; crossing any owned boundary is unsafe even
/// when most of the window remains on a physical display.
FOUNDATION_EXPORT YMUpdateOwnedWindowRelation YMUpdateWindowRelationToOwnedDisplays(NSDictionary *frame, NSArray<NSDictionary *> *displays);
/// Pure, conservative classification of a system menu surface or its hidden
/// backing copies. Evidence is collected afresh by the native backend, never
/// persisted. Ordinary AX windows always take precedence over this exclusion.
/// Other menu regions include their current display bounds, inset and system
/// surface; an AX menu frame must match one of these independently checked regions.
FOUNDATION_EXPORT BOOL YMUpdateIsVerifiedMenuChrome(NSDictionary *candidate, NSDictionary *displayBounds,
    double topInset, NSInteger mainMenuLevel, NSDictionary *systemMenu, NSDictionary * _Nullable ownerAX,
    NSArray<NSDictionary *> * _Nullable currentMenuRegions);
/// Exact native identity/lookup helpers used only for in-memory workspace
/// checkpoint handoff. No titles, paths, permissions prompts or activation.
FOUNDATION_EXPORT NSDictionary * _Nullable YMUpdateIdentityForWindowElement(id element);
FOUNDATION_EXPORT id _Nullable YMUpdateResolveWindowIdentity(NSDictionary *identity, NSError **error);

/// All dictionaries are geometry/identity allowlists, never window titles,
/// document contents, application paths, screenshots or account state.
/// A profile contains ordinal, displayID, width, height and hiDPI. Its current
/// bounds are obtained from the independent display inventory.
@protocol YMUpdateWorkspaceRecoveryBackend <NSObject>
/// Complete display inventory plus all windows intersecting the owned outputs.
/// Implementations must reject modal, hidden/fullscreen, ambiguous or immovable
/// candidate windows. No mutation or Accessibility permission prompt is allowed.
- (nullable NSDictionary *)captureWithProfiles:(NSArray<NSDictionary *> *)profiles
                                        error:(NSError **)error;
/// Reacquires only the exact process-start identity and CG window ID. A missing
/// or uncertain identity is an error, never an application-level fallback.
- (nullable NSDictionary *)readWindow:(NSDictionary *)identity error:(NSError **)error;
/// Checks identity and current geometry again immediately before a write and
/// verifies the resulting geometry. Never activates an application or sends input.
- (BOOL)moveWindow:(NSDictionary *)identity fromFrame:(NSDictionary *)before
           toFrame:(NSDictionary *)after error:(NSError **)error;
- (NSTimeInterval)now;
- (NSString *)bootSessionIdentifier;
- (NSString *)runningVersion;
- (NSString *)runningBuild;
@end

/// Main-thread-only restart transaction. It never creates/removes displays,
/// saves documents, launches applications or changes physical display state.
/// The owner must serialize display/window operations until the update finishes.
@interface YMUpdateWorkspaceRecovery : NSObject
- (instancetype)init;
/// Injection is also used by pure tests; those tests never query WindowServer.
- (instancetype)initWithDirectoryURL:(NSURL *)directory
                            backend:(id<YMUpdateWorkspaceRecoveryBackend>)backend NS_DESIGNATED_INITIALIZER;
/// A successful prepare writes a private 0600 journal in a private 0700 directory.
/// It does not make the journal eligible for startup recovery yet.
- (BOOL)prepareRestartWithProfiles:(NSArray<NSDictionary *> *)profiles
                   targetVersion:(NSString *)version targetBuild:(NSString *)build
                originCheckpoints:(NSArray<NSDictionary *> *)origins error:(NSError **)error;
/// Final read-only comparison of the exact captured windows and full topology.
/// Arms the journal only after that comparison succeeds. Call immediately before
/// granting the updater permission to terminate; failure must cancel installation.
- (BOOL)commitPreparedRestart:(NSError **)error;
/// An armed, valid, same-boot journal exposes saved profile ordinals/modes/bounds
/// to the controller. It must recreate those profiles before restoring windows.
- (nullable NSArray<NSDictionary *> *)pendingProfilesWithError:(NSError **)error;
/// Called only for an explicit Retry action. It may claim a retained journal
/// from an interrupted recovery; it never bypasses identity/topology/age gates.
- (nullable NSArray<NSDictionary *> *)retryPendingProfilesWithError:(NSError **)error;
/// New profiles must have the same ordinal/mode/bounds and preserve every
/// unowned output. All window identities are preflighted before the first move.
/// Failure retains the journal and does not sweep other application windows.
- (BOOL)verifyRestorationEnvironmentWithProfiles:(NSArray<NSDictionary *> *)profiles error:(NSError **)error;
/// Call after the workspace manager has adopted restoredOriginCheckpoints.
- (BOOL)completeRestoration:(NSError **)error;
- (BOOL)restoreWithProfiles:(NSArray<NSDictionary *> *)profiles error:(NSError **)error;
@property(nonatomic, copy, readonly) NSArray<NSDictionary *> *restoredOriginCheckpoints;
/// Cancels only this transaction's journal. Never discards an unknown journal.
- (BOOL)cancelPreparedRestart:(NSError **)error;
/// Explicit user confirmation only. Removes a validated private journal without
/// moving windows or changing any display, including expired checkpoints.
- (BOOL)discardRecoveryAfterUserRequest:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
