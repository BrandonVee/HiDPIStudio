import Foundation

/// Pure packet tests. These never open IOKit services or communicate with a monitor.
enum DDCChecks {
    static func run() throws {
        try StudioChecks.require(
            DDCBrightnessPacket.getRequest() == [0x82, 0x01, 0x10, 0xac],
            "Canonical brightness GET packet changed")
        try StudioChecks.require(
            DDCBrightnessPacket.getRequest(includeSourceInChecksum: false) == [0x82, 0x01, 0x10, 0xfd],
            "Source-omitted compatibility GET packet changed")
        try StudioChecks.require(
            DDCBrightnessPacket.setRequest(value: 50) == [0x84, 0x03, 0x10, 0x00, 0x32, 0x9a],
            "Brightness SET packet changed")
        try StudioChecks.require(
            DDCBrightnessPacket.setRequest(value: 0x1234) == [0x84, 0x03, 0x10, 0x12, 0x34, 0x8e],
            "Brightness SET lost the high value byte")
        try StudioChecks.require(
            DDCBrightnessPacket.getRequest(chipAddress: 0xb7) == DDCBrightnessPacket.getRequest()
                && DDCBrightnessPacket.setRequest(value: 50, chipAddress: 0xb7)
                    == DDCBrightnessPacket.setRequest(value: 50),
            "MCDP29xx transport must retain the on-wire checksum address")

        let standard: [UInt8] = [0x6e, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32, 0xf2]
        let parsed = try DDCBrightnessPacket.parseReply(standard)
        try StudioChecks.require(
            parsed.current == 50 && parsed.maximum == 100 && parsed.normalized == 0.5,
            "Brightness response decoded incorrectly")
        let extended = try DDCBrightnessPacket.parseReply(frame(maximum: 1000, current: 750))
        try StudioChecks.require(
            extended.current == 750 && extended.maximum == 1000 && extended.normalized == 0.75,
            "Non-100 brightness ranges or big-endian values were truncated")

        var corrupt = standard
        corrupt[9] ^= 1
        try expect(.invalidChecksum) { _ = try DDCBrightnessPacket.parseReply(corrupt) }
        try expect(.invalidLength(10)) { _ = try DDCBrightnessPacket.parseReply(Array(standard.prefix(10))) }
        try expect(.invalidLength(12)) { _ = try DDCBrightnessPacket.parseReply(standard + [0]) }
        try expect(.noReply) { _ = try DDCBrightnessPacket.parseReply([0x6e, 0x80, 0xbe]) }
        try expect(.noReply) { _ = try DDCBrightnessPacket.parseReply(Array(repeating: 0, count: 11)) }
        try expect(.invalidSource(0x6f)) {
            _ = try DDCBrightnessPacket.parseReply(changing(standard, index: 0, to: 0x6f))
        }
        try expect(.invalidPayloadLength(0x87)) {
            _ = try DDCBrightnessPacket.parseReply(changing(standard, index: 1, to: 0x87))
        }
        try expect(.invalidResponseOpcode(0x03)) {
            _ = try DDCBrightnessPacket.parseReply(changing(standard, index: 2, to: 0x03))
        }
        try expect(.wrongVCP(0x12)) { _ = try DDCBrightnessPacket.parseReply(changing(standard, index: 4, to: 0x12)) }
        try expect(.unsupportedBrightness) {
            _ = try DDCBrightnessPacket.parseReply(changing(standard, index: 3, to: 1))
        }
        try expect(.monitorResult(2)) { _ = try DDCBrightnessPacket.parseReply(changing(standard, index: 3, to: 2)) }
        try expect(.nonContinuousBrightness(1)) {
            _ = try DDCBrightnessPacket.parseReply(changing(standard, index: 5, to: 1))
        }
        try expect(.zeroMaximum) { _ = try DDCBrightnessPacket.parseReply(frame(maximum: 0, current: 0)) }
        try expect(.currentExceedsMaximum(current: 101, maximum: 100)) {
            _ = try DDCBrightnessPacket.parseReply(frame(maximum: 100, current: 101))
        }

        for value in [-0.01, 1.01, Double.nan, .infinity, -.infinity] {
            try expect(.invalidNormalizedValue) {
                _ = try DDCBrightnessPacket.scaledValue(normalized: value, maximum: 100)
            }
        }
        try expect(.zeroMaximum) { _ = try DDCBrightnessPacket.scaledValue(normalized: 0.5, maximum: 0) }
        let minimum = try DDCBrightnessPacket.scaledValue(normalized: 0, maximum: 1000)
        let maximum = try DDCBrightnessPacket.scaledValue(normalized: 1, maximum: .max)
        let fractional = try DDCBrightnessPacket.scaledValue(normalized: 0.333, maximum: 1000)
        let rounded = try DDCBrightnessPacket.scaledValue(normalized: 0.5, maximum: 255)
        try StudioChecks.require(
            minimum == 0 && maximum == .max && fractional == 333 && rounded == 128,
            "Brightness scaling did not respect the device range and rounding")
        print("PASS: DDC brightness packet encoding, strict reply checks, device ranges and invalid-value rejection")
    }

    private static func expect(_ expected: DDCProtocolError, action: () throws -> Void) throws {
        do {
            try action()
            throw DisplayFailure(message: "DDC accepted invalid input; expected \(expected)")
        } catch let actual as DDCProtocolError {
            try StudioChecks.require(actual == expected, "DDC returned \(actual), expected \(expected)")
        }
    }

    private static func frame(maximum: UInt16, current: UInt16) -> [UInt8] {
        let body: [UInt8] = [
            0x6e, 0x88, 0x02, 0, 0x10, 0,
            UInt8(maximum >> 8), UInt8(maximum & 0xff), UInt8(current >> 8), UInt8(current & 0xff),
        ]
        return body + [body.reduce(UInt8(0x50), ^)]
    }

    private static func changing(_ packet: [UInt8], index: Int, to value: UInt8) -> [UInt8] {
        var changed = packet
        changed[index] = value
        changed[10] = changed.prefix(10).reduce(UInt8(0x50), ^)
        return changed
    }
}
