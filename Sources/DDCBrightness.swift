import CoreGraphics
import Foundation

enum BrightnessControlBackend: String, Codable {
    case system, ddc
    var title: String { self == .system ? "系统亮度" : "DDC 硬件亮度" }
}

private final class DDCCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
    func check() throws {
        lock.lock()
        let value = cancelled
        lock.unlock()
        if value { throw CancellationError() }
    }
}

/// IOAV calls are synchronous. Keep complete GET/SET/verification sequences on
/// one serial worker, never the main thread; cancelled queued slider requests
/// are discarded before reaching the monitor.
final class DDCBrightnessService {
    static let shared = DDCBrightnessService()
    private let queue = DispatchQueue(label: "local.hidpistudio.ddc", qos: .userInitiated)
    private struct ReadConfiguration {
        let includesSource: Bool
        let offset: UInt32
    }
    private var preferredReads: [String: ReadConfiguration] = [:]

    func read(displayID: CGDirectDisplayID, identity: DisplayIdentity) async throws -> NativeBrightnessReading {
        try await perform { token in
            try self.checkIdentity(displayID, identity, token)
            let transport = try HDAppleDDC(displayID: displayID)
            let value = try self.readValue(transport, identity: identity, token: token)
            return self.reading(displayID, identity, value)
        }
    }

    func set(_ normalized: Double, displayID: CGDirectDisplayID, identity: DisplayIdentity) async throws
        -> NativeBrightnessReading
    {
        _ = try NativeBrightnessService.validated(normalized)
        return try await perform { token in
            try self.checkIdentity(displayID, identity, token)
            let transport = try HDAppleDDC(displayID: displayID)
            let before = try self.readValue(transport, identity: identity, token: token)
            let requested = try DDCBrightnessPacket.scaledValue(normalized: normalized, maximum: before.maximum)
            if before.current == requested { return self.reading(displayID, identity, before) }
            try self.checkIdentity(displayID, identity, token)
            try transport.validateConnection()
            let packet = DDCBrightnessPacket.setRequest(value: requested, chipAddress: UInt8(transport.chipAddress))
            try transport.writeBrightnessPacket(Data(packet))
            var last = before
            // Some monitor firmwares apply Set VCP asynchronously.
            for _ in 0..<3 {
                Thread.sleep(forTimeInterval: 0.08)
                try self.checkIdentity(displayID, identity, token)
                last = try self.readValue(transport, identity: identity, token: token)
                if last.maximum == before.maximum && last.current == requested {
                    return self.reading(displayID, identity, last)
                }
            }
            throw DisplayFailure(
                message:
                    "显示器实际返回亮度 \(last.current)/\(last.maximum)，未采用请求的 \(requested)/\(before.maximum)。请检查 HDR、动态对比度或显示器亮度锁定。"
            )
        }
    }

    private func reading(_ id: CGDirectDisplayID, _ identity: DisplayIdentity, _ value: DDCBrightnessValue)
        -> NativeBrightnessReading
    {
        NativeBrightnessReading(
            displayID: id, identity: identity, value: value.normalized,
            backend: .ddc, rawCurrent: value.current, rawMaximum: value.maximum)
    }
    private func checkIdentity(_ id: CGDirectDisplayID, _ identity: DisplayIdentity, _ token: DDCCancellation) throws {
        try token.check()
        guard CGDisplayIsOnline(id) != 0, CGDisplayIsBuiltin(id) == 0, identity.matches(id) else {
            throw DisplayFailure(message: "外接屏已断开或身份变化，已取消 DDC 操作。")
        }
    }
    private func readValue(_ transport: HDAppleDDC, identity: DisplayIdentity, token: DDCCancellation) throws
        -> DDCBrightnessValue
    {
        let key = identity.uuid + "/" + String(transport.registryEntryID)
        let canonical = ReadConfiguration(includesSource: true, offset: 0)
        var choices = [
            canonical, ReadConfiguration(includesSource: true, offset: 0x51),
            ReadConfiguration(includesSource: false, offset: 0), ReadConfiguration(includesSource: false, offset: 0x51),
        ]
        if let preferred = preferredReads[key] {
            choices.removeAll { $0.includesSource == preferred.includesSource && $0.offset == preferred.offset }
            choices.insert(preferred, at: 0)
        }
        var lastError: Error = DDCProtocolError.noReply
        for configuration in choices {
            try checkIdentity(transport.displayID, identity, token)
            do {
                let request = DDCBrightnessPacket.getRequest(
                    includeSourceInChecksum: configuration.includesSource,
                    chipAddress: UInt8(transport.chipAddress))
                let reply = try transport.readBrightnessReply(Data(request), readOffset: configuration.offset)
                try checkIdentity(transport.displayID, identity, token)
                let result = try DDCBrightnessPacket.parseReply(Array(reply))
                if preferredReads.count > 32 { preferredReads.removeAll() }
                preferredReads[key] = configuration
                return result
            } catch DDCProtocolError.unsupportedBrightness {
                throw DDCProtocolError.unsupportedBrightness
            } catch is CancellationError { throw CancellationError() } catch { lastError = error }
        }
        throw DisplayFailure(
            message: "DDC 亮度读取失败：\(lastError.localizedDescription) 请确认显示器菜单中 DDC/CI 已开启，且连接线或扩展坞支持 DDC。")
    }
    private func perform<T>(_ work: @escaping (DDCCancellation) throws -> T) async throws -> T {
        let token = DDCCancellation()
        return try await withTaskCancellationHandler(
            operation: {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { continuation in
                    queue.async {
                        do {
                            try token.check()
                            continuation.resume(returning: try work(token))
                        } catch { continuation.resume(throwing: error) }
                    }
                }
            }, onCancel: { token.cancel() })
    }
}

/// Prefer Apple's brightness controller. Only a failed native capability read
/// on a physical external display falls through to the OS IOKit DDC transport.
enum HardwareBrightness {
    static func read(displayID: CGDirectDisplayID) async throws -> NativeBrightnessReading {
        try Task.checkCancellation()
        do { return try NativeBrightnessService.shared.read(displayID: displayID) } catch {
            guard CGDisplayIsBuiltin(displayID) == 0, let identity = DisplayIdentity.capture(displayID),
                !(CGDisplayVendorNumber(displayID) == 0x4844 && CGDisplayModelNumber(displayID) == 0x5354)
            else { throw error }
            return try await DDCBrightnessService.shared.read(displayID: displayID, identity: identity)
        }
    }
    @MainActor static func set(_ value: Double, displayID: CGDirectDisplayID, expectedIdentity: DisplayIdentity)
        async throws -> NativeBrightnessReading
    {
        _ = try NativeBrightnessService.validated(value)
        let reading = try await read(displayID: displayID)
        guard reading.identity == expectedIdentity else { throw DisplayFailure(message: "显示器已变化，已取消亮度调整。") }
        switch reading.backend {
        case .system:
            return try await NativeBrightnessService.shared.set(
                value, displayID: displayID, expectedIdentity: expectedIdentity)
        case .ddc:
            return try await DDCBrightnessService.shared.set(value, displayID: displayID, identity: expectedIdentity)
        }
    }
}
