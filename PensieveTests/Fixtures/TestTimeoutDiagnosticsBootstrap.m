#import <Foundation/Foundation.h>

extern void PensieveInstallTimeoutDiagnostics(void);

// XCTest loads the bundle before running any cases. Never register from a timed-out worker.
@interface PensieveTimeoutDiagnosticsBootstrap : NSObject
@end

@implementation PensieveTimeoutDiagnosticsBootstrap
+ (void)load {
    if ([NSThread isMainThread]) {
        PensieveInstallTimeoutDiagnostics();
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{ PensieveInstallTimeoutDiagnostics(); });
    }
}
@end
