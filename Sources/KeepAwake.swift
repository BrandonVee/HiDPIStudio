import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac from putting displays to sleep while the user is working at
/// the desk. The assertion is process-scoped and is always released on exit.
final class KeepAwakeManager: ObservableObject {
    @Published private(set) var enabled: Bool
    @Published private(set) var isActive = false
    @Published var error: String?

    private let defaults: UserDefaults
    private let preferenceKey = "HiDPIStudio.keepAwake.enabled.v1"
    private var assertionID: IOPMAssertionID = IOPMAssertionID(kIOPMNullAssertionID)

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: preferenceKey)
        if enabled { activate() }
    }

    func setEnabled(_ value: Bool) {
        if value {
            activate()
            guard isActive else { return }
        } else {
            deactivate()
        }
        enabled = value
        defaults.set(value, forKey: preferenceKey)
    }

    func shutdown() {
        deactivate()
    }

    private func activate() {
        guard !isActive else { return }
        var id = IOPMAssertionID(kIOPMNullAssertionID)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "HiDPI Studio · 保持显示器唤醒" as CFString,
            &id)
        guard result == kIOReturnSuccess else {
            isActive = false
            enabled = false
            error = "无法开启保持唤醒（\(result)）。请检查系统电源管理设置。"
            return
        }
        assertionID = id
        isActive = true
        error = nil
    }

    private func deactivate() {
        guard assertionID != IOPMAssertionID(kIOPMNullAssertionID) else {
            isActive = false
            return
        }
        IOPMAssertionRelease(assertionID)
        assertionID = IOPMAssertionID(kIOPMNullAssertionID)
        isActive = false
    }

    deinit { deactivate() }
}
