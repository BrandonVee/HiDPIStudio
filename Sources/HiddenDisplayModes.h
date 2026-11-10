#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// A native 2x desktop mode present in WindowServer's private mode table.
/// The private descriptor reports integer Hz only. Read back the applied public
/// CGDisplayMode to obtain the actual refresh rate, including fractional rates.
@interface HDHiddenDisplayMode : NSObject
@property(nonatomic, readonly) int32_t modeID;
@property(nonatomic, readonly) uint32_t width;
@property(nonatomic, readonly) uint32_t height;
@property(nonatomic, readonly) uint32_t pixelWidth;
@property(nonatomic, readonly) uint32_t pixelHeight;
@property(nonatomic, readonly) double refreshRate;
@property(nonatomic, readonly) uint32_t flags;
@end

@interface HDHiddenDisplayModes : NSObject
+ (BOOL)isAvailable;
/// Only returns viable 2x modes absent from the public CG mode list.
+ (NSArray<HDHiddenDisplayMode *> *)modesForDisplay:(CGDirectDisplayID)display;
/// Queues one freshly validated mode in an existing CoreGraphics transaction.
/// The caller owns Begin/Complete/Cancel, identity checks and post-commit readback.
+ (BOOL)configure:(CGDisplayConfigRef)config
          display:(CGDirectDisplayID)display
             mode:(int32_t)modeID
            error:(NSError *_Nullable *_Nullable)error;
@end

NS_ASSUME_NONNULL_END
