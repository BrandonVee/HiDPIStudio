import AppKit
import ColorSync
import Combine

/// A single outstanding trial. Wall-clock deadlines survive delayed timer ticks.
final class ResolutionTrial {
    private var timer: Timer?
    private var deadline: Date?
    var onTick: ((Int) -> Void)?
    var onExpire: (() -> Void)?
    func start(seconds: TimeInterval = 15) {
        cancel()
        deadline = Date().addingTimeInterval(seconds)
        tick()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func tick() {
        guard let deadline else { return }
        let remaining = max(0, Int(ceil(deadline.timeIntervalSinceNow)))
        onTick?(remaining)
        if remaining == 0 {
            cancel()
            onExpire?()
        }
    }
    func cancel() {
        timer?.invalidate()
        timer = nil
        deadline = nil
    }
    deinit { timer?.invalidate() }
}

final class DisplayModel: ObservableObject {
    @Published var activeSection: StudioSection = .resolution
    var externalOperationBlocked: () -> Bool = { false }
    @Published var displays: [DisplayInfo] = []
    @Published var selectedDisplay: CGDirectDisplayID = 0
    @Published var selectedMode: Int32?
    @Published var showLowResolution = false
    @Published var customWidth = "2560"
    @Published var customHeight = "1440"
    @Published var customRefreshRate = "60"
    @Published var remaining = 0
    @Published var isBusy = false
    @Published var error: String?
    @Published var message = "选择显示器，使用 HiDPI 模式改善文字显示。"
    @Published var virtualTarget: CGDirectDisplayID?
    @Published var virtualSize: CustomSize?
    @Published private(set) var displayAliases: [String: String] = [:]
    private var virtual: HDVirtualDisplay?
    private var virtualSnapshot: DisplaySnapshot?
    private struct NativeTrial {
        let display: CGDirectDisplayID
        let before: DisplaySnapshot
        let requested: DisplayMode
    }
    private var pendingNative: NativeTrial?
    private var nativeValidationTask: Task<Void, Never>?
    private var originals: [CGDirectDisplayID: DisplaySnapshot] = [:]
    private var savedDisplayIDs = Set<CGDirectDisplayID>()
    private let nativeSaveScope: CGConfigureOption
    private var isShuttingDown = false
    private let trial = ResolutionTrial()
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var refreshWork: DispatchWorkItem?
    private var operationGeneration = 0
    private var displayNames: [CGDirectDisplayID: String] = [:]
    private let defaults: UserDefaults
    private let displayAliasesKey = "HiDPIStudio.displayAliases.v1"

    var currentDisplay: DisplayInfo? { displays.first { $0.id == selectedDisplay } }
    func display(for id: CGDirectDisplayID) -> DisplayInfo? { displays.first { $0.id == id } }
    var hasTrial: Bool { remaining > 0 }
    var hasPendingConfiguration: Bool { pendingNative != nil || virtualSnapshot != nil }
    var virtualSourceID: CGDirectDisplayID? { virtual?.displayID }
    var hasChanges: Bool { virtual != nil || !originals.isEmpty }
    var visibleModes: [DisplayMode] { currentDisplay?.modes.filter { showLowResolution || $0.isHiDPI } ?? [] }
    var chosenMode: DisplayMode? { visibleModes.first { $0.id == selectedMode } }
    var modeGroups: [ModeGroup] { ModeGroup.group(visibleModes) }
    var selectedGroupID: String? { modeGroups.first { $0.modes.contains { $0.id == selectedMode } }?.id }
    func rowMode(_ group: ModeGroup) -> DisplayMode {
        group.preferred(
            selectedID: selectedMode, current: currentDisplay?.current,
            preferredRate: chosenMode?.refreshRate ?? currentDisplay?.current?.refreshRate)
    }
    var canApply: Bool {
        guard let display = currentDisplay, let mode = chosenMode else { return false }
        return !externalOperationBlocked() && !isShuttingDown && !isBusy && !hasTrial && pendingNative == nil
            && virtual == nil && virtualSnapshot == nil && !display.isMirrored
            && mode.signature != display.current?.signature
    }
    var customAvailable: Bool {
        !externalOperationBlocked() && currentDisplay.map { !$0.isBuiltin && !$0.isMirrored } == true
            && HDVirtualDisplay.isAvailable() && virtual == nil && virtualSnapshot == nil && pendingNative == nil
            && !hasTrial && !isBusy && !isShuttingDown
    }
    var virtualCurrentMode: DisplayMode? {
        guard let virtual else { return nil }
        return CGDisplayCopyDisplayMode(virtual.displayID).map(DisplayMode.init)
    }
    func renderedMode(for display: DisplayInfo) -> DisplayMode? {
        if display.id == virtualTarget { return virtualCurrentMode }
        return display.current
    }

