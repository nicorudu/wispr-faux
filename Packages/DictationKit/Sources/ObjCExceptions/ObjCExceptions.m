#import "ObjCExceptions.h"

NSErrorDomain const DKObjCExceptionErrorDomain = @"DKObjCException";
NSString * const DKObjCExceptionNameKey = @"DKObjCExceptionName";

@implementation DKObjCExceptionCatcher

+ (BOOL)runBlock:(NS_NOESCAPE void (^)(void))block error:(NSError * _Nullable * _Nullable)error {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            *error = [NSError errorWithDomain:DKObjCExceptionErrorDomain
                                         code:1
                                     userInfo:@{
                NSLocalizedDescriptionKey: exception.reason ?: exception.name,
                DKObjCExceptionNameKey: exception.name,
            }];
        }
        return NO;
    }
}

@end
