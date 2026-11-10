import AppKit
import SwiftUI

struct BrightnessSyncTarget: Codable, Identifiable, Equatable {
    var id: String { identity.uuid }
    let identity: DisplayIdentity
    var name: String
    var enabled: Bool
    var ratio: Double

    func validate() throws {
        guard !identity.uuid.isEmpty, !name.isEmpty, name.count <= 120,
            ratio.isFinite, (0.25...1.5).contains(ratio)
        else {
            throw DisplayFailure(message: "亮度联动配置无效。比例需在 25–150% 之间。")
        }
    }
}

struct BrightnessSyncScreen: Equatable {
    let displayID: CGDirectDisplayID
    let identity: DisplayIdentity
    let name: String
    let builtIn: Bool
    let mirrored: Bool
    let studioVirtual: Bool
    var canFollow: Bool { !builtIn && !mirrored && !studioVirtual }
}

/// Injectable I/O keeps the policy tests separate from real monitor writes.
struct BrightnessSyncEnvironment {
    var screens: () -> [BrightnessSyncScreen]
    var sourceRead: (CGDirectDisplayID) throws -> NativeBrightnessReading
    var targetRead: @MainActor (CGDirectDisplayID) async throws -> NativeBrightnessReading
    var write: @MainActor (Double, CGDirectDisplayID, DisplayIdentity) async throws -> NativeBrightnessReading
    var now: () -> Date

    static var live: BrightnessSyncEnvironment {
        BrightnessSyncEnvironment(
            screens: {
                DisplayCore.onlineIDs().compactMap { id in
                    // A closed-lid/inactive built-in panel must not drive followers
                    // with a stale or zero backlight reading.
                    guard CGDisplayIsActive(id) != 0, CGDisplayIsAsleep(id) == 0,
                        let identity = DisplayIdentity.capture(id)
                    else { return nil }
                    let screen = NSScreen.screens.first {
                        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
                    }
                    return BrightnessSyncScreen(
                        displayID: id, identity: identity,
                        name: screen?.localizedName ?? "显示器 \(id)", builtIn: CGDisplayIsBuiltin(id) != 0,
                        mirrored: CGDisplayIsInMirrorSet(id) != 0,
                        studioVirtual: CGDisplayVendorNumber(id) == 0x4844 && CGDisplayModelNumber(id) == 0x5354)
                }
            }, sourceRead: { try NativeBrightnessService.shared.read(displayID: $0) },
            targetRead: { try await HardwareBrightness.read(displayID: $0) },
            write: { try await HardwareBrightness.set($0, displayID: $1, expectedIdentity: $2) }, now: Date.init)
    }
}

final class BrightnessSyncManager: ObservableObject {
    @Published private(set) var enabled: Bool
    @Published private(set) var targets: [BrightnessSyncTarget] = []
    @Published private(set) var screens: [BrightnessSyncScreen] = []
    @Published private(set) var sourceName: String?
    @Published private(set) var sourceError: String?
    @Published private(set) var targetErrors: [String: String] = [:]
    @Published var error: String?
    var isBlocked: () -> Bool = { false }
    var onApplied: (NativeBrightnessReading) -> Void = { _ in }

    private let defaults: UserDefaults
    private let environment: BrightnessSyncEnvironment
    private let observeNotifications: Bool
    private let enabledKey = "brightnessSync.enabled.v1"
    private let targetsKey = "brightnessSync.targets.v1"
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var operation: Task<Void, Never>?
    private var generation = 0
    private var started = false
    private var stopped = false
    private var sleeping = false
    private var screensSleeping = false
    private var sampling = false
    private var lastAppliedSource: [String: Double] = [:]
    private var lastWrite: [String: Date] = [:]
    private var retryAfter: [String: Date] = [:]

    init(
        defaults: UserDefaults = .standard, environment: BrightnessSyncEnvironment = .live,
        observeNotifications: Bool = true
    ) {
        self.defaults = defaults
        self.environment = environment
        self.observeNotifications = observeNotifications
        enabled = defaults.bool(forKey: enabledKey)
        if let data = defaults.data(forKey: targetsKey) {
            do {
                let saved = try JSONDecoder().decode([BrightnessSyncTarget].self, from: data)
                guard saved.count <= 32, Set(saved.map(\.id)).count == saved.count else {
                    throw DisplayFailure(message: "亮度联动配置数量或标识无效。")
                }
                try saved.forEach { try $0.validate() }
                targets = saved
            } catch {
                self.error = "无法读取亮度联动配置，已暂停联动：\(error.localizedDescription)"
                enabled = false
            }
        }
        refreshScreens()
    }

