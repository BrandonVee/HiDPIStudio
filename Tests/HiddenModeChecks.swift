import AppKit

enum HiddenModeChecks {
    /// Explicit hardware trial, always restores the previous physical mode.
    @MainActor static func run(displayID: CGDirectDisplayID) async throws {
        guard CGDisplayIsBuiltin(displayID) == 0, CGDisplayIsInMirrorSet(displayID) == 0,
              let identity = DisplayIdentity.capture(displayID),
              let previous = CGDisplayCopyDisplayMode(displayID),
              let requested = DisplayCore.modes(displayID).first(where: {
                  $0.width == 2560 && $0.height == 1440 && $0.pixelWidth == 5120 && $0.pixelHeight == 2880 &&
                  CustomRefreshRate.matches($0.refreshRate, 144)
              }) else { throw DisplayFailure(message: "未找到独立外接屏的 2560 × 1440 HiDPI / 144 Hz 模式。") }
        let snapshot = DisplaySnapshot(ids: [displayID])
        var failure: Error?
        do {
            try StudioChecks.require(identity.matches(displayID), "显示器身份变化")
            try DisplayCore.setMode(displayID, requested)
            try await Task.sleep(nanoseconds: 300_000_000)
            try DisplayCore.verify(displayID, width: 2560, height: 1440, hiDPI: true, refreshRate: 144)
            let actual = CGDisplayCopyDisplayMode(displayID)!
            try StudioChecks.require(actual.pixelWidth == 5120 && actual.pixelHeight == 2880 && CGDisplayMirrorsDisplay(displayID) == 0,
                                     "实际 backing 或镜像状态不符")
            let saved = SavedDisplayMode(DisplayMode(raw: actual))
            try StudioChecks.require(saved.resolve(on: displayID)?.id == actual.ioDisplayModeID, "预设无法重新匹配隐藏原生模式")
            print("PASS: native desktop \(actual.width)×\(actual.height), backing \(actual.pixelWidth)×\(actual.pixelHeight), \(actual.refreshRate) Hz, no mirror")
        } catch { failure = error }
        try snapshot.restoreModesOnly()
        try StudioChecks.require(CGDisplayCopyDisplayMode(displayID)?.ioDisplayModeID == previous.ioDisplayModeID, "未恢复测试前显示模式")
        print("PASS: original physical mode restored")
        if let failure { throw failure }
    }
}
