import CoreGraphics
import ColorSync

/// ColorSync's UUID survives transient numeric display IDs and distinguishes
/// monitors that share a model name. Stored presets never rely on a CG mode ID.
struct DisplayIdentity: Codable, Hashable {
    let uuid: String
    let vendor: UInt32
    let product: UInt32
    let serial: UInt32

    static func capture(_ id: CGDirectDisplayID) -> DisplayIdentity? {
        guard let value = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return DisplayIdentity(uuid: CFUUIDCreateString(nil, value) as String,
                               vendor: CGDisplayVendorNumber(id), product: CGDisplayModelNumber(id), serial: CGDisplaySerialNumber(id))
    }
    func matches(_ id: CGDirectDisplayID) -> Bool { Self.capture(id) == self }
    func resolve() -> CGDirectDisplayID? { DisplayCore.onlineIDs().first(where: matches) }
}

struct SavedDisplayMode: Codable, Hashable {
    let width: Int
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Double
    init(_ mode: DisplayMode) {
        width = mode.width; height = mode.height
        pixelWidth = mode.pixelWidth; pixelHeight = mode.pixelHeight
        refreshRate = mode.refreshRate
    }
    var isHiDPI: Bool { DisplayMode.isHiDPI(width: width, height: height, pixelsWide: pixelWidth, pixelsHigh: pixelHeight) }
    var label: String {
        let rate = refreshRate == 0 ? "未报告刷新率" : String(format: abs(refreshRate.rounded() - refreshRate) < 0.005 ? "%.0f Hz" : "%.2f Hz", refreshRate)
        return "\(width) × \(height) · \(rate)\(isHiDPI ? " · HiDPI" : "")"
    }
    func resolve(on display: CGDirectDisplayID) -> DisplayMode? {
        DisplayCore.modes(display).first {
            $0.width == width && $0.height == height && $0.pixelWidth == pixelWidth && $0.pixelHeight == pixelHeight &&
            ((refreshRate == 0 && $0.refreshRate == 0) || CustomRefreshRate.matches($0.refreshRate, refreshRate))
        }
    }
}
