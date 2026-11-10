import AppKit
import Darwin

/// Verifies the actual process boundary: the fixture belongs to the parent,
/// while all trial/confirmation/shutdown operations happen in child processes.
/// Session scope intentionally avoids writing permanent display preferences.
enum PersistenceChecks {
    @MainActor static func run() async throws {
        let originalIDs = Set(DisplayCore.onlineIDs())
        let before = DisplaySnapshot(ids: Array(originalIDs))
        var fixture: HDVirtualDisplay?
        var testError: Error?

        do {
            fixture = try HDVirtualDisplay(
                width: 2560, height: 1440, refreshRate: 60,
                name: "HiDPI Studio · Persistence Test")
            guard let fixture else { throw DisplayFailure(message: "Persistence fixture was nil") }
            let displayID = fixture.displayID
            let high = try await DisplayCore.waitForHiDPI(displayID, size: CustomSize(width: 2560, height: 1440))
            guard let low = DisplayCore.modes(displayID).first(where: { !$0.isHiDPI }) else {
                throw DisplayFailure(message: "Persistence fixture has no alternative mode")
            }
            try DisplayCore.setMode(displayID, high)

            try await runWorker(displayID: displayID, mode: low, action: "trial")
            try await expectMode(displayID, high, context: "Unconfirmed trial after process exit")
            print("PASS: quitting an unconfirmed native trial restores its previous mode")

            try await runWorker(displayID: displayID, mode: low, action: "confirm")
            try await expectMode(displayID, low, context: "Confirmed mode after process exit")
            print("PASS: confirmed native mode survives actual worker process exit (session scope)")

            // Start from the newly saved low mode. The child confirms high, then
            // explicitly restores low. Its process must not reapply high on exit.
            try await runWorker(displayID: displayID, mode: high, action: "restore")
            try await expectMode(displayID, low, context: "Explicit restore after process exit")
            print("PASS: explicit restoration of a confirmed mode survives process exit")
        } catch { testError = error }

        fixture?.disconnect()
        fixture = nil
        for _ in 0..<40 {
            if Set(DisplayCore.onlineIDs()) == originalIDs { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        // Always attempt layout cleanup, even when a worker/assertion failed.
        do { try before.restore(scope: .forAppOnly) } catch { if testError == nil { testError = error } }
        try StudioChecks.require(
            Set(DisplayCore.onlineIDs()) == originalIDs,
            "Persistence fixture did not disappear")
        for entry in before.entries {
            try StudioChecks.require(
                CGDisplayCopyDisplayMode(entry.id)?.ioDisplayModeID == entry.mode.ioDisplayModeID,
                "Original physical display mode changed during persistence checks")
        }
        print("PASS: persistence fixture cleanup and original physical modes")
        if let testError { throw testError }
    }

    @MainActor static func worker(args: [String]) async throws {
        guard args.count == 3, let displayID = UInt32(args[0]), let modeID = Int32(args[1]),
            ["trial", "confirm", "restore"].contains(args[2])
        else {
            throw DisplayFailure(message: "Usage: --test-persistence-worker DISPLAY_ID MODE_ID trial|confirm|restore")
        }
        // This entry point can only target an app-created virtual fixture.
        guard CGDisplayVendorNumber(displayID) == 0x4844,
            CGDisplayModelNumber(displayID) == 0x5354,
            let fixture = DisplayCore.displays().first(where: { $0.id == displayID }),
            let previous = fixture.current,
            let requested = fixture.modes.first(where: { $0.id == modeID })
        else {
            throw DisplayFailure(message: "Persistence worker target is not an available virtual fixture/mode")
        }
        let model = DisplayModel(nativeSaveScope: .forSession)
        model.displays = [fixture]
        model.showLowResolution = true
        model.selectedDisplay = displayID
        model.selectedMode = modeID

        do {
            try StudioChecks.require(model.canApply, "Persistence worker cannot apply the requested mode")
            model.applyNative()
            try StudioChecks.require(model.error == nil, model.error ?? "Native trial failed")
            try StudioChecks.require(model.hasTrial, "Native trial did not start")
            try await expectMode(displayID, requested, context: "Worker trial")

            if args[2] != "trial" {
                model.confirmTrial()
                try StudioChecks.require(model.error == nil, model.error ?? "Confirmation failed")
                try StudioChecks.require(!model.hasTrial, "Confirmation did not finish the trial")
            }
            if args[2] == "restore" {
                await model.restoreAll()
                try StudioChecks.require(model.error == nil, model.error ?? "Explicit restore failed")
                try await expectMode(displayID, previous, context: "Worker explicit restore")
            }
            await model.shutdown()
            try StudioChecks.require(model.error == nil, model.error ?? "Worker shutdown failed")
            let expected = args[2] == "confirm" ? requested : previous
            try await expectMode(displayID, expected, context: "Worker shutdown")
        } catch {
            await model.shutdown()
            throw error
        }
    }

    @MainActor private static func runWorker(displayID: CGDirectDisplayID, mode: DisplayMode, action: String)
        async throws
    {
        // Re-resolve mode IDs in case WindowServer regenerated its mode list.
        guard let currentMode = DisplayCore.modes(displayID).first(where: { $0.signature == mode.signature }) else {
            throw DisplayFailure(message: "Requested persistence-test mode disappeared")
        }
        let process = Process()
        process.executableURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--test-persistence-worker", String(displayID), String(currentMode.id), action]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()

        // Never block the parent's main runloop: it owns the CGVirtualDisplay.
        let deadline = Date().addingTimeInterval(20)
        while process.isRunning && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        if process.isRunning {
            process.terminate()
            for _ in 0..<20 where process.isRunning {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            for _ in 0..<20 where process.isRunning {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            throw DisplayFailure(message: "Persistence worker timed out: \(action)")
        }
        let captured = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationReason == .exit && process.terminationStatus == 0 else {
            throw DisplayFailure(
                message: "Persistence worker \(action) failed (\(process.terminationStatus)): \(captured)")
        }
    }

    @MainActor private static func expectMode(_ id: CGDirectDisplayID, _ mode: DisplayMode, context: String)
        async throws
    {
        // Process exit and WindowServer's scope rollback need not be simultaneous.
        // Wait a settling interval before accepting the first matching value.
        try await Task.sleep(nanoseconds: 200_000_000)
        var consecutiveMatches = 0
        for _ in 0..<30 {
            if let current = CGDisplayCopyDisplayMode(id), DisplayMode(raw: current).signature == mode.signature {
                consecutiveMatches += 1
                if consecutiveMatches == 3 { return }
            } else {
                consecutiveMatches = 0
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw DisplayFailure(
            message: "\(context): expected \(mode.sizeLabel) / \(mode.backingLabel) / \(mode.rateLabel)")
    }
}
