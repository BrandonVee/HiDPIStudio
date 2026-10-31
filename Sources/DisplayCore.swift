import AppKit
import CoreGraphics

struct DisplayFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct DisplayMode: Identifiable {
    let raw: CGDisplayMode?
    let id: Int32
    let width: Int
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Double
    let isHiddenNative: Bool
    init(raw: CGDisplayMode) {
        self.raw = raw; id = raw.ioDisplayModeID
        width = raw.width; height = raw.height
        pixelWidth = raw.pixelWidth; pixelHeight = raw.pixelHeight
        refreshRate = raw.refreshRate; isHiddenNative = false
    }
    init(hidden: HDHiddenDisplayMode) {
        raw = nil; id = hidden.modeID
        width = Int(hidden.width); height = Int(hidden.height)
        pixelWidth = Int(hidden.pixelWidth); pixelHeight = Int(hidden.pixelHeight)
        refreshRate = hidden.refreshRate; isHiddenNative = true
    }
    var isHiDPI: Bool { Self.isHiDPI(width: width, height: height, pixelsWide: pixelWidth, pixelsHigh: pixelHeight) }
    var sizeLabel: String { "\(width) × \(height)" }
    var backingLabel: String { "\(pixelWidth) × \(pixelHeight)" }
    var rateLabel: String {
        let rate = refreshRate
        guard rate > 0 else { return "未报告" }
        return String(format: abs(rate.rounded() - rate) < 0.005 ? "%.0f Hz" : "%.2f Hz", rate)
    }
    var signature: String { "\(width)x\(height)/\(pixelWidth)x\(pixelHeight)/\(refreshRate)" }
    static func isHiDPI(width: Int, height: Int, pixelsWide: Int, pixelsHigh: Int) -> Bool {
        width > 0 && height > 0 && pixelsWide >= width * 2 && pixelsHigh >= height * 2
    }
}

struct DisplayInfo: Identifiable {
    let id: CGDirectDisplayID
    let name: String
    let isBuiltin: Bool
    let isStudioVirtual: Bool
    let current: DisplayMode?
    let modes: [DisplayMode]
    var isMirrored: Bool { CGDisplayIsInMirrorSet(id) != 0 }
}

struct CustomSize: Equatable {
    let width: Int
    let height: Int
    init(width: Int, height: Int) throws {
        guard (640...3840).contains(width), (480...2160).contains(height) else {
            throw DisplayFailure(message: "桌面尺寸需在 640 × 480 到 3840 × 2160 之间。")
        }
        self.width = width
        self.height = height
    }
    static func matchesAspect(width: Int, height: Int, targetWidth: Int, targetHeight: Int) -> Bool {
        guard width > 0, height > 0, targetWidth > 0, targetHeight > 0 else { return false }
        return abs(Double(width) / Double(height) / (Double(targetWidth) / Double(targetHeight)) - 1) < 0.015
    }
}

struct CustomRefreshRate: Equatable {
    let value: Double
    init(value: Double) throws {
        guard value.isFinite, (24...240).contains(value) else {
            throw DisplayFailure(message: "自定义刷新率需为 24–240 Hz 之间的有效数值。")
        }
        self.value = value
    }
    static func matches(_ actual: Double, _ requested: Double) -> Bool {
        actual.isFinite && requested.isFinite && actual > 0 && requested > 0 && abs(actual - requested) <= 0.02
    }
}

enum DisplayCore {
    static func check(_ error: CGError, _ operation: String) throws {
        guard error == .success else { throw DisplayFailure(message: "\(operation)失败（macOS \(error.rawValue)）。请退出全屏应用后重试。") }
    }

