import SwiftUI

/// Application-level preferences collected in one place. Detailed editors stay
/// in their feature sections, while these switches make the main behavior easy
/// to understand and change without opening the macOS Display settings.
struct SoftwareSettingsView: View {
    @ObservedObject var shortcuts: StudioShortcutManager
    @ObservedObject var nativeKeys: NativeBrightnessKeyManager
    @ObservedObject var brightnessSync: BrightnessSyncManager
    @ObservedObject var autoRestore: AutoRestoreManager
    @ObservedObject var keepAwake: KeepAwakeManager
    let openSection: (StudioSection) -> Void

    private var firstError: String? {
        shortcuts.error ?? nativeKeys.error ?? brightnessSync.error ?? autoRestore.error ?? keepAwake.error
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 7) {
                Text("应用行为").font(.system(size: 15, weight: .semibold))
                Text("这些开关只影响 HiDPI Studio，不会修改 macOS 的显示器系统设置。")
                    .font(.callout).foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                toggleRow(
                    icon: "keyboard",
                    title: "全局快捷键",
                    detail: shortcuts.enabled ? "已启用，可在应用运行时使用。" : "关闭时不注册全局组合键。",
                    isOn: Binding(get: { shortcuts.enabled }, set: shortcuts.setEnabled))
                Divider().padding(.leading, 56)
                toggleRow(
                    icon: "sun.max",
                    title: "F1/F2 亮度键",
                    detail: nativeKeys.enabled
                        ? (nativeKeys.permissionGranted ? "已启用，控制鼠标所在的受支持屏幕。" : "等待辅助功能授权。")
                        : "关闭时保留 macOS 原有按键行为。",
                    isOn: Binding(get: { nativeKeys.enabled }, set: nativeKeys.setEnabled))
                Divider().padding(.leading, 56)
                toggleRow(
                    icon: "arrow.triangle.2.circlepath",
                    title: "亮度联动",
                    detail: brightnessSync.enabled ? "已启用，按每块外接屏的比例跟随内置屏。" : "关闭时不自动同步外接屏亮度。",
                    isOn: Binding(get: { brightnessSync.enabled }, set: brightnessSync.setEnabled))
                Divider().padding(.leading, 56)
                toggleRow(
                    icon: "arrow.clockwise",
                    title: "自动恢复",
                    detail: autoRestore.enabled ? "已启用，在唤醒或重连后恢复所选预设。" : "关闭时不自动恢复布局预设。",
                    isOn: Binding(get: { autoRestore.enabled }, set: autoRestore.setEnabled))
                Divider().padding(.leading, 56)
                toggleRow(
                    icon: "moon.zzz",
                    title: "保持显示器唤醒",
                    detail: keepAwake.isActive ? "已启用，防止系统自动关闭显示器。" : "关闭时遵循 macOS 当前的睡眠设置。",
                    isOn: Binding(get: { keepAwake.enabled }, set: keepAwake.setEnabled))
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))

            if let firstError {
                Label(firstError, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("详细配置").font(.system(size: 15, weight: .semibold))
                settingLink(
                    icon: "keyboard",
                    title: "快捷键与亮度键",
                    detail: "选择组合键、查看收藏和布局预设的快捷键。",
                    action: { openSection(.shortcuts) })
                settingLink(
                    icon: "arrow.triangle.2.circlepath",
                    title: "联动与恢复",
                    detail: "选择跟随亮度的显示器和自动恢复的布局预设。",
                    action: { openSection(.automation) })
            }
        }
    }

    private func toggleRow(
        icon: String, title: String, detail: String, isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(StudioStyle.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle(title, isOn: isOn).labelsHidden()
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
    }

    private func settingLink(
        icon: String, title: String, detail: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
