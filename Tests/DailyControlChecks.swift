import Foundation

enum DailyControlChecks {
    static func run() throws {
        for value in [-0.01, 1.01, Double.nan, Double.infinity] {
            var rejected = false
            do { _ = try NativeBrightnessService.validated(value) } catch { rejected = true }
            try StudioChecks.require(rejected, "Invalid native brightness value was accepted")
        }
        let minimum = try NativeBrightnessService.validated(0)
        let maximum = try NativeBrightnessService.validated(1)
        try StudioChecks.require(minimum == 0 && maximum == 1, "Native brightness should allow the OS bounds")
        try StudioChecks.require(
            NativeBrightnessService.matches(0.5001, 0.5) && !NativeBrightnessService.matches(0.49, 0.5),
            "Native brightness must reject an unapplied request")
        for (brightness, warmth) in [
            (0.19, 0.0), (1.01, 0.0), (1.0, -0.01), (1.0, 1.01), (.nan, 0.0), (1.0, .infinity),
        ] {
            var rejected = false
            do { _ = try SoftwareDisplayAdjustment(brightness: brightness, warmth: warmth) } catch { rejected = true }
            try StudioChecks.require(rejected, "Invalid software filter adjustment was accepted")
        }
        let floor = try SoftwareDisplayAdjustment(brightness: 0.2, warmth: 1)
        try StudioChecks.require(
            floor.dimOpacity <= 0.8 && floor.warmOpacity <= 0.25,
            "Software filters exceeded their visibility limits")
        try StudioChecks.require(
            SoftwareDisplayAdjustment.neutral.isNeutral,
            "Neutral software filter must not require a window")

        // Isolated preferences only. No filter method is called, so these checks
        // never create windows, alter the desktop, or change real display modes.
        let suite = "HiDPIStudio.tests.daily." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw DisplayFailure(message: "Cannot create test preferences")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let identity = DisplayIdentity(uuid: UUID().uuidString, vendor: 1, product: 2, serial: 3)
        let modeJSON = #"{"width":2560,"height":1440,"pixelWidth":5120,"pixelHeight":2880,"refreshRate":144}"#
        let mode = try JSONDecoder().decode(SavedDisplayMode.self, from: Data(modeJSON.utf8))
        let favorite = FavoriteResolution(name: " 阅读模式 ", displayName: "测试屏幕", identity: identity, mode: mode)
        let manager = DailyControlManager(defaults: defaults, observeScreens: false)
        manager.addFavorite(favorite)
        let loaded = DailyControlManager(defaults: defaults, observeScreens: false)
        try StudioChecks.require(
            loaded.favorites.count == 1 && loaded.favorites[0].name == "阅读模式",
            "Favorite did not survive preferences reload")
        try StudioChecks.require(
            loaded.favorites[0].identity == identity && loaded.favorites[0].mode == mode,
            "Favorite lost physical identity or backing/refresh details")
        let renamed = FavoriteResolution(name: "工作模式", displayName: "测试屏幕", identity: identity, mode: mode)
        loaded.addFavorite(renamed)
        try StudioChecks.require(
            loaded.favorites.count == 1 && loaded.favorites[0].id == favorite.id && loaded.favorites[0].name == "工作模式",
            "Updating a duplicate favorite changed its shortcut position or identity")
        loaded.removeFavorite(id: favorite.id)
        let emptied = DailyControlManager(defaults: defaults, observeScreens: false)
        try StudioChecks.require(
            emptied.favorites.isEmpty && emptied.activeFilterCount == 0,
            "Favorite removal failed or initialization activated a filter")
        print(
            "PASS: native brightness validation/readback comparison, software filter bounds, favorite persistence/rename/removal"
        )
    }
}
