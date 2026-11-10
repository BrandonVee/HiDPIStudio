#import "DDCTransport.h"
#import <IOKit/IOKitLib.h>
#import <dlfcn.h>
#import <unistd.h>

typedef CFDictionaryRef (*HDDisplayInfoFunction)(uint32_t);
typedef CFTypeRef (*HDAVCreateFunction)(CFAllocatorRef, io_service_t);
typedef IOReturn (*HDAVTransferFunction)(CFTypeRef, uint32_t, uint32_t, void *, uint32_t);

typedef struct {
    void *ioKitLibrary;
    void *coreDisplayLibrary;
    HDDisplayInfoFunction displayInfo;
    HDAVCreateFunction create;
    HDAVTransferFunction read;
    HDAVTransferFunction write;
} HDAPIs;

static const HDAPIs *HDGetAPIs(void) {
    static HDAPIs api;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      // Keep framework handles alive for the process lifetime: function pointers
      // and live IOAVService objects must never outlive their loaded framework.
      api.ioKitLibrary = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY | RTLD_LOCAL);
      api.coreDisplayLibrary =
          dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY | RTLD_LOCAL);
      if (api.ioKitLibrary) {
          api.create = (HDAVCreateFunction)dlsym(api.ioKitLibrary, "IOAVServiceCreateWithService");
          api.read = (HDAVTransferFunction)dlsym(api.ioKitLibrary, "IOAVServiceReadI2C");
          api.write = (HDAVTransferFunction)dlsym(api.ioKitLibrary, "IOAVServiceWriteI2C");
      }
      if (api.coreDisplayLibrary)
          api.displayInfo =
              (HDDisplayInfoFunction)dlsym(api.coreDisplayLibrary, "CoreDisplay_DisplayCreateInfoDictionary");
    });
    return &api;
}

static BOOL HDFail(NSError **error, NSInteger code, NSString *message) {
    if (error)
        *error = [NSError errorWithDomain:@"HiDPIStudio.DDC" code:code userInfo:@{NSLocalizedDescriptionKey : message}];
    return NO;
}

