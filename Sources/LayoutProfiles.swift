import AppKit
import SwiftUI
import Combine

struct SavedLayoutEntry: Codable, Hashable {
    let identity: DisplayIdentity
    let name: String
    let mode: SavedDisplayMode
    let x: Int32
    let y: Int32
    let isMain: Bool
    let rotation: Double
}

struct SavedLayoutProfile: Codable, Identifiable {
    let id: UUID
    var name: String
    let entries: [SavedLayoutEntry]
    let createdAt: Date
}

struct LayoutScreen: Identifiable {
    let id: CGDirectDisplayID
    let identity: DisplayIdentity
    let name: String
    let bounds: CGRect
    let mode: DisplayMode
    let isMain: Bool
    let isMirrored: Bool
    let isBuiltin: Bool
}

enum LayoutDirection: String, CaseIterable, Identifiable {
    case left, right, above, below
    var id: String { rawValue }
    var label: String {
        switch self {
        case .left: return "左侧"
        case .right: return "右侧"
        case .above: return "上方"
        case .below: return "下方"
        }
    }
}

/// Pure geometry shared by arrangement and its focused regression checks.
enum LayoutGeometry {
    static func place(target: CGDirectDisplayID, relativeTo anchor: CGDirectDisplayID,
                      direction: LayoutDirection, frames: [CGDirectDisplayID: CGRect],
                      main: CGDirectDisplayID) throws -> [CGDirectDisplayID: CGPoint] {
        guard target != anchor, let targetFrame = frames[target], let anchorFrame = frames[anchor], frames[main] != nil else {
            throw DisplayFailure(message: "请选择两块不同的已连接显示器。")
        }
        var origin: CGPoint
        switch direction {
        case .left: origin = CGPoint(x: anchorFrame.minX - targetFrame.width, y: anchorFrame.minY)
        case .right: origin = CGPoint(x: anchorFrame.maxX, y: anchorFrame.minY)
        case .above: origin = CGPoint(x: anchorFrame.minX, y: anchorFrame.minY - targetFrame.height)
        case .below: origin = CGPoint(x: anchorFrame.minX, y: anchorFrame.maxY)
        }
        origin.x = origin.x.rounded(); origin.y = origin.y.rounded()
        var proposed = frames
        proposed[target] = CGRect(origin: origin, size: targetFrame.size)
        for (other, rect) in frames where other != target {
            let overlap = proposed[target]!.intersection(rect)
            guard overlap.isNull || overlap.width <= 0 || overlap.height <= 0 else {
                throw DisplayFailure(message: "该位置会与另一块显示器重叠。请先调整其他显示器的位置。")
            }
        }
        // Global coordinate (0,0) belongs to the main screen. If it is the screen
        // being moved, translate every origin together to preserve relationships.
        let translation = proposed[main]!.origin
        return proposed.mapValues { CGPoint(x: $0.minX - translation.x, y: $0.minY - translation.y) }
    }

    static func validate(_ entries: [SavedLayoutEntry]) throws {
        guard !entries.isEmpty, entries.count <= 32,
              Set(entries.map(\.identity)).count == entries.count,
              entries.filter(\.isMain).count == 1 else {
            throw DisplayFailure(message: "配置预设无效：显示器身份重复、缺失或主屏设置不完整。")
        }
        guard entries.allSatisfy({ entry in
            entry.rotation.isFinite && abs(Int64(entry.x)) <= 1_000_000 && abs(Int64(entry.y)) <= 1_000_000 &&
            entry.mode.width > 0 && entry.mode.height > 0 && entry.mode.pixelWidth > 0 && entry.mode.pixelHeight > 0 &&
            entry.mode.refreshRate.isFinite && entry.mode.refreshRate >= 0
        }) else { throw DisplayFailure(message: "配置预设包含无效的尺寸、坐标或刷新率。") }
        guard entries.first(where: \.isMain).map({ $0.x == 0 && $0.y == 0 }) == true else {
            throw DisplayFailure(message: "配置预设的主屏坐标必须为 0, 0。")
        }
    }

