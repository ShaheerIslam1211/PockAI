#import "SafeObjC.h"

BOOL TPSafely(NSString *label, NS_NOESCAPE void (^block)(void)) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        NSLog(@"[TouchPlay] Caught exception in %@: %@ — %@", label, exception.name, exception.reason);
        return NO;
    }
}