static NSString *HDStringProperty(io_registry_entry_t entry, CFStringRef key) {
    id value = CFBridgingRelease(IORegistryEntryCreateCFProperty(entry, key, kCFAllocatorDefault, 0));
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static NSString *HDRegistryName(io_registry_entry_t entry) {
    io_name_t buffer = {};
    return IORegistryEntryGetName(entry, buffer) == KERN_SUCCESS ? [NSString stringWithUTF8String:buffer] : nil;
}

/// Returns one retained IORegistry entry. Rejects missing paths and ambiguous
/// associations instead of matching a monitor by name or registry enumeration order.
static io_service_t HDCopyMatchedProxy(uint32_t displayID, NSString **locationOut, NSString **uuidOut,
                                       uint64_t *registryIDOut, uint32_t *chipOut, NSError **error) {
    const HDAPIs *api = HDGetAPIs();
    if (!api->displayInfo || !api->create || !api->read || !api->write) {
        HDFail(error, 1, @"此 macOS 未提供兼容的 Apple Silicon DDC 接口。");
        return IO_OBJECT_NULL;
    }
    if (!CGDisplayIsOnline(displayID) || CGDisplayIsBuiltin(displayID)) {
        HDFail(error, 2, @"DDC 仅用于已连接的外接实体显示器。");
        return IO_OBJECT_NULL;
    }
    id rawInfo = CFBridgingRelease(api->displayInfo(displayID));
    NSDictionary *info = [rawInfo isKindOfClass:NSDictionary.class] ? rawInfo : nil;
    NSString *location = [info[@"IODisplayLocation"] isKindOfClass:NSString.class] ? info[@"IODisplayLocation"] : nil;
    NSString *uuid = [info[@"kCGDisplayUUID"] isKindOfClass:NSString.class] ? info[@"kCGDisplayUUID"] : nil;
    if (location.length == 0 || uuid.length == 0) {
        HDFail(error, 3, @"系统未提供此屏幕的物理连接位置，无法安全匹配 DDC 通道。");
        return IO_OBJECT_NULL;
    }

    io_registry_entry_t adapter = IORegistryEntryCopyFromPath(kIOMainPortDefault, (__bridge CFStringRef)location);
    uint64_t adapterID = 0;
    if (!adapter || IORegistryEntryGetRegistryEntryID(adapter, &adapterID) != KERN_SUCCESS) {
        if (adapter)
            IOObjectRelease(adapter);
        HDFail(error, 4, @"显示器的系统连接节点已失效，请刷新显示器。");
        return IO_OBJECT_NULL;
    }
    io_registry_entry_t adapterParent = IO_OBJECT_NULL;
    NSString *portName = nil;
    if (IORegistryEntryGetParentEntry(adapter, kIOServicePlane, &adapterParent) == KERN_SUCCESS) {
        portName = HDRegistryName(adapterParent);
        IOObjectRelease(adapterParent);
    }
    IOObjectRelease(adapter);

    io_registry_entry_t root = IORegistryGetRootEntry(kIOMainPortDefault);
    io_iterator_t iterator = IO_OBJECT_NULL;
    kern_return_t status =
        root ? IORegistryEntryCreateIterator(root, kIOServicePlane, kIORegistryIterateRecursively, &iterator)
             : KERN_FAILURE;
    if (root)
        IOObjectRelease(root);
    if (status != KERN_SUCCESS) {
        HDFail(error, 5, @"无法枚举系统显示器连接节点。");
        return IO_OBJECT_NULL;
    }

    BOOL withinTargetFramebuffer = NO;
    io_service_t selected = IO_OBJECT_NULL;
    uint64_t selectedID = 0;
    uint32_t selectedChip = 0x37;
    NSUInteger matches = 0;
    io_registry_entry_t entry;
    while ((entry = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        if (IOObjectConformsTo(entry, "IOMobileFramebuffer")) {
            uint64_t candidateID = 0;
            withinTargetFramebuffer =
                IORegistryEntryGetRegistryEntryID(entry, &candidateID) == KERN_SUCCESS && candidateID == adapterID;
        } else if (withinTargetFramebuffer && [HDRegistryName(entry) isEqualToString:@"DCPAVServiceProxy"] &&
                   [HDStringProperty(entry, CFSTR("Location")) isEqualToString:@"External"]) {
            uint64_t candidateID = 0;
            io_registry_entry_t parent = IO_OBJECT_NULL;
            NSString *provider = nil;
            NSString *endpoint = nil;
            if (IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS) {
                provider = HDStringProperty(parent, CFSTR("EPICProviderClass"));
                endpoint = HDRegistryName(parent);
                IOObjectRelease(parent);
            }
            // Current DCP endpoints name the associated display port explicitly.
            // Validate that additional evidence whenever this naming is available.
            BOOL endpointMatches = YES;
            if ([portName hasPrefix:@"disp"] && [endpoint containsString:@":dcpav-service-epic:"])
                endpointMatches = [endpoint hasPrefix:[portName stringByAppendingString:@":"]];
            if (endpointMatches && IORegistryEntryGetRegistryEntryID(entry, &candidateID) == KERN_SUCCESS &&
                candidateID != selectedID) {
                matches += 1;
                if (!selected) {
                    IOObjectRetain(entry);
                    selected = entry;
                    selectedID = candidateID;
                    // This is a bridge address; DDC packet checksum still uses 0x6E.
                    selectedChip = [provider isEqualToString:@"AppleDCPMCDP29XX"] ? 0xB7 : 0x37;
                }
            }
        }
        IOObjectRelease(entry);
    }
    IOObjectRelease(iterator);
    if (matches != 1 || !selected) {
        if (selected)
            IOObjectRelease(selected);
        HDFail(error, 6,
               matches > 1 ? @"此显示器对应多个 DDC 通道，已停止以避免操作错误屏幕。"
                           : @"未找到此显示器的 DDC 通道。请确认直连或使用支持 DDC 的连接方式。");
        return IO_OBJECT_NULL;
    }
    if (locationOut)
        *locationOut = location;
    if (uuidOut)
        *uuidOut = uuid;
    if (registryIDOut)
        *registryIDOut = selectedID;
    if (chipOut)
        *chipOut = selectedChip;
    return selected;
}

@implementation HDAppleDDC {
    CFTypeRef _service;
    NSString *_displayUUID;
}
+ (BOOL)isAvailable {
#if defined(__arm64__)
    const HDAPIs *api = HDGetAPIs();
    return api->displayInfo && api->create && api->read && api->write;
#else
    return NO;
#endif
}
- (instancetype)initWithDisplayID:(uint32_t)displayID error:(NSError **)error {
    self = [super init];
    if (!self)
        return nil;
    if (![HDAppleDDC isAvailable]) {
        HDFail(error, 1, @"此 DDC 通道需要支持的 Apple Silicon Mac。");
        return nil;
    }
    NSString *location = nil, *uuid = nil;
    io_service_t proxy = HDCopyMatchedProxy(displayID, &location, &uuid, &_registryEntryID, &_chipAddress, error);
    if (!proxy)
        return nil;
    _ioDisplayLocation = [location copy];
    _displayUUID = [uuid copy];
    _displayID = displayID;
    _service = HDGetAPIs()->create(kCFAllocatorDefault, proxy);
    IOObjectRelease(proxy);
    if (!_service) {
        HDFail(error, 7, @"系统拒绝打开此显示器的 DDC 通道。");
        return nil;
    }
    return self;
}
- (BOOL)validateConnection:(NSError **)error {
    NSString *location = nil, *uuid = nil;
    uint64_t entryID = 0;
    uint32_t chip = 0;
    io_service_t proxy = HDCopyMatchedProxy(_displayID, &location, &uuid, &entryID, &chip, error);
    if (!proxy)
        return NO;
    IOObjectRelease(proxy);
    if (entryID != _registryEntryID || chip != _chipAddress || ![uuid isEqualToString:_displayUUID] ||
        ![location isEqualToString:_ioDisplayLocation])
        return HDFail(error, 8, @"显示器或 DDC 通道已变化，已取消操作，请重新读取亮度。");
    return YES;
}
- (BOOL)sendPacket:(NSData *)packet error:(NSError **)error {
    for (NSUInteger attempt = 0; attempt < 2; attempt++) {
        if (![self validateConnection:error])
            return NO;
        usleep(10000);
        IOReturn status =
            HDGetAPIs()->write(_service, _chipAddress, 0x51, (void *)packet.bytes, (uint32_t)packet.length);
        if (status != kIOReturnSuccess)
            return HDFail(error, 9,
                          [NSString stringWithFormat:@"DDC 请求发送失败（0x%08x）。请检查显示器 DDC/CI 与连接方式。",
                                                     (unsigned)status]);
    }
    return YES;
}
- (NSData *)readBrightnessReply:(NSData *)request readOffset:(uint32_t)readOffset error:(NSError **)error {
    const uint8_t *bytes = request.bytes;
    if (request.length != 4 || bytes[0] != 0x82 || bytes[1] != 0x01 || bytes[2] != 0x10 ||
        (readOffset != 0 && readOffset != 0x51)) {
        HDFail(error, 10, @"无效的 DDC 亮度查询包。");
        return nil;
    }
    if (![self sendPacket:request error:error])
        return nil;
    usleep(50000);
    if (![self validateConnection:error])
        return nil;
    uint8_t reply[11] = {};
    IOReturn status = HDGetAPIs()->read(_service, _chipAddress, readOffset, reply, sizeof(reply));
    if (status != kIOReturnSuccess) {
        HDFail(error, 11, [NSString stringWithFormat:@"DDC 亮度读取失败（0x%08x）。", (unsigned)status]);
        return nil;
    }
    if (![self validateConnection:error])
        return nil;
    return [NSData dataWithBytes:reply length:sizeof(reply)];
}
- (BOOL)writeBrightnessPacket:(NSData *)packet error:(NSError **)error {
    const uint8_t *bytes = packet.bytes;
    if (packet.length != 6 || bytes[0] != 0x84 || bytes[1] != 0x03 || bytes[2] != 0x10)
        return HDFail(error, 12, @"无效的 DDC 亮度设置包。");
    uint8_t checksum = 0x6E ^ 0x51;
    for (NSUInteger i = 0; i < 5; i++)
        checksum ^= bytes[i];
    if (checksum != bytes[5])
        return HDFail(error, 13, @"DDC 亮度设置包校验失败。");
    return [self sendPacket:packet error:error];
}
- (void)dealloc {
    if (_service)
        CFRelease(_service);
}
@end
