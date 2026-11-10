import AppKit

enum DDCLiveChecks {
    @MainActor static func probe() async {
        for display in DisplayCore.displays().filter({ !$0.isStudioVirtual }) {
            do {
                let value = try await HardwareBrightness.read(displayID: display.id)
                print(
                    "\(display.id) \(display.name): \(value.backend.rawValue) \(value.value * 100)%"
                        + (value.rawCurrent.map { " raw=\($0)/\(value.rawMaximum ?? 0)" } ?? ""))
            } catch { print("\(display.id) \(display.name): \(error.localizedDescription)") }
        }
    }

    /// Explicit opt-in hardware smoke test. Never runs as part of unit checks.
    /// Changes one raw brightness step, reads it back, and always attempts restore.
    @MainActor static func run(displayID: CGDirectDisplayID) async throws {
        guard CGDisplayIsBuiltin(displayID) == 0 else { throw DisplayFailure(message: "DDC 实测只接受外接屏幕 ID。") }
        let before = try await HardwareBrightness.read(displayID: displayID)
        let name = DisplayCore.displays().first(where: { $0.id == displayID })?.name ?? "External display"
        print("TARGET: \(name), display ID \(displayID), backend \(before.backend.rawValue)")
        guard before.backend == .ddc, let raw = before.rawCurrent, let maximum = before.rawMaximum, maximum >= 20 else {
            throw DisplayFailure(message: "所选屏幕没有可进行小幅测试的 DDC 亮度范围。")
        }
        let target = raw > 0 ? raw - 1 : raw + 1
        var failure: Error?
        do {
            let applied = try await HardwareBrightness.set(
                Double(target) / Double(maximum), displayID: displayID, expectedIdentity: before.identity)
            try StudioChecks.require(
                applied.backend == .ddc && applied.rawCurrent == target && applied.rawMaximum == maximum,
                "DDC 写入后实际读回与请求不符")
            print("PASS: DDC actual readback \(raw)/\(maximum) → \(target)/\(maximum)")
        } catch { failure = error }
        let restored = try await HardwareBrightness.set(
            before.value, displayID: displayID, expectedIdentity: before.identity)
        try StudioChecks.require(
            restored.backend == .ddc && restored.rawCurrent == raw && restored.rawMaximum == maximum,
            "未能验证恢复原始 DDC 亮度")
        print("PASS: DDC original brightness restored and verified \(raw)/\(maximum)")
        if let failure { throw failure }
    }
}
