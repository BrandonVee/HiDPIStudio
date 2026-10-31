import AppKit

enum BrightnessSyncChecks {
    private final class Fixture {
        let builtin = DisplayIdentity(uuid: "sync-built-in", vendor: 1, product: 1, serial: 1)
        let external = DisplayIdentity(uuid: "sync-external", vendor: 2, product: 2, serial: 2)
        var screens: [BrightnessSyncScreen] = []
        var sourceValue = 0.6
        var targetValue = 0.2
        var writes: [(CGDirectDisplayID, Double)] = []
        var targetReads = 0
        var time = Date(timeIntervalSince1970: 100)
        var afterTargetRead: (() -> Void)?
        var targetFailure = false
        init() {
            screens = [BrightnessSyncScreen(displayID: 1, identity: builtin, name: "测试内置屏", builtIn: true, mirrored: false, studioVirtual: false),
                       BrightnessSyncScreen(displayID: 2, identity: external, name: "测试外接屏", builtIn: false, mirrored: false, studioVirtual: false)]
        }
        var environment: BrightnessSyncEnvironment {
            BrightnessSyncEnvironment(screens: { self.screens }, sourceRead: { id in
                NativeBrightnessReading(displayID: id, identity: self.builtin, value: self.sourceValue)
            }, targetRead: { id in
                self.targetReads += 1
                if self.targetFailure { throw DisplayFailure(message: "测试：显示器不支持亮度") }
                let result = NativeBrightnessReading(displayID: id, identity: self.external, value: self.targetValue,
                    backend: .ddc, rawCurrent: UInt16((self.targetValue * 100).rounded()), rawMaximum: 100)
                self.afterTargetRead?()
                return result
            }, write: { value, id, identity in
                self.writes.append((id, value))
                self.targetValue = (value * 100).rounded() / 100
                return NativeBrightnessReading(displayID: id, identity: identity, value: self.targetValue,
                    backend: .ddc, rawCurrent: UInt16((self.targetValue * 100).rounded()), rawMaximum: 100)
            }, now: { self.time })
        }
    }

    @MainActor static func run() async throws {
        let suite = "HiDPIStudio.tests.brightnessSync." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else { throw DisplayFailure(message: "Cannot create sync test preferences") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let fake = Fixture()
        let manager = BrightnessSyncManager(defaults: defaults, environment: fake.environment, observeNotifications: false)
        defer { manager.shutdown() }
        var callbacks = 0
        manager.onApplied = { _ in callbacks += 1 }
        try StudioChecks.require(!manager.enabled && manager.targets.count == 1 && !manager.targets[0].enabled,
                                 "Brightness sync must start off with targets unchecked")
        await manager.sample()
        try StudioChecks.require(fake.targetReads == 0 && fake.writes.isEmpty, "Disabled sync performed target I/O")
        manager.setTargetEnabled(true, identity: fake.external)
        manager.setRatio(0.75, identity: fake.external)
        manager.setEnabled(true)
        await manager.sample()
        try StudioChecks.require(fake.writes.count == 1 && abs(fake.writes[0].1 - 0.45) < 0.00001 && callbacks == 1,
                                 "Source brightness and per-target ratio were not applied/verified")
        let reads = fake.targetReads
        fake.sourceValue = 0.605
        fake.targetValue = 0.1 // An OSD change must not become a feedback source.
        fake.time.addTimeInterval(1)
        await manager.sample()
        try StudioChecks.require(fake.writes.count == 1 && fake.targetReads == reads, "Tiny source noise or target-only edits triggered writes")

        fake.sourceValue = 0.61
        await manager.sample()
        try StudioChecks.require(fake.writes.count == 2, "Meaningful source change did not reach the target")
        fake.sourceValue = 0.8
        fake.time.addTimeInterval(0.1)
        await manager.sample()
        try StudioChecks.require(fake.writes.count == 2, "Sync exceeded per-target write rate")
        fake.time.addTimeInterval(1)
        manager.noteManualChange(displayID: 2, value: 0.3)
        fake.targetValue = 0.3
        await manager.sample()
        try StudioChecks.require(fake.writes.count == 2, "Sync immediately overwrote a manual target adjustment")
        fake.sourceValue = 0.85
        fake.time.addTimeInterval(1)
        await manager.sample()
        try StudioChecks.require(fake.writes.count == 3, "Manual override did not resume after a later source change")

        var blocked = false
        manager.isBlocked = { blocked }
        fake.sourceValue = 0.9; fake.time.addTimeInterval(1)
        fake.afterTargetRead = { blocked = true }
        await manager.sample()
        try StudioChecks.require(fake.writes.count == 3, "Sync wrote after configuration became blocked during a read")
        blocked = false; fake.afterTargetRead = nil

        fake.sourceValue = .nan; fake.time.addTimeInterval(1)
        await manager.sample()
        try StudioChecks.require(fake.writes.count == 3 && manager.sourceError != nil, "Invalid source brightness reached hardware")
        fake.sourceValue = 0.95
        fake.targetFailure = true
        await manager.sample()
        let failureReads = fake.targetReads
        fake.time.addTimeInterval(1)
        await manager.sample()
        try StudioChecks.require(fake.targetReads == failureReads && manager.targetErrors[fake.external.uuid] != nil,
                                 "Unsupported targets should use a retry cooldown")
        fake.targetFailure = false; fake.time.addTimeInterval(11)

        // The same numeric ID now points at another monitor. No queued write may
        // reach it, and the new monitor must not inherit the old enabled target.
        let replacement = DisplayIdentity(uuid: "sync-replacement", vendor: 2, product: 2, serial: 3)
        fake.afterTargetRead = {
            fake.screens[1] = BrightnessSyncScreen(displayID: 2, identity: replacement, name: "替换屏", builtIn: false, mirrored: false, studioVirtual: false)
        }
        await manager.sample()
        try StudioChecks.require(fake.writes.count == 3, "A reused display ID received a queued write")
        manager.refreshScreens()
        try StudioChecks.require(manager.targets.first(where: { $0.identity == replacement })?.enabled == false,
                                 "Replacement monitor inherited an enabled sync rule")
        fake.afterTargetRead = nil

        let reopened = BrightnessSyncManager(defaults: defaults, environment: fake.environment, observeNotifications: false)
        defer { reopened.shutdown() }
        try StudioChecks.require(reopened.enabled && reopened.targets.first(where: { $0.identity == fake.external })?.ratio == 0.75,
                                 "Sync opt-in or ratio did not survive reopening")
        try StudioChecks.require(fake.writes.count == 3, "Loading sync preferences changed hardware")
        manager.setEnabled(false)
        fake.sourceValue = 0.2; fake.time.addTimeInterval(1)
        await manager.sample()
        try StudioChecks.require(fake.writes.count == 3, "Disabled sync continued writing")
        print("PASS: brightness sync opt-in, ratios, noise/rate limits, manual override, blockers, cooldown, identity reuse and persistence (mock I/O)")
    }
}
