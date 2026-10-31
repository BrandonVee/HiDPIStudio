import AppKit
import SwiftUI
import CoreGraphics

struct SoftwareDisplayAdjustment: Equatable {
    let brightness: Double
    let warmth: Double

    init(brightness: Double = 1, warmth: Double = 0) throws {
        guard brightness.isFinite, warmth.isFinite,
              (0.2...1).contains(brightness), (0...1).contains(warmth) else {
            throw DisplayFailure(message: "软件亮度需在 20–100%，暖色强度需在 0–100%。")
        }
        self.brightness = brightness
        self.warmth = warmth
    }
    static let neutral = try! SoftwareDisplayAdjustment()
    var isNeutral: Bool { brightness == 1 && warmth == 0 }
    var dimOpacity: Double { 1 - brightness }
    var warmOpacity: Double { warmth * 0.25 }
}

struct FavoriteResolution: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    let displayName: String
    let identity: DisplayIdentity
    let mode: SavedDisplayMode

    init(id: UUID = UUID(), name: String, displayName: String,
         identity: DisplayIdentity, mode: SavedDisplayMode) {
        self.id = id
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = String((trimmed.isEmpty ? mode.label : trimmed).prefix(64))
        self.displayName = String(displayName.prefix(100))
        self.identity = identity
        self.mode = mode
    }
}

private final class DisplayFilterPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private final class DisplayFilterView: NSView {
    var adjustment = SoftwareDisplayAdjustment.neutral { didSet { needsDisplay = true } }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill(using: .copy)
        if adjustment.warmth > 0 {
            NSColor(calibratedRed: 1, green: 0.48, blue: 0.12, alpha: adjustment.warmOpacity).setFill()
            bounds.fill(using: .sourceOver)
        }
        if adjustment.brightness < 1 {
            NSColor.black.withAlphaComponent(adjustment.dimOpacity).setFill()
            bounds.fill(using: .sourceOver)
        }
    }
}

/// Main-thread UI owner. System brightness is applied through the OS; additional
/// software filters are session-only windows and never modify gamma/color profiles.
final class DailyControlManager: ObservableObject {
    @Published private(set) var favorites: [FavoriteResolution] = []
    @Published private(set) var adjustments: [String: SoftwareDisplayAdjustment] = [:]
    @Published private(set) var nativeReadings: [String: NativeBrightnessReading] = [:]
    @Published private(set) var pendingNativeBrightness: [String: Double] = [:]
    @Published private(set) var nativeUnavailable: [String: String] = [:]
    @Published private(set) var brightnessErrors: [String: String] = [:]
    @Published var error: String?
    @Published var message: String?
    var isBlocked: () -> Bool = { false }
    var onManualBrightnessRequest: (CGDirectDisplayID, Double) -> Void = { _, _ in }

    private struct FilterWindow {
        let identity: DisplayIdentity
        let panel: DisplayFilterPanel
        let view: DisplayFilterView
    }
    private var filters: [String: FilterWindow] = [:]
    private var observers: [NSObjectProtocol] = []
    private let defaults: UserDefaults
    private let favoritesKey = "HiDPIStudio.favoriteResolutions.v1"
    private var isShuttingDown = false
    private var nativeTasks: [String: Task<Void, Never>] = [:]
    private var originalNativeBrightness: [String: Double] = [:]
    private var nativeReadTasks: [String: Task<Void, Never>] = [:]
    private var nativeReadGenerations: [String: UUID] = [:]
    @Published private(set) var readingBrightnessIDs = Set<String>()
    private var pendingShortcutDeltas: [String: Double] = [:]

