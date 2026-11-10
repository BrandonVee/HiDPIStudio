import AppKit
import ApplicationServices
import SwiftUI

/// Apple's NX_SYSDEFINED / NX_SUBTYPE_AUX_CONTROL_BUTTONS protocol, declared in
/// the macOS SDK's IOKit/hidsystem/IOLLEvent.h and ev_keymap.h. Ordinary keyDown
/// events are deliberately never observed by this feature.
struct NativeBrightnessKeyPacket: Equatable {
    enum Phase { case down, up }
    let key: UInt16
    let phase: Phase
    let isRepeat: Bool
    let allowsAdjustment: Bool
    var delta: Double { key == 2 ? 0.05 : -0.05 }

    static func decode(
        eventType: UInt32, subtype: Int16, data1: Int,
        modifiers: NSEvent.ModifierFlags
    ) -> NativeBrightnessKeyPacket? {
        guard eventType == 14, subtype == 8 else { return nil }
        let value = UInt32(truncatingIfNeeded: data1)
        let key = UInt16((value >> 16) & 0xffff)
        guard key == 2 || key == 3 else { return nil }
        let state = (value >> 8) & 0xff
        guard state == 0x0a || state == 0x0b else { return nil }
        // Preserve modifier information until routing: a held key already taken
        // over by this app must not leak modified repeats to the system midway.
        let allowsAdjustment = modifiers.intersection([.command, .control, .option, .shift]).isEmpty
        return NativeBrightnessKeyPacket(
            key: key, phase: state == 0x0a ? .down : .up,
            isRepeat: value & 1 != 0, allowsAdjustment: allowsAdjustment)
    }
}

struct NativeBrightnessKeyTarget: Equatable {
    let displayID: CGDirectDisplayID
    let identity: DisplayIdentity
}

struct NativeBrightnessKeyDecision {
    let consume: Bool
    let adjustment: (target: NativeBrightnessKeyTarget, delta: Double)?
    static let passthrough = NativeBrightnessKeyDecision(consume: false, adjustment: nil)
}

/// A held key stays with the monitor where its first press was handled. Moving
/// the pointer mid-hold must not start changing a different display.
struct NativeBrightnessKeyRouting {
    private var held: [UInt16: NativeBrightnessKeyTarget] = [:]
    mutating func reset() { held.removeAll() }

    mutating func route(
        _ packet: NativeBrightnessKeyPacket,
        targetForNewPress: NativeBrightnessKeyTarget?,
        mayAdjust: (NativeBrightnessKeyTarget) -> Bool
    ) -> NativeBrightnessKeyDecision {
        if packet.phase == .up {
            return NativeBrightnessKeyDecision(consume: held.removeValue(forKey: packet.key) != nil, adjustment: nil)
        }
        if let target = held[packet.key] {
            // Complete an already-handled sequence without leaking repeats to
            // macOS if its target disconnects or a display trial starts mid-hold.
            return NativeBrightnessKeyDecision(
                consume: true,
                adjustment: packet.allowsAdjustment && mayAdjust(target) ? (target, packet.delta) : nil)
        }
        guard packet.allowsAdjustment, !packet.isRepeat, let target = targetForNewPress, mayAdjust(target) else {
            return .passthrough
        }
        held[packet.key] = target
        return NativeBrightnessKeyDecision(consume: true, adjustment: (target, packet.delta))
    }
}