    static func sameConfiguration(_ a: [SavedLayoutEntry], _ b: [SavedLayoutEntry]) -> Bool {
        guard a.count == b.count else { return false }
        return a.allSatisfy { lhs in
            b.contains { rhs in
                lhs.identity == rhs.identity && lhs.x == rhs.x && lhs.y == rhs.y && lhs.isMain == rhs.isMain &&
                abs(lhs.rotation - rhs.rotation) < 0.01 && lhs.mode.width == rhs.mode.width && lhs.mode.height == rhs.mode.height &&
                lhs.mode.pixelWidth == rhs.mode.pixelWidth && lhs.mode.pixelHeight == rhs.mode.pixelHeight &&
                ((lhs.mode.refreshRate == 0 && rhs.mode.refreshRate == 0) || CustomRefreshRate.matches(lhs.mode.refreshRate, rhs.mode.refreshRate))
            }
        }
    }
}

final class LayoutProfileManager: ObservableObject {
    @Published private(set) var screens: [LayoutScreen] = []
    @Published private(set) var profiles: [SavedLayoutProfile] = []
    @Published private(set) var remaining = 0
    @Published private(set) var isBusy = false
    @Published var error: String?
    @Published var message = "排列显示器，或保存当前桌面配置以便再次使用。"
    @Published var targetDisplay: CGDirectDisplayID = 0
    @Published var anchorDisplay: CGDirectDisplayID = 0
    @Published var direction: LayoutDirection = .right
    @Published var profileName = ""
    /// Root coordinates this with native trials and virtual-screen creation.
    var isBlocked: () -> Bool = { false }
    private let defaults: UserDefaults
    private let persistenceScope: CGConfigureOption
    private let storageKey = "layoutProfiles.v1"
    private let trial = ResolutionTrial()
    private var observer: NSObjectProtocol?
    private var refreshWork: DispatchWorkItem?
    private var isShuttingDown = false
    private struct Pending {
        let id = UUID()
        let before: [SavedLayoutEntry]
        let applied: [SavedLayoutEntry]
        var restoreScope: CGConfigureOption = .forAppOnly
    }
    @Published private var pending: Pending?
    var isPending: Bool { pending != nil }
    var hasTrial: Bool { isPending }
    var canModify: Bool { !isBusy && !isPending && !isShuttingDown && !isBlocked() }
    @Published private(set) var hasVirtualScreen = false
    var canArrange: Bool { canModify && screens.count >= 2 && !screens.contains(where: \.isMirrored) && !hasVirtualScreen }
    var canSave: Bool { canModify && !screens.isEmpty && !screens.contains(where: \.isMirrored) && !hasVirtualScreen }

