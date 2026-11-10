import AppKit

let arguments = CommandLine.arguments
let ciChecks = arguments.contains("--test-ci")
let app = NSApplication.shared
if arguments.contains("--test-sync-live") {
    app.setActivationPolicy(.prohibited)
    Task { @MainActor in
        do {
            guard let index = arguments.firstIndex(of: "--test-sync-live"), arguments.indices.contains(index + 1),
                let id = UInt32(arguments[index + 1])
            else { throw DisplayFailure(message: "需提供外接屏幕 ID。") }
            try await AutomationLiveChecks.sync(displayID: id)
            exit(0)
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
    app.run()
} else if arguments.contains("--test-hidden-native") {
    app.setActivationPolicy(.prohibited)
    Task { @MainActor in
        do {
            guard let index = arguments.firstIndex(of: "--test-hidden-native"), arguments.indices.contains(index + 1),
                let id = UInt32(arguments[index + 1])
            else { throw DisplayFailure(message: "需提供外接屏幕 ID。") }
            try await HiddenModeChecks.run(displayID: id)
            exit(0)
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
    app.run()
} else if arguments.contains("--brightness-read") || arguments.contains("--test-ddc-live") {
    app.setActivationPolicy(.prohibited)
    Task { @MainActor in
        do {
            if let index = arguments.firstIndex(of: "--test-ddc-live") {
                guard arguments.indices.contains(index + 1), let id = UInt32(arguments[index + 1]) else {
                    throw DisplayFailure(message: "需提供外接屏幕 ID。")
                }
                try await DDCLiveChecks.run(displayID: id)
            } else {
                await DDCLiveChecks.probe()
            }
            exit(0)
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
    app.run()
} else if arguments.contains("--diagnose") {
    app.setActivationPolicy(.prohibited)
    print(DisplayModel().diagnostics())
} else if arguments.count > 1 && arguments[1] == "--test-persistence-worker" {
    app.setActivationPolicy(.prohibited)
    Task { @MainActor in
        do {
            try await PersistenceChecks.worker(args: Array(arguments.dropFirst(2)))
            exit(0)
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
    app.run()
} else if ciChecks || arguments.contains("--test-core") || arguments.contains("--test-virtual")
    || arguments.contains("--test-persistence") || arguments.contains("--test-features")
    || arguments.contains("--test-workspace") || arguments.contains("--test-ddc")
    || arguments.contains("--test-automation")
{
    app.setActivationPolicy(.prohibited)
    Task { @MainActor in
        do {
            try await StudioChecks.runCore()
            if ciChecks || arguments.contains("--test-automation") {
                try await BrightnessSyncChecks.run()
                try AutoRestoreChecks.run()
                try NativeBrightnessKeyChecks.run()
                if !ciChecks { try await AutomationLiveChecks.unchangedProfile() }
            }
            if ciChecks || arguments.contains("--test-ddc") { try DDCChecks.run() }
            if arguments.contains("--test-virtual") { try await StudioChecks.runVirtual() }
            if arguments.contains("--test-persistence") { try await PersistenceChecks.run() }
            if ciChecks || arguments.contains("--test-features") {
                try DailyControlChecks.run()
                try LayoutProfileChecks.run()
                try await VirtualWorkspaceChecks.runDefinitions()
            }
            if arguments.contains("--test-workspace") { try await VirtualWorkspaceChecks.runConnection() }
            print("PASS: all requested checks")
            exit(0)
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
    app.run()
} else if arguments.count > 1 {
    print(
        "HiDPI Studio\n  --test-ci       Isolated checks; no physical mode or brightness writes\n  --diagnose      Read-only display mode report (JSON)\n  --test-core     Validation and countdown checks\n  --test-virtual  Temporary virtual displays; mode switch, mirror and rollback checks\n  --test-persistence  Native confirmation, quit and restore checks using a disposable virtual display"
    )
} else {
    // Prevent multiple GUI owners from fighting over app-scoped display state.
    let existing = NSRunningApplication.runningApplications(withBundleIdentifier: "local.hidpistudio.app")
        .first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    if let existing {
        existing.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    } else {
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
