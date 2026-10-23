#import <Foundation/Foundation.h>
#import "UpdateWorkspaceRecovery.h"

NS_ASSUME_NONNULL_BEGIN
/// Hosted-fixture orchestration around unchanged production display/recovery APIs.
/// Owns only its one test virtual screen. Separate fixture apps outlive the updater.
@interface YMUpdateRuntimeWorkspace : NSObject
- (instancetype)initWithDirectory:(NSString *)directory workPID:(pid_t)workPID probePID:(pid_t)probePID
    backend:(id<YMUpdateWorkspaceRecoveryBackend>)backend record:(void (^)(NSString *, NSDictionary *))record;
- (void)prepareOccupiedWorkspace:(void (^)(BOOL, NSError * _Nullable))completion;
- (void)recreateProfiles:(NSArray<NSDictionary *> *)profiles completion:(void (^)(BOOL, NSError * _Nullable))completion;
- (NSArray<NSDictionary *> *)profiles;
- (BOOL)verifyRestoredWorkspace:(NSError **)error;
- (void)recordRecoveryFailureDiagnostic;
- (void)recordSurfaceInventoryDiagnostic;
@end
NS_ASSUME_NONNULL_END
