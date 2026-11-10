import AppKit

enum AutomationLiveChecks {
    /// Explicit live check using isolated preferences, no background timer, and
    /// a write guard limiting the external change to two hardware steps.
    @MainActor static func sync(displayID: CGDirectDisplayID) async throws {
        let live = BrightnessSyncEnvironment.live
        guard let source = live.screens().first(where: { $0.builtIn && !$0.mirrored }),
            let target = live.screens().first(where: { $0.displayID == displayID && $0.canFollow })
        else {
            throw DisplayFailure(message: "联动实测需要内置屏和独立外接屏。")
        }
        let sourceValue = try live.sourceRead(source.displayID)
        let before = try await HardwareBrightness.read(displayID: displayID)
        guard before.backend == .ddc, let current = before.rawCurrent, let maximum = before.rawMaximum,
            maximum >= 20, sourceValue.value > 0
        else { throw DisplayFailure(message: "当前硬件亮度不适合小幅联动实测。") }
        let requested = current < maximum ? current + 1 : current - 1
        let ratio = (Double(requested) / Double(maximum)) / sourceValue.value
        guard (0.25...1.5).contains(ratio) else { throw DisplayFailure(message: "当前源亮度和目标亮度无法在比例范围内进行小幅测试。") }
        let suite = "HiDPIStudio.tests.liveSync." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var appliedReading: NativeBrightnessReading?
        var environment = live
        environment.write = { value, id, identity in
            guard id == displayID, identity == target.identity,
                abs(value - before.value) <= 2 / Double(maximum) + 0.00001
            else {
                throw DisplayFailure(message: "源亮度或目标发生变化，已取消此次测试写入。")
            }
            return try await HardwareBrightness.set(value, displayID: id, expectedIdentity: identity)
        }
        let manager = BrightnessSyncManager(defaults: defaults, environment: environment, observeNotifications: false)
        manager.onApplied = { appliedReading = $0 }
        var failure: Error?
        do {
            manager.setTargetEnabled(true, identity: target.identity)
            manager.setRatio(ratio, identity: target.identity)
            manager.setEnabled(true)
            await manager.sample()
            guard let applied = appliedReading, applied.identity == before.identity,
                applied.rawCurrent != before.rawCurrent
            else {
                throw DisplayFailure(message: manager.targetErrors[target.identity.uuid] ?? "未收到已验证的联动写入。")
            }
            print(
                "PASS: live brightness sync \(target.name) \(current)/\(maximum) → \(applied.rawCurrent ?? 0)/\(maximum), ratio \(ratio)"
            )
        } catch { failure = error }
        manager.shutdown()
        let restored = try await HardwareBrightness.set(
            before.value, displayID: displayID, expectedIdentity: before.identity)
        try StudioChecks.require(
            restored.rawCurrent == before.rawCurrent && restored.rawMaximum == before.rawMaximum,
            "联动实测后未确认恢复原亮度")
        print("PASS: live sync original brightness restored; no automatic preference enabled")
        if let failure { throw failure }
    }

    @MainActor static func unchangedProfile() async throws {
        let suite = "HiDPIStudio.tests.autoNoop." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = LayoutProfileManager(defaults: defaults, persistenceScope: .forSession)
        guard manager.canSave else {
            print("SKIP: unchanged-profile check needs independent physical screens")
            return
        }
        manager.profileName = "自动恢复只读验证"
        manager.saveCurrentProfile()
        guard let profile = manager.profiles.first else { throw DisplayFailure(message: manager.error ?? "无法保存测试预设") }
        let changed = try await manager.restoreProfileAutomatically(id: profile.id)
        try StudioChecks.require(!changed && !manager.isPending && !manager.isBusy, "相同配置不应切换或弹出试用")
        await manager.shutdown()
        print("PASS: automatic restore recognizes unchanged physical profile without applying it")
    }
}
