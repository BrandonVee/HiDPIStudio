#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "DDCTransport.h"
#import "HiddenDisplayModes.h"

NS_ASSUME_NONNULL_BEGIN

/// Small, runtime-checked boundary around macOS's undocumented virtual display API.
@interface HDVirtualDisplay : NSObject
@property(nonatomic, readonly) CGDirectDisplayID displayID;
+ (BOOL)isAvailable;
- (nullable instancetype)initWithWidth:(uint32_t)width
                                height:(uint32_t)height
                           refreshRate:(double)rate
                                  name:(NSString *)name
                                 error:(NSError *_Nullable *_Nullable)error;
- (void)disconnect;
@end

NS_ASSUME_NONNULL_END