    init(defaults: UserDefaults = .standard, persistenceScope: CGConfigureOption = .permanently) {
        self.defaults = defaults
        self.persistenceScope = persistenceScope
        if let data = defaults.data(forKey: storageKey) {
            do {
                let decoded = try JSONDecoder().decode([SavedLayoutProfile].self, from: data)
                guard decoded.count <= 100, Set(decoded.map(\.id)).count == decoded.count else { throw DisplayFailure(message: "预设数量或标识异常。") }
                for profile in decoded { try LayoutGeometry.validate(profile.entries) }
                profiles = decoded
            } catch { self.error = "已保存的布局预设无法读取：\(error.localizedDescription)" }
        }
        trial.onTick = { [weak self] in self?.remaining = $0 }
        trial.onExpire = { [weak self] in self?.revertTrial() }
        refreshScreens()
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.refreshScreens() }
            self?.refreshWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }
    }

    func refreshScreens() {
        let allDisplays = DisplayCore.displays()
        hasVirtualScreen = allDisplays.contains(where: \.isStudioVirtual)
        screens = allDisplays.filter { !$0.isStudioVirtual }.compactMap { display in
            guard let identity = DisplayIdentity.capture(display.id), let mode = display.current else { return nil }
            return LayoutScreen(id: display.id, identity: identity, name: display.name, bounds: CGDisplayBounds(display.id),
                                mode: mode, isMain: CGDisplayIsMain(display.id) != 0, isMirrored: display.isMirrored, isBuiltin: display.isBuiltin)
        }
        if !screens.contains(where: { $0.id == targetDisplay }) { targetDisplay = screens.first(where: { !$0.isBuiltin })?.id ?? screens.first?.id ?? 0 }
        if !screens.contains(where: { $0.id == anchorDisplay && $0.id != targetDisplay }) {
            anchorDisplay = screens.first(where: { $0.id != targetDisplay })?.id ?? 0
        }
        if let pending, !isBusy {
            let expected = Set(pending.applied.map(\.identity))
            let actual = Set(screens.map(\.identity))
            if expected != actual || hasVirtualScreen || screens.contains(where: \.isMirrored) {
                error = "显示器连接或镜像关系已变化，正在撤销尚未确认的布局。"
                revertTrial()
            }
        }
    }

    func arrange() {
        guard canArrange else { error = modificationBlockReason; return }
        do {
            let before = try capture()
            let frames = Dictionary(uniqueKeysWithValues: screens.map { ($0.id, $0.bounds) })
            let origins = try LayoutGeometry.place(target: targetDisplay, relativeTo: anchorDisplay, direction: direction, frames: frames, main: CGMainDisplayID())
            let requested = try before.map { entry -> SavedLayoutEntry in
                guard let id = entry.identity.resolve(), let point = origins[id] else {
                    throw DisplayFailure(message: "显示器连接已变化，请刷新后重试。")
                }
                return SavedLayoutEntry(identity: entry.identity, name: entry.name, mode: entry.mode,
                                        x: Int32(point.x), y: Int32(point.y), isMain: entry.isMain, rotation: entry.rotation)
            }
            try begin(requested, before: before, description: "正在试用新的显示器位置。")
        } catch { self.error = error.localizedDescription }
    }

    func makeMain(_ id: CGDirectDisplayID) {
        guard canArrange, let target = screens.first(where: { $0.id == id }) else { error = modificationBlockReason; return }
        guard !target.isMain else { message = "该显示器已是主屏。"; return }
        do {
            let before = try capture()
            let requested = before.map { entry in
                SavedLayoutEntry(identity: entry.identity, name: entry.name, mode: entry.mode,
                                 x: entry.x - Int32(target.bounds.minX), y: entry.y - Int32(target.bounds.minY),
                                 isMain: entry.identity == target.identity, rotation: entry.rotation)
            }
            try begin(requested, before: before, description: "正在试用新的主显示器。")
        } catch { self.error = error.localizedDescription }
    }

    func saveCurrentProfile() {
        guard canSave else { error = modificationBlockReason; return }
        let name = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 60 else { error = "请填写 1–60 个字符的预设名称。"; return }
        guard profiles.count < 100 else { error = "最多保存 100 个布局预设，请先删除不用的预设。"; return }
        do {
            let entries = try capture()
            try LayoutGeometry.validate(entries)
            var updated = profiles
            updated.append(SavedLayoutProfile(id: UUID(), name: name, entries: entries, createdAt: Date()))
            try persist(updated)
            profileName = ""; error = nil; message = "已保存“\(name)”的显示器、分辨率、刷新率与位置。"
        } catch { self.error = error.localizedDescription }
    }

    func deleteProfile(id: UUID) {
        guard !isPending, !isBusy else { return }
        do { try persist(profiles.filter { $0.id != id }); error = nil }
        catch { self.error = error.localizedDescription }
    }

    func unavailableReason(for profile: SavedLayoutProfile) -> String? {
        if isPending || isBusy || isBlocked() { return "请先完成当前显示设置操作。" }
        if hasVirtualScreen { return "请先断开临时虚拟屏幕再应用布局预设。" }
        if screens.contains(where: \.isMirrored) { return "请先在系统设置中结束镜像。" }
        if Set(screens.map(\.identity)) != Set(profile.entries.map(\.identity)) { return "当前连接的显示器组合与预设不同。" }
        for entry in profile.entries {
            guard let id = entry.identity.resolve(), entry.mode.resolve(on: id) != nil else { return "显示器缺少预设所需的分辨率或刷新率。" }
            if abs(CGDisplayRotation(id) - entry.rotation) > 0.01 { return "屏幕旋转方向与预设不同，请先在系统设置中调整。" }
        }
        return nil
    }

    func applyProfile(id: UUID) {
        guard let profile = profiles.first(where: { $0.id == id }) else { error = "找不到此布局预设。"; return }
        guard canModify else { error = modificationBlockReason; return }
        refreshScreens()
        if let reason = unavailableReason(for: profile) { error = reason; return }
        do { try begin(profile.entries, before: capture(), description: "正在试用“\(profile.name)”。") }
        catch { self.error = error.localizedDescription }
    }

    func confirmTrial() {
        guard let pending, !isBusy, !isShuttingDown, !isBlocked() else { return }
        isBusy = true
        defer { isBusy = false; refreshScreens() }
        do {
            let current = try capture()
            guard LayoutGeometry.sameConfiguration(current, pending.applied) else {
                throw DisplayFailure(message: "试用期间显示配置发生变化，未保存。请恢复后重试。")
            }
            try apply(pending.applied, scope: persistenceScope, requireExactTopology: true)
            self.pending?.restoreScope = persistenceScope
            let saved = try capture()
            guard LayoutGeometry.sameConfiguration(saved, pending.applied) else {
                throw DisplayFailure(message: "系统在保存时再次调整了布局，正在恢复试用前设置。")
            }
            trial.cancel(); remaining = 0; self.pending = nil; error = nil
            message = "已保存当前布局到系统，退出应用后继续生效。"
        } catch {
            self.error = error.localizedDescription
            if let currentPending = self.pending, currentPending.restoreScope != .forAppOnly {
                isBusy = false
                revertTrial()
            }
        }
    }

    func revertTrial() {
        guard let pending, !isBusy else { return }
        trial.cancel(); remaining = 0; isBusy = true
        defer { isBusy = false; refreshScreensWithoutRollback() }
        do {
            try apply(pending.before, scope: pending.restoreScope, requireExactTopology: false)
            self.pending = nil
            let restoredAll = pending.before.allSatisfy { $0.identity.resolve() != nil }
            message = restoredAll ? "已恢复试用前的布局与显示模式。" : "已恢复仍连接的显示器；断开的显示器未作更改。"
        } catch {
            self.error = "布局恢复失败：\(error.localizedDescription) 可重试恢复；退出应用会撤销尚未保存的临时配置。"
        }
    }

    func shutdown() async {
        isShuttingDown = true
        trial.cancel(); remaining = 0
        if isPending { revertTrial() }
    }

    /// Called only after explicit automatic-restore opt-in for a saved profile.
    /// Session scope survives app exit without changing the permanent baseline.
    @MainActor @discardableResult func restoreProfileAutomatically(id: UUID) async throws -> Bool {
        try Task.checkCancellation()
        guard canModify else { throw DisplayFailure(message: modificationBlockReason) }
        refreshScreens()
        guard let profile = profiles.first(where: { $0.id == id }) else { throw DisplayFailure(message: "自动恢复所选的预设已被删除。") }
        if let reason = unavailableReason(for: profile) { throw DisplayFailure(message: reason) }
        let before = try capture()
        if LayoutGeometry.sameConfiguration(before, profile.entries) { return false }
        isBusy = true
        defer { isBusy = false; refreshScreens() }
        do {
            try apply(profile.entries, scope: .forSession, requireExactTopology: true)
            var matched = false
            for _ in 0..<20 {
                try Task.checkCancellation()
                if let actual = try? capture(), LayoutGeometry.sameConfiguration(actual, profile.entries) {
                    matched = true; break
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard matched else {
                throw DisplayFailure(message: "系统未按预设恢复，已请求恢复操作前配置。")
            }
            error = nil; message = "已自动恢复“\(profile.name)”。"
            return true
        } catch {
            let cause = error
            do { try apply(before, scope: .forSession, requireExactTopology: false) }
            catch {
                pending = Pending(before: before, applied: (try? capture()) ?? before, restoreScope: .forSession)
                remaining = 0
                self.error = "自动恢复及回退未完成，请点击恢复重试：\(error.localizedDescription)"
            }
            throw cause
        }
    }

    private var modificationBlockReason: String {
        if isPending { return "请先保留或恢复当前布局试用。" }
        if isBusy || isBlocked() { return "请先完成其他显示设置操作。" }
        if hasVirtualScreen { return "布局保存前请先断开临时虚拟屏幕。" }
        if screens.contains(where: \.isMirrored) { return "请先在系统设置中结束镜像，再调整布局。" }
        return "请连接至少两块显示器以调整相对位置。"
    }

    private func capture() throws -> [SavedLayoutEntry] {
        let displays = DisplayCore.displays()
        guard !displays.isEmpty, !displays.contains(where: { $0.isStudioVirtual || $0.isMirrored }) else {
            throw DisplayFailure(message: "当前包含镜像组或临时虚拟屏幕，无法保存独立显示器布局。")
        }
        return try displays.map { display in
            guard let identity = DisplayIdentity.capture(display.id), let mode = display.current else {
                throw DisplayFailure(message: "无法读取显示器身份或显示模式。")
            }
            let bounds = CGDisplayBounds(display.id)
            guard bounds.origin.x.isFinite, bounds.origin.y.isFinite,
                  abs(bounds.origin.x) <= 1_000_000, abs(bounds.origin.y) <= 1_000_000 else {
                throw DisplayFailure(message: "显示器坐标超出支持范围。")
            }
            return SavedLayoutEntry(identity: identity, name: display.name, mode: SavedDisplayMode(mode),
                                    x: Int32(bounds.minX), y: Int32(bounds.minY), isMain: CGDisplayIsMain(display.id) != 0,
                                    rotation: CGDisplayRotation(display.id))
        }
    }

    private func begin(_ requested: [SavedLayoutEntry], before: [SavedLayoutEntry], description: String) throws {
        try LayoutGeometry.validate(requested)
        error = nil; isBusy = true
        defer { isBusy = false; refreshScreens() }
        do {
            try apply(requested, scope: .forAppOnly, requireExactTopology: true)
            let actual = try capture()
            // Position normalization is allowed only after all modes and the main
            // display were accepted. The confirmation then stores the visible result.
            for wanted in requested {
                guard let found = actual.first(where: { $0.identity == wanted.identity }),
                      found.mode.width == wanted.mode.width, found.mode.height == wanted.mode.height,
                      found.mode.pixelWidth == wanted.mode.pixelWidth, found.mode.pixelHeight == wanted.mode.pixelHeight,
                      ((wanted.mode.refreshRate == 0 && found.mode.refreshRate == 0) || CustomRefreshRate.matches(found.mode.refreshRate, wanted.mode.refreshRate)),
                      found.isMain == wanted.isMain else {
                    throw DisplayFailure(message: "系统未采用请求的显示模式或主屏，已请求恢复。")
                }
            }
            pending = Pending(before: before, applied: actual)
            message = LayoutGeometry.sameConfiguration(actual, requested) ? description : "macOS 为避免重叠或空隙调整了位置。请检查下方实际布局后再保留。"
            trial.start()
        } catch {
            // Keep a rollback record if the first restoration attempt also fails.
            pending = Pending(before: before, applied: (try? capture()) ?? before)
            do { try apply(before, scope: .forAppOnly, requireExactTopology: false); pending = nil }
            catch { self.error = "恢复原布局失败，可点击恢复重试。" }
            throw error
        }
    }

    private func apply(_ entries: [SavedLayoutEntry], scope: CGConfigureOption, requireExactTopology: Bool) throws {
        let displays = DisplayCore.displays()
        if requireExactTopology {
            try LayoutGeometry.validate(entries)
            let identities = Set(displays.compactMap { DisplayIdentity.capture($0.id) })
            guard identities == Set(entries.map(\.identity)), !displays.contains(where: { $0.isStudioVirtual || $0.isMirrored }) else {
                throw DisplayFailure(message: "显示器组合已变化，已取消布局操作。")
            }
        }
        let resolved = try entries.compactMap { entry -> (SavedLayoutEntry, CGDirectDisplayID, DisplayMode)? in
            guard let id = entry.identity.resolve() else {
                if requireExactTopology { throw DisplayFailure(message: "预设中的显示器已断开。") }
                return nil
            }
            guard abs(CGDisplayRotation(id) - entry.rotation) < 0.01 else { throw DisplayFailure(message: "显示器旋转方向已变化。") }
            guard let mode = entry.mode.resolve(on: id) else { throw DisplayFailure(message: "显示器不再提供原有分辨率或刷新率。") }
            return (entry, id, mode)
        }
        guard !resolved.isEmpty else { return }
        try DisplayCore.configure(scope: scope) { config in
            for (_, id, mode) in resolved {
                try DisplayCore.configureMode(config, display: id, mode: mode)
            }
            for (entry, id, _) in resolved {
                try DisplayCore.check(CGConfigureDisplayOrigin(config, id, entry.x, entry.y), "应用显示器位置")
            }
        }
    }

    private func persist(_ updated: [SavedLayoutProfile]) throws {
        let data = try JSONEncoder().encode(updated)
        defaults.set(data, forKey: storageKey)
        profiles = updated
    }
    private func refreshScreensWithoutRollback() {
        // Suppress automatic rollback reentry if the recovery itself failed.
        let wasBusy = isBusy
        isBusy = true; refreshScreens(); isBusy = wasBusy
    }
    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        refreshWork?.cancel()
        trial.cancel()
    }
}

