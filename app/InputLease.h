#import <AppKit/AppKit.h>
#import "InputLeasePolicy.h"

NS_ASSUME_NONNULL_BEGIN

// Runs inside the app: answers agent requests to borrow the shared mouse and
// keyboard, asks the person first, and keeps a notice on the physical main
// display while a lease is active. It never posts input itself and cannot stop
// an agent's tool from posting; the agent checks the lease before each batch.
@interface YMInputLeaseCenter : NSObject
@property(nonatomic, readonly, nullable) NSString *activeLeaseID;
- (void)start;
- (void)endActiveLeaseWithReason:(NSString *)reason;
- (void)stop;
@end

// Command-line client: Yomado --input request|status|release ...
int YMInputLeaseCommand(int argc, const char *_Nonnull argv[_Nonnull]);

NS_ASSUME_NONNULL_END
