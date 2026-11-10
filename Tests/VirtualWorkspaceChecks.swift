import AppKit

enum VirtualWorkspaceChecks {
    @MainActor static func runDefinitions() async throws {
        let suite = "HiDPIStudio.Tests.VirtualWorkspace." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw DisplayFailure(message: "Unable to create test preferences")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = VirtualWorkspace(defaults: defaults)
        let definition = try manager.addDefinition(name: "  工作屏幕  ", width: 2560, height: 1440, refreshRate: 144)
        try StudioChecks.require(definition.name == "工作屏幕", "Definition names must be trimmed")
        let reopened = VirtualWorkspace(defaults: defaults)
        try StudioChecks.require(reopened.definitions == [definition], "Definitions did not survive reopening")
        try StudioChecks.require(!reopened.hasConnectedScreens, "Loading definitions must not create screens")
        await reopened.remove(definition.id)
        let removed = VirtualWorkspace(defaults: defaults)
        try StudioChecks.require(removed.definitions.isEmpty, "Removing a definition must persist")
        var invalidRejected = false
        do { _ = try manager.addDefinition(name: "", width: 2560, height: 1440, refreshRate: 144) } catch {
            invalidRejected = true
        }
        try StudioChecks.require(invalidRejected, "Empty virtual screen name accepted")
        let wide = ScreenPreviewController.previewSize(width: 5120, height: 1440)
        let tall = ScreenPreviewController.previewSize(width: 1440, height: 2560)
        try StudioChecks.require(
            wide.width <= 1920 && wide.height <= 1080 && wide.width % 2 == 0 && wide.height % 2 == 0,
            "Wide preview sizing exceeded limits")
        try StudioChecks.require(
            tall.width <= 1920 && tall.height <= 1080 && tall.width < tall.height,
            "Portrait preview sizing lost orientation")
        await manager.shutdown()
        await reopened.shutdown()
        await removed.shutdown()
        print("PASS: virtual definition persistence, manual reconnect policy, removal and preview bounds")
    }

    @MainActor static func runConnection() async throws {
        let suite = "HiDPIStudio.Tests.VirtualConnection." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw DisplayFailure(message: "Unable to create test preferences")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let before = DisplaySnapshot(ids: DisplayCore.onlineIDs())
        let beforeIDs = Set(DisplayCore.onlineIDs())
        let manager = VirtualWorkspace(defaults: defaults)
        var failure: Error?
        do {
            let definition = try manager.addDefinition(
                name: "Workspace Test", width: 1920, height: 1080, refreshRate: 120)
            await manager.connect(definition.id)
            guard let id = manager.displayIDs[definition.id] else {
                throw DisplayFailure(message: manager.error ?? "Managed virtual screen did not connect")
            }
            try DisplayCore.verify(id, width: 1920, height: 1080, hiDPI: true, refreshRate: 120)
            await manager.disconnect(definition.id)
            try StudioChecks.require(
                !manager.hasConnectedScreens && manager.displayIDs.isEmpty, "Disconnect retained virtual handles")
            try StudioChecks.require(manager.definitions.count == 1, "Disconnect should retain the definition")
            print("PASS: managed 120 Hz virtual desktop connect and disconnect")
        } catch { failure = error }
        await manager.shutdown()
        for _ in 0..<40 {
            if Set(DisplayCore.onlineIDs()) == beforeIDs { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try before.restore()
        try StudioChecks.require(Set(DisplayCore.onlineIDs()) == beforeIDs, "Managed virtual test did not clean up")
        if let failure { throw failure }
    }
}
