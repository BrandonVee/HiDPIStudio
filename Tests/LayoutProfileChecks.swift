import Foundation
import CoreGraphics

enum LayoutProfileChecks {
    static func run() throws {
        let frames: [CGDirectDisplayID: CGRect] = [
            1: CGRect(x: 0, y: 0, width: 1728, height: 1117),
            2: CGRect(x: 1728, y: 0, width: 2560, height: 1440)
        ]
        let left = try LayoutGeometry.place(target: 2, relativeTo: 1, direction: .left, frames: frames, main: 1)
        try StudioChecks.require(left[2] == CGPoint(x: -2560, y: 0) && left[1] == .zero,
                                 "Moving external screen left must preserve main origin")
        let above = try LayoutGeometry.place(target: 2, relativeTo: 1, direction: .above, frames: frames, main: 1)
        try StudioChecks.require(above[2] == CGPoint(x: 0, y: -1440), "Above uses negative CG y coordinates")
        let mainMoved = try LayoutGeometry.place(target: 1, relativeTo: 2, direction: .below, frames: frames, main: 1)
        try StudioChecks.require(mainMoved[1] == .zero && mainMoved[2] == CGPoint(x: 0, y: -1440),
                                 "Moving the main display must translate all origins consistently")
        var crowded = frames
        crowded[3] = CGRect(x: -2560, y: 0, width: 2560, height: 1440)
        var overlapRejected = false
        do { _ = try LayoutGeometry.place(target: 2, relativeTo: 1, direction: .left, frames: crowded, main: 1) }
        catch { overlapRejected = true }
        try StudioChecks.require(overlapRejected, "Arranging over an existing third monitor must be rejected")

        let modeJSON = "{\"width\":2560,\"height\":1440,\"pixelWidth\":5120,\"pixelHeight\":2880,\"refreshRate\":59.94}"
        let mode = try JSONDecoder().decode(SavedDisplayMode.self, from: Data(modeJSON.utf8))
        let identity = DisplayIdentity(uuid: "test-display-stable-uuid", vendor: 1, product: 2, serial: 3)
        let entry = SavedLayoutEntry(identity: identity, name: "4K 测试屏", mode: mode, x: 0, y: 0, isMain: true, rotation: 0)
        let profile = SavedLayoutProfile(id: UUID(), name: "办公配置", entries: [entry], createdAt: Date(timeIntervalSince1970: 100))
        try LayoutGeometry.validate(profile.entries)
        let decoded = try JSONDecoder().decode(SavedLayoutProfile.self, from: JSONEncoder().encode(profile))
        try StudioChecks.require(decoded.id == profile.id && decoded.name == profile.name &&
                                 LayoutGeometry.sameConfiguration(decoded.entries, profile.entries),
                                 "Saved profile must preserve identity, 2× dimensions and fractional refresh through encoding")
        var duplicateRejected = false
        do { try LayoutGeometry.validate([entry, entry]) } catch { duplicateRejected = true }
        try StudioChecks.require(duplicateRejected, "A preset may not target the same physical monitor twice")
        let sixty = try JSONDecoder().decode(SavedDisplayMode.self, from: Data(modeJSON.replacingOccurrences(of: "59.94", with: "60").utf8))
        let changedRate = SavedLayoutEntry(identity: identity, name: "4K 测试屏", mode: sixty, x: 0, y: 0, isMain: true, rotation: 0)
        try StudioChecks.require(!LayoutGeometry.sameConfiguration([entry], [changedRate]),
                                 "Confirmation must reject externally changed 59.94/60 Hz modes")
        let changedOrigin = SavedLayoutEntry(identity: identity, name: "4K 测试屏", mode: mode, x: 10, y: 0, isMain: true, rotation: 0)
        try StudioChecks.require(!LayoutGeometry.sameConfiguration([entry], [changedOrigin]),
                                 "Confirmation must detect external layout changes")
        var invalidMainRejected = false
        do { try LayoutGeometry.validate([changedOrigin]) } catch { invalidMainRejected = true }
        try StudioChecks.require(invalidMainRejected, "A stored main screen must be anchored at zero")
        print("PASS: layout geometry, overlap rejection, stable profile round-trip and confirmation change detection")
    }
}
