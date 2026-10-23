// Independent test window that stays alive through the updater process restart.
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <fcntl.h>
#import <unistd.h>

@interface YMRuntimeWindow : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) NSTextField *label;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic) NSUInteger counter;
@property(nonatomic, copy) NSString *role;
@property(nonatomic, copy) NSString *path;
@end
@implementation YMRuntimeWindow
- (void)sample {
    self.counter++;
    self.label.stringValue=[NSString stringWithFormat:@"%@\nSurviving window\n%lu",self.role,(unsigned long)self.counter];
    NSArray *windows=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow,(CGWindowID)self.window.windowNumber));
    NSDictionary *raw=windows.count==1 ? windows.firstObject : nil; CGRect frame=CGRectZero;
    if (raw) CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)raw[(__bridge NSString *)kCGWindowBounds],&frame);
    NSDictionary *record=@{@"event":@"window-sample",@"role":self.role,@"pid":@(getpid()),@"windowID":@(self.window.windowNumber),
        @"counter":@(self.counter),@"time":@(NSDate.date.timeIntervalSince1970),@"onscreen":raw[(__bridge NSString *)kCGWindowIsOnscreen] ?: @NO,
        @"frame":@{@"x":@(frame.origin.x),@"y":@(frame.origin.y),@"width":@(frame.size.width),@"height":@(frame.size.height)}};
    NSData *json=[NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:NULL];
    NSMutableData *line=json.mutableCopy; [line appendBytes:"\n" length:1];
    int fd=open(self.path.fileSystemRepresentation,O_WRONLY|O_CREAT|O_APPEND,0600);
    if (fd<0 || write(fd,line.bytes,line.length)!=(ssize_t)line.length) _exit(4);
    close(fd);
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    self.role=[NSBundle.mainBundle objectForInfoDictionaryKey:@"YMFixtureWindowRole"];
    self.path=[NSBundle.mainBundle objectForInfoDictionaryKey:@"YMFixtureSamplePath"];
    BOOL probe=[self.role isEqual:@"physical-probe"];
    self.window=[[NSWindow alloc] initWithContentRect:NSMakeRect(probe ? 40 : 430,100,probe ? 340 : 460,280)
        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
    self.window.releasedWhenClosed=NO; self.window.title=self.role;
    self.label=[NSTextField labelWithString:self.role]; self.label.frame=NSMakeRect(20,30,300,220);
    self.label.font=[NSFont monospacedSystemFontOfSize:30 weight:NSFontWeightMedium]; self.label.maximumNumberOfLines=4;
    [self.window.contentView addSubview:self.label]; [self.window orderFront:nil];
    [self sample]; self.timer=[NSTimer scheduledTimerWithTimeInterval:.5 target:self selector:@selector(sample) userInfo:nil repeats:YES];
}
@end
int main(void) {
    @autoreleasepool {
        if (![[NSBundle.mainBundle objectForInfoDictionaryKey:@"YMHostedDisposableFixture"] boolValue] ||
            ![NSFileManager.defaultManager fileExistsAtPath:@"/Users/runner"]) return 3;
        [NSApplication sharedApplication]; NSApp.activationPolicy=NSApplicationActivationPolicyRegular;
        YMRuntimeWindow *delegate=[YMRuntimeWindow new]; NSApp.delegate=delegate; [NSApp run];
    }
    return 0;
}
