import Foundation

enum AutoRestoreChecks {
    static func run() throws {
        try StudioChecks.require(
            AutoRestoreEventPolicy.isPhysicalConnectionEvent(.addFlag, isStudioVirtual: false)
                && AutoRestoreEventPolicy.isPhysicalConnectionEvent(.removeFlag, isStudioVirtual: false),
            "Physical add/remove callbacks must trigger even when IDs are reused")
        try StudioChecks.require(
            !AutoRestoreEventPolicy.isPhysicalConnectionEvent(.setModeFlag, isStudioVirtual: false)
                && !AutoRestoreEventPolicy.isPhysicalConnectionEvent(
                    [.movedFlag, .setMainFlag], isStudioVirtual: false)
                && !AutoRestoreEventPolicy.isPhysicalConnectionEvent(
                    [.beginConfigurationFlag, .addFlag], isStudioVirtual: false)
                && !AutoRestoreEventPolicy.isPhysicalConnectionEvent(.addFlag, isStudioVirtual: true)
                && !AutoRestoreEventPolicy.isPhysicalConnectionEvent(.removeFlag, isStudioVirtual: true),
            "Mode/layout/begin notifications and Studio virtual changes must be ignored")
        let start = Date(timeIntervalSince1970: 1_000)
        let internalOnly = AutoRestoreTopology(connections: ["internal-uuid": 1])
        let dual = AutoRestoreTopology(connections: ["internal-uuid": 1, "external-uuid": 4])
        var policy = AutoRestoreEventPolicy()
        try StudioChecks.require(
            !policy.observe(dual, at: start) && policy.request == nil,
            "Launching with displays attached must not change their configuration")
        try StudioChecks.require(
            !policy.observe(dual, at: start.addingTimeInterval(1)) && policy.request == nil,
            "Resolution/rate/layout notifications with unchanged connections must not trigger restore")
        policy.arm(.connection, at: start.addingTimeInterval(1))
        try StudioChecks.require(
            policy.request?.reason == .connection && policy.topology == dual,
            "An explicit physical reconnect must arm with identical final UUID and display ID")
        try StudioChecks.require(
            policy.observe(internalOnly, at: start.addingTimeInterval(2)),
            "Physical disconnect must be observed")
        let removedGeneration = policy.request!.generation
        try StudioChecks.require(
            policy.observe(dual, at: start.addingTimeInterval(3)),
            "Reconnection must queue a new settled request")
        let reconnectedGeneration = policy.request!.generation
        try StudioChecks.require(
            !policy.consumeAttempt(generation: reconnectedGeneration, at: start.addingTimeInterval(4)),
            "A reconnect must settle before restoration can run")
        try StudioChecks.require(
            !policy.consumeAttempt(generation: removedGeneration, at: start.addingTimeInterval(5)),
            "A cancelled debounce callback may not restore an old topology")
        for attempt in 1...5 {
            let now = start.addingTimeInterval(3 + Double(attempt * 2))
            try StudioChecks.require(
                policy.consumeAttempt(generation: reconnectedGeneration, at: now),
                "Eligible bounded retry was lost")
            try StudioChecks.require(
                policy.canRetry(generation: reconnectedGeneration, at: now) == (attempt < 5),
                "Automatic restoration must stop after five readiness attempts")
        }
        try StudioChecks.require(
            !policy.consumeAttempt(generation: reconnectedGeneration, at: start.addingTimeInterval(14)),
            "A sixth attempt must not run")
        policy.arm(.wake, at: start)
        let wakeGeneration = policy.request!.generation
        try StudioChecks.require(
            !policy.consumeAttempt(generation: wakeGeneration, at: start.addingTimeInterval(16)),
            "Delayed wake work must expire rather than overwrite later manual work")
        policy.arm(.wake, at: start)
        let manualCancellation = policy.request!.generation
        policy.cancel()
        try StudioChecks.require(
            !policy.consumeAttempt(generation: manualCancellation, at: start.addingTimeInterval(2)),
            "Manual change or shutdown must invalidate pending work")
        let recreated = AutoRestoreTopology(connections: ["internal-uuid": 1, "external-uuid": 9])
        try StudioChecks.require(
            policy.observe(recreated, at: start),
            "A recreated connection must be detected without using its transient ID as profile identity")

        // Preferences only: start(layouts:) is deliberately not called, so no
        // observers, timers, display reads or configuration writes are installed.
        let suite = "HiDPIStudio.tests.autoRestore." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw DisplayFailure(message: "Cannot create test preferences")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = AutoRestoreManager(defaults: defaults)
        try StudioChecks.require(
            !manager.enabled && manager.selectedProfileID == nil, "Automatic restore must default off")
        manager.setEnabled(true)
        try StudioChecks.require(!manager.enabled, "Enabling without an explicitly selected preset must be rejected")
        let id = UUID()
        manager.setSelectedProfile(id)
        manager.setEnabled(true)
        let reopened = AutoRestoreManager(defaults: defaults)
        try StudioChecks.require(
            reopened.enabled && reopened.selectedProfileID == id && !reopened.isWaiting,
            "Opt-in must persist without applying a configuration during initialization")
        manager.setSelectedProfile(nil)
        let cleared = AutoRestoreManager(defaults: defaults)
        try StudioChecks.require(
            !cleared.enabled && cleared.selectedProfileID == nil,
            "Removing the chosen preset must disable automatic restoration")
        manager.shutdown()
        reopened.shutdown()
        cleared.shutdown()
        print(
            "PASS: reconnect/wake event policy, mode-change exclusion, bounded retry, cancellation and opt-in persistence"
        )
    }
}
