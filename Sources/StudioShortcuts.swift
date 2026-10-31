import AppKit
import Carbon
import SwiftUI

enum StudioShortcutModifiers: String, CaseIterable, Identifiable {
    case controlOption, controlCommand
    var id: String { rawValue }
    var label: String { self == .controlOption ? "Control + Option" : "Control + Command" }
    var symbols: String { self == .controlOption ? "⌃⌥" : "⌃⌘" }
    var carbonFlags: UInt32 { UInt32(controlKey | (self == .controlOption ? optionKey : cmdKey)) }
}

final class StudioShortcutManager: ObservableObject {
    @Published private(set) var enabled = false
    @Published var modifiers: StudioShortcutModifiers
    @Published var error: String?
    var onFavorite: (Int) -> Void = { _ in }
    var onProfile: (Int) -> Void = { _ in }
    var onOpen: () -> Void = {}
    var onResetFilters: () -> Void = {}
    var onBrightness: (Double) -> Void = { _ in }
    private var hotKeys: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private let defaults: UserDefaults
    private let signature: OSType = 0x48445354

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        modifiers = StudioShortcutModifiers(rawValue: defaults.string(forKey: "shortcutModifiers.v1") ?? "") ?? .controlOption
    }
    func restorePreference() {
        if defaults.bool(forKey: "shortcutsEnabled.v1") { setEnabled(true) }
    }
    func setEnabled(_ value: Bool) {
        unregister()
        error = nil
        guard value else { defaults.set(false, forKey: "shortcutsEnabled.v1"); return }
        do {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var identifier = EventHotKeyID()
                let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                              nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
                guard result == noErr else { return result }
                let owner = Unmanaged<StudioShortcutManager>.fromOpaque(context).takeUnretainedValue()
                guard identifier.signature == owner.signature else { return OSStatus(eventNotHandledErr) }
                DispatchQueue.main.async { [weak owner] in owner?.invoke(identifier.id) }
                return noErr
            }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard status == noErr else { throw DisplayFailure(message: "无法注册快捷键事件（\(status)）。") }
            let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
            for (index, key) in digits.enumerated() {
                try register(key: UInt32(key), flags: modifiers.carbonFlags, id: UInt32(index + 1))
                try register(key: UInt32(key), flags: modifiers.carbonFlags | UInt32(shiftKey), id: UInt32(index + 101))
            }
            try register(key: UInt32(kVK_ANSI_0), flags: modifiers.carbonFlags, id: 201)
            try register(key: UInt32(kVK_ANSI_R), flags: modifiers.carbonFlags, id: 202)
            try register(key: UInt32(kVK_ANSI_Equal), flags: modifiers.carbonFlags, id: 203)
            try register(key: UInt32(kVK_ANSI_Minus), flags: modifiers.carbonFlags, id: 204)
            enabled = true
            defaults.set(true, forKey: "shortcutsEnabled.v1")
        } catch {
            unregister()
            self.error = error.localizedDescription
            defaults.set(false, forKey: "shortcutsEnabled.v1")
        }
    }
    func setModifiers(_ value: StudioShortcutModifiers) {
        let wasEnabled = enabled
        modifiers = value
        defaults.set(value.rawValue, forKey: "shortcutModifiers.v1")
        if wasEnabled { setEnabled(true) }
    }
    private func register(key: UInt32, flags: UInt32, id: UInt32) throws {
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(key, flags, EventHotKeyID(signature: signature, id: id), GetApplicationEventTarget(), 0, &reference)
        guard status == noErr, let reference else {
            throw DisplayFailure(message: "快捷键被其他应用占用或无法注册（\(status)）。请尝试另一组组合键。")
        }
        hotKeys.append(reference)
    }
    private func invoke(_ id: UInt32) {
        guard enabled else { return }
        switch id {
        case 1...9: onFavorite(Int(id - 1))
        case 101...109: onProfile(Int(id - 101))
        case 201: onOpen()
        case 202: onResetFilters()
        case 203: onBrightness(0.05)
        case 204: onBrightness(-0.05)
        default: break
        }
    }
    func shutdown() { unregister() }
    private func unregister() {
        hotKeys.forEach { UnregisterEventHotKey($0) }; hotKeys.removeAll()
        if let handler { RemoveEventHandler(handler); self.handler = nil }
        enabled = false
    }
    deinit { unregister() }
}

struct StudioShortcutsView: View {
    @ObservedObject var manager: StudioShortcutManager
    let favoriteNames: [String]
    let profileNames: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Toggle("启用全局快捷键", isOn: Binding(get: { manager.enabled }, set: manager.setEnabled))
                Spacer()
                Picker("组合键", selection: Binding(get: { manager.modifiers }, set: manager.setModifiers)) {
                    ForEach(StudioShortcutModifiers.allCases) { item in Text(item.label).tag(item) }
                }.frame(width: 260)
            }
            if let error = manager.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            VStack(spacing: 0) {
                action("打开 HiDPI Studio", keys: manager.modifiers.symbols + "0")
                action("增加／减少所选屏幕亮度", keys: manager.modifiers.symbols + "＝ / −")
                action("移除全部软件滤镜", keys: manager.modifiers.symbols + "R")
            }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            group("收藏分辨率", names: favoriteNames, prefix: manager.modifiers.symbols,
                  empty: "在“日常控制”中收藏分辨率后，可用数字键快速试用。")
            group("显示配置", names: profileNames, prefix: manager.modifiers.symbols + "⇧",
                  empty: "在“布局与预设”中保存配置后，可用组合键快速试用。")
            Text("按列表顺序对应前 9 项。切换分辨率或布局仍需确认；快捷键仅在应用运行时有效。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func action(_ name: String, keys: String) -> some View {
        HStack {
            Text(name).font(.system(size: 13))
            Spacer()
            Text(keys).font(.system(size: 13, weight: .medium, design: .monospaced)).padding(.horizontal, 9).padding(.vertical, 5)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
        }.padding(12)
    }
    private func group(_ title: String, names: [String], prefix: String, empty: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            if names.isEmpty { Text(empty).font(.callout).foregroundStyle(.secondary) }
            else {
                VStack(spacing: 0) {
                    ForEach(Array(names.prefix(9).enumerated()), id: \.offset) { index, name in
                        action(name, keys: prefix + String(index + 1))
                    }
                }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}
