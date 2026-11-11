import AppKit
import SwiftUI

/// Menu-bar presentation shares the same managers and hardware safeguards as the main window.
struct StatusPanelView: View {
    private enum ControlTab: Hashable {
        case resolution
        case brightness
    }

    @ObservedObject var model: DisplayModel
    @ObservedObject var daily: DailyControlManager
    @ObservedObject var layouts: LayoutProfileManager
    @ObservedObject var workspace: VirtualWorkspace
    @ObservedObject var autoRestore: AutoRestoreManager
    let openSection: (StudioSection) -> Void
    let refresh: () -> Void
    let quit: () -> Void
    var panelWidth: CGFloat = 460

    @State private var activeTab: ControlTab = .resolution
    @State private var resolutionPreviewIDs: [CGDirectDisplayID: String] = [:]
    @State private var resolutionIdentities: [CGDirectDisplayID: DisplayIdentity] = [:]

    private var isConfiguring: Bool {
        model.hasTrial || model.isBusy || layouts.isPending || layouts.isBusy || workspace.isBusy || autoRestore.isBusy
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            iconTabs
            VStack(alignment: .leading, spacing: 8) {
                if model.hasTrial || layouts.isPending {
                    trialNotice
                } else if isConfiguring {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在更新显示设置…").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("DISPLAYS")
                    .font(.system(size: 13, weight: .bold))
                    .tracking(1.1)
                    .foregroundStyle(.secondary)
                    .padding(.top, 5)
                if !model.displays.isEmpty {
                    ScrollView(.vertical) {
                        switch activeTab {
                        case .resolution:
                            resolutionGrid
                        case .brightness:
                            brightnessGrid
                        }
                    }
                    .frame(maxHeight: 440)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "display.trianglebadge.exclamationmark")
                            .font(.system(size: 24)).foregroundStyle(.secondary)
                        Text("尚未检测到显示器").font(.headline)
                        Button("重新检测", action: refresh)
                    }.frame(maxWidth: .infinity).padding(.vertical, 16)
                }
                if let error = model.error ?? layouts.error ?? daily.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.padding(.horizontal, 20).padding(.vertical, 16)
            Divider()
                .overlay(Color.white.opacity(0.14))
                .padding(.horizontal, 20)
            footer
        }
        .frame(width: panelWidth)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(red: 0.055, green: 0.065, blue: 0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.6)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .preferredColorScheme(.dark)
        .tint(StudioStyle.accent)
        .onAppear {
            refreshBrightnessReadings()
        }
        .onChange(of: model.displays.map(\.id)) { _ in refreshBrightnessReadings() }
    }

    private var header: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 7) {
                if let icon = AppBranding.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .accessibilityHidden(true)
                }
                Text("HiDPI Studio")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(model.displays.count) 块显示器")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Menu {
                Button(action: refresh) { Label("刷新显示器", systemImage: "arrow.clockwise") }.disabled(isConfiguring)
                Button {
                    NSWorkspace.shared.open(
                        URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!)
                } label: {
                    Label("系统显示设置…", systemImage: "gearshape")
                }
                Divider()
                Button("退出 HiDPI Studio", action: quit)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("更多操作")
            .padding(.top, 2)
            .padding(.trailing, 16)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var iconTabs: some View {
        HStack(spacing: 5) {
            localTab(.resolution, symbol: "display.2", label: "显示模式")
            localTab(.brightness, symbol: "sun.max.fill", label: "亮度")
            sectionTab(.automation, symbol: "arrow.triangle.2.circlepath")
            sectionTab(.virtual, symbol: "rectangle.on.rectangle")
            sectionTab(.layouts, symbol: "rectangle.3.group")
            sectionTab(.shortcuts, symbol: "keyboard")
            sectionTab(.settings, symbol: "gearshape")
        }
        .padding(6)
        .background(
            Color.white.opacity(0.09),
            in: RoundedRectangle(cornerRadius: 17, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
        )
        .padding(.horizontal, 20)
    }

    private func localTab(_ tab: ControlTab, symbol: String, label: String) -> some View {
        Button { activeTab = tab } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(activeTab == tab ? Color.white : Color.white.opacity(0.58))
                .frame(maxWidth: .infinity, minHeight: 34)
                .background {
                    if activeTab == tab {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(StudioStyle.accent)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(activeTab == tab ? .isSelected : [])
    }

    private func sectionTab(_ section: StudioSection, symbol: String) -> some View {
        Button { openSection(section) } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.58))
                .frame(maxWidth: .infinity, minHeight: 34)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(section.title)
    }

    private var resolutionGrid: some View {
        VStack(spacing: 0) {
            ForEach(model.displays) { display in
                resolutionControls(display)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
                if display.id != model.displays.last?.id {
                    Divider().overlay(Color.white.opacity(0.14)).padding(.horizontal, 14)
                }
            }
        }
        .statusSurface()
    }

    private var brightnessGrid: some View {
        VStack(spacing: 0) {
            ForEach(model.displays) { display in
                brightnessControls(display)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
                if display.id != model.displays.last?.id {
                    Divider().overlay(Color.white.opacity(0.14)).padding(.horizontal, 14)
                }
            }
        }
        .statusSurface()
    }

    private func refreshBrightnessReadings() {
        for display in model.displays {
            daily.refreshSystemBrightness(displayID: display.id)
        }
    }

    private func resolutionGroups(for display: DisplayInfo) -> [ModeGroup] {
        let hiDPI = display.modes.filter(\.isHiDPI)
        var candidates = hiDPI.isEmpty ? display.modes : hiDPI
        if let current = display.current,
            !candidates.contains(where: { $0.width == current.width && $0.height == current.height })
        {
            candidates.append(current)
        }
        // One step per desktop size; refresh-rate variants stay within that step.
        var sizes = Set<String>()
        return ModeGroup.group(candidates).filter {
            sizes.insert($0.representative.sizeLabel).inserted
        }
    }

    private func resolutionControls(_ display: DisplayInfo) -> some View {
        let current = model.renderedMode(for: display)
        let groups = resolutionGroups(for: display)
        let currentIndex = groups.firstIndex {
            $0.representative.width == current?.width && $0.representative.height == current?.height
        } ?? 0
        let previewID = resolutionPreviewIDs[display.id]
        let index = groups.firstIndex { $0.id == previewID } ?? currentIndex
        let preview = previewID.flatMap { id in groups.first { $0.id == id } }?
            .preferred(selectedID: nil, current: current, preferredRate: current?.refreshRate)
        let mode = preview ?? current
        let blocked = isConfiguring || model.hasPendingConfiguration || workspace.hasConnectedScreens
            || model.externalOperationBlocked() || display.isMirrored
        return VStack(spacing: 8) {
            HStack(spacing: 8) {
                Label(display.name, systemImage: display.isBuiltin ? "laptopcomputer" : "display")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button("更多…") {
                    model.selectedDisplay = display.id
                    openSection(.resolution)
                }
                    .buttonStyle(.borderless).font(.system(size: 12))
            }
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(mode?.sizeLabel ?? "显示模式未知")
                        .font(.system(size: 15, weight: .medium)).monospacedDigit()
                    Text((mode?.rateLabel ?? "—") + (mode?.isHiDPI == true ? " · HiDPI" : ""))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
            }
            if groups.count > 1 {
                Slider(
                    value: Binding(
                        get: { Double(index) },
                        set: { value in
                            let next = min(max(Int(value.rounded()), 0), groups.count - 1)
                            resolutionPreviewIDs[display.id] = groups[next].id
                        }),
                    in: 0...Double(groups.count - 1), step: 1,
                    onEditingChanged: { editing in
                        if editing {
                            resolutionIdentities[display.id] = DisplayIdentity.capture(display.id)
                        } else {
                            applyResolution(for: display.id)
                        }
                    })
                    .disabled(blocked)
                    .accessibilityLabel(display.name + " 分辨率")
                    .accessibilityValue(mode?.sizeLabel ?? "未知")
                HStack {
                    Text("更大文字")
                    Spacer()
                    Text(blocked ? "暂不可调整" : "松开后试用")
                    Spacer()
                    Text("更多空间")
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                Text("暂无其他可用分辨率")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func applyResolution(for displayID: CGDirectDisplayID) {
        defer {
            resolutionPreviewIDs[displayID] = nil
            resolutionIdentities[displayID] = nil
        }
        guard let groupID = resolutionPreviewIDs[displayID], let identity = resolutionIdentities[displayID],
            let display = model.display(for: displayID),
            identity.matches(displayID), !isConfiguring, !model.hasPendingConfiguration,
            !workspace.hasConnectedScreens, !model.externalOperationBlocked(),
            let group = resolutionGroups(for: display).first(where: { $0.id == groupID })
        else { return }
        let mode = group.preferred(selectedID: nil, current: display.current, preferredRate: display.current?.refreshRate)
        // Returning to the current desktop size should not change its HiDPI/rate variant.
        guard mode.width != display.current?.width || mode.height != display.current?.height else { return }
        if !mode.isHiDPI { model.showLowResolution = true }
        model.applyNative(displayID: displayID, mode: mode)
    }

    @ViewBuilder private func brightnessControls(_ display: DisplayInfo) -> some View {
        if let reading = daily.nativeReading(for: display.id) {
            let value = daily.systemBrightnessValue(for: display.id) ?? reading.value
            VStack(spacing: 9) {
                HStack {
                    Label(display.name, systemImage: display.isBuiltin ? "laptopcomputer" : "display")
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                }
                HStack {
                    Text(reading.backend == .system ? "系统亮度" : "硬件亮度")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
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
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(display.name, systemImage: display.isBuiltin ? "laptopcomputer" : "display")
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                }
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
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private var trialNotice: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("\(layouts.isPending ? layouts.remaining : model.remaining) 秒内确认显示设置", systemImage: "timer")
                .font(.system(size: 12, weight: .medium)).monospacedDigit()
            HStack {
                Text("未确认将自动恢复").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button("恢复") {
                    if layouts.isPending { layouts.revertTrial() }
                    else { Task { @MainActor in await model.revertTrial() } }
                }.disabled(layouts.isBusy || model.isBusy)
                Button("保留") {
                    if layouts.isPending { layouts.confirmTrial() }
                    else { model.confirmTrial() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(layouts.isBusy || model.isBusy
                    || (layouts.isPending ? layouts.isBlocked() : model.externalOperationBlocked()))
            }
        }
        .controlSize(.small).padding(12)
        .background(StudioStyle.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button { openSection(.settings) } label: {
                Label("设置", systemImage: "gearshape")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 38)
            }
            .buttonStyle(StatusFooterButtonStyle())
            Button(action: quit) {
                Label("退出", systemImage: "power")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 38)
            }
            .buttonStyle(StatusFooterButtonStyle())
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 18)
    }

}

private struct StatusSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                Color.white.opacity(0.085),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
    }
}

private struct StatusFooterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.white.opacity(configuration.isPressed ? 0.72 : 0.82))
            .background(
                Color.white.opacity(configuration.isPressed ? 0.14 : 0.09),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
            )
    }
}

extension View {
    fileprivate func statusSurface() -> some View { modifier(StatusSurface()) }
}
