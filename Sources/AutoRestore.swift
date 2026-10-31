import AppKit
import Combine
import SwiftUI

/// Connection identity only: changing resolution, rate or position cannot create
/// another restore event. Numeric IDs help detect a re-created connection for the
/// same physical UUID; they are never used to resolve a saved profile.
struct AutoRestoreTopology: Equatable {
    let connections: [String: CGDirectDisplayID]
    static func current() -> AutoRestoreTopology {
        var connections: [String: CGDirectDisplayID] = [:]
        for id in DisplayCore.onlineIDs() {
            guard !(CGDisplayVendorNumber(id) == 0x4844 && CGDisplayModelNumber(id) == 0x5354),
                  let identity = DisplayIdentity.capture(id) else { continue }
            connections[identity.uuid] = id
        }
        return AutoRestoreTopology(connections: connections)
    }
}

/// Pure event/deadline policy, tested without sleeping or changing real displays.
struct AutoRestoreEventPolicy {
    enum Reason { case wake, connection }
    struct Request {
        let generation: UInt64
        let reason: Reason
        let deadline: Date
        var notBefore: Date
        var attempts: Int
    }
    private(set) var topology: AutoRestoreTopology?
    private(set) var request: Request?
    private var generation: UInt64 = 0
    static let settleDelay: TimeInterval = 2
    static let maximumAttempts = 5
    static let retryWindow: TimeInterval = 15

    static func isPhysicalConnectionEvent(_ flags: CGDisplayChangeSummaryFlags, isStudioVirtual: Bool) -> Bool {
        !isStudioVirtual && !flags.contains(.beginConfigurationFlag) &&
            (flags.contains(.addFlag) || flags.contains(.removeFlag))
    }

    mutating func observe(_ value: AutoRestoreTopology, at now: Date) -> Bool {
        guard let previous = topology else { topology = value; return false }
        topology = value
        guard value != previous else { return false }
        arm(.connection, at: now)
        return true
    }
    mutating func arm(_ reason: Reason, at now: Date) {
        generation &+= 1
        request = Request(generation: generation, reason: reason,
                          deadline: now.addingTimeInterval(Self.retryWindow),
                          notBefore: now.addingTimeInterval(Self.settleDelay), attempts: 0)
    }
    mutating func consumeAttempt(generation expected: UInt64, at now: Date) -> Bool {
        guard var pending = request, pending.generation == expected, now >= pending.notBefore, now <= pending.deadline,
              pending.attempts < Self.maximumAttempts else { return false }
        pending.attempts += 1
        pending.notBefore = now.addingTimeInterval(Self.settleDelay)
        request = pending
        return true
    }
    func canRetry(generation expected: UInt64, at now: Date) -> Bool {
        guard let pending = request, pending.generation == expected else { return false }
        return pending.attempts < Self.maximumAttempts && now.addingTimeInterval(Self.settleDelay) <= pending.deadline
    }
    mutating func cancel() { generation &+= 1; request = nil }
}

/// Kept alive while registered with CoreGraphics. The weak owner prevents a
/// native callback from retaining the whole feature after shutdown.
private final class AutoRestoreCallbackContext {
    weak var owner: AutoRestoreManager?
    init(owner: AutoRestoreManager) { self.owner = owner }
}

final class AutoRestoreManager: ObservableObject {
    @Published private(set) var enabled: Bool
    @Published private(set) var selectedProfileID: UUID?
    @Published private(set) var isBusy = false
    @Published private(set) var isWaiting = false
    @Published private(set) var error: String?
    @Published private(set) var message = "开启后，仅在唤醒或显示器重新连接时恢复所选预设。"
    var isBlocked: () -> Bool = { false }

    private weak var layouts: LayoutProfileManager?
    private let defaults: UserDefaults
    private let enabledKey = "HiDPIStudio.autoRestore.enabled.v1"
    private let profileKey = "HiDPIStudio.autoRestore.profile.v1"
    private var policy = AutoRestoreEventPolicy()
    private var work: DispatchWorkItem?
    private var restoreTask: Task<Void, Never>?
    private var activeRestoreID: UUID?
    private var screenObserver: NSObjectProtocol?
    private var callbackContext: UnsafeMutableRawPointer?
    private var recentDisplayIDs: [CGDirectDisplayID] = []
    private var knownStudioVirtual: [CGDirectDisplayID: Bool] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []
    private var profileSubscription: AnyCancellable?
    private var started = false
    private var shuttingDown = false
    private var systemSleeping = false
    private var screensSleeping = false

