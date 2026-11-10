import Foundation

enum DDCProtocolError: LocalizedError, Equatable {
    case noReply
    case invalidLength(Int)
    case invalidSource(UInt8)
    case invalidPayloadLength(UInt8)
    case invalidChecksum
    case invalidResponseOpcode(UInt8)
    case wrongVCP(UInt8)
    case unsupportedBrightness
    case monitorResult(UInt8)
    case nonContinuousBrightness(UInt8)
    case zeroMaximum
    case currentExceedsMaximum(current: UInt16, maximum: UInt16)
    case invalidNormalizedValue

    var errorDescription: String? {
        switch self {
        case .noReply:
            return "显示器没有返回 DDC 亮度数据。请确认显示器菜单中的 DDC/CI 已开启。"
        case .invalidLength(let length):
            return "DDC 亮度回复长度异常（\(length) 字节），未采用该数据。"
        case .invalidSource(let source):
            return String(format: "DDC 回复来源地址异常（0x%02X）。", Int(source))
        case .invalidPayloadLength(let length):
            return String(format: "DDC 回复声明的长度异常（0x%02X）。", Int(length))
        case .invalidChecksum:
            return "DDC 亮度回复校验失败，请检查连接后重试。"
        case .invalidResponseOpcode(let opcode):
            return String(format: "收到非亮度查询回复（操作码 0x%02X）。", Int(opcode))
        case .wrongVCP(let code):
            return String(format: "DDC 回复属于其他控制项（0x%02X），未用于亮度控制。", Int(code))
        case .unsupportedBrightness:
            return "显示器报告不支持 DDC 亮度控制（VCP 0x10）。"
        case .monitorResult(let result):
            return String(format: "显示器返回 DDC 错误状态 0x%02X。", Int(result))
        case .nonContinuousBrightness(let type):
            return String(format: "显示器亮度不是可连续调节的 DDC 参数（类型 0x%02X）。", Int(type))
        case .zeroMaximum:
            return "显示器返回的 DDC 最大亮度为 0，无法安全换算亮度。"
        case .currentExceedsMaximum(let current, let maximum):
            return "显示器返回的 DDC 亮度 \(current) 超过最大值 \(maximum)，未采用该数据。"
        case .invalidNormalizedValue:
            return "DDC 亮度需为 0–100% 之间的有效数值。"
        }
    }
}

struct DDCBrightnessValue: Equatable {
    let current: UInt16
    let maximum: UInt16
    /// Instances returned by parseReply always have maximum > 0 and current <= maximum.
    var normalized: Double { Double(current) / Double(maximum) }
}

/// MCCS luminance (VCP 0x10) only. IOAVService supplies the source byte through
/// its offset argument (0x51), so request arrays deliberately omit that byte.
enum DDCBrightnessPacket {
    static let vcpCode: UInt8 = 0x10
    static let sourceAddress: UInt8 = 0x51

    static func getRequest(includeSourceInChecksum: Bool = true, chipAddress: UInt8 = 0x37) -> [UInt8] {
        let body: [UInt8] = [0x82, 0x01, vcpCode]
        let destination = UInt8(truncatingIfNeeded: UInt16(chipAddress) << 1)
        let seed = destination ^ (includeSourceInChecksum ? sourceAddress : 0)
        return body + [body.reduce(seed, ^)]
    }

    static func setRequest(value: UInt16, chipAddress: UInt8 = 0x37) -> [UInt8] {
        let body: [UInt8] = [0x84, 0x03, vcpCode, UInt8(value >> 8), UInt8(value & 0xff)]
        // MCDP29xx uses IOAV chip address 0xB7, but its low 8-bit on-wire
        // destination/checksum byte is still 0x6E, just like address 0x37.
        let seed = UInt8(truncatingIfNeeded: UInt16(chipAddress) << 1) ^ sourceAddress
        return body + [body.reduce(seed, ^)]
    }

    static func parseReply(_ bytes: [UInt8]) throws -> DDCBrightnessValue {
        if bytes.isEmpty || bytes.allSatisfy({ $0 == 0 }) || (bytes.count >= 2 && bytes[0] == 0x6e && bytes[1] == 0x80)
        {
            throw DDCProtocolError.noReply
        }
        guard bytes.count == 11 else { throw DDCProtocolError.invalidLength(bytes.count) }
        guard bytes[0] == 0x6e else { throw DDCProtocolError.invalidSource(bytes[0]) }
        guard bytes[1] == 0x88 else { throw DDCProtocolError.invalidPayloadLength(bytes[1]) }
        guard bytes.reduce(UInt8(0x50), ^) == 0 else { throw DDCProtocolError.invalidChecksum }
        guard bytes[2] == 0x02 else { throw DDCProtocolError.invalidResponseOpcode(bytes[2]) }
        guard bytes[4] == vcpCode else { throw DDCProtocolError.wrongVCP(bytes[4]) }
        if bytes[3] == 0x01 { throw DDCProtocolError.unsupportedBrightness }
        guard bytes[3] == 0 else { throw DDCProtocolError.monitorResult(bytes[3]) }
        guard bytes[5] == 0 else { throw DDCProtocolError.nonContinuousBrightness(bytes[5]) }
        let maximum = UInt16(bytes[6]) << 8 | UInt16(bytes[7])
        let current = UInt16(bytes[8]) << 8 | UInt16(bytes[9])
        guard maximum > 0 else { throw DDCProtocolError.zeroMaximum }
        guard current <= maximum else {
            throw DDCProtocolError.currentExceedsMaximum(current: current, maximum: maximum)
        }
        return DDCBrightnessValue(current: current, maximum: maximum)
    }

    static func scaledValue(normalized: Double, maximum: UInt16) throws -> UInt16 {
        guard maximum > 0 else { throw DDCProtocolError.zeroMaximum }
        guard normalized.isFinite, (0...1).contains(normalized) else { throw DDCProtocolError.invalidNormalizedValue }
        return UInt16((normalized * Double(maximum)).rounded())
    }
}
