#import <AppKit/AppKit.h>
#import <dispatch/dispatch.h>

NS_ASSUME_NONNULL_BEGIN

// Pure geometry, in AppKit global points (upward Y; no pixel/CG conversion).
typedef struct {
    NSRect frame;
    NSRect visibleFrame;
    BOOL isVirtual;
    BOOL isMain;
} YMPanelScreen;

typedef struct {
    NSRect frame;
    NSInteger screenIndex; // NSNotFound if no usable screen exists.
    BOOL shouldMove;
} YMPanelPlacement;

// Keeps an existing physical-screen position where possible. Otherwise prefers
// the physical screen under the pointer, then the physical main/first screen.
// If no physical screen is usable, applies the same policy to virtual screens.
// No AppKit objects, display enumeration, window creation or system mutation.
FOUNDATION_EXPORT YMPanelPlacement YMControlPanelPlacement(
    NSRect panelFrame, const YMPanelScreen * _Nullable screens,
    NSUInteger screenCount, NSPoint pointerLocation);

@protocol YMPanelPresentationEnvironment <NSObject>
- (NSApplicationActivationPolicy)activationPolicy;
- (BOOL)requestActivationPolicy:(NSApplicationActivationPolicy)policy;
- (void)activateApplication;
- (void)deferUntilAfterMenuTracking:(dispatch_block_t)block;
- (BOOL)hasAttachedSheetForWindow:(NSWindow *)window;
- (void)presentWindow:(NSWindow *)window;
- (void)hideWindow:(NSWindow *)window;
- (void)reportActivationPolicyFailure:(NSApplicationActivationPolicy)requested
                        actualPolicy:(NSApplicationActivationPolicy)actual;
@end

@interface YMControlPanelPresenter : NSObject
@property(nonatomic, readonly) BOOL panelOpen;
- (instancetype)initWithWindow:(NSWindow * _Nullable)window;
- (instancetype)initWithWindow:(NSWindow * _Nullable)window
                  environment:(id<YMPanelPresentationEnvironment>)environment;
- (void)open;
- (BOOL)closeWindow:(NSWindow * _Nullable)window;
- (void)invalidate;
@end

// Explicit open/reopen only; never call from inventory refresh or a timer.
// Requests activation immediately on the main thread, then queues presentation
// after menu tracking. Only the passed panel is repositioned; no displays or
// other applications are changed.
FOUNDATION_EXPORT void YMPresentControlPanel(NSWindow * _Nullable window);

NS_ASSUME_NONNULL_END