    /// Starting observes only while opted in. Loading preferences never writes
    /// hardware; the app calls start once after installing operation blockers.
    func start() {
        guard !started, !stopped else { return }
        started = true
        if observeNotifications {
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: NSApplication.didChangeScreenParametersNotification,
                    object: nil, queue: .main
                ) { [weak self] _ in self?.refreshScreens() })
            workspaceObservers.append(
                NSWorkspace.shared.notificationCenter.addObserver(
                    forName: NSWorkspace.willSleepNotification,
                    object: nil, queue: .main
                ) { [weak self] _ in
                    self?.sleeping = true
                    self?.cancelWork()
                })
            workspaceObservers.append(
                NSWorkspace.shared.notificationCenter.addObserver(
                    forName: NSWorkspace.didWakeNotification,
                    object: nil, queue: .main
                ) { [weak self] _ in
                    guard let self else { return }
                    self.sleeping = false
                    self.lastAppliedSource.removeAll()
                    self.retryAfter.removeAll()
                    self.refreshScreens()
                })
            workspaceObservers.append(
                NSWorkspace.shared.notificationCenter.addObserver(
                    forName: NSWorkspace.screensDidSleepNotification,
                    object: nil, queue: .main
                ) { [weak self] _ in
                    self?.screensSleeping = true
                    self?.cancelWork()
                })
            workspaceObservers.append(
                NSWorkspace.shared.notificationCenter.addObserver(
                    forName: NSWorkspace.screensDidWakeNotification,
                    object: nil, queue: .main
                ) { [weak self] _ in
                    guard let self else { return }
                    self.screensSleeping = false
                    self.lastAppliedSource.removeAll()
                    self.retryAfter.removeAll()
                    self.refreshScreens()
                })
        }
        updateTimer()
    }

    func setEnabled(_ value: Bool) {
        guard !stopped else { return }
        cancelWork()
        enabled = value
        defaults.set(value, forKey: enabledKey)
        sourceError = nil
        targetErrors.removeAll()
        if value {
            lastAppliedSource.removeAll()
            retryAfter.removeAll()
        }
        updateTimer()
        if value && started { launchSample() }
    }

    func setTargetEnabled(_ value: Bool, identity: DisplayIdentity) {
        guard !stopped, let index = targets.firstIndex(where: { $0.identity == identity }) else { return }
        cancelWork()
        targets[index].enabled = value
        lastAppliedSource[identity.uuid] = nil
        retryAfter[identity.uuid] = nil
        targetErrors[identity.uuid] = nil
        persist()
        if enabled && started { launchSample() }
    }

    func setRatio(_ value: Double, identity: DisplayIdentity) {
        guard value.isFinite, (0.25...1.5).contains(value) else {
            error = "联动比例需在 25–150% 之间。"
            return
        }
        guard !stopped, let index = targets.firstIndex(where: { $0.identity == identity }) else { return }
        guard abs(targets[index].ratio - value) > 0.00001 else { return }
        cancelWork()
        targets[index].ratio = value
        lastAppliedSource[identity.uuid] = nil
        retryAfter[identity.uuid] = nil
        persist()
        if enabled && started { launchSample() }
    }

    func syncNow() {
        guard enabled, !stopped else { return }
        cancelWork()
        lastAppliedSource.removeAll()
        retryAfter.removeAll()
        launchSample()
    }

    func suspendForConfiguration() { cancelWork() }

    /// Manual target adjustments win until the built-in source changes again.
    /// A manual source request cancels an old in-flight sample; next tick reads
    /// the source after its own hardware write has had time to finish.
    func noteManualChange(displayID: CGDirectDisplayID, value: Double) {
        guard enabled, value.isFinite, (0...1).contains(value), !stopped else { return }
        let current = environment.screens()
        guard let changed = current.first(where: { $0.displayID == displayID }) else { return }
        cancelWork()
        if changed.builtIn { return }
        guard let source = sourceScreen(in: current), let reading = try? environment.sourceRead(source.displayID),
            reading.identity == source.identity
        else { return }
        lastAppliedSource[changed.identity.uuid] = reading.value
        retryAfter[changed.identity.uuid] = nil
    }

    func refreshScreens() {
        guard !stopped else { return }
        let current = environment.screens().filter { !$0.studioVirtual }
        let old = Dictionary(uniqueKeysWithValues: screens.map { ($0.identity.uuid, $0) })
        let changed = current != screens
        if changed {
            cancelWork()
            let live = Set(current.map { $0.identity.uuid })
            for key in Set(lastAppliedSource.keys).union(lastWrite.keys).union(retryAfter.keys).union(targetErrors.keys)
            where !live.contains(key) {
                lastAppliedSource[key] = nil
                lastWrite[key] = nil
                retryAfter[key] = nil
                targetErrors[key] = nil
            }
            for screen in current where old[screen.identity.uuid] != screen {
                lastAppliedSource[screen.identity.uuid] = nil
                retryAfter[screen.identity.uuid] = nil
            }
            screens = current
        }
        let source = sourceScreen(in: current)
        if sourceName != source?.name {
            sourceName = source?.name
            sourceError = nil
            lastAppliedSource.removeAll()
        }
        var next = targets
        for screen in current where screen.canFollow {
            if let index = next.firstIndex(where: { $0.identity == screen.identity }) {
                next[index].name = screen.name
            } else if next.count < 32 {
                next.append(
                    BrightnessSyncTarget(identity: screen.identity, name: screen.name, enabled: false, ratio: 1))
            }
        }
        if next != targets { targets = next }
        if changed && enabled && started { launchSample() }
    }

    func connectedScreen(for target: BrightnessSyncTarget) -> BrightnessSyncScreen? {
        screens.first { $0.identity == target.identity && $0.canFollow }
    }

    private func sourceScreen(in screens: [BrightnessSyncScreen]) -> BrightnessSyncScreen? {
        screens.first { $0.builtIn && !$0.mirrored && !$0.studioVirtual }
    }

    private func persist() {
        do {
            try targets.forEach { try $0.validate() }
            defaults.set(try JSONEncoder().encode(targets), forKey: targetsKey)
            error = nil
        } catch { self.error = "亮度联动配置未保存：\(error.localizedDescription)" }
    }

    private func updateTimer() {
        timer?.invalidate()
        timer = nil
        guard enabled, started, !stopped else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.launchSample() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func cancelWork() {
        generation += 1
        operation?.cancel()
        operation = nil
    }

    private func launchSample() {
        guard enabled, !sleeping, !screensSleeping, !stopped, !isBlocked() else {
            if operation != nil { cancelWork() }
            return
        }
        guard operation == nil, !sampling else { return }
        let token = generation
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.sample()
            if self.generation == token { self.operation = nil }
        }
    }

    /// One production synchronization pass. Exposed internally for deterministic
    /// tests with a fake environment, not as an alternate hardware path.
    @MainActor func sample() async {
        guard enabled, !sleeping, !screensSleeping, !stopped, !sampling, !isBlocked() else { return }
        sampling = true
        defer { sampling = false }
        let token = generation
        let live = environment.screens()
        guard let source = sourceScreen(in: live) else { return }
        let initial: NativeBrightnessReading
        do {
            initial = try environment.sourceRead(source.displayID)
            guard initial.displayID == source.displayID, initial.identity == source.identity, initial.value.isFinite,
                (0...1).contains(initial.value)
            else {
                throw DisplayFailure(message: "内置屏亮度读回无效。")
            }
            if sourceError != nil { sourceError = nil }
        } catch {
            if sourceError != error.localizedDescription { sourceError = error.localizedDescription }
            return
        }
        for target in targets where target.enabled {
            let key = target.id
            guard shouldContinue(token) else { return }
            guard let screen = live.first(where: { $0.identity == target.identity && $0.canFollow }) else { continue }
            let time = environment.now()
            if let retry = retryAfter[key], retry > time { continue }
            if let prior = lastAppliedSource[key], abs(prior - initial.value) < 0.01 - 0.000001 { continue }
            if let written = lastWrite[key], time.timeIntervalSince(written) < 0.8 { continue }
            do {
                let before = try await environment.targetRead(screen.displayID)
                guard shouldContinue(token), stillConnected(screen), stillConnected(source),
                    before.displayID == screen.displayID, before.identity == target.identity
                else { return }
                let freshSource = try environment.sourceRead(source.displayID)
                guard freshSource.displayID == source.displayID, freshSource.identity == source.identity,
                    freshSource.value.isFinite, (0...1).contains(freshSource.value)
                else {
                    throw DisplayFailure(message: "内置屏亮度或身份已变化。")
                }
                let desired = Self.targetValue(source: freshSource.value, ratio: target.ratio)
                if !Self.matches(before, target: desired) {
                    guard shouldContinue(token), stillConnected(screen), stillConnected(source) else { return }
                    lastWrite[key] = environment.now()
                    let applied = try await environment.write(desired, screen.displayID, target.identity)
                    guard shouldContinue(token), stillConnected(screen), applied.displayID == screen.displayID,
                        applied.identity == target.identity
                    else { return }
                    guard Self.matches(applied, target: desired) else { throw DisplayFailure(message: "显示器没有采用联动亮度。") }
                    onApplied(applied)
                }
                lastAppliedSource[key] = freshSource.value
                if targetErrors[key] != nil { targetErrors[key] = nil }
                retryAfter[key] = nil
            } catch is CancellationError { return } catch {
                guard shouldContinue(token) else { return }
                if targetErrors[key] != error.localizedDescription { targetErrors[key] = error.localizedDescription }
                // Unsupported or busy monitors are not queried every second.
                retryAfter[key] = environment.now().addingTimeInterval(10)
            }
        }
    }

    private func shouldContinue(_ token: Int) -> Bool {
        enabled && !sleeping && !screensSleeping && !stopped && !isBlocked() && generation == token && !Task.isCancelled
    }
    private func stillConnected(_ screen: BrightnessSyncScreen) -> Bool {
        environment.screens().contains {
            $0.displayID == screen.displayID && $0.identity == screen.identity && !$0.mirrored && !$0.studioVirtual
                && $0.builtIn == screen.builtIn
        }
    }
    static func targetValue(source: Double, ratio: Double) -> Double { min(1, max(0, source * ratio)) }
    private static func matches(_ reading: NativeBrightnessReading, target: Double) -> Bool {
        if reading.backend == .ddc, let maximum = reading.rawMaximum, let current = reading.rawCurrent,
            let scaled = try? DDCBrightnessPacket.scaledValue(normalized: target, maximum: maximum)
        {
            return current == scaled
        }
        return NativeBrightnessService.matches(reading.value, target)
    }

    func shutdown() {
        stopped = true
        cancelWork()
        timer?.invalidate()
        timer = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceObservers.removeAll()
    }
    deinit {
        timer?.invalidate()
        operation?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }
}

