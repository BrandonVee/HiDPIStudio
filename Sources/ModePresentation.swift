import CoreGraphics

/// A resolution row keeps every real refresh-rate variant. Retina and ordinary
/// modes stay separate even when they have the same logical desktop dimensions.
struct ModeGroup: Identifiable {
    let id: String
    let modes: [DisplayMode]
    var representative: DisplayMode { modes[0] }

    static func group(_ modes: [DisplayMode]) -> [ModeGroup] {
        let grouped = Dictionary(grouping: modes) { mode in
            "\(mode.width)x\(mode.height)/\(mode.pixelWidth)x\(mode.pixelHeight)"
        }
        return grouped.map { key, values in
            ModeGroup(id: key, modes: values.sorted { $0.refreshRate > $1.refreshRate })
        }.sorted {
            let a = $0.representative, b = $1.representative
            if a.width != b.width { return a.width < b.width }
            if a.height != b.height { return a.height < b.height }
            if a.isHiDPI != b.isHiDPI { return a.isHiDPI }
            return a.pixelWidth < b.pixelWidth
        }
    }

    func preferred(selectedID: Int32?, current: DisplayMode?, preferredRate: Double?) -> DisplayMode {
        if let selected = modes.first(where: { $0.id == selectedID }) { return selected }
        if let current, let match = modes.first(where: { $0.signature == current.signature }) { return match }
        if let rate = preferredRate, let match = modes.first(where: { CustomRefreshRate.matches($0.refreshRate, rate) }) { return match }
        return representative
    }
}
