#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Apple Silicon DDC transport for one exactly identified physical display.
/// Packet parsing and monitor-value policy live in Swift, outside this boundary.
@interface HDAppleDDC : NSObject
@property(nonatomic, readonly) uint32_t displayID;
@property(nonatomic, readonly) uint64_t registryEntryID;
@property(nonatomic, readonly) uint32_t chipAddress;
@property(nonatomic, readonly, copy) NSString *ioDisplayLocation;
+ (BOOL)isAvailable;
- (nullable instancetype)initWithDisplayID:(uint32_t)displayID error:(NSError * _Nullable * _Nullable)error;
- (BOOL)validateConnection:(NSError * _Nullable * _Nullable)error;
- (nullable NSData *)readBrightnessReply:(NSData *)request
                             readOffset:(uint32_t)readOffset
                                  error:(NSError * _Nullable * _Nullable)error;
- (BOOL)writeBrightnessPacket:(NSData *)packet error:(NSError * _Nullable * _Nullable)error;
@end

NS_ASSUME_NONNULL_END