    static func onlineIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    static func modes(_ id: CGDirectDisplayID) -> [DisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        let raw = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] ?? []
        var modes = raw.filter { $0.isUsableForDesktopGUI() }.map { DisplayMode(raw: $0) }
        // Prefer public CGDisplayMode objects (precise Hz). The current mode can
        // be absent from the public array even after a hidden mode is activated.
        if let current = CGDisplayCopyDisplayMode(id), !modes.contains(where: { $0.id == current.ioDisplayModeID }) {
            modes.append(DisplayMode(raw: current))
        }
        let known = Set(modes.map(\.id))
        if CGDisplayIsBuiltin(id) == 0 && !(CGDisplayVendorNumber(id) == 0x4844 && CGDisplayModelNumber(id) == 0x5354) {
            modes += HDHiddenDisplayModes.modes(forDisplay: id).filter { !known.contains($0.modeID) }.map(DisplayMode.init(hidden:))
        }
        return modes
    }

    static func displays() -> [DisplayInfo] {
        let screens = NSScreen.screens
        return onlineIDs().map { id in
            let screen = screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
            let builtin = CGDisplayIsBuiltin(id) != 0
            var seen = Set<String>()
            let available = modes(id).sorted {
                if $0.width != $1.width { return $0.width < $1.width }
                if $0.height != $1.height { return $0.height < $1.height }
                if $0.isHiDPI != $1.isHiDPI { return $0.isHiDPI }
                return $0.refreshRate > $1.refreshRate
            }.filter { seen.insert($0.signature).inserted }
            return DisplayInfo(id: id, name: screen?.localizedName ?? (builtin ? "内置显示器" : "外接显示器 \(id)"),
                               isBuiltin: builtin, isStudioVirtual: CGDisplayVendorNumber(id) == 0x4844 && CGDisplayModelNumber(id) == 0x5354,
                               current: CGDisplayCopyDisplayMode(id).map(DisplayMode.init), modes: available)
        }.sorted { ($0.isBuiltin ? 1 : 0, $0.id) < ($1.isBuiltin ? 1 : 0, $1.id) }
    }

    static func configure(scope: CGConfigureOption = .forAppOnly, _ body: (CGDisplayConfigRef) throws -> Void) throws {
        var config: CGDisplayConfigRef?
        try check(CGBeginDisplayConfiguration(&config), "开始显示设置")
        guard let config else { throw DisplayFailure(message: "无法建立显示设置事务。") }
        do { try body(config) } catch { CGCancelDisplayConfiguration(config); throw error }
        // Trials and virtual screens stay app-scoped; confirmation explicitly saves.
        try check(CGCompleteDisplayConfiguration(config, scope), "应用显示设置")
    }

    static func setMode(_ display: CGDirectDisplayID, _ mode: CGDisplayMode, scope: CGConfigureOption = .forAppOnly) throws {
        guard onlineIDs().contains(display) else { throw DisplayFailure(message: "显示器已断开，请刷新后重试。") }
        try configure(scope: scope) { try configureMode($0, display: display, mode: DisplayMode(raw: mode)) }
    }

    static func configureMode(_ config: CGDisplayConfigRef, display: CGDirectDisplayID, mode: DisplayMode) throws {
        if let raw = mode.raw {
            let result = CGConfigureDisplayWithDisplayMode(config, display, raw, nil)
            if result == .success { return }
            guard HDHiddenDisplayModes.modes(forDisplay: display).contains(where: { $0.modeID == mode.id }) else {
                try check(result, "切换分辨率"); return
            }
        }
        try HDHiddenDisplayModes.configure(config, display: display, mode: mode.id)
    }

    static func setMode(_ display: CGDirectDisplayID, _ mode: DisplayMode, scope: CGConfigureOption = .forAppOnly) throws {
        guard onlineIDs().contains(display), modes(display).contains(where: {
            $0.id == mode.id && $0.width == mode.width && $0.height == mode.height &&
            $0.pixelWidth == mode.pixelWidth && $0.pixelHeight == mode.pixelHeight &&
            ($0.refreshRate == mode.refreshRate || CustomRefreshRate.matches($0.refreshRate, mode.refreshRate))
        }) else { throw DisplayFailure(message: "请求的显示模式已变化，请刷新后重试。") }
        try configure(scope: scope) { try configureMode($0, display: display, mode: mode) }
    }

    static func verify(_ id: CGDirectDisplayID, width: Int, height: Int, hiDPI: Bool, refreshRate: Double? = nil) throws {
        guard let raw = CGDisplayCopyDisplayMode(id) else { throw DisplayFailure(message: "无法读取切换后的显示模式。") }
        let mode = DisplayMode(raw: raw)
        guard mode.width == width, mode.height == height, mode.isHiDPI == hiDPI else {
            throw DisplayFailure(message: "macOS 未采用请求的模式，已请求恢复原设置。")
        }
        if let refreshRate, !CustomRefreshRate.matches(raw.refreshRate, refreshRate) {
            let requested = String(format: "%.2f Hz", refreshRate)
            throw DisplayFailure(message: "请求刷新率为 \(requested)，系统实际报告为 \(mode.rateLabel)。已请求恢复，请尝试其他刷新率。")
        }
    }

    static func mirror(target: CGDirectDisplayID, source: CGDirectDisplayID, sourceMode: DisplayMode) throws {
        let origin = CGDisplayBounds(target).origin
        try configure { config in
            try configureMode(config, display: source, mode: sourceMode)
            try check(CGConfigureDisplayOrigin(config, source, Int32(origin.x), Int32(origin.y)), "放置虚拟屏幕")
            try check(CGConfigureDisplayMirrorOfDisplay(config, target, source), "开启镜像")
        }
    }

    static func waitForHiDPI(_ display: CGDirectDisplayID, size: CustomSize, refreshRate: Double? = nil) async throws -> DisplayMode {
        for _ in 0..<30 {
            if let mode = modes(display).first(where: { candidate in
                candidate.width == size.width && candidate.height == size.height && candidate.isHiDPI &&
                    (refreshRate.map { CustomRefreshRate.matches(candidate.refreshRate, $0) } ?? true)
            }) { return mode }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let rateDescription = refreshRate.map { String(format: " / %.2f Hz", $0) } ?? ""
        throw DisplayFailure(message: "macOS 没有发布 \(size.width) × \(size.height) HiDPI\(rateDescription) 模式。请尝试较低刷新率或较小桌面尺寸。")
    }
}

