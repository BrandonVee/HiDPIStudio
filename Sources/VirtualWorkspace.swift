import AppKit
import Combine
import SwiftUI

struct VirtualScreenDefinition: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    let width: Int
    let height: Int
    let refreshRate: Double

    init(id: UUID = UUID(), name: String, width: Int, height: Int, refreshRate: Double) throws {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.count <= 60 else { throw DisplayFailure(message: "名称需为 1–60 个字符。") }
        _ = try CustomSize(width: width, height: height)
        _ = try CustomRefreshRate(value: refreshRate)
        self.id = id; self.name = cleaned
        self.width = width; self.height = height; self.refreshRate = refreshRate
    }
    var description: String {
        let rate = String(format: abs(refreshRate.rounded() - refreshRate) < 0.005 ? "%.0f" : "%.2f", refreshRate)
        return "\(width) × \(height) HiDPI · \(rate) Hz"
    }
    func validate() throws { _ = try Self(id: id, name: name, width: width, height: height, refreshRate: refreshRate) }
}

final class VirtualWorkspace: ObservableObject {
    static let maximumDefinitions = 8
    private static let storageKey = "HiDPIStudio.virtualDefinitions.v1"
    private static let pendingRemovalMessage = "系统尚未移除这个虚拟屏幕，请稍后刷新或退出应用。"
    @Published private(set) var definitions: [VirtualScreenDefinition] = []
    @Published private(set) var displayIDs: [UUID: CGDirectDisplayID] = [:]
    @Published private(set) var screens: [DisplayInfo] = []
    @Published private(set) var connectionErrors: [UUID: String] = [:]
    @Published private(set) var isBusy = false
    @Published var error: String?
    let previews = ScreenPreviewController()
    var isBlocked: () -> Bool = { false }
    private let defaults: UserDefaults
    private var handles: [UUID: HDVirtualDisplay] = [:]
    private var identities: [UUID: DisplayIdentity] = [:]
    private var generation = 0
    private var isShuttingDown = false
    private var observer: NSObjectProtocol?

