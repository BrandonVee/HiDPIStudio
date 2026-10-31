import CoreGraphics
import Foundation
import Darwin

struct NativeBrightnessReading {
    let displayID: CGDirectDisplayID
    let identity: DisplayIdentity
    let value: Double
    var backend: BrightnessControlBackend = .system
    var rawCurrent: UInt16? = nil
    var rawMaximum: UInt16? = nil
}

/// Apple's DisplayServices brightness SPI is not in the public SDK. Resolve its
/// functions at runtime and expose support only after a successful real read.
/// Signatures: int GetBrightness(CGDirectDisplayID, float *),
///             int SetBrightness(CGDirectDisplayID, float).
final class NativeBrightnessService {
    static let shared = NativeBrightnessService()
    private typealias Getter = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias Setter = @convention(c) (UInt32, Float) -> Int32
    private let handle: UnsafeMutableRawPointer?
    private let getter: Getter?
    private let setter: Setter?

    private init() {
        let library = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY | RTLD_LOCAL)
        handle = library
        getter = library.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: Getter.self) }
        setter = library.flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map { unsafeBitCast($0, to: Setter.self) }
    }

    static func validated(_ value: Double) throws -> Double {
        guard value.isFinite, (0...1).contains(value) else {
            throw DisplayFailure(message: "系统亮度需为 0–100% 之间的有效数值。")
        }
        return value
    }
    static func matches(_ actual: Double, _ requested: Double) -> Bool {
        actual.isFinite && requested.isFinite && (0...1).contains(actual) && (0...1).contains(requested) && abs(actual - requested) <= 0.005
    }

    func read(displayID: CGDirectDisplayID) throws -> NativeBrightnessReading {
        guard let identity = DisplayIdentity.capture(displayID), DisplayCore.onlineIDs().contains(displayID) else {
            throw DisplayFailure(message: "显示器已断开，无法读取系统亮度。")
        }
        guard !(CGDisplayVendorNumber(displayID) == 0x4844 && CGDisplayModelNumber(displayID) == 0x5354) else {
            throw DisplayFailure(message: "虚拟屏幕没有独立的硬件亮度，请选择实体显示器。")
        }
        guard let getter, setter != nil else {
            throw DisplayFailure(message: "此 macOS 版本未提供兼容的系统亮度接口。")
        }
        var value: Float = -1
        let status = getter(displayID, &value)
        guard status == 0, value.isFinite, (0...1).contains(value), identity.matches(displayID) else {
            throw DisplayFailure(message: "系统亮度接口不支持此屏幕（返回 \(status)）。")
        }
        return NativeBrightnessReading(displayID: displayID, identity: identity, value: Double(value))
    }

    /// The caller explicitly requested a system setting change. Do not restore
    /// this value on app exit. Only return success after reading the applied value.
    @MainActor func set(_ requested: Double, displayID: CGDirectDisplayID,
                        expectedIdentity: DisplayIdentity) async throws -> NativeBrightnessReading {
        let value = try Self.validated(requested)
        try Task.checkCancellation()
        let before = try read(displayID: displayID)
        guard before.identity == expectedIdentity, expectedIdentity.matches(displayID), let setter else {
            throw DisplayFailure(message: "显示器身份已变化，已取消系统亮度调整。")
        }
        let status = setter(displayID, Float(value))
        guard status == 0 else { throw DisplayFailure(message: "系统亮度设置失败（返回 \(status)）。") }
        var last = before
        for _ in 0..<10 {
            try Task.checkCancellation()
            guard expectedIdentity.matches(displayID) else {
                throw DisplayFailure(message: "显示器已变化，无法验证系统亮度。")
            }
            last = try read(displayID: displayID)
            if Self.matches(last.value, value) { return last }
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        throw DisplayFailure(message: String(format: "系统实际亮度为 %.0f%%，未采用请求的 %.0f%%。", last.value * 100, value * 100))
    }

    deinit { if let handle { dlclose(handle) } }
}
