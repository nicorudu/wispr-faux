#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Swift can't catch Objective-C exceptions, and some AVAudioEngine calls raise them
/// instead of returning errors (e.g. `installTap` when the input device's hardware format
/// is invalid while it's being unplugged or reconnected). Uncaught, they abort the app.
@interface DKObjCExceptionCatcher : NSObject

/// Runs `block`; if it raises an Objective-C exception, returns NO and fills `error`
/// with the exception's name and reason. In Swift: `try DKObjCExceptionCatcher.run { … }`.
+ (BOOL)runBlock:(NS_NOESCAPE void (^)(void))block error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(run(_:));

@end

/// Error domain for caught exceptions; `userInfo` carries the exception's name under
/// `DKObjCExceptionNameKey`.
extern NSErrorDomain const DKObjCExceptionErrorDomain;
extern NSString * const DKObjCExceptionNameKey;

NS_ASSUME_NONNULL_END
