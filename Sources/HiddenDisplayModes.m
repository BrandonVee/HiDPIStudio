#import "HiddenDisplayModes.h"
#import <dlfcn.h>
#import <math.h>
#import <stddef.h>

// System ABI declarations, independently wrapped here. Offsets verified by a
// read-only probe on macOS 26.4 and checked against Crisp's published header:
// https://github.com/didriksg/Crisp/blob/main/Crisp/Crisp-Bridging-Header.h
typedef struct {
    uint32_t modeNumber;
    uint32_t flags;
    uint32_t width;
    uint32_t height;
    uint32_t depth;
    uint32_t reservedA[42];
    uint16_t reservedB;
    uint16_t frequency;
    uint32_t reservedC[4];
    float density;
} HDModeDescription;

_Static_assert(sizeof(HDModeDescription) == 212, "Unexpected private mode ABI size");
_Static_assert(offsetof(HDModeDescription, frequency) == 190, "Unexpected refresh offset");
_Static_assert(offsetof(HDModeDescription, density) == 208, "Unexpected density offset");

typedef CGError (*HDModeCountFunction)(CGDirectDisplayID, int32_t *);
typedef CGError (*HDModeDescriptionFunction)(CGDirectDisplayID, int32_t, void *, int32_t);
typedef CGError (*HDModeConfigureFunction)(CGDisplayConfigRef, CGDirectDisplayID, int32_t);

typedef struct {
    void *coreGraphics;
    void *skyLight;
    HDModeCountFunction count;
    HDModeDescriptionFunction describe;
    HDModeConfigureFunction configure;
} HDModeAPIs;

static void *HDModeSymbol(const HDModeAPIs *api, const char *name) {
    void *symbol = api->coreGraphics ? dlsym(api->coreGraphics, name) : NULL;
    return symbol ?: (api->skyLight ? dlsym(api->skyLight, name) : NULL);
}

static const HDModeAPIs *HDGetModeAPIs(void) {
    static HDModeAPIs api;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Keep handles loaded for as long as any function pointer can be used.
        api.coreGraphics = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY | RTLD_LOCAL);
        api.skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL);
        api.count = (HDModeCountFunction)HDModeSymbol(&api, "CGSGetNumberOfDisplayModes");
        api.describe = (HDModeDescriptionFunction)HDModeSymbol(&api, "CGSGetDisplayModeDescriptionOfLength");
        api.configure = (HDModeConfigureFunction)HDModeSymbol(&api, "CGSConfigureDisplayMode");
    });
    return &api;
}

static BOOL HDUsableMode(const HDModeDescription *mode) {
    // The private flag is the same usability exclusion used by the public API.
    // Only strict 2x modes are accepted; unknown future densities are rejected.
    return !(mode->flags & 0x40000000) && isfinite(mode->density) &&
           fabsf(mode->density - 2.0f) < 0.001f &&
           mode->width >= 320 && mode->height >= 200 &&
           mode->width <= 16384 && mode->height <= 16384 &&
           mode->frequency <= 1000;
}

static BOOL HDModeFailure(NSError **error, NSInteger code, NSString *description) {
    if (error) *error = [NSError errorWithDomain:@"HiDPIStudio.HiddenModes" code:code
                                      userInfo:@{NSLocalizedDescriptionKey: description}];
    return NO;
}

@interface HDHiddenDisplayMode ()
- (instancetype)initWithDescription:(HDModeDescription)description;
@end

@implementation HDHiddenDisplayMode
- (instancetype)initWithDescription:(HDModeDescription)description {
    self = [super init];
    if (self) {
        _modeID = (int32_t)description.modeNumber;
        _width = description.width;
        _height = description.height;
        _pixelWidth = description.width * 2;
        _pixelHeight = description.height * 2;
        _refreshRate = description.frequency;
        _flags = description.flags;
    }
    return self;
}
@end

@implementation HDHiddenDisplayModes
+ (BOOL)isAvailable {
    const HDModeAPIs *api = HDGetModeAPIs();
    return api->count && api->describe && api->configure;
}

+ (NSArray<HDHiddenDisplayMode *> *)modesForDisplay:(CGDirectDisplayID)display {
    if (![self isAvailable] || !CGDisplayIsOnline(display)) return @[];
    const HDModeAPIs *api = HDGetModeAPIs();
    int32_t count = 0;
    if (api->count(display, &count) != kCGErrorSuccess || count <= 0 || count > 8192) return @[];

    NSMutableSet<NSNumber *> *publicIDs = [NSMutableSet set];
    NSDictionary *options = @{(__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES};
    CFArrayRef publicModes = CGDisplayCopyAllDisplayModes(display, (__bridge CFDictionaryRef)options);
    if (publicModes) {
        for (CFIndex i = 0; i < CFArrayGetCount(publicModes); i++) {
            CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(publicModes, i);
            [publicIDs addObject:@(CGDisplayModeGetIODisplayModeID(mode))];
        }
        CFRelease(publicModes);
    }

    NSMutableSet<NSNumber *> *seen = [NSMutableSet set];
    NSMutableArray<HDHiddenDisplayMode *> *result = [NSMutableArray array];
    for (int32_t index = 0; index < count; index++) {
        HDModeDescription description = {0};
        if (api->describe(display, index, &description, sizeof(description)) != kCGErrorSuccess || !HDUsableMode(&description)) continue;
        NSNumber *identifier = @((int32_t)description.modeNumber);
        if ([publicIDs containsObject:identifier] || [seen containsObject:identifier]) continue;
        [seen addObject:identifier];
        [result addObject:[[HDHiddenDisplayMode alloc] initWithDescription:description]];
    }
    return result;
}

+ (BOOL)configure:(CGDisplayConfigRef)config display:(CGDirectDisplayID)display
             mode:(int32_t)modeID error:(NSError **)error {
    if (!config) return HDModeFailure(error, 1, @"缺少显示设置事务，已取消切换。");
    if (![self isAvailable]) return HDModeFailure(error, 2, @"当前 macOS 未提供兼容的原生扩展模式接口。");
    if (!CGDisplayIsOnline(display)) return HDModeFailure(error, 3, @"显示器已断开，请刷新后重试。");
    const HDModeAPIs *api = HDGetModeAPIs();
    int32_t count = 0;
    if (api->count(display, &count) != kCGErrorSuccess || count <= 0 || count > 8192)
        return HDModeFailure(error, 4, @"无法安全读取当前原生模式表。");
    BOOL found = NO;
    for (int32_t index = 0; index < count; index++) {
        HDModeDescription description = {0};
        if (api->describe(display, index, &description, sizeof(description)) == kCGErrorSuccess &&
            (int32_t)description.modeNumber == modeID && HDUsableMode(&description)) {
            found = YES;
            break;
        }
    }
    if (!found) return HDModeFailure(error, 5, @"请求的原生 HiDPI 模式已不可用，请刷新后重试。");
    // This is a CGDisplayConfigRef from Begin, never a CGS connection identifier.
    CGError status = api->configure(config, display, modeID);
    if (status != kCGErrorSuccess)
        return HDModeFailure(error, status, [NSString stringWithFormat:@"macOS 拒绝原生 HiDPI 模式（%d）。", status]);
    return YES;
}
@end
