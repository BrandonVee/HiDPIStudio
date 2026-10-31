#import "VirtualDisplay.h"
#import <objc/runtime.h>
#import <math.h>

// The declarations describe OS objects, not implementations. Instantiate by name
// so an OS that removes the private classes can still run the native-mode UI.
@interface NSObject (HDPrivateDisplayAPI)
@property(nonatomic) unsigned int vendorID, productID, serialNum, serialNumber;
@property(nonatomic) unsigned int maxPixelsWide, maxPixelsHigh, hiDPI;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) CGPoint redPrimary, greenPrimary, bluePrimary, whitePoint;
@property(nonatomic, strong) NSString *name;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, strong) NSArray *modes;
@property(nonatomic, readonly) unsigned int displayID;
- (id)initWithDescriptor:(id)descriptor;
- (id)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)rate;
- (BOOL)applySettings:(id)settings;
@end

@implementation HDVirtualDisplay {
    id _display;
}
+ (BOOL)isAvailable {
    NSDictionary *requirements = @{
        @"CGVirtualDisplay": @[@"initWithDescriptor:", @"applySettings:", @"displayID"],
        @"CGVirtualDisplayDescriptor": @[@"setVendorID:", @"setProductID:", @"setSerialNum:",
            @"setName:", @"setQueue:", @"setMaxPixelsWide:", @"setMaxPixelsHigh:",
            @"setSizeInMillimeters:", @"setRedPrimary:", @"setGreenPrimary:",
            @"setBluePrimary:", @"setWhitePoint:"],
        @"CGVirtualDisplaySettings": @[@"setHiDPI:", @"setModes:"],
        @"CGVirtualDisplayMode": @[@"initWithWidth:height:refreshRate:"]
    };
    for (NSString *name in requirements) {
        Class cls = NSClassFromString(name);
        if (!cls) return NO;
        for (NSString *selector in requirements[name]) {
            if (![cls instancesRespondToSelector:NSSelectorFromString(selector)]) return NO;
        }
    }
    return YES;
}
- (instancetype)initWithWidth:(uint32_t)width height:(uint32_t)height
                 refreshRate:(double)rate name:(NSString *)name error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    NSString *failure = nil;
    if (width < 640 || height < 480 || width > 3840 || height > 2160) {
        failure = @"虚拟屏幕尺寸需在 640 × 480 到 3840 × 2160 之间。";
    } else if (!isfinite(rate) || rate < 24 || rate > 240) {
        failure = @"自定义刷新率需为 24–240 Hz 之间的有效数值。";
    } else if (![HDVirtualDisplay isAvailable]) {
        failure = @"此版本 macOS 未提供兼容的虚拟屏幕接口。仍可使用系统 HiDPI 模式。";
    } else {
        @try {
            id descriptor = [[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
            [descriptor setName:name];
            [descriptor setQueue:dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0)];
            [descriptor setVendorID:0x4844];
            [descriptor setProductID:0x5354];
            uint32_t serial = arc4random_uniform(UINT32_MAX - 1) + 1;
            [descriptor setSerialNum:serial];
            if ([descriptor respondsToSelector:@selector(setSerialNumber:)])
                [descriptor setSerialNumber:serial];
            [descriptor setMaxPixelsWide:width * 2];
            [descriptor setMaxPixelsHigh:height * 2];
            [descriptor setSizeInMillimeters:CGSizeMake(width * 25.4 / 110.0, height * 25.4 / 110.0)];
            [descriptor setRedPrimary:CGPointMake(0.64, 0.33)];
            [descriptor setGreenPrimary:CGPointMake(0.30, 0.60)];
            [descriptor setBluePrimary:CGPointMake(0.15, 0.06)];
            [descriptor setWhitePoint:CGPointMake(0.3127, 0.3290)];
            _display = [[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:descriptor];
            if (!_display) {
                failure = @"macOS 拒绝创建虚拟屏幕。请检查显示器数量限制。";
            } else {
                id settings = [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
                [settings setHiDPI:1];
                id mode = [[NSClassFromString(@"CGVirtualDisplayMode") alloc]
                           initWithWidth:width height:height refreshRate:rate];
                if (!mode) {
                    failure = @"macOS 拒绝了虚拟 HiDPI 模式。";
                } else {
                    [settings setModes:@[mode]];
                    if (![_display applySettings:settings])
                        failure = @"macOS 无法应用虚拟 HiDPI 设置。";
                }
            }
        } @catch (NSException *exception) {
            failure = [@"虚拟屏幕接口不可用：" stringByAppendingString:exception.reason ?: exception.name];
        }
    }
    if (failure) {
        _display = nil;
        if (error) *error = [NSError errorWithDomain:@"HiDPIStudio" code:1
                                          userInfo:@{NSLocalizedDescriptionKey:failure}];
        return nil;
    }
    return self;
}
- (CGDirectDisplayID)displayID { return _display ? [_display displayID] : 0; }
- (void)disconnect { _display = nil; }
@end
