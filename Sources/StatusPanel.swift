import AppKit
import SwiftUI

/// Menu-bar presentation shares the same managers and hardware safeguards as the main window.
struct StatusPanelView: View {
    @ObservedObject var model: DisplayModel
    @ObservedObject var daily: DailyControlManager
    @ObservedObject var layouts: LayoutProfileManager
    @ObservedObject var workspace: VirtualWorkspace
    @ObservedObject var autoRestore: AutoRestoreManager
    let openSection: (StudioSection) -> Void
    let refresh: () -> Void
    let quit: () -> Void
    var panelWidth: CGFloat = 380

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var displaySelection
    @State private var resolutionPreviewID: String?
    @State private var resolutionIdentity: DisplayIdentity?

    private var isConfiguring: Bool {
        model.hasTrial || model.isBusy || layouts.isPending || layouts.isBusy || workspace.isBusy || autoRestore.isBusy
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().padding(.horizontal, 16)
            VStack(alignment: .leading, spacing: 8) {
                if !model.displays.isEmpty { displayPicker }
                if model.hasTrial || layouts.isPending {
                    trialNotice
                } else if isConfiguring {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在更新显示设置…").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let display = model.currentDisplay {
                    displayControls(display)
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
            }.padding(14)
            Divider().padding(.horizontal, 16)
            footer
        }
        .frame(width: panelWidth)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial)
        .tint(StudioStyle.accent)
        .onChange(of: model.selectedDisplay) { id in
            resolutionPreviewID = nil
            resolutionIdentity = nil
            model.selectPreferredMode()
            daily.refreshSystemBrightness(displayID: id)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let icon = AppBranding.icon {
                Image(nsImage: icon).resizable().frame(width: 26, height: 26).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("HiDPI Studio").font(.system(size: 14, weight: .semibold))
                Text("\(model.displays.count) 块显示器")
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
                Divider()
                Button("退出 HiDPI Studio", action: quit)
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 18)).foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("更多操作")
        }.padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var displayPicker: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 6)], spacing: 6) {
            ForEach(model.displays) { display in
                let isSelected = model.selectedDisplay == display.id
                Button {
                    model.selectedDisplay = display.id
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: display.isBuiltin ? "laptopcomputer" : "display")
                            .font(.system(size: 17)).frame(width: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(display.name).font(.system(size: 11, weight: .medium)).lineLimit(2).help(display.name)
                            Text(model.renderedMode(for: display)?.sizeLabel ?? "显示模式未知")
                                .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Spacer(minLength: 0)
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isSelected ? StudioStyle.accent : Color.secondary)
                    }
                    .padding(8).frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(StudioStyle.accent.opacity(0.12))
                                .matchedGeometryEffect(id: "display", in: displaySelection)
                        } else {
                            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.035))
                        }
                    }
                }
                .buttonStyle(StudioPressStyle())
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .disabled(isConfiguring)
        .animation(reduceMotion ? nil : StudioStyle.selection, value: model.selectedDisplay)
    }

    private func displayControls(_ display: DisplayInfo) -> some View {
        return VStack(alignment: .leading, spacing: 14) {
            resolutionControls(display)
            Divider()
            brightnessControls(display)
        }.padding(14).statusSurface()
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
        let index = groups.firstIndex { $0.id == resolutionPreviewID } ?? currentIndex
        let preview = resolutionPreviewID.flatMap { id in groups.first { $0.id == id } }?
            .preferred(selectedID: nil, current: current, preferredRate: current?.refreshRate)
        let mode = preview ?? current
        let blocked = isConfiguring || model.hasPendingConfiguration || workspace.hasConnectedScreens
            || model.externalOperationBlocked() || display.isMirrored
        return VStack(spacing: 8) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(mode?.sizeLabel ?? "显示模式未知")
                        .font(.system(size: 15, weight: .medium)).monospacedDigit()
                    Text((mode?.rateLabel ?? "—") + (mode?.isHiDPI == true ? " · HiDPI" : ""))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button("更多…") { openSection(.resolution) }
                    .buttonStyle(.borderless).font(.system(size: 12))
            }
            if groups.count > 1 {
                Slider(
                    value: Binding(
                        get: { Double(index) },
                        set: { value in
                            let next = min(max(Int(value.rounded()), 0), groups.count - 1)
                            resolutionPreviewID = groups[next].id
                        }),
                    in: 0...Double(groups.count - 1), step: 1,
                    onEditingChanged: { editing in
                        if editing {
                            resolutionIdentity = DisplayIdentity.capture(display.id)
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
            resolutionPreviewID = nil
            resolutionIdentity = nil
        }
        guard let groupID = resolutionPreviewID, let identity = resolutionIdentity,
            let display = model.currentDisplay, display.id == displayID,
            identity.matches(displayID), !isConfiguring, !model.hasPendingConfiguration,
            !workspace.hasConnectedScreens, !model.externalOperationBlocked(),
            let group = resolutionGroups(for: display).first(where: { $0.id == groupID })
        else { return }
        let mode = group.preferred(selectedID: nil, current: display.current, preferredRate: display.current?.refreshRate)
        // Returning to the current desktop size should not change its HiDPI/rate variant.
        guard mode.width != display.current?.width || mode.height != display.current?.height else { return }
        if !mode.isHiDPI { model.showLowResolution = true }
        model.selectedMode = mode.id
        model.applyNative()
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
        Button {
            openSection(model.activeSection)
        } label: {
            Label("打开主窗口", systemImage: "macwindow")
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity)
        }.buttonStyle(.borderless).padding(14)
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