struct LayoutProfilesView: View {
    @ObservedObject var displayModel: DisplayModel
    @ObservedObject var manager: LayoutProfileManager
    private let accent = Color(red: 0.12, green: 0.39, blue: 0.84)

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text("示意图使用桌面逻辑尺寸，主屏位于坐标原点。")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button { manager.refreshScreens() } label: { Label("刷新", systemImage: "arrow.clockwise") }
                    .disabled(manager.isBusy)
            }
            if let error = manager.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            if manager.isPending {
                HStack(spacing: 12) {
                    Text(String(manager.remaining)).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                    VStack(alignment: .leading, spacing: 3) {
                        Text("保留这个布局？").font(.headline)
                        Text(manager.remaining > 0 ? "未确认会自动恢复。" : "请重试恢复原布局。").font(.caption)
                    }
                    Spacer()
                    Button("恢复") { manager.revertTrial() }.disabled(manager.isBusy)
                    Button("保留布局") { manager.confirmTrial() }.buttonStyle(.borderedProminent).disabled(manager.isBusy || manager.remaining == 0)
                }.padding(14).background(accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
            }
            LayoutMap(screens: manager.screens, selectedID: manager.targetDisplay)
                .frame(height: 190).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityLabel("当前显示器布局，共 \(manager.screens.count) 块显示器")
            if manager.screens.count < 2 {
                Label("连接另一块显示器后，可调整相对位置和主屏。现在仍可保存当前分辨率预设。", systemImage: "display.2")
                    .font(.callout).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("排列显示器").font(.system(size: 15, weight: .semibold))
                HStack(spacing: 10) {
                    Picker("移动", selection: $manager.targetDisplay) {
                        ForEach(manager.screens) { screen in Text(screen.name).tag(screen.id) }
                    }.frame(maxWidth: .infinity)
                    Text("到").foregroundStyle(.secondary)
                    Picker("参照", selection: $manager.anchorDisplay) {
                        if !manager.screens.contains(where: { $0.id != manager.targetDisplay }) {
                            Text("未连接其他显示器").tag(CGDirectDisplayID(0))
                        }
                        ForEach(manager.screens.filter { $0.id != manager.targetDisplay }) { screen in Text(screen.name).tag(screen.id) }
                    }.frame(maxWidth: .infinity)
                    Picker("位置", selection: $manager.direction) {
                        ForEach(LayoutDirection.allCases) { item in Text(item.label).tag(item) }
                    }.labelsHidden().frame(width: 86)
                }.disabled(!manager.canArrange || displayModel.hasTrial || displayModel.isBusy)
                HStack {
                    Text("屏幕边缘对齐；系统可能自动消除空隙。")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("设为主屏") { manager.makeMain(manager.targetDisplay) }
                        .disabled(!manager.canArrange || manager.screens.first(where: { $0.id == manager.targetDisplay })?.isMain == true)
                    Button("试用位置") { manager.arrange() }.disabled(!manager.canArrange)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("配置预设").font(.system(size: 15, weight: .semibold))
                Text("保存连接的显示器、分辨率、刷新率、主屏和位置。旋转方向需与预设一致；不自动更改色彩配置。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("例如：办公双屏", text: $manager.profileName).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("布局预设名称")
                    Button("保存当前配置") { manager.saveCurrentProfile() }.disabled(!manager.canSave)
                }
                if manager.profiles.isEmpty {
                    Text("还没有配置预设。调整好显示器后，保存当前配置即可。")
                        .font(.callout).foregroundStyle(.secondary).padding(.vertical, 16)
                } else {
                    ForEach(manager.profiles) { profile in
                        profileRow(profile)
                    }
                }
            }
            Text(manager.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
        .onAppear { manager.refreshScreens() }
        .onChange(of: manager.targetDisplay) { _ in
            if manager.anchorDisplay == manager.targetDisplay {
                manager.anchorDisplay = manager.screens.first(where: { $0.id != manager.targetDisplay })?.id ?? 0
            }
        }
    }

    private func profileRow(_ profile: SavedLayoutProfile) -> some View {
        let reason = manager.unavailableReason(for: profile)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "rectangle.3.group").foregroundStyle(accent)
                Text(profile.name).font(.system(size: 14, weight: .medium))
                Spacer()
                Button("试用") { manager.applyProfile(id: profile.id) }.disabled(reason != nil)
                Button { manager.deleteProfile(id: profile.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).accessibilityLabel("删除预设“\(profile.name)”")
                    .disabled(manager.isPending || manager.isBusy)
            }
            ForEach(profile.entries, id: \.identity) { entry in
                Text("\(entry.name)\(entry.isMain ? " · 主屏" : "")  ·  \(entry.mode.label)  ·  (\(entry.x), \(entry.y))")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            if let reason { Text(reason).font(.caption).foregroundStyle(.orange) }
        }.padding(13).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }
}