    init(nativeSaveScope: CGConfigureOption = .permanently, defaults: UserDefaults = .standard) {
        self.nativeSaveScope = nativeSaveScope
        self.defaults = defaults
        if let data = defaults.data(forKey: displayAliasesKey),
            let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        {
            displayAliases = decoded.reduce(into: [:]) { result, pair in
                let name = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { result[pair.key] = String(name.prefix(64)) }
            }
        }
        trial.onTick = { [weak self] in self?.remaining = $0 }
        trial.onExpire = { [weak self] in Task { @MainActor in await self?.revertTrial() } }
        refresh()
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in
                self?.refreshWork?.cancel()
                let work = DispatchWorkItem { [weak self] in self?.screenChanged() }
                self?.refreshWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
            })
        workspaceObservers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if self.hasTrial { await self.revertTrial() }
                    if self.virtual != nil { await self.stopVirtual() }
                }
            })
    }

    func refresh() {
        let all = DisplayCore.displays()
        displays = all.filter { !$0.isStudioVirtual }.map { display in
            if !display.name.hasPrefix("外接显示器 ") { displayNames[display.id] = display.name }
            let baseName = displayNames[display.id] ?? display.name
            let alias = DisplayIdentity.capture(display.id).flatMap { displayAliases[$0.uuid] }
            return DisplayInfo(
                id: display.id, name: alias ?? baseName, isBuiltin: display.isBuiltin,
                isStudioVirtual: display.isStudioVirtual, current: display.current, modes: display.modes)
        }
        if !displays.contains(where: { $0.id == selectedDisplay }) {
            selectedDisplay = displays.first?.id ?? 0
        }
        if !visibleModes.contains(where: { $0.id == selectedMode }) { selectPreferredMode() }
    }
    func alias(for displayID: CGDirectDisplayID) -> String? {
        guard let identity = DisplayIdentity.capture(displayID) else { return nil }
        return displayAliases[identity.uuid]
    }
    func setAlias(_ value: String, for displayID: CGDirectDisplayID) {
        guard let identity = DisplayIdentity.capture(displayID) else { return }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            displayAliases[identity.uuid] = nil
        } else {
            displayAliases[identity.uuid] = String(trimmed.prefix(64))
        }
        do {
            let data = try JSONEncoder().encode(displayAliases)
            defaults.set(data, forKey: displayAliasesKey)
            error = nil
            refresh()
            message = trimmed.isEmpty ? "已恢复系统显示器名称。" : "已保存显示器名称“\(String(trimmed.prefix(64)))”。"
        } catch {
            self.error = "显示器名称保存失败：\(error.localizedDescription)"
        }
    }
    private func screenChanged() {
        guard !isBusy else { return }
        if let target = virtualTarget, !DisplayCore.onlineIDs().contains(target) {
            Task { @MainActor in
                await stopVirtual()
                message = "外接屏已断开，临时虚拟屏幕已移除。"
            }
        } else {
            refresh()
        }
    }
    func selectPreferredMode() {
        let preferred = visibleModes.first { $0.width == 2560 && $0.height == 1440 && $0.isHiDPI }
        let current = visibleModes.first { $0.signature == currentDisplay?.current?.signature }
        selectedMode = (current ?? preferred ?? visibleModes.first)?.id
    }
    func choosePreset(width: Int, height: Int) {
        customWidth = String(width)
        customHeight = String(height)
        if let group = modeGroups.first(where: {
            $0.representative.width == width && $0.representative.height == height && $0.representative.isHiDPI
        }) {
            let mode = rowMode(group)
            selectedMode = mode.id
            message = "系统提供 \(width) × \(height) HiDPI，可直接试用。"
        } else {
            message = "系统未提供此 HiDPI 尺寸，可使用下方的自定义 HiDPI。"
        }
    }
    func applyNative() {
        guard canApply, let display = currentDisplay, let mode = chosenMode else { return }
        applyNative(display: display, mode: mode)
    }
    func applyNative(displayID: CGDirectDisplayID, mode: DisplayMode) {
        guard let display = display(for: displayID), canApply(display: display, mode: mode) else { return }
        applyNative(display: display, mode: mode)
    }
    private func canApply(display: DisplayInfo, mode: DisplayMode) -> Bool {
        guard display.modes.contains(where: { $0.id == mode.id }) else { return false }
        return !externalOperationBlocked() && !isShuttingDown && !isBusy && !hasTrial && pendingNative == nil
            && virtual == nil && virtualSnapshot == nil && !display.isMirrored
            && mode.signature != display.current?.signature
    }
    private func applyNative(display: DisplayInfo, mode: DisplayMode) {
        let snapshot = DisplaySnapshot(ids: [display.id])
        guard !snapshot.entries.isEmpty else {
            error = "无法保存当前显示设置，已取消切换。"
            return
        }
        if originals[display.id]?.containsCurrentDisplay(display.id) != true {
            originals[display.id] = snapshot
            savedDisplayIDs.remove(display.id)
        }
        pendingNative = NativeTrial(display: display.id, before: snapshot, requested: mode)
        error = nil
        trial.start()
        do {
            try DisplayCore.setMode(display.id, mode)
            if mode.isHiddenNative {
                isBusy = true
                nativeValidationTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        var matched = false
                        for _ in 0..<20 {
                            try Task.checkCancellation()
                            if let current = CGDisplayCopyDisplayMode(display.id),
                                current.ioDisplayModeID == mode.id,
                                DisplayMode(raw: current).signature == mode.signature
                            {
                                matched = true
                                break
                            }
                            try await Task.sleep(nanoseconds: 100_000_000)
                        }
                        try Task.checkCancellation()
                        guard matched else { throw DisplayFailure(message: "系统未采用请求的原生 HiDPI 模式，已请求恢复。") }
                        self.isBusy = false
                        self.nativeValidationTask = nil
                        self.message = "正在试用原生 \(mode.sizeLabel) HiDPI · \(mode.rateLabel)。"
                        self.refresh()
                    } catch is CancellationError { return } catch {
                        self.isBusy = false
                        self.nativeValidationTask = nil
                        self.error = error.localizedDescription
                        await self.revertTrial()
                    }
                }
                return
            }
            try DisplayCore.verify(
                display.id, width: mode.width, height: mode.height, hiDPI: mode.isHiDPI,
                refreshRate: mode.refreshRate > 0 ? mode.refreshRate : nil)
            message = "正在试用 \(mode.sizeLabel) · \(mode.rateLabel) · \(mode.isHiDPI ? "HiDPI" : "低分辨率")。"
            refresh()
        } catch {
            self.error = error.localizedDescription
            Task { @MainActor in await revertTrial() }
        }
    }
    func confirmTrial() {
        guard hasTrial, !isBusy, !isShuttingDown, !externalOperationBlocked() else { return }
        if let pending = pendingNative {
            do {
                if nativeSaveScope == .permanently && DisplayCore.displays().contains(where: \.isStudioVirtual) {
                    throw DisplayFailure(message: "系统仍存在临时虚拟屏幕，请先断开后再保存原生模式。")
                }
                guard virtual == nil, virtualSnapshot == nil,
                    DisplayCore.onlineIDs().contains(pending.display),
                    pending.before.containsCurrentDisplay(pending.display),
                    CGDisplayIsInMirrorSet(pending.display) == 0,
                    let current = CGDisplayCopyDisplayMode(pending.display),
                    DisplayMode(raw: current).signature == pending.requested.signature
                else {
                    throw DisplayFailure(message: "显示器或模式已变化，请恢复后重新试用。")
                }
                try DisplayCore.setMode(pending.display, current, scope: nativeSaveScope)
                savedDisplayIDs.insert(pending.display)
                trial.cancel()
                remaining = 0
                pendingNative = nil
                message = "已保存到系统。退出 HiDPI Studio 后，此 HiDPI 模式仍然生效。"
            } catch {
                // Keep both the timer and snapshot if saving failed.
                self.error = "保存失败：\(error.localizedDescription) 未确认的试用仍会自动恢复。"
            }
        } else if virtual != nil {
            trial.cancel()
            remaining = 0
            message = "已保留虚拟 HiDPI。此模式需应用保持运行；关闭窗口可继续使用。"
        }
    }
    func revertTrial() async {
        nativeValidationTask?.cancel()
        nativeValidationTask = nil
        if pendingNative != nil { isBusy = false }
        trial.cancel()
        remaining = 0
        if virtual != nil {
            await stopVirtual()
        } else if let pending = pendingNative {
            do {
                try pending.before.restoreModesOnly()
                pendingNative = nil
                message = "已恢复试用前的显示设置。"
            } catch { self.error = "恢复失败：\(error.localizedDescription) 可退出应用，让 macOS 撤销临时配置。" }
            refresh()
        }
    }

    func startVirtual() async {
        guard customAvailable, let display = currentDisplay else { return }
        error = nil
        guard let width = Int(customWidth), let height = Int(customHeight) else {
            error = "请输入整数形式的桌面宽度和高度。"
            return
        }
        let size: CustomSize
        do { size = try CustomSize(width: width, height: height) } catch {
            self.error = error.localizedDescription
            return
        }
        guard let requestedRate = Double(customRefreshRate.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            error = "请输入有效刷新率，例如 60、120 或 144 Hz。"
            return
        }
        let refreshRate: Double
        do { refreshRate = try CustomRefreshRate(value: requestedRate).value } catch {
            self.error = error.localizedDescription
            return
        }
        if let mode = display.modes.first(where: {
            $0.width == width && $0.height == height && $0.isHiDPI
                && CustomRefreshRate.matches($0.refreshRate, refreshRate)
        }) {
            selectedMode = mode.id
            applyNative()
            if !hasTrial && error == nil { message = "此显示器已经在使用 \(mode.sizeLabel) HiDPI · \(mode.rateLabel)。" }
            return
        }
        // Refuse stretching/letterboxing silently. The user can choose matching dimensions.
        if let mode = display.current,
            !CustomSize.matchesAspect(width: width, height: height, targetWidth: mode.width, targetHeight: mode.height)
        {
            error = "所选尺寸与当前屏幕比例不一致。请按 \(mode.sizeLabel) 的宽高比例输入，避免黑边或拉伸。"
            return
        }
        isBusy = true
        operationGeneration += 1
        let generation = operationGeneration
        defer {
            if generation == operationGeneration {
                isBusy = false
                refresh()
            }
        }
        virtualSnapshot = DisplaySnapshot(ids: DisplayCore.onlineIDs())
        do {
            virtual = try HDVirtualDisplay(
                width: UInt32(width), height: UInt32(height), refreshRate: refreshRate,
                name: "HiDPI Studio · \(width) × \(height)")
            guard let virtual, virtual.displayID != 0 else { throw DisplayFailure(message: "虚拟屏幕创建失败。") }
            virtualTarget = display.id
            virtualSize = size
            let mode = try await DisplayCore.waitForHiDPI(virtual.displayID, size: size, refreshRate: refreshRate)
            guard generation == operationGeneration else { return }
            guard DisplayCore.onlineIDs().contains(display.id) else { throw DisplayFailure(message: "外接屏已断开。") }
            trial.start()
            try DisplayCore.mirror(target: display.id, source: virtual.displayID, sourceMode: mode)
            try await Task.sleep(nanoseconds: 300_000_000)
            guard generation == operationGeneration else { return }
            try DisplayCore.verify(
                virtual.displayID, width: width, height: height, hiDPI: true, refreshRate: refreshRate)
            guard CGDisplayMirrorsDisplay(display.id) == virtual.displayID else {
                throw DisplayFailure(message: "macOS 未将外接屏设为虚拟屏幕的镜像，已请求恢复。")
            }
            let actual = CGDisplayCopyDisplayMode(virtual.displayID).map(DisplayMode.init)
            message = "虚拟桌面已启用 \(width * 2) × \(height * 2) 渲染 · \(actual?.rateLabel ?? "未报告刷新率")。"
        } catch {
            guard generation == operationGeneration else { return }
            self.error = error.localizedDescription
            await stopVirtual()
        }
    }

    func stopVirtual() async {
        operationGeneration += 1
        trial.cancel()
        remaining = 0
        isBusy = true
        virtual?.disconnect()
        virtual = nil
        virtualTarget = nil
        virtualSize = nil
        // WindowServer removes the virtual display asynchronously.
        try? await Task.sleep(nanoseconds: 350_000_000)
        do {
            try virtualSnapshot?.restore()
            virtualSnapshot = nil
            message = "已停止自定义 HiDPI，并恢复显示配置。"
        } catch { self.error = "恢复失败：\(error.localizedDescription) 退出应用可撤销临时配置。" }
        isBusy = false
        refresh()
    }
    func restoreAll() async {
        guard !externalOperationBlocked() else {
            error = "请先结束其他显示设置试用或断开独立虚拟屏幕，再恢复原设置。"
            return
        }
        trial.cancel()
        remaining = 0
        // Saved-scope transactions commit the global layout. Remove an outstanding
        // trial before restoring another display, including from the menu bar.
        if pendingNative != nil { await revertTrial() }
        guard pendingNative == nil else { return }
        if virtual != nil || virtualSnapshot != nil { await stopVirtual() }
        guard virtualSnapshot == nil else { return }
        for (id, snapshot) in Array(originals) {
            do {
                try snapshot.restoreModesOnly(scope: savedDisplayIDs.contains(id) ? nativeSaveScope : .forAppOnly)
                originals[id] = nil
                savedDisplayIDs.remove(id)
                if pendingNative?.display == id { pendingNative = nil }
            } catch { self.error = error.localizedDescription }
        }
        message = originals.isEmpty ? "已恢复原显示配置。" : "部分显示配置未恢复，请退出应用后检查。"
        refresh()
    }
    func shutdown() async {
        nativeValidationTask?.cancel()
        nativeValidationTask = nil
        if pendingNative != nil { isBusy = false }
        isShuttingDown = true
        trial.cancel()
        remaining = 0
        // A timer expiry can be queued with remaining == 0: inspect pending state.
        if pendingNative != nil { await revertTrial() }
        if virtual != nil || virtualSnapshot != nil { await stopVirtual() }
        // Confirmed native settings belong to macOS and survive this process.
    }
    func diagnostics() -> String {
        let items: [[String: Any]] = DisplayCore.displays().map { display in
            let physicalSize = CGDisplayScreenSize(display.id)
            let identity = DisplayIdentity.capture(display.id)
            var item: [String: Any] = [
                "id": display.id, "name": display.name, "builtIn": display.isBuiltin,
                "displayUUID": identity?.uuid ?? "",
                "vendor": CGDisplayVendorNumber(display.id),
                "product": CGDisplayModelNumber(display.id),
                "serial": CGDisplaySerialNumber(display.id),
                "isMain": CGDisplayIsMain(display.id) != 0,
                "rotation": CGDisplayRotation(display.id),
                "physicalWidthMM": physicalSize.width,
                "physicalHeightMM": physicalSize.height,
                "mirrorSource": CGDisplayMirrorsDisplay(display.id),
                "current": display.current.map { modeJSON($0) } ?? [:],
                "modes": display.modes.map(modeJSON),
            ]
            if let profile = ColorSyncProfileCreateWithDisplayID(display.id)?.takeRetainedValue() {
                let md5 = ColorSyncProfileGetMD5(profile)
                let digest = withUnsafeBytes(of: md5.digest) { Data($0) }
                    .map { String(format: "%02x", $0) }
                    .joined()
                item["colorProfileName"] = (ColorSyncProfileCopyDescriptionString(profile)?.takeRetainedValue() as String?) ?? ""
                item["colorProfileWideGamut"] = ColorSyncProfileIsWideGamut(profile)
                item["colorProfilePQ"] = ColorSyncProfileIsPQBased(profile)
                item["colorProfileHLG"] = ColorSyncProfileIsHLGBased(profile)
                item["colorProfileMD5"] = digest
            }
            return item
        }
        let document: [String: Any] = [
            "app": "HiDPI Studio "
                + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"),
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "virtualAPIAvailable": HDVirtualDisplay.isAvailable(), "displays": items,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }
    private func modeJSON(_ mode: DisplayMode) -> [String: Any] {
        [
            "id": mode.id, "width": mode.width, "height": mode.height, "pixelWidth": mode.pixelWidth,
            "pixelHeight": mode.pixelHeight, "hiDPI": mode.isHiDPI, "refreshRate": mode.refreshRate,
        ]
    }
    func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "HiDPI-diagnostics.json"
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            do { try diagnostics().write(to: url, atomically: true, encoding: .utf8) } catch {
                self.error = error.localizedDescription
            }
        }
    }
    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        refreshWork?.cancel()
    }
}
