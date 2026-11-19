//
//  SystemHelper.h
//  Pock
//
//  Created by Pierluigi Galdi on 06/07/2019.
//  Copyright © 2019 Pierluigi Galdi. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

#include <dlfcn.h>
// Private symbols resolved at runtime (no private-framework linking, and no crash if one disappears).
static inline void SACLockScreenImmediate(void) {
    static void (*fn)(void) = NULL;
    if (!fn) {
        void *h = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY);
        fn = h ? (void (*)(void))dlsym(h, "SACLockScreenImmediate") : NULL;
    }
    if (fn) fn();
}

@interface SystemHelper : NSObject
+ (void)lock;
+ (void)sleep;
@end


/// Thanks to: https://github.com/Astrr/Pock/commit/64f8b55a7ac67c58eb3d24a65a3c70ecde311da7
NS_ASSUME_NONNULL_BEGIN
static inline void *PKCoreDisplay(const char *name) {
    static void *h = NULL;
    if (!h) h = dlopen("/System/Library/Frameworks/CoreDisplay.framework/Versions/Current/CoreDisplay", RTLD_LAZY);
    return h ? dlsym(h, name) : NULL;
}
static inline void CoreDisplay_Display_SetUserBrightness(int CGDirectDisplayID, double level) {
    void (*fn)(int, double) = (void (*)(int, double))PKCoreDisplay("CoreDisplay_Display_SetUserBrightness");
    if (fn) fn(CGDirectDisplayID, level);
}
static inline double CoreDisplay_Display_GetUserBrightness(int CGDirectDisplayID) {
    double (*fn)(int) = (double (*)(int))PKCoreDisplay("CoreDisplay_Display_GetUserBrightness");
    return fn ? fn(CGDirectDisplayID) : 0.5;
}
NS_ASSUME_NONNULL_END