struct BrightnessSyncView: View {
    @ObservedObject var displayModel: DisplayModel
    @ObservedObject var manager: BrightnessSyncManager

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("多屏亮度联动").font(.system(size: 15, weight: .semibold))
                Spacer()
                Toggle("开启", isOn: Binding(get: { manager.enabled }, set: manager.setEnabled)).toggleStyle(.switch)
                    .labelsHidden().accessibilityLabel("开启多屏亮度联动")
            }
            Text("以内置屏亮度为基准，按比例调整勾选的外接屏。不同屏幕的百分比不代表相同的实际亮度。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let source = manager.sourceName {
                Text("跟随来源：" + source).font(.callout)
            } else {
                Text("未检测到可独立控制的内置屏幕，联动暂停。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let error = manager.error ?? manager.sourceError {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            if manager.targets.isEmpty {
                Text("连接外接显示器后，可选择需要联动的屏幕。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(manager.targets) { target in
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 10) {
                        Toggle(
                            target.name,
                            isOn: Binding(
                                get: {
                                    manager.targets.first(where: { $0.id == target.id })?.enabled ?? false
                                }, set: { manager.setTargetEnabled($0, identity: target.identity) })
                        )
                        .toggleStyle(.checkbox).lineLimit(2)
                        Spacer(minLength: 4)
                        if manager.connectedScreen(for: target) == nil {
                            Text("未连接或不可独立控制").font(.caption).foregroundStyle(.secondary)
                        }
                        Slider(
                            value: Binding(
                                get: {
                                    manager.targets.first(where: { $0.id == target.id })?.ratio ?? 1
                                }, set: { manager.setRatio($0, identity: target.identity) }), in: 0.25...1.5, step: 0.05
                        )
                        .frame(width: 125).disabled(!target.enabled)
                        .accessibilityLabel(target.name + " 联动比例")
                        Text(String(format: "%.0f%%", target.ratio * 100)).font(.caption).monospacedDigit().frame(
                            width: 40)
                    }
                    if let error = manager.targetErrors[target.id] {
                        Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(12).background(
                    Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            HStack {
                Text("仅在应用运行且开启时联动；手动调外接屏后，等内置屏再次变化再跟随。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("立即同步") { manager.syncNow() }
                    .disabled(
                        !manager.enabled || manager.sourceName == nil || manager.isBlocked() || displayModel.isBusy
                            || displayModel.hasTrial)
            }
        }
    }
}