/// Captures the actual mode objects, including refresh rate, before changing a
/// display. Scope is explicit, so reverting one screen does not reset another.
struct DisplaySnapshot {
    struct Entry {
        let id: CGDirectDisplayID
        let mode: CGDisplayMode
        let origin: CGPoint
        let mirror: CGDirectDisplayID
        let identity: [UInt32]
    }
    let entries: [Entry]
    init(ids: [CGDirectDisplayID]) {
        entries = ids.compactMap { id in
            CGDisplayCopyDisplayMode(id).map { Entry(id: id, mode: $0, origin: CGDisplayBounds(id).origin,
                                                    mirror: CGDisplayMirrorsDisplay(id), identity: Self.identity(id)) }
        }
    }
    private static func identity(_ id: CGDirectDisplayID) -> [UInt32] {
        [CGDisplayVendorNumber(id), CGDisplayModelNumber(id), CGDisplaySerialNumber(id)]
    }
    func containsCurrentDisplay(_ id: CGDirectDisplayID) -> Bool {
        entries.contains { $0.id == id && Self.identity(id) == $0.identity }
    }
    /// Native mode undo must not overwrite a layout confirmed by another feature.
    func restoreModesOnly(scope: CGConfigureOption = .forAppOnly) throws {
        let online = Set(DisplayCore.onlineIDs())
        let present = entries.filter { online.contains($0.id) && Self.identity($0.id) == $0.identity }
        guard !present.isEmpty else { return }
        guard present.allSatisfy({ CGDisplayIsInMirrorSet($0.id) == 0 }) else {
            throw DisplayFailure(message: "显示器已加入镜像组，请先结束镜像再恢复分辨率。")
        }
        try DisplayCore.configure(scope: scope) { config in
            for entry in present {
                try DisplayCore.configureMode(config, display: entry.id, mode: DisplayMode(raw: entry.mode))
            }
        }
    }
    func restore(scope: CGConfigureOption = .forAppOnly) throws {
        let online = Set(DisplayCore.onlineIDs())
        let present = entries.filter { online.contains($0.id) && Self.identity($0.id) == $0.identity }
        let validIDs = Set(present.map(\.id))
        guard !present.isEmpty else { return }
        try DisplayCore.configure(scope: scope) { config in
            for entry in present {
                try DisplayCore.check(CGConfigureDisplayMirrorOfDisplay(config, entry.id, 0), "取消临时镜像")
                try DisplayCore.configureMode(config, display: entry.id, mode: DisplayMode(raw: entry.mode))
                try DisplayCore.check(CGConfigureDisplayOrigin(config, entry.id, Int32(entry.origin.x), Int32(entry.origin.y)), "恢复位置")
            }
            for entry in present where entry.mirror != 0 && validIDs.contains(entry.mirror) {
                try DisplayCore.check(CGConfigureDisplayMirrorOfDisplay(config, entry.id, entry.mirror), "恢复原镜像")
            }
        }
    }
}
