import AppKit
import SwiftUI

/// Menu-bar presentation shares the same managers and hardware safeguards as the main window.
struct StatusPanelView: View {
    @ObservedObject var model: DisplayModel
    @ObservedObject var daily: DailyControlManager
    @ObservedObject var layouts: LayoutProfileManager
    @ObservedObject var workspace: VirtualWorkspace
    @ObservedObject var brightnessSync: BrightnessSyncManager
    @ObservedObject var autoRestore: AutoRestoreManager
    @ObservedObject var nativeKeys: NativeBrightnessKeyManager
    let openSection: (StudioSection) -> Void
    let applyFavorite: (UUID) -> Void
    let applyProfile: (UUID) -> Void
    let refresh: () -> Void
    let exportDiagnostics: () -> Void
    let about: () -> Void
    let quit: () -> Void
    var panelHeight: CGFloat = 650

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsFilters = false
    @Namespace private var displaySelection

    private var isConfiguring: Bool {
        model.hasTrial || model.isBusy || layouts.isPending || layouts.isBusy || workspace.isBusy || autoRestore.isBusy
    }

    private var activeFollowers: Int {
        brightnessSync.targets.filter { $0.enabled && brightnessSync.connectedScreen(for: $0) != nil }.count
    }

    private var syncDetail: String {
        guard brightnessSync.enabled else { return "外接屏跟随内置屏亮度" }
        if brightnessSync.isBlocked() { return "显示配置操作期间暂停" }
        guard brightnessSync.sourceName != nil else { return "来源屏幕不可用，已暂停" }
        if brightnessSync.sourceError != nil { return "暂时无法读取来源亮度" }
        guard brightnessSync.targets.contains(where: { $0.enabled }) else { return "请在设置中选择外接屏" }
        guard activeFollowers > 0 else { return "已选择的外接屏尚未连接" }
        return "已选择 \(activeFollowers) 块在线外接屏"
    }

