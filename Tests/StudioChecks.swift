import AppKit

enum StudioChecks {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw DisplayFailure(message: message) }
    }
    @MainActor static func runCore() async throws {
        try require(DisplayMode.isHiDPI(width: 2560, height: 1440, pixelsWide: 5120, pixelsHigh: 2880), "5K backing must be HiDPI")
        try require(!DisplayMode.isHiDPI(width: 2560, height: 1440, pixelsWide: 2560, pixelsHigh: 1440), "2K backing must be LoDPI")
        try require(!DisplayMode.isHiDPI(width: 2560, height: 1440, pixelsWide: 5120, pixelsHigh: 1440), "Both axes must be doubled")
        try require(!DisplayMode.isHiDPI(width: 0, height: 0, pixelsWide: 0, pixelsHigh: 0), "Zero-sized modes must not be HiDPI")
        for (width, height) in [(0, 1440), (-1, 1080), (3841, 2160), (2560, 2161), (640, 479)] {
            var rejected = false
            do { _ = try CustomSize(width: width, height: height) } catch { rejected = true }
            try require(rejected, "Invalid custom size accepted: \(width)x\(height)")
        }
        _ = try CustomSize(width: 3840, height: 2160)
        for rate in [Double.nan, .infinity, -.infinity, 0, 23.99, 240.01] {
            var rejected = false
            do { _ = try CustomRefreshRate(value: rate) } catch { rejected = true }
            try require(rejected, "Invalid refresh rate accepted: \(rate)")
        }
        for rate in [24.0, 59.94, 60, 120, 144, 240] { _ = try CustomRefreshRate(value: rate) }
        try require(CustomRefreshRate.matches(59.939987, 59.94), "OS fractional rounding should match")
        try require(!CustomRefreshRate.matches(59.94, 60), "59.94 Hz and 60 Hz must remain distinct")
        try require(!CustomRefreshRate.matches(0, 120), "Unreported refresh rate cannot confirm 120 Hz")
        try require(!CustomRefreshRate.matches(.nan, 60), "Nonfinite reported rate cannot confirm a request")
        try require(CustomSize.matchesAspect(width: 2560, height: 1440, targetWidth: 3840, targetHeight: 2160), "4K/2K ratios should match")
        try require(!CustomSize.matchesAspect(width: 2560, height: 1440, targetWidth: 3440, targetHeight: 1440), "Ultrawide mismatch should be rejected")
        var expired = 0
        let trial = ResolutionTrial()
        trial.onExpire = { expired += 1 }
        trial.start(seconds: 0.15)
        try await Task.sleep(nanoseconds: 350_000_000)
        try require(expired == 1, "Trial must expire exactly once")
        trial.start(seconds: 0.15)
        trial.cancel()
        try await Task.sleep(nanoseconds: 250_000_000)
        try require(expired == 1, "Confirmed trial must not expire")
        print("PASS: HiDPI classification, custom dimensions, refresh validation, aspect ratio, countdown and cancellation")
    }

    /// Creates disposable fixtures instead of changing a user's physical screen.
    /// The same CoreGraphics paths used by the GUI are exercised on WindowServer.
    @MainActor static func runVirtual() async throws {
        let before = DisplaySnapshot(ids: DisplayCore.onlineIDs())
        let originalIDs = Set(DisplayCore.onlineIDs())
        var source: HDVirtualDisplay?
        var target: HDVirtualDisplay?
        var testError: Error?
        do {
            for rate in [60.0, 120, 144] {
                let sourceSize = try CustomSize(width: 2560, height: 1440)
                source = try HDVirtualDisplay(width: 2560, height: 1440, refreshRate: rate, name: "HiDPI Studio · Test Source")
                guard let activeSource = source else { throw DisplayFailure(message: "Virtual source was nil") }
                let sourceID = activeSource.displayID
                let high = try await DisplayCore.waitForHiDPI(sourceID, size: sourceSize, refreshRate: rate)
                try DisplayCore.setMode(sourceID, high)
                try DisplayCore.verify(sourceID, width: 2560, height: 1440, hiDPI: true, refreshRate: rate)
                print("PASS: virtual 2560 × 1440 desktop, 5120 × 2880 backing at \(Int(rate)) Hz")

                if rate == 60 {
                    var rejectedMismatch = false
                    do { try DisplayCore.verify(sourceID, width: 2560, height: 1440, hiDPI: true, refreshRate: 120) }
                    catch { rejectedMismatch = true }
                    try require(rejectedMismatch, "A lower actual refresh rate must not be reported as success")

                    let snapshot = DisplaySnapshot(ids: [sourceID])
                    guard let low = DisplayCore.modes(sourceID).first(where: { !$0.isHiDPI }) else {
                        throw DisplayFailure(message: "No alternative mode available for rollback test")
                    }
                    try DisplayCore.setMode(sourceID, low)
                    try DisplayCore.verify(sourceID, width: low.width, height: low.height, hiDPI: false, refreshRate: rate)
                    var restored = false
                    var rollbackError: Error?
                    let trial = ResolutionTrial()
                    trial.onExpire = {
                        do { try snapshot.restore(); restored = true } catch { rollbackError = error }
                    }
                    trial.start(seconds: 0.2)
                    try await Task.sleep(nanoseconds: 550_000_000)
                    if let rollbackError { throw rollbackError }
                    try require(restored, "Rollback did not run")
                    try DisplayCore.verify(sourceID, width: 2560, height: 1440, hiDPI: true, refreshRate: rate)
                    print("PASS: native mode change, actual-rate mismatch rejection and automatic rollback")
                }

                target = try HDVirtualDisplay(width: 1920, height: 1080, refreshRate: rate, name: "HiDPI Studio · Test Target")
                guard let activeTarget = target else { throw DisplayFailure(message: "Virtual target was nil") }
                let targetID = activeTarget.displayID
                _ = try await DisplayCore.waitForHiDPI(targetID, size: CustomSize(width: 1920, height: 1080), refreshRate: rate)
                let mirrorSnapshot = DisplaySnapshot(ids: [sourceID, targetID])
                try DisplayCore.mirror(target: targetID, source: sourceID, sourceMode: high)
                try await Task.sleep(nanoseconds: 350_000_000)
                try require(CGDisplayMirrorsDisplay(targetID) == sourceID, "Mirror master did not match the HiDPI source")
                try DisplayCore.verify(sourceID, width: 2560, height: 1440, hiDPI: true, refreshRate: rate)
                print("PASS: mirror direction, 2× source rendering and retained \(Int(rate)) Hz source refresh")
                try mirrorSnapshot.restore()
                try require(CGDisplayMirrorsDisplay(targetID) == 0, "Mirror was not removed")
                print("PASS: mirror restoration at \(Int(rate)) Hz")

                target?.disconnect(); target = nil
                source?.disconnect(); source = nil
                for _ in 0..<40 {
                    if Set(DisplayCore.onlineIDs()) == originalIDs { break }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                try require(Set(DisplayCore.onlineIDs()) == originalIDs, "Virtual rate fixtures did not disappear")
            }
        } catch { testError = error }

        target?.disconnect(); target = nil
        source?.disconnect(); source = nil
        for _ in 0..<40 {
            if Set(DisplayCore.onlineIDs()) == originalIDs { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try require(Set(DisplayCore.onlineIDs()) == originalIDs, "Temporary virtual displays did not disappear")
        // Restore the physical display arrangement if WindowServer moved origins
        // while adding test fixtures, without changing the saved OS configuration.
        try before.restore()
        for entry in before.entries {
            try require(CGDisplayCopyDisplayMode(entry.id)?.ioDisplayModeID == entry.mode.ioDisplayModeID,
                        "A physical display's original mode was not restored")
        }
        print("PASS: fixture cleanup and original physical display modes")
        if let testError { throw testError }
    }
}