    var hasConnectedScreens: Bool { !handles.isEmpty || !displayIDs.isEmpty }
    func isDisconnecting(_ id: UUID) -> Bool { displayIDs[id] != nil && handles[id] == nil }
    var canCreate: Bool { HDVirtualDisplay.isAvailable() && definitions.count < Self.maximumDefinitions && !isBusy && !isBlocked() && !isShuttingDown }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey) {
            do {
                let loaded = try JSONDecoder().decode([VirtualScreenDefinition].self, from: data)
                guard loaded.count <= Self.maximumDefinitions, Set(loaded.map(\.id)).count == loaded.count else {
                    throw DisplayFailure(message: "虚拟屏幕定义数量或标识无效。")
                }
                try loaded.forEach { try $0.validate() }
                definitions = loaded
            } catch { self.error = "无法读取已保存的虚拟屏幕：\(error.localizedDescription)" }
        }
        refreshScreens()
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshScreens()
        }
    }

    /// Save a definition without creating a desktop. Used by imports/tests and
    /// followed explicitly by connect when the user chooses Create and Connect.
    @discardableResult func addDefinition(name: String, width: Int, height: Int, refreshRate: Double) throws -> VirtualScreenDefinition {
        guard !isShuttingDown, !isBlocked(), !isBusy else { throw DisplayFailure(message: "请先结束正在进行的显示设置。") }
        guard definitions.count < Self.maximumDefinitions else { throw DisplayFailure(message: "最多保存 8 个虚拟屏幕定义。") }
        let definition = try VirtualScreenDefinition(name: name, width: width, height: height, refreshRate: refreshRate)
        var next = definitions
        next.append(definition)
        try persist(next)
        definitions = next
        return definition
    }

    @MainActor func create(name: String, width: Int, height: Int, refreshRate: Double) async {
        error = nil
        do {
            let definition = try addDefinition(name: name, width: width, height: height, refreshRate: refreshRate)
            await connect(definition.id)
        } catch { self.error = error.localizedDescription }
    }

    @MainActor func connect(_ id: UUID) async {
        guard !isShuttingDown, !isBusy, !isBlocked(), handles[id] == nil, displayIDs[id] == nil,
              let definition = definitions.first(where: { $0.id == id }) else { return }
        isBusy = true
        generation += 1
        let operation = generation
        error = nil; connectionErrors[id] = nil
        defer { if generation == operation { isBusy = false; refreshScreens() } }
        do {
            try definition.validate()
            let virtual = try HDVirtualDisplay(width: UInt32(definition.width), height: UInt32(definition.height), refreshRate: definition.refreshRate,
                                               name: "HiDPI Studio · " + definition.name)
            handles[id] = virtual
            let displayID = virtual.displayID
            guard displayID != 0 else { throw DisplayFailure(message: "系统没有返回有效的虚拟屏幕。") }
            let size = try CustomSize(width: definition.width, height: definition.height)
            let mode = try await DisplayCore.waitForHiDPI(displayID, size: size, refreshRate: definition.refreshRate)
            guard operation == generation, !isShuttingDown else { return }
            try DisplayCore.setMode(displayID, mode)
            try DisplayCore.verify(displayID, width: definition.width, height: definition.height, hiDPI: true, refreshRate: definition.refreshRate)
            displayIDs[id] = displayID
            identities[id] = DisplayIdentity.capture(displayID)
            refreshScreens()
        } catch {
            guard operation == generation else { return }
            let removed = await disconnectInternal(id)
            guard operation == generation else { return }
            let message = error.localizedDescription + (removed ? "" : " 虚拟屏幕仍在断开，请稍后刷新。")
            connectionErrors[id] = message
            self.error = message
        }
    }

    @MainActor func disconnect(_ id: UUID) async {
        guard !isBusy, !isBlocked(), !isShuttingDown else { return }
        isBusy = true
        error = nil
        _ = await disconnectInternal(id)
        isBusy = false
        refreshScreens()
    }

    @MainActor func remove(_ id: UUID) async {
        guard !isBusy, !isBlocked(), !isShuttingDown else { return }
        isBusy = true
        error = nil
        defer { isBusy = false; refreshScreens() }
        guard await disconnectInternal(id) else { return }
        do {
            let next = definitions.filter { $0.id != id }
            try persist(next)
            definitions = next
            connectionErrors[id] = nil
        } catch { self.error = error.localizedDescription }
    }

    private func persist(_ definitions: [VirtualScreenDefinition]) throws {
        let data = try JSONEncoder().encode(definitions)
        defaults.set(data, forKey: Self.storageKey)
    }

    @MainActor private func disconnectInternal(_ id: UUID) async -> Bool {
        guard let displayID = displayIDs[id] ?? handles[id]?.displayID, displayID != 0 else {
            handles.removeValue(forKey: id)?.disconnect()
            displayIDs[id] = nil; identities[id] = nil
            return true
        }
        let identity = identities[id] ?? DisplayIdentity.capture(displayID)
        identities[id] = identity
        await previews.stop(displayID: displayID)
        handles.removeValue(forKey: id)?.disconnect()
        // WindowServer releases the display asynchronously. Keep ownership state
        // visible until disappearance, so another transaction cannot save it.
        displayIDs[id] = displayID
        for _ in 0..<30 {
            if !DisplayCore.onlineIDs().contains(displayID) || identity.map({ !$0.matches(displayID) }) == true {
                displayIDs[id] = nil; identities[id] = nil; connectionErrors[id] = nil
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let message = Self.pendingRemovalMessage
        connectionErrors[id] = message
        error = message
        return false
    }

    func refreshScreens() {
        let online = Set(DisplayCore.onlineIDs())
        if !isBusy {
            for (id, displayID) in Array(displayIDs) where !online.contains(displayID) || identities[id].map({ !$0.matches(displayID) }) == true {
                let wasDisconnecting = handles[id] == nil
                handles.removeValue(forKey: id)?.disconnect()
                displayIDs[id] = nil; identities[id] = nil
                connectionErrors[id] = wasDisconnecting ? nil : "虚拟屏幕已被系统断开，可点击连接重试。"
            }
            if error == Self.pendingRemovalMessage && !displayIDs.keys.contains(where: isDisconnecting) { error = nil }
        }
        screens = DisplayCore.displays()
        previews.refreshScreens()
    }

    @MainActor func shutdown() async {
        isShuttingDown = true
        generation += 1
        await previews.stopAll()
        for id in Set(handles.keys).union(displayIDs.keys) { _ = await disconnectInternal(id) }
        isBusy = false
        refreshScreens()
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
}

struct VirtualWorkspaceView: View {
    @ObservedObject var displayModel: DisplayModel
    @ObservedObject var manager: VirtualWorkspace
    @State private var name = "工作屏幕"
    @State private var width = "2560"
    @State private var height = "1440"
    @State private var refreshRate = "60"
    private var blocked: Bool { displayModel.isBusy || displayModel.hasTrial || manager.isBusy || manager.isBlocked() }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let error = manager.error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            VStack(alignment: .leading, spacing: 12) {
                Text("新建虚拟屏幕").font(.system(size: 15, weight: .semibold))
                HStack(alignment: .bottom, spacing: 10) {
                    field("名称", text: $name, width: 150)
                    field("桌面宽度", text: $width, width: 84)
                    field("桌面高度", text: $height, width: 84)
                    field("刷新率 Hz", text: $refreshRate, width: 76)
                    Spacer(minLength: 0)
                    Button("创建并连接") {
                        guard let w = Int(width), let h = Int(height), let rate = Double(refreshRate) else {
                            manager.error = "请输入整数宽高和有效刷新率。"; return
                        }
                        Task { @MainActor in await manager.create(name: name, width: w, height: h, refreshRate: rate) }
                    }.disabled(blocked || !manager.canCreate)
                }
                Text("保存最多 8 个定义；实际可连接数量取决于 Mac。退出会移除虚拟桌面，下次打开可手动连接。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(16).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("我的虚拟屏幕").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Button("刷新") { manager.refreshScreens() }.disabled(manager.isBusy)
                }
                if manager.definitions.isEmpty {
                    Text("还没有虚拟屏幕。创建后可作为扩展桌面使用，不会自动镜像到物理显示器。")
                        .font(.callout).foregroundStyle(.secondary).padding(.vertical, 12)
                }
                ForEach(manager.definitions) { definition in
                    definitionRow(definition)
                }
            }
            Divider()
            ScreenPreviewsView(screens: manager.screens, controller: manager.previews)
        }.onAppear { manager.refreshScreens() }
    }

    private func field(_ title: String, text: Binding<String>, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, text: text).textFieldStyle(.roundedBorder).frame(width: width).accessibilityLabel("虚拟屏幕" + title)
        }
    }

    private func definitionRow(_ definition: VirtualScreenDefinition) -> some View {
        let displayID = manager.displayIDs[definition.id]
        let actual = displayID.flatMap { id in manager.screens.first { $0.id == id }?.current }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: "display.2").font(.system(size: 22)).frame(width: 30)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(definition.name).font(.system(size: 13, weight: .medium))
                        Text(manager.isDisconnecting(definition.id) ? "正在断开" : (displayID == nil ? "未连接" : "已连接"))
                            .font(.caption).foregroundStyle(manager.isDisconnecting(definition.id) ? Color.orange : (displayID == nil ? Color.secondary : Color.green))
                    }
                    Text(actual.map { $0.sizeLabel + " HiDPI · " + $0.rateLabel + " · 渲染 " + $0.backingLabel } ?? definition.description)
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer(minLength: 8)
                if displayID != nil {
                    Button("断开") { Task { @MainActor in await manager.disconnect(definition.id) } }
                } else {
                    Button("连接") { Task { @MainActor in await manager.connect(definition.id) } }
                }
                Button("移除") { Task { @MainActor in await manager.remove(definition.id) } }
            }.disabled(blocked)
            if let error = manager.connectionErrors[definition.id] { Text(error).font(.caption).foregroundStyle(.orange) }
        }.padding(12).background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
    }
}