    init(defaults: UserDefaults = .standard, observeScreens: Bool = true) {
        self.defaults = defaults
        if let data = defaults.data(forKey: favoritesKey) {
            do {
                let decoded = try JSONDecoder().decode([FavoriteResolution].self, from: data)
                var ids = Set<UUID>()
                favorites = decoded.filter { ids.insert($0.id).inserted }
            } catch { self.error = "无法读取收藏数据，原数据尚未改动。" }
        }
        // Loading favorites never creates filter windows or changes any display.
        if observeScreens {
            observers.append(NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil, queue: .main
            ) { [weak self] _ in self?.refreshScreens() })
        }
    }

    var activeFilterCount: Int { adjustments.count }

    func nativeReading(for displayID: CGDirectDisplayID) -> NativeBrightnessReading? {
        guard let identity = DisplayIdentity.capture(displayID),
              let reading = nativeReadings[identity.uuid], reading.identity == identity else { return nil }
        return reading
    }

    func systemBrightnessValue(for displayID: CGDirectDisplayID) -> Double? {
        guard let reading = nativeReading(for: displayID) else { return nil }
        return pendingNativeBrightness[reading.identity.uuid] ?? reading.value
    }

    func isChangingSystemBrightness(displayID: CGDirectDisplayID) -> Bool {
        guard let identity = DisplayIdentity.capture(displayID) else { return false }
        return pendingNativeBrightness[identity.uuid] != nil
    }

    func nativeUnavailableReason(for displayID: CGDirectDisplayID) -> String? {
        guard let identity = DisplayIdentity.capture(displayID) else { return "请连接并选择显示器。" }
        return nativeUnavailable[identity.uuid]
    }
    func brightnessError(for displayID: CGDirectDisplayID) -> String? {
        guard let identity = DisplayIdentity.capture(displayID) else { return nil }
        return brightnessErrors[identity.uuid]
    }

    func refreshSystemBrightness(displayID: CGDirectDisplayID) {
        guard !isShuttingDown, let identity = DisplayIdentity.capture(displayID),
              pendingNativeBrightness[identity.uuid] == nil, nativeReadTasks[identity.uuid] == nil else { return }
        let key = identity.uuid, generation = UUID()
        nativeReadGenerations[key] = generation
        readingBrightnessIDs.insert(key)
        nativeReadTasks[key] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.nativeReadGenerations[key] == generation {
                    self.readingBrightnessIDs.remove(key); self.nativeReadTasks[key] = nil
                    self.nativeReadGenerations[key] = nil
                }
            }
            do {
                let reading = try await HardwareBrightness.read(displayID: displayID)
                try Task.checkCancellation()
                guard !self.isShuttingDown, reading.identity == identity, identity.matches(displayID) else { return }
                self.nativeReadings[key] = reading
                self.nativeUnavailable[key] = nil
                self.brightnessErrors[key] = nil
                if let delta = self.pendingShortcutDeltas.removeValue(forKey: key) {
                    self.nativeReadTasks[key] = nil; self.nativeReadGenerations[key] = nil
                    self.readingBrightnessIDs.remove(key)
                    let base = self.pendingNativeBrightness[key] ?? reading.value
                    self.setSystemBrightness(min(1, max(0, base + delta)), for: displayID, expectedIdentity: identity)
                }
            } catch is CancellationError { return }
            catch {
                guard !self.isShuttingDown, !Task.isCancelled else { return }
                self.nativeReadings[key] = nil
                self.nativeUnavailable[key] = error.localizedDescription
                if self.pendingShortcutDeltas.removeValue(forKey: key) != nil {
                    self.brightnessErrors[key] = "硬件亮度不可用：" + error.localizedDescription
                }
            }
        }
    }

    func setSystemBrightness(_ value: Double, for displayID: CGDirectDisplayID, expectedIdentity: DisplayIdentity? = nil) {
        guard !isShuttingDown else { return }
        guard !isBlocked() else { error = "请先完成当前显示配置试用，再调整亮度。"; return }
        guard let identity = DisplayIdentity.capture(displayID) else { error = "显示器已断开。"; return }
        guard expectedIdentity == nil || expectedIdentity == identity else { error = "显示器身份已变化，请刷新后重试。"; return }
        do { _ = try NativeBrightnessService.validated(value) }
        catch { self.error = error.localizedDescription; return }
        onManualBrightnessRequest(displayID, value)
        let key = identity.uuid
        brightnessErrors[key] = nil
        nativeTasks[key]?.cancel()
        nativeReadTasks.removeValue(forKey: key)?.cancel()
        nativeReadGenerations[key] = nil; readingBrightnessIDs.remove(key)
        pendingShortcutDeltas[key] = nil
        pendingNativeBrightness[key] = value
        nativeTasks[key] = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // Coalesce rapid slider events before issuing slow monitor I/O.
                if self.nativeReadings[key]?.backend == .ddc { try await Task.sleep(nanoseconds: 120_000_000) }
                let before = try await HardwareBrightness.read(displayID: displayID)
                guard before.identity == identity else { throw DisplayFailure(message: "显示器身份已变化，已取消亮度调整。") }
                if self.originalNativeBrightness[key] == nil { self.originalNativeBrightness[key] = before.value }
                let applied = try await HardwareBrightness.set(value, displayID: displayID, expectedIdentity: identity)
                try Task.checkCancellation()
                self.nativeReadings[key] = applied
                self.nativeUnavailable[key] = nil
                self.brightnessErrors[key] = nil
            } catch is CancellationError { return }
            catch {
                guard !Task.isCancelled else { return }
                let failure = error.localizedDescription
                if let actual = try? await HardwareBrightness.read(displayID: displayID), actual.identity == identity {
                    guard !Task.isCancelled else { return }
                    self.nativeReadings[key] = actual
                } else {
                    guard !Task.isCancelled else { return }
                    self.nativeReadings[key] = nil; self.nativeUnavailable[key] = failure
                }
                self.brightnessErrors[key] = failure
            }
            self.pendingNativeBrightness[key] = nil
            self.nativeTasks[key] = nil
        }
    }

    func canResetSystemBrightness(displayID: CGDirectDisplayID) -> Bool {
        guard let reading = nativeReading(for: displayID), let original = originalNativeBrightness[reading.identity.uuid] else { return false }
        return !isChangingSystemBrightness(displayID: displayID) && !NativeBrightnessService.matches(reading.value, original)
    }

    /// Accept a verified sync reading without starting another write or changing
    /// the manual undo baseline. Never jump a slider the user is manipulating.
    func acceptObservedBrightness(_ reading: NativeBrightnessReading) {
        guard !isShuttingDown, reading.identity.matches(reading.displayID),
              pendingNativeBrightness[reading.identity.uuid] == nil else { return }
        nativeReadings[reading.identity.uuid] = reading
        nativeUnavailable[reading.identity.uuid] = nil
        brightnessErrors[reading.identity.uuid] = nil
    }

    func resetSystemBrightness(displayID: CGDirectDisplayID) {
        guard let identity = DisplayIdentity.capture(displayID), let original = originalNativeBrightness[identity.uuid] else { return }
        setSystemBrightness(original, for: displayID)
    }

    func adjustment(for displayID: CGDirectDisplayID) -> SoftwareDisplayAdjustment {
        guard let identity = DisplayIdentity.capture(displayID) else { return .neutral }
        return adjustments[identity.uuid] ?? .neutral
    }

    func unavailableReason(for displayID: CGDirectDisplayID) -> String? {
        guard DisplayCore.onlineIDs().contains(displayID) else { return "显示器已断开。" }
        if CGDisplayIsInMirrorSet(displayID) != 0 { return "镜像组暂不提供独立软件滤镜，请先停止镜像。" }
        if CGDisplayVendorNumber(displayID) == 0x4844 && CGDisplayModelNumber(displayID) == 0x5354 {
            return "软件滤镜用于实体显示器；请在左侧选择内置屏或外接屏。"
        }
        guard Self.screen(for: displayID) != nil, DisplayIdentity.capture(displayID) != nil else {
            return "这块显示器没有可独立调整的桌面。"
        }
        return nil
    }

    func setBrightness(_ value: Double, for displayID: CGDirectDisplayID) {
        let current = adjustment(for: displayID)
        setAdjustment(brightness: value, warmth: current.warmth, for: displayID)
    }

    func setWarmth(_ value: Double, for displayID: CGDirectDisplayID) {
        let current = adjustment(for: displayID)
        setAdjustment(brightness: current.brightness, warmth: value, for: displayID)
    }

    func adjustBrightness(displayID: CGDirectDisplayID, delta: Double) {
        guard delta.isFinite else { error = "亮度调整值无效。"; return }
        guard !isShuttingDown, !isBlocked() else { error = "请先完成当前显示配置试用，再调整亮度。"; return }
        guard let identity = DisplayIdentity.capture(displayID) else { error = "显示器已断开。"; return }
        if let current = pendingNativeBrightness[identity.uuid] {
            setSystemBrightness(min(1, max(0, current + delta)), for: displayID, expectedIdentity: identity)
        } else {
            // Read afresh when idle: the monitor OSD may have changed brightness.
            // One identity-pinned read accumulates all repeats until it finishes.
            pendingShortcutDeltas[identity.uuid, default: 0] += delta
            refreshSystemBrightness(displayID: displayID)
        }
    }

    private func setAdjustment(brightness: Double, warmth: Double, for displayID: CGDirectDisplayID) {
        guard !isShuttingDown else { return }
        guard !isBlocked() else { error = "请先完成当前显示配置试用，再调整滤镜。"; return }
        if let reason = unavailableReason(for: displayID) { error = reason; return }
        guard let identity = DisplayIdentity.capture(displayID), let screen = Self.screen(for: displayID) else { return }
        do {
            let value = try SoftwareDisplayAdjustment(brightness: brightness, warmth: warmth)
            if value.isNeutral {
                removeFilter(identity.uuid)
            } else {
                let filter: FilterWindow
                if let existing = filters[identity.uuid], existing.identity == identity {
                    filter = existing
                } else {
                    removeFilter(identity.uuid)
                    let panel = DisplayFilterPanel(contentRect: screen.frame,
                                                   styleMask: [.borderless, .nonactivatingPanel],
                                                   backing: .buffered, defer: false)
                    panel.title = "HiDPI Studio 软件滤镜"
                    panel.isOpaque = false
                    panel.backgroundColor = .clear
                    panel.hasShadow = false
                    panel.ignoresMouseEvents = true
                    panel.hidesOnDeactivate = false
                    panel.isFloatingPanel = true
                    panel.isReleasedWhenClosed = false
                    panel.animationBehavior = .none
                    panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
                    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
                    let view = DisplayFilterView(frame: NSRect(origin: .zero, size: screen.frame.size))
                    view.autoresizingMask = [.width, .height]
                    panel.contentView = view
                    filter = FilterWindow(identity: identity, panel: panel, view: view)
                    filters[identity.uuid] = filter
                }
                filter.panel.setFrame(screen.frame, display: false)
                filter.view.adjustment = value
                adjustments[identity.uuid] = value
                if !filter.panel.isVisible { filter.panel.orderFrontRegardless() }
            }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func reset(displayID: CGDirectDisplayID) {
        guard let identity = DisplayIdentity.capture(displayID) else { return }
        removeFilter(identity.uuid)
        error = nil
    }

    func resetAll() {
        for key in Array(filters.keys) { removeFilter(key) }
        adjustments.removeAll()
        error = nil
    }

    func refreshScreens() {
        // Keep an existing filter only while the exact physical identity remains
        // independently drawable. Never bind a reused numeric display ID.
        for (key, filter) in Array(filters) {
            guard let id = filter.identity.resolve(), filter.identity.matches(id),
                  unavailableReason(for: id) == nil, let screen = Self.screen(for: id) else {
                removeFilter(key)
                continue
            }
            filter.panel.setFrame(screen.frame, display: true)
        }
        let displays = DisplayCore.onlineIDs()
        let connected = Set(displays.compactMap { DisplayIdentity.capture($0)?.uuid })
        for key in Set(nativeReadings.keys).union(pendingNativeBrightness.keys).union(originalNativeBrightness.keys).union(nativeReadTasks.keys).union(nativeUnavailable.keys).union(pendingShortcutDeltas.keys).union(brightnessErrors.keys) where !connected.contains(key) {
            nativeTasks.removeValue(forKey: key)?.cancel()
            nativeReadTasks.removeValue(forKey: key)?.cancel()
            nativeReadGenerations[key] = nil; readingBrightnessIDs.remove(key); pendingShortcutDeltas[key] = nil
            nativeReadings[key] = nil; pendingNativeBrightness[key] = nil
            originalNativeBrightness[key] = nil; nativeUnavailable[key] = nil; brightnessErrors[key] = nil
        }
        for display in displays { refreshSystemBrightness(displayID: display) }
    }

    func shutdown() {
        isShuttingDown = true
        nativeTasks.values.forEach { $0.cancel() }
        nativeTasks.removeAll(); pendingNativeBrightness.removeAll()
        nativeReadTasks.values.forEach { $0.cancel() }
        nativeReadTasks.removeAll(); nativeReadGenerations.removeAll(); readingBrightnessIDs.removeAll(); pendingShortcutDeltas.removeAll()
        // Native system brightness is intentionally not restored on shutdown.
        resetAll()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    private func removeFilter(_ uuid: String) {
        filters.removeValue(forKey: uuid)?.panel.close()
        adjustments[uuid] = nil
    }

    private static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
    }

    func saveFavorite(name: String, display: DisplayInfo, mode: DisplayMode) {
        guard !display.isStudioVirtual, !display.isMirrored,
              let identity = DisplayIdentity.capture(display.id),
              DisplayCore.modes(display.id).contains(where: { $0.signature == mode.signature }) else {
            error = "请先选择可用的独立实体显示器和系统显示模式。"; return
        }
        addFavorite(FavoriteResolution(name: name, displayName: display.name,
                                       identity: identity, mode: SavedDisplayMode(mode)))
    }

    /// Upserts an identity+mode pair; re-saving with a new name renames it while
    /// retaining its position and keyboard shortcut index.
    func addFavorite(_ favorite: FavoriteResolution) {
        var next = favorites
        if let index = next.firstIndex(where: { $0.identity == favorite.identity && $0.mode == favorite.mode }) {
            next[index].name = favorite.name
        } else { next.append(favorite) }
        persist(next)
    }

    func removeFavorite(id: UUID) { persist(favorites.filter { $0.id != id }) }

    private func persist(_ next: [FavoriteResolution]) {
        do {
            let data = try JSONEncoder().encode(next)
            defaults.set(data, forKey: favoritesKey)
            favorites = next
            error = nil
            message = "收藏已保存。收藏模式仍通过试用和确认后才应用。"
        } catch { self.error = "收藏保存失败：\(error.localizedDescription)" }
    }

    func applyFavorite(id: UUID, displayModel: DisplayModel) {
        guard let favorite = favorites.first(where: { $0.id == id }) else { error = "收藏已被移除。"; return }
        guard !isShuttingDown, !isBlocked(), !displayModel.hasTrial, !displayModel.isBusy,
              displayModel.virtualTarget == nil else {
            error = "请先完成当前试用或停止镜像，再使用收藏。"; return
        }
        guard let displayID = favorite.identity.resolve() else { error = "收藏对应的显示器未连接：\(favorite.displayName)。"; return }
        guard CGDisplayIsInMirrorSet(displayID) == 0,
              let mode = favorite.mode.resolve(on: displayID) else {
            error = "当前连接未提供此收藏模式，或显示器处于镜像组。"; return
        }
        displayModel.refresh()
        guard displayModel.displays.contains(where: { $0.id == displayID }) else {
            error = "收藏对应的显示器当前不可用。"; return
        }
        if !mode.isHiDPI { displayModel.showLowResolution = true }
        displayModel.selectedDisplay = displayID
        displayModel.selectedMode = mode.id
        if let current = CGDisplayCopyDisplayMode(displayID), DisplayMode(raw: current).signature == mode.signature {
            error = nil; message = "该显示器已经在使用“\(favorite.name)”。"; return
        }
        guard displayModel.canApply else { error = "请先恢复或结束当前显示配置操作。"; return }
        error = nil
        displayModel.applyNative()
        if let failure = displayModel.error {
            error = failure
            message = "收藏模式未能应用。"
        } else {
            message = displayModel.hasTrial ? "正在试用收藏“\(favorite.name)”，请在倒计时结束前确认。" : displayModel.message
        }
    }

    deinit {
        nativeTasks.values.forEach { $0.cancel() }
        nativeReadTasks.values.forEach { $0.cancel() }
        observers.forEach(NotificationCenter.default.removeObserver)
        filters.values.forEach { $0.panel.close() }
    }
}

struct DailyControlsView: View {
    @ObservedObject var displayModel: DisplayModel
    @ObservedObject var manager: DailyControlManager
    @State private var favoriteName = ""
    @State private var showsBrightnessDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let display = displayModel.currentDisplay {
                nativeControls(display)
                Divider()
                filterControls(display)
            } else {
                Label("连接并选择显示器后可使用软件滤镜。", systemImage: "display")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Divider()
            favoritesSection
            if let error = manager.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else if let message = manager.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { manager.refreshSystemBrightness(displayID: displayModel.selectedDisplay) }
        .onChange(of: displayModel.selectedDisplay) { id in
            showsBrightnessDetails = false
            manager.refreshSystemBrightness(displayID: id)
        }
    }

    private func nativeControls(_ display: DisplayInfo) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(manager.nativeReading(for: display.id)?.backend.title ?? "显示器亮度").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("刷新") { manager.refreshSystemBrightness(displayID: display.id) }
                    .disabled(manager.isChangingSystemBrightness(displayID: display.id))
                Button("恢复调整前亮度") { manager.resetSystemBrightness(displayID: display.id) }
                    .disabled(!manager.canResetSystemBrightness(displayID: display.id) || displayModel.hasTrial || displayModel.isBusy || manager.isBlocked())
            }
            if let reading = manager.nativeReading(for: display.id) {
                sliderRow(reading.backend == .system ? "系统亮度" : "硬件亮度", value: Binding(
                    get: { (manager.systemBrightnessValue(for: display.id) ?? reading.value) * 100 },
                    set: { manager.setSystemBrightness($0 / 100, for: display.id, expectedIdentity: reading.identity) }), range: 0...100, symbol: "sun.max.fill")
                    .padding(16)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                    .disabled(displayModel.hasTrial || displayModel.isBusy || manager.isBlocked())
                Text("直接调节显示器亮度，退出应用后保留。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                DisclosureGroup(isExpanded: $showsBrightnessDetails) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("控制方式：" + reading.backend.title)
                        Text(String(format: "已确认亮度：%.0f%%", reading.value * 100)).monospacedDigit()
                        if let current = reading.rawCurrent, let maximum = reading.rawMaximum {
                            Text("显示器读回：" + String(current) + " / " + String(maximum)).monospacedDigit()
                        }
                        if reading.backend == .system {
                            Text("系统自动亮度仍可能调整实际数值。")
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                } label: { Text("亮度详情") }
                    .font(.caption).foregroundStyle(.secondary)
                if let failure = manager.brightnessError(for: display.id) {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(manager.nativeUnavailableReason(for: display.id) ?? "正在检测系统亮度与 DDC…")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("也可以使用下方的软件滤镜进一步调暗。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func filterControls(_ display: DisplayInfo) -> some View {
        let adjustment = manager.adjustment(for: display.id)
        let reason = manager.unavailableReason(for: display.id)
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("软件滤镜 · 进一步调暗").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("恢复原始画面") { manager.reset(displayID: display.id) }
                    .disabled(adjustment.isNeutral)
            }
            Text("调暗画面和添加暖色滤镜，不改变屏幕背光或系统色彩配置。")
                .font(.caption).foregroundStyle(.secondary)
            VStack(spacing: 16) {
                sliderRow("软件亮度", value: Binding(
                    get: { manager.adjustment(for: display.id).brightness * 100 },
                    set: { manager.setBrightness($0 / 100, for: display.id) }), range: 20...100,
                    symbol: "sun.max")
                sliderRow("暖色强度", value: Binding(
                    get: { manager.adjustment(for: display.id).warmth * 100 },
                    set: { manager.setWarmth($0 / 100, for: display.id) }), range: 0...100,
                    symbol: "sun.haze")
            }.padding(16)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                .disabled(reason != nil || displayModel.hasTrial || displayModel.isBusy || manager.isBlocked())
            if let reason {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            } else {
                Text("仅在应用运行期间生效；最低亮度保留 20%，暖色强度不代表校准色温。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, symbol: String) -> some View {
        HStack(spacing: 12) {
            Label(label, systemImage: symbol).font(.system(size: 12)).frame(width: 100, alignment: .leading)
            Slider(value: value, in: range, step: 1).accessibilityLabel(label)
            Text(String(format: "%.0f%%", value.wrappedValue)).font(.system(size: 12, weight: .medium))
                .monospacedDigit().frame(width: 42, alignment: .trailing)
        }
    }

    private var favoritesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("收藏分辨率").font(.system(size: 15, weight: .semibold))
                Text(String(manager.favorites.count) + " 项").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                TextField("收藏名称（可选）", text: $favoriteName).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("收藏名称")
                Button("收藏当前") {
                    if let display = displayModel.currentDisplay, let mode = display.current {
                        manager.saveFavorite(name: favoriteName, display: display, mode: mode)
                    }
                }.disabled(!canSaveFavorite || displayModel.currentDisplay?.current == nil)
                Button("收藏所选") {
                    if let display = displayModel.currentDisplay, let mode = displayModel.chosenMode {
                        manager.saveFavorite(name: favoriteName, display: display, mode: mode)
                    }
                }.disabled(!canSaveFavorite || displayModel.chosenMode == nil)
            }
            if manager.favorites.isEmpty {
                Text("把常用的尺寸和刷新率存为收藏，下次可直接试用。")
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(manager.favorites) { favorite in
                        favoriteRow(favorite)
                        if favorite.id != manager.favorites.last?.id { Divider().padding(.horizontal, 12) }
                    }
                }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            }
            Text("收藏跟随显示器身份保存；重新连接后会查找当前可用模式。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var canSaveFavorite: Bool {
        guard let display = displayModel.currentDisplay else { return false }
        return !display.isMirrored && !display.isStudioVirtual && !displayModel.hasTrial && !displayModel.isBusy && !manager.isBlocked()
    }

    private func favoriteRow(_ favorite: FavoriteResolution) -> some View {
        let connected = favorite.identity.resolve() != nil
        return HStack(spacing: 12) {
            Image(systemName: "star.fill").foregroundStyle(.yellow).font(.system(size: 13))
            VStack(alignment: .leading, spacing: 4) {
                Text(favorite.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(favorite.displayName + " · " + favorite.mode.label)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if !connected { Text("未连接").font(.caption).foregroundStyle(.secondary) }
            Button("试用") { manager.applyFavorite(id: favorite.id, displayModel: displayModel) }
                .disabled(!connected || displayModel.hasTrial || displayModel.isBusy || manager.isBlocked())
            Button { manager.removeFavorite(id: favorite.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help("移除此收藏").accessibilityLabel("移除收藏 " + favorite.name)
        }.padding(12)
    }
}