private struct LayoutMap: View {
    let screens: [LayoutScreen]
    let selectedID: CGDirectDisplayID
    var body: some View {
        GeometryReader { geometry in
            let bounds = screens.map(\.bounds).reduce(CGRect.null) { $0.union($1) }
            let scale = bounds.isNull ? 1 : min((geometry.size.width - 36) / max(bounds.width, 1), (geometry.size.height - 36) / max(bounds.height, 1))
            let offsetX = bounds.isNull ? 0 : (geometry.size.width - bounds.width * scale) / 2
            let offsetY = bounds.isNull ? 0 : (geometry.size.height - bounds.height * scale) / 2
            ZStack(alignment: .topLeading) {
                ForEach(screens) { screen in
                    let width = max(24, screen.bounds.width * scale)
                    let height = max(24, screen.bounds.height * scale)
                    VStack(spacing: 4) {
                        if screen.isMain { Capsule().fill(Color.accentColor).frame(width: min(width - 16, 80), height: 3) }
                        Image(systemName: screen.isBuiltin ? "laptopcomputer" : "display").font(.system(size: 18))
                        Text(screen.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        if height > 75 { Text(screen.mode.sizeLabel).font(.system(size: 10)).foregroundStyle(.secondary) }
                    }.padding(6).frame(width: width, height: height)
                        .background(screen.id == selectedID ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(screen.id == selectedID ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: 1))
                        .position(x: offsetX + (screen.bounds.midX - bounds.minX) * scale,
                                  y: offsetY + (screen.bounds.midY - bounds.minY) * scale)
                }
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}