/// UI and event-tap lifecycle owner. Install the tap on the main run loop so
/// NSScreen mouse coordinates and the provided cached-capability closures are
/// accessed on the same thread as the rest of the application.
final class NativeBrightnessKeyManager: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var isActive = false
    @Published private(set) var permissionGranted = false
    @Published private(set) var error: String?
    @Published private(set) var status = "关闭时保留 macOS 原有的亮度键行为。"
    var onAdjust: (CGDirectDisplayID, Double) -> Void = { _, _ in }
    /// Must only inspect cached capability/state; never perform hardware I/O.
    var canHandle: (CGDirectDisplayID) -> Bool = { _ in false }
    var isBlocked: () -> Bool = { false }

    private let defaults: UserDefaults
    private let preferenceKey = "nativeBrightnessKeys.enabled.v1"
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var permissionTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var routing = NativeBrightnessKeyRouting()
    private var generation: UInt64 = 0
    private var isShuttingDown = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        permissionGranted = AXIsProcessTrusted()
    }

    /// App startup never triggers a permission prompt. A prior user preference
    /// is honored only if the current application already has the required grant.
    func restorePreference() {
        guard !isShuttingDown else { return }
        enabled = defaults.bool(forKey: preferenceKey)
        ensureObservers()
        refreshPermission(retryIfTrusted: true)
    }

    /// This method is for an explicit user toggle only. Parent automation and
    /// startup code must call restorePreference()/refreshPermission() instead.
    func setEnabled(_ value: Bool) {
        guard !isShuttingDown else { return }
        enabled = value
        defaults.set(value, forKey: preferenceKey)
        error = nil
        guard value else {
            stopTap()
            stopPermissionTimer()
            status = "已关闭，亮度键交由 macOS 处理。"
            return
        }
        ensureObservers()
        permissionGranted = AXIsProcessTrusted()
        if !permissionGranted {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        refreshPermission(retryIfTrusted: true)
    }

    /// Read-only trust check. The retry button and app activation can restart a
    /// suspended tap; polling only restarts it after a grant changed to allowed.
    func refreshPermission(retryIfTrusted: Bool = false) {
        guard !isShuttingDown else { return }
        let wasGranted = permissionGranted
        permissionGranted = AXIsProcessTrusted()
        guard enabled else { return }
        ensurePermissionTimer()
        guard permissionGranted else {
            stopTap()
            status = "等待辅助功能授权；当前亮度键仍由 macOS 处理。"
            return
        }
        if tap == nil && (retryIfTrusted || !wasGranted) { installTap() }
    }

    func openPermissionSettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    private func ensureObservers() {
        guard observers.isEmpty else { return }
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil, queue: .main
            ) { [weak self] _ in self?.refreshPermission(retryIfTrusted: true) })
        workspaceObservers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.stopTap()
                if self.enabled { self.status = "休眠期间暂停监听，唤醒后重新检查权限。" }
            })
        workspaceObservers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil, queue: .main
            ) { [weak self] _ in self?.refreshPermission(retryIfTrusted: true) })
    }

    private func ensurePermissionTimer() {
        guard permissionTimer == nil else { return }
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.refreshPermission() }
        permissionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func installTap() {
        guard enabled, permissionGranted, !isShuttingDown else { return }
        stopTap()
        let mask = CGEventMask(1) << 14
        guard
            let created = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap,
                options: .defaultTap, eventsOfInterest: mask,
                callback: { _, type, event, context in
                    guard let context else { return Unmanaged.passUnretained(event) }
                    let owner = Unmanaged<NativeBrightnessKeyManager>.fromOpaque(context).takeUnretainedValue()
                    return owner.handle(type: type, event: event)
                }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            error = "系统未能启动亮度键监听。请检查辅助功能权限，或授权后重新打开应用。"
            status = "监听未启动，保留 macOS 原有行为。"
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0) else {
            CFMachPortInvalidate(created)
            error = "无法建立亮度键事件源。"
            status = "监听未启动，保留 macOS 原有行为。"
            return
        }
        tap = created
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        isActive = CGEvent.tapIsEnabled(tap: created)
        if isActive {
            error = nil
            status = "已启用：亮度键控制鼠标所在的受支持显示器。"
        } else {
            stopTap()
            error = "系统没有启用亮度键监听。"
            status = "监听未启动，保留 macOS 原有行为。"
        }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            stopTap()
            permissionGranted = AXIsProcessTrusted()
            status = permissionGranted ? "系统暂停了亮度键监听，可点击“重新检查”恢复。" : "辅助功能权限已撤销，亮度键交由 macOS 处理。"
            return Unmanaged.passUnretained(event)
        }
        guard enabled, isActive, !isShuttingDown else { return Unmanaged.passUnretained(event) }
        // Do not wait for the periodic UI permission check before passing events
        // through when access is revoked.
        guard AXIsProcessTrusted() else {
            permissionGranted = false
            stopTap()
            status = "辅助功能权限已撤销，亮度键交由 macOS 处理。"
            return Unmanaged.passUnretained(event)
        }
        guard type.rawValue == 14, let nsEvent = NSEvent(cgEvent: event),
            let packet = NativeBrightnessKeyPacket.decode(
                eventType: type.rawValue, subtype: nsEvent.subtype.rawValue,
                data1: nsEvent.data1, modifiers: nsEvent.modifierFlags)
        else {
            return Unmanaged.passUnretained(event)
        }
        let target = packet.phase == .down ? targetUnderPointer() : nil
        let decision = routing.route(packet, targetForNewPress: target) { [weak self] in self?.mayAdjust($0) == true }
        if let adjustment = decision.adjustment {
            let expectedGeneration = generation
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == expectedGeneration, self.enabled, self.isActive,
                    !self.isShuttingDown, AXIsProcessTrusted(), self.mayAdjust(adjustment.target)
                else { return }
                self.onAdjust(adjustment.target.displayID, adjustment.delta)
            }
        }
        return decision.consume ? nil : Unmanaged.passUnretained(event)
    }

    private func targetUnderPointer() -> NativeBrightnessKeyTarget? {
        guard !isBlocked(),
            let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }),
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        let id = number.uint32Value
        guard let identity = DisplayIdentity.capture(id) else { return nil }
        return NativeBrightnessKeyTarget(displayID: id, identity: identity)
    }

    private func mayAdjust(_ target: NativeBrightnessKeyTarget) -> Bool {
        guard !isBlocked(), CGDisplayIsOnline(target.displayID) != 0, CGDisplayIsActive(target.displayID) != 0,
            CGDisplayIsAsleep(target.displayID) == 0,
            target.identity.matches(target.displayID),
            !(CGDisplayVendorNumber(target.displayID) == 0x4844 && CGDisplayModelNumber(target.displayID) == 0x5354),
            CGDisplayIsInMirrorSet(target.displayID) == 0
        else { return false }
        return canHandle(target.displayID)
    }

    private func stopTap() {
        generation &+= 1
        routing.reset()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        runLoopSource = nil
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        isActive = false
    }
    private func stopPermissionTimer() {
        permissionTimer?.invalidate()
        permissionTimer = nil
    }
    func shutdown() {
        isShuttingDown = true
        stopTap()
        stopPermissionTimer()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceObservers.removeAll()
    }
    deinit { shutdown() }
}

