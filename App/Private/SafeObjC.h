//
//  SafeObjC.h
//  TouchPlay
//
//  Runs a block and catches Objective-C exceptions (AppKit layout errors and the like), which Swift
//  can't catch. Returns NO and logs when the block threw, so one bad update can't take the app down.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
BOOL TPSafely(NSString *label, NS_NOESCAPE void (^block)(void));
NS_ASSUME_NONNULL_END