    private static let reconfigurationCallback: CGDisplayReconfigurationCallBack = { displayID, flags, context in
        guard let context, !flags.contains(.beginConfigurationFlag),
              flags.contains(.addFlag) || flags.contains(.removeFlag) else { return }
        let registration = Unmanaged<AutoRestoreCallbackContext>.fromOpaque(context).takeUnretainedValue()
        // Added-display state is valid here. Removed-display queries can fail,
        // so their classification is taken from the main-thread identity cache.
        let addedIsStudio: Bool? = flags.contains(.addFlag) && CGDisplayIsOnline(displayID) != 0
            ? (CGDisplayVendorNumber(displayID) == 0x4844 && CGDisplayModelNumber(displayID) == 0x5354) : nil
        DispatchQueue.main.async { [weak owner = registration.owner] in
            owner?.connectionChanged(displayID: displayID, flags: flags, addedIsStudio: addedIsStudio)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let loadedProfile = defaults.string(forKey: profileKey).flatMap(UUID.init(uuidString:))
        selectedProfileID = loadedProfile
        enabled = defaults.bool(forKey: enabledKey) && loadedProfile != nil
    }

    func start(layouts: LayoutProfileManager) {
        guard !started, !shuttingDown else { return }
        self.layouts = layouts
        started = true
        _ = policy.observe(.current(), at: Date())
        rememberCurrentDisplays()
        registerConnectionCallback()
        // Merely launching the application never applies a stored configuration.
        profileSubscription = layouts.$profiles.sink { [weak self] in self?.profilesChanged($0) }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            self?.screenParametersChanged()
        }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.systemSleeping = true; self?.cancelPending()
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.screensSleeping = true; self?.cancelPending()
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.systemSleeping = false; self?.woke()
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.screensSleeping = false; self?.woke()
        })
    }

    func setEnabled(_ value: Bool) {
        guard !shuttingDown else { return }
        guard !value || selectedProfileID != nil else {
            error = "请先选择一个已保存的显示配置。"; return
        }
        enabled = value
        defaults.set(value, forKey: enabledKey)
        cancelPending()
        error = nil
        message = value ? "已开启，等待下一次唤醒或重新连接。" : "自动恢复已关闭。"
    }

    func setSelectedProfile(_ id: UUID?) {
        guard !shuttingDown else { return }
        if let id, let layouts, !layouts.profiles.contains(where: { $0.id == id }) {
            error = "所选配置已被删除，请重新选择。"; return
        }
        selectedProfileID = id
        if let id { defaults.set(id.uuidString, forKey: profileKey) }
        else { defaults.removeObject(forKey: profileKey); enabled = false; defaults.set(false, forKey: enabledKey) }
        cancelPending()
        error = nil
        message = enabled ? "预设已更新，下次唤醒或重新连接时生效。" : "选择预设后可开启自动恢复。"
    }

    /// Call when a manual mode/layout trial or virtual-screen operation begins.
    /// A queued wake restore must not run immediately after the user confirms a
    /// different setting. Automatic restoration itself does not call this hook.
    func cancelPendingForUserChange() {
        guard policy.request != nil || restoreTask != nil else { return }
        cancelPending()
        message = "本次自动恢复已跳过，保留你的手动操作。"
    }

    private func profilesChanged(_ profiles: [SavedLayoutProfile]) {
        guard let selectedProfileID, !profiles.contains(where: { $0.id == selectedProfileID }) else { return }
        self.selectedProfileID = nil
        enabled = false
        defaults.removeObject(forKey: profileKey)
        defaults.set(false, forKey: enabledKey)
        cancelPending()
        error = nil
        message = "所选预设已删除，自动恢复已关闭。"
    }

    private func screenParametersChanged() {
        guard !shuttingDown else { return }
        rememberCurrentDisplays()
        let changed = policy.observe(.current(), at: Date())
        if systemSleeping || screensSleeping || !enabled {
            cancelPending()
            return
        }
        // Existing mode changes and notifications produced by our own apply do
        // not create events, so manual changes are never continuously fought.
        if changed {
            if !isBusy && (isBlocked() || layouts?.isBusy == true || layouts?.isPending == true) {
                cancelPending()
                message = "本次自动恢复已跳过，保留正在进行的显示设置。"
                return
            }
            // A new physical topology invalidates an in-flight request. Its
            // layout transaction performs rollback before isBusy is released.
            restoreTask?.cancel()
            scheduleCurrentRequest()
        }
    }

    private func registerConnectionCallback() {
        let context = Unmanaged.passRetained(AutoRestoreCallbackContext(owner: self)).toOpaque()
        let status = CGDisplayRegisterReconfigurationCallback(Self.reconfigurationCallback, context)
        if status == .success { callbackContext = context }
        else {
            Unmanaged<AutoRestoreCallbackContext>.fromOpaque(context).release()
            error = "无法注册显示器连接事件（\(status.rawValue)）。可尝试重新打开应用。"
        }
    }

    private func unregisterConnectionCallback() {
        guard let context = callbackContext else { return }
        Unmanaged<AutoRestoreCallbackContext>.fromOpaque(context).takeUnretainedValue().owner = nil
        if CGDisplayRemoveReconfigurationCallback(Self.reconfigurationCallback, context) == .success {
            callbackContext = nil
            Unmanaged<AutoRestoreCallbackContext>.fromOpaque(context).release()
        }
        // If the OS refuses removal, retain the ownerless context rather than
        // leaving an opaque dangling pointer in a still-registered callback.
    }

    private func remember(_ displayID: CGDirectDisplayID, isStudioVirtual: Bool) {
        knownStudioVirtual[displayID] = isStudioVirtual
        recentDisplayIDs.removeAll { $0 == displayID }
        recentDisplayIDs.append(displayID)
        while recentDisplayIDs.count > 128 {
            knownStudioVirtual[recentDisplayIDs.removeFirst()] = nil
        }
    }

    private func rememberCurrentDisplays() {
        for id in DisplayCore.onlineIDs() {
            remember(id, isStudioVirtual: CGDisplayVendorNumber(id) == 0x4844 && CGDisplayModelNumber(id) == 0x5354)
        }
    }

    private func connectionChanged(displayID: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags, addedIsStudio: Bool?) {
        guard !shuttingDown else { return }
        let isStudio = addedIsStudio ?? knownStudioVirtual[displayID]
        if let addedIsStudio { remember(displayID, isStudioVirtual: addedIsStudio) }
        guard let isStudio,
              AutoRestoreEventPolicy.isPhysicalConnectionEvent(flags, isStudioVirtual: isStudio) else { return }
        rememberCurrentDisplays()
        _ = policy.observe(.current(), at: Date())
        guard enabled, !systemSleeping, !screensSleeping else { cancelPending(); return }
        // Preserve manually initiated work. An actual connection change during
        // our own restore instead cancels that transaction and settles anew.
        if !isBusy && (isBlocked() || layouts?.isBusy == true || layouts?.isPending == true) {
            cancelPending()
            message = "本次自动恢复已跳过，保留正在进行的显示设置。"
            return
        }
        restoreTask?.cancel()
        // Explicit add/remove must arm even if NSApplication coalesced a fast
        // unplug/replug back to the identical UUID and numeric display ID.
        policy.arm(.connection, at: Date())
        scheduleCurrentRequest()
    }

    private func woke() {
        guard enabled, started, !shuttingDown, !systemSleeping, !screensSleeping else { return }
        _ = policy.observe(.current(), at: Date())
        policy.arm(.wake, at: Date())
        scheduleCurrentRequest()
    }

    private func scheduleCurrentRequest() {
        work?.cancel()
        guard enabled, let request = policy.request, selectedProfileID != nil else { cancelPending(); return }
        isWaiting = true
        let generation = request.generation
        let item = DispatchWorkItem { [weak self] in self?.attempt(generation: generation) }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + AutoRestoreEventPolicy.settleDelay, execute: item)
    }

    private func attempt(generation: UInt64) {
        guard enabled, !shuttingDown, !systemSleeping, !screensSleeping,
              let layouts, let profileID = selectedProfileID,
              policy.consumeAttempt(generation: generation, at: Date()) else {
            if policy.request?.generation == generation { cancelPending() }
            return
        }
        guard let profile = layouts.profiles.first(where: { $0.id == profileID }) else {
            profilesChanged(layouts.profiles); return
        }
        if isBusy || isBlocked() || layouts.isBusy || layouts.isPending {
            retryOrFinish(generation, message: "本次自动恢复已跳过，其他显示设置仍在进行。")
            return
        }
        layouts.refreshScreens()
        if let reason = layouts.unavailableReason(for: profile) {
            retryOrFinish(generation, message: "等待预设对应的显示器与模式可用。" + reason)
            return
        }
        guard enabled, selectedProfileID == profileID, !isBlocked(), !layouts.isBusy, !layouts.isPending else {
            retryOrFinish(generation, message: "本次自动恢复已跳过，其他显示设置仍在进行。")
            return
        }
        isBusy = true
        isWaiting = false
        let restoreID = UUID()
        activeRestoreID = restoreID
        restoreTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.activeRestoreID == restoreID {
                    self.activeRestoreID = nil; self.restoreTask = nil; self.isBusy = false
                }
            }
            do {
                try Task.checkCancellation()
                let changed = try await layouts.restoreProfileAutomatically(id: profileID)
                try Task.checkCancellation()
                if self.enabled, !self.shuttingDown, self.policy.request?.generation == generation {
                    self.error = nil
                    self.message = changed ? "已自动恢复“\(profile.name)”。" : "当前配置已符合“\(profile.name)”。"
                }
            } catch is CancellationError {
                // The layout manager finishes rollback before this task returns.
            } catch {
                // A failed write/verification is not repeatedly re-applied.
                if !self.shuttingDown, self.policy.request?.generation == generation {
                    self.error = "自动恢复失败：\(error.localizedDescription)"
                    self.message = "本次自动恢复已停止，可手动应用预设。"
                }
            }
            if self.policy.request?.generation == generation {
                self.work?.cancel(); self.work = nil
                self.policy.cancel(); self.isWaiting = false
            }
        }
    }

    private func retryOrFinish(_ generation: UInt64, message: String) {
        if policy.canRetry(generation: generation, at: Date()) { scheduleCurrentRequest() }
        else { cancelPending(); self.message = message }
    }

    private func cancelPending() {
        work?.cancel(); work = nil
        restoreTask?.cancel()
        policy.cancel()
        isWaiting = false
    }

    func shutdown() {
        shuttingDown = true
        cancelPending()
        unregisterConnectionCallback()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver); self.screenObserver = nil }
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceObservers.removeAll()
        profileSubscription?.cancel(); profileSubscription = nil
    }
    func waitForShutdown() async {
        if let restoreTask { await restoreTask.value }
    }
    deinit {
        work?.cancel()
        restoreTask?.cancel()
        unregisterConnectionCallback()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }
}

struct AutoRestoreView: View {
    @ObservedObject var manager: AutoRestoreManager
    let profiles: [SavedLayoutProfile]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("唤醒与重连恢复").font(.system(size: 15, weight: .semibold))
            Toggle("自动恢复所选配置", isOn: Binding(get: { manager.enabled }, set: manager.setEnabled))
                .disabled(!manager.enabled && (profiles.isEmpty || manager.selectedProfileID == nil || manager.isBusy))
            Picker("配置预设", selection: Binding(get: { manager.selectedProfileID }, set: manager.setSelectedProfile)) {
                Text("请选择预设").tag(Optional<UUID>.none)
                ForEach(profiles) { profile in Text(profile.name).tag(Optional(profile.id)) }
            }.disabled(profiles.isEmpty || manager.isBusy)
            Text("仅在唤醒或重新连接后恢复，显示器组合与模式必须匹配。手动切换不触发；应用需保持运行。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if profiles.isEmpty {
                Text("先保存一个显示配置，再选择自动恢复的预设。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = manager.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(manager.message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.padding(16).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
    }
}