    private var restoreProfileName: String? {
        layouts.profiles.first { $0.id == autoRestore.selectedProfileID }?.name
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().padding(.horizontal, 18)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if model.hasTrial || layouts.isPending {
                        trialNotice
                    } else if isConfiguring {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在更新显示设置…").font(.caption).foregroundStyle(.secondary)
                        }.padding(.horizontal, 4)
                    }
                    if let display = model.currentDisplay {
                        if model.displays.count > 1 { displayPicker }
                        displayControls(display)
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "display.trianglebadge.exclamationmark")
                                .font(.system(size: 28)).foregroundStyle(.secondary)
                            Text("尚未检测到显示器").font(.headline)
                            Button("重新检测", action: refresh)
                        }.frame(maxWidth: .infinity).padding(.vertical, 24)
                    }
                    savedSettings
                    automation
                    shortcuts
                    if let error = daily.error ?? brightnessSync.error ?? autoRestore.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(16)
            }
            Divider().padding(.horizontal, 18)
            footer
        }
        .frame(width: 368, height: panelHeight)
        .background(.regularMaterial)
        .tint(StudioStyle.accent)
        .onChange(of: model.selectedDisplay) { id in
            showsFilters = false
            daily.refreshSystemBrightness(displayID: id)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let icon = AppBranding.icon {
                Image(nsImage: icon).resizable().frame(width: 38, height: 38).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("HiDPI Studio").font(.system(size: 14, weight: .semibold))
                Text("显示控制中心 · \(model.displays.count) 块显示器")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Menu {
                Button(action: refresh) { Label("刷新显示器", systemImage: "arrow.clockwise") }.disabled(isConfiguring)
                Button {
                    NSWorkspace.shared.open(
                        URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!)
                } label: {
                    Label("系统显示设置…", systemImage: "gearshape")
                }
                Button(action: exportDiagnostics) { Label("导出显示诊断…", systemImage: "square.and.arrow.up") }
                    .disabled(isConfiguring)
                Divider()
                Button("关于 HiDPI Studio", action: about)
                Button("退出 HiDPI Studio", action: quit)
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 18)).foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("更多操作")
        }.padding(.horizontal, 18).padding(.vertical, 15)
    }

    private var displayPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.displays) { display in
                    Button {
                        model.selectedDisplay = display.id
                    } label: {
                        Label(display.name, systemImage: display.isBuiltin ? "laptopcomputer" : "display")
                            .font(.system(size: 11, weight: .medium)).lineLimit(1)
                            .padding(.horizontal, 11).padding(.vertical, 8)
                            .background {
                                if model.selectedDisplay == display.id {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(StudioStyle.accent.opacity(0.14))
                                        .matchedGeometryEffect(id: "display", in: displaySelection)
                                }
                            }
                    }
                    .buttonStyle(StudioPressStyle())
                    .accessibilityAddTraits(model.selectedDisplay == display.id ? .isSelected : [])
                }
            }
        }
        .disabled(isConfiguring)
        .animation(reduceMotion ? nil : StudioStyle.selection, value: model.selectedDisplay)
    }

    private func displayControls(_ display: DisplayInfo) -> some View {
        let mode = model.renderedMode(for: display)
        return VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 12) {
                Image(systemName: display.isBuiltin ? "laptopcomputer" : "display")
                    .font(.system(size: 26, weight: .light)).foregroundStyle(StudioStyle.accent)
                    .frame(width: 54, height: 48)
                    .background(
                        StudioStyle.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                    )
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(display.name).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                    HStack(spacing: 5) {
                        Text(display.isBuiltin ? "内置屏幕" : "外接屏幕")
                        Text("·")
                        Text(mode?.isHiDPI == true ? (display.isBuiltin ? "Retina" : "HiDPI 2×") : "标准分辨率")
                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            Button {
                openSection(.resolution)
            } label: {
                HStack(spacing: 6) {
                    Text(mode?.sizeLabel ?? "显示模式").fontWeight(.medium).monospacedDigit()
                    Spacer(minLength: 0)
                    Text(mode?.rateLabel ?? "—").foregroundStyle(.secondary).monospacedDigit()
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(
                        .tertiary)
                }.font(.system(size: 12)).padding(.vertical, 2)
            }.buttonStyle(StudioPressStyle()).help("设置分辨率与刷新率")
            Divider()
            brightnessControls(display)
            DisclosureGroup(isExpanded: $showsFilters) {
                VStack(spacing: 12) {
                    filterSlider(
                        "软件亮度", symbol: "sun.min",
                        value: Binding(
                            get: { daily.adjustment(for: display.id).brightness },
                            set: { daily.setBrightness($0, for: display.id) }), range: 0.2...1)
                    filterSlider(
                        "暖色强度", symbol: "sun.haze",
                        value: Binding(
                            get: { daily.adjustment(for: display.id).warmth },
                            set: { daily.setWarmth($0, for: display.id) }), range: 0...1)
                    HStack {
                        Text("仅调整画面，不改变屏幕背光。")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button("重置") { daily.reset(displayID: display.id) }
                            .font(.system(size: 11)).disabled(daily.adjustment(for: display.id).isNeutral)
                    }
                }
                .padding(.top, 12)
                .disabled(daily.isBlocked() || daily.unavailableReason(for: display.id) != nil)
                if let reason = daily.unavailableReason(for: display.id) {
                    Text(reason).font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                }
            } label: {
                Label("画面滤镜", systemImage: "slider.horizontal.3")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .animation(reduceMotion ? nil : StudioStyle.selection, value: showsFilters)
        }
        .padding(16)
        .statusSurface()
    }

    @ViewBuilder private func brightnessControls(_ display: DisplayInfo) -> some View {
        if let reading = daily.nativeReading(for: display.id) {
            let value = daily.systemBrightnessValue(for: display.id) ?? reading.value
            VStack(spacing: 9) {
                HStack {
                    Text(reading.backend == .system ? "系统亮度" : "硬件亮度")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    if daily.isChangingSystemBrightness(displayID: display.id) {
                        ProgressView().controlSize(.mini).accessibilityLabel("正在应用亮度")
                    }
                    Text(value.formatted(.percent.precision(.fractionLength(0))))
                        .font(.system(size: 11, weight: .medium)).monospacedDigit()
                }
                HStack(spacing: 10) {
                    Image(systemName: "sun.min.fill").font(.system(size: 12)).foregroundStyle(.secondary)
                    Slider(
                        value: Binding(
                            get: { daily.systemBrightnessValue(for: display.id) ?? reading.value },
                            set: { daily.setSystemBrightness($0, for: display.id, expectedIdentity: reading.identity) }),
                        in: 0...1, step: 0.01
                    )
                    .accessibilityLabel(display.name + " 亮度")
                    Image(systemName: "sun.max.fill").font(.system(size: 16)).foregroundStyle(.secondary)
                }.disabled(daily.isBlocked())
                if let error = daily.brightnessError(for: display.id) {
                    Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            HStack(alignment: .top, spacing: 8) {
                if let identity = DisplayIdentity.capture(display.id),
                    daily.readingBrightnessIDs.contains(identity.uuid)
                {
                    ProgressView().controlSize(.small)
                    Text("正在读取屏幕亮度…")
                } else {
                    Image(systemName: "sun.max")
                    Text(daily.nativeUnavailableReason(for: display.id) ?? "亮度尚未读取")
                    Spacer(minLength: 0)
                    Button("重试") { daily.refreshSystemBrightness(displayID: display.id) }.buttonStyle(.borderless)
                }
            }.font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func filterSlider(_ title: String, symbol: String, value: Binding<Double>, range: ClosedRange<Double>)
        -> some View
    {
        VStack(spacing: 5) {
            HStack {
                Label(title, systemImage: symbol).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Text(value.wrappedValue.formatted(.percent.precision(.fractionLength(0))))
                    .font(.system(size: 11)).monospacedDigit()
            }
            Slider(value: value, in: range).accessibilityLabel(title)
        }
    }

    private var savedSettings: some View {
        HStack(spacing: 10) {
            savedMenu("收藏分辨率", detail: "\(daily.favorites.count) 个收藏", symbol: "star.fill", tint: .orange) {
                if daily.favorites.isEmpty { Text("尚未收藏分辨率") }
                ForEach(daily.favorites) { favorite in
                    Button {
                        applyFavorite(favorite.id)
                    } label: {
                        Text(favorite.name + " · " + favorite.displayName)
                    }
                    .disabled(
                        isConfiguring || model.hasPendingConfiguration || workspace.hasConnectedScreens
                            || model.externalOperationBlocked() || favorite.identity.resolve() == nil)
                }
                Divider()
                Button("管理收藏…") { openSection(.daily) }
            }
            savedMenu("布局预设", detail: "\(layouts.profiles.count) 个预设", symbol: "rectangle.3.group.fill", tint: .indigo)
            {
                if layouts.profiles.isEmpty { Text("尚未保存显示配置") }
                ForEach(layouts.profiles) { profile in
                    Button(profile.name) { applyProfile(profile.id) }
                        .disabled(!layouts.canModify || layouts.unavailableReason(for: profile) != nil)
                }
                Divider()
                Button("管理预设…") { openSection(.layouts) }
            }
        }
    }

    private func savedMenu<Content: View>(
        _ title: String, detail: String, symbol: String, tint: Color, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Menu(content: content) {
                Label(title, systemImage: symbol).font(.system(size: 11, weight: .semibold))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).tint(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
                .padding(.leading, 2)
        }
        .padding(13).frame(maxWidth: .infinity, alignment: .leading).statusSurface()
    }

    private var automation: some View {
        VStack(spacing: 12) {
            HStack {
                Text("自动化").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("设置…") { openSection(.automation) }.font(.system(size: 11)).buttonStyle(.borderless)
            }
            Toggle(isOn: Binding(get: { brightnessSync.enabled }, set: brightnessSync.setEnabled)) {
                automationLabel(
                    "亮度联动",
                    detail: syncDetail,
                    symbol: "sun.max", tint: .blue)
            }
            .accessibilityLabel("亮度联动")
            .disabled(!brightnessSync.enabled && brightnessSync.isBlocked())
            Divider()
            Toggle(isOn: Binding(get: { autoRestore.enabled }, set: autoRestore.setEnabled)) {
                automationLabel(
                    "唤醒与重连恢复", detail: restoreProfileName ?? "请先在设置中选择预设",
                    symbol: "arrow.clockwise", tint: .teal)
            }
            .accessibilityLabel("唤醒后恢复显示配置")
            .disabled(!autoRestore.enabled && (restoreProfileName == nil || isConfiguring))
        }
        .toggleStyle(.switch).controlSize(.small)
        .padding(14).statusSurface()
    }

    private func automationLabel(_ title: String, detail: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(tint)
                .frame(width: 24, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    private var shortcuts: some View {
        HStack(spacing: 8) {
            quickLink("显示模式", symbol: "display", section: .resolution)
            quickLink("虚拟屏幕", symbol: "rectangle.on.rectangle", section: .virtual)
            quickLink(nativeKeys.isActive ? "亮度键已开启" : "快捷键", symbol: "keyboard", section: .shortcuts)
        }
    }

    private func quickLink(_ title: String, symbol: String, section: StudioSection) -> some View {
        Button {
            openSection(section)
        } label: {
            VStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(StudioStyle.sectionColor(section))
                Text(title).font(.system(size: 10)).lineLimit(1).minimumScaleFactor(0.9)
            }.frame(maxWidth: .infinity).padding(.vertical, 13).statusSurface()
        }.buttonStyle(StudioPressStyle())
    }

    private var trialNotice: some View {
        Button {
            openSection(layouts.isPending ? .layouts : .resolution)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "timer").font(.system(size: 18))
                VStack(alignment: .leading, spacing: 3) {
                    Text(
                        (layouts.isPending ? layouts.remaining : model.remaining) > 0
                            ? "\(layouts.isPending ? layouts.remaining : model.remaining) 秒内确认显示设置"
                            : "显示配置需要处理"
                    )
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    Text("打开主窗口，保留设置或恢复。").font(.system(size: 11))
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption)
            }.foregroundStyle(StudioStyle.accent).padding(12)
                .background(StudioStyle.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }.buttonStyle(StudioPressStyle())
    }

    private var footer: some View {
        HStack {
            Button {
                openSection(model.activeSection)
            } label: {
                Label("打开主窗口", systemImage: "macwindow")
                    .font(.system(size: 12, weight: .medium))
            }.buttonStyle(.borderless)
            Spacer()
            Button {
                openSection(.layouts)
            } label: {
                Image(systemName: "rectangle.3.group").font(.system(size: 14))
            }.buttonStyle(.borderless).help("布局与预设").accessibilityLabel("布局与预设")
        }.padding(.horizontal, 20).padding(.vertical, 14)
    }
}

private struct StatusSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                Color(nsColor: .controlBackgroundColor).opacity(0.8),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
    }
}

extension View {
    fileprivate func statusSurface() -> some View { modifier(StatusSurface()) }
}