struct NativeBrightnessKeysView: View {
    @ObservedObject var manager: NativeBrightnessKeyManager
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Toggle("用 F1/F2 亮度键控制鼠标所在屏幕", isOn: Binding(get: { manager.enabled }, set: manager.setEnabled))
                Spacer()
                if manager.enabled {
                    Text(manager.isActive ? "已启用" : "未运行")
                        .font(.caption).foregroundStyle(manager.isActive ? Color.green : Color.secondary)
                }
            }
            Text("只接管键盘发出的亮度调节事件，每次调整 5%。标准 F1/F2 功能键不会被拦截；如有需要，请配合 Fn 使用。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if manager.enabled && !manager.permissionGranted {
                Text("需要在系统设置的“辅助功能”中允许 HiDPI Studio。未授权时保留系统原来的按键行为。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let error = manager.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
            }
            if manager.enabled && !manager.isActive {
                HStack {
                    Button("打开辅助功能设置") { manager.openPermissionSettings() }
                    Button("重新检查") { manager.refreshPermission(retryIfTrusted: true) }
                }
            }
            Text(manager.status).font(.caption).foregroundStyle(.secondary)
            Text("不支持硬件亮度的屏幕、镜像屏，以及带 Command/Control/Option/Shift 的亮度组合键会交给 macOS。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
