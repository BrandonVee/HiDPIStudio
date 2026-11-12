import AppKit
import SwiftUI

struct StudioView: View {
    @ObservedObject var model: DisplayModel
    @ObservedObject var daily: DailyControlManager
    @ObservedObject var workspace: VirtualWorkspace
    @ObservedObject var layouts: LayoutProfileManager
    @ObservedObject var shortcuts: StudioShortcutManager
    @ObservedObject var brightnessSync: BrightnessSyncManager
    @ObservedObject var autoRestore: AutoRestoreManager
    @ObservedObject var nativeKeys: NativeBrightnessKeyManager
    @ObservedObject var keepAwake: KeepAwakeManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var navigationSelection
    @Namespace private var displaySelection
    private let accent = StudioStyle.accent
    private var selectionAnimation: Animation? { reduceMotion ? nil : StudioStyle.selection }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        heading
                        if let error = model.error {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    Color.orange.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        if model.hasTrial {
                            trialBanner.transition(
                                reduceMotion ? .identity : .opacity.combined(with: .move(edge: .top)))
                        }
                        sectionContent
                            .id(model.activeSection)
                            .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: 8)))
                    }.padding(28)
                        .animation(selectionAnimation, value: model.activeSection)
                        .animation(selectionAnimation, value: model.hasTrial)
                }
                Divider()
                HStack(spacing: 8) {
                    if model.isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "info.circle").foregroundStyle(.secondary)
                    }
                    Text(model.activeSection == .resolution ? model.message : model.activeSection.subtitle).font(
                        .caption
                    ).foregroundStyle(.secondary).lineLimit(2)
                    Spacer(minLength: 0)
                }.padding(.horizontal, 22).padding(.vertical, 12).frame(minHeight: 46)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .tint(accent)
        .frame(minWidth: 900, minHeight: 720)
        .onChange(of: model.selectedDisplay) { _ in model.selectPreferredMode() }
        .onChange(of: model.showLowResolution) { _ in
            if !model.visibleModes.contains(where: { $0.id == model.selectedMode }) { model.selectPreferredMode() }
        }
        .onChange(of: layouts.isPending) { value in if value { model.activeSection = .layouts } }
        .onChange(of: model.hasTrial) { value in if value { model.activeSection = .resolution } }
    }

    private var sectionContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            switch model.activeSection {
            case .resolution:
                if workspace.hasConnectedScreens {
                    Label("独立虚拟屏幕正在运行。请先在“虚拟屏幕与预览”中断开，再保存物理屏幕的分辨率。", systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let display = model.currentDisplay {
                    currentStatus(display)
                    if model.virtualTarget != nil {
                        activeVirtual
                    } else {
                        nativeModes(display)
                        Divider()
                        customSection(display)
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "display.trianglebadge.exclamationmark")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text("尚未检测到显示器")
                            .font(.headline)
                        Text("连接显示器后重新检测，即可开始调整分辨率和亮度。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("重新检测") { model.refresh() }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.isBusy || model.hasTrial)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 56)
                }
            case .daily:
                DailyControlsView(displayModel: model, manager: daily)
            case .details:
                DisplayDetailsView(displayModel: model)
            case .automation:
                BrightnessSyncView(displayModel: model, manager: brightnessSync)
                Divider()
                AutoRestoreView(manager: autoRestore, profiles: layouts.profiles)
            case .virtual:
                VirtualWorkspaceView(displayModel: model, manager: workspace)
            case .layouts:
                LayoutProfilesView(displayModel: model, manager: layouts)
            case .shortcuts:
                NativeBrightnessKeysView(manager: nativeKeys)
                Divider()
                Text("自定义组合键").font(.headline)
                StudioShortcutsView(
                    manager: shortcuts, favoriteNames: daily.favorites.map(\.name),
                    profileNames: layouts.profiles.map(\.name))
            case .settings:
                SoftwareSettingsView(
                    shortcuts: shortcuts, nativeKeys: nativeKeys, brightnessSync: brightnessSync,
                    autoRestore: autoRestore, keepAwake: keepAwake,
                    openSection: { model.activeSection = $0 })
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: AppBranding.icon ?? NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 36, height: 36)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("HiDPI Studio").font(.system(size: 15, weight: .semibold))
                    Text("显示器清晰度工具").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 18).padding(.top, 26).padding(.bottom, 20)
            VStack(spacing: 3) {
                ForEach(StudioSection.allCases) { section in
                    Button {
                        model.activeSection = section
                    } label: {
                        StudioNavigationLabel(section: section, isSelected: model.activeSection == section)
                            .background {
                                if model.activeSection == section {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(accent.opacity(0.14))
                                        .matchedGeometryEffect(id: "section", in: navigationSelection)
                                }
                            }
                    }.buttonStyle(StudioPressStyle())
                        .accessibilityAddTraits(model.activeSection == section ? .isSelected : [])
                        .disabled(
                            model.hasTrial || layouts.isPending || model.isBusy || layouts.isBusy)
                }
            }.padding(.horizontal, 10)
                .animation(selectionAnimation, value: model.activeSection)
            Divider().padding(.horizontal, 18).padding(.vertical, 16)
            Text("显示器").font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.horizontal, 20)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(model.displays) { display in
                        Button {
                            model.selectedDisplay = display.id
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: display.isBuiltin ? "laptopcomputer" : "display").font(
                                    .system(size: 20)
                                )
                                .frame(width: 28).padding(.top, 1)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(display.name).font(.system(size: 13, weight: .medium)).lineLimit(2)
                                    Text(display.isBuiltin ? "内置 · Retina" : "外接显示器").font(.caption).foregroundStyle(
                                        .secondary)
                                }
                                Spacer(minLength: 0)
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background {
                                    if model.selectedDisplay == display.id {
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .fill(accent.opacity(0.1))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                    .strokeBorder(accent.opacity(0.15), lineWidth: 0.5)
                                            )
                                            .matchedGeometryEffect(id: "display", in: displaySelection)
                                    }
                                }
                        }.buttonStyle(StudioPressStyle())
                            .accessibilityAddTraits(model.selectedDisplay == display.id ? .isSelected : [])
                            .disabled(
                                model.hasTrial || model.isBusy || layouts.isPending || layouts.isBusy
                                    || workspace.isBusy)
                    }
                }.padding(8)
                    .animation(selectionAnimation, value: model.selectedDisplay)
            }
            if !model.displays.contains(where: { !$0.isBuiltin }) {
                Label("连接外接屏后，它会自动出现在这里。", systemImage: "cable.connector")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(18)
            }
            Text("关闭窗口后，菜单栏继续运行。")
                .font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.bottom, 18)
        }.frame(width: 232)
            .background(StudioSidebarMaterial())
    }

    private var heading: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 7) {
                Text(model.activeSection.title).font(.system(size: 24, weight: .bold))
                Text(model.activeSection.subtitle)
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer()
            if model.activeSection == .resolution {
                Button("恢复原设置") { Task { @MainActor in await model.restoreAll() } }
                    .disabled(!model.hasChanges || model.isBusy || model.hasTrial || model.externalOperationBlocked())
            }
        }
    }

    private func currentStatus(_ display: DisplayInfo) -> some View {
        let current = model.renderedMode(for: display)
        return VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text(display.name).font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(current?.isHiDPI == true ? "HiDPI 已启用" : "当前为低分辨率")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(current?.isHiDPI == true ? Color.green : Color.orange)
            }
            HStack(spacing: 0) {
                metric("桌面看起来像", current?.sizeLabel ?? "—")
                Divider().frame(height: 35).padding(.horizontal, 24)
                metric("渲染分辨率", current?.backingLabel ?? "—")
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Text(model.virtualTarget == display.id ? "虚拟桌面刷新率" : "刷新率").font(.caption).foregroundStyle(
                        .secondary)
                    Text(current?.rateLabel ?? "—").font(.system(size: 14, weight: .medium)).monospacedDigit()
                }
            }
            if display.isBuiltin {
                Text("这块内置屏幕已支持 Retina。连接外接屏后，选择左侧的外接显示器进行设置。")
                    .font(.caption).foregroundStyle(.secondary)
            } else if display.isMirrored && model.virtualTarget == nil {
                Text("此显示器已处于镜像组中。请先在系统设置中切换为扩展显示，再调整分辨率。")
                    .font(.caption).foregroundStyle(.orange)
            }
        }.padding(18).background(
            Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.primary.opacity(0.07), lineWidth: 1))
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 19, weight: .medium)).monospacedDigit()
        }
    }

    private func nativeModes(_ display: DisplayInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("系统 HiDPI 模式").font(.system(size: 15, weight: .semibold))
                Text(String(model.modeGroups.count) + " 项").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Toggle("显示低分辨率", isOn: $model.showLowResolution).toggleStyle(.checkbox).font(.caption)
                    .disabled(model.hasTrial || model.isBusy)
            }
            HStack(spacing: 8) {
                ForEach([1920, 2304, 2560], id: \.self) { width in
                    Button {
                        model.choosePreset(width: width, height: width * 9 / 16)
                    } label: {
                        Text(String(width) + " × " + String(width * 9 / 16) + (width == 2560 ? " · 2K 桌面" : "")).font(
                            .system(size: 11))
                    }
                }
            }.disabled(model.isBusy || model.hasTrial)
            if model.modeGroups.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("系统没有提供可用的 HiDPI 模式").font(.callout.weight(.medium))
                    Text("可在下方创建自定义 HiDPI 桌面。无需安装显示器驱动。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Text("桌面尺寸").padding(.leading, 32).frame(maxWidth: .infinity, alignment: .leading)
                        Text("渲染分辨率").frame(width: 150, alignment: .leading)
                        Text("刷新率").frame(width: 126, alignment: .leading)
                    }.font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Color.primary.opacity(0.025))
                    Divider()
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 1) {
                                ForEach(model.modeGroups) { group in
                                    modeRow(group, display: display).id(group.id)
                                }
                            }.padding(4)
                        }.frame(height: 248)
                            .onChange(of: model.selectedGroupID) { id in
                                if let id { proxy.scrollTo(id, anchor: .center) }
                            }
                            .onAppear { if let id = model.selectedGroupID { proxy.scrollTo(id, anchor: .center) } }
                    }
                }.background(
                    Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(
                        Color.primary.opacity(0.1), lineWidth: 1))
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    if let chosen = model.chosenMode {
                        Text(
                            "已选：" + chosen.sizeLabel + " · " + chosen.rateLabel
                                + (chosen.isHiDPI ? " · HiDPI" : " · 低分辨率")
                        )
                        .font(.system(size: 12, weight: .medium)).monospacedDigit()
                    }
                    Text("选择后点击试用；确认后退出应用仍生效。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("试用所选模式") { model.applyNative() }
                    .buttonStyle(.borderedProminent).disabled(!model.canApply)
            }
        }
    }

    private func modeRow(_ group: ModeGroup, display: DisplayInfo) -> some View {
        let mode = model.rowMode(group)
        let isSelected = group.modes.contains { $0.id == model.selectedMode }
        let current = group.modes.first { $0.signature == display.current?.signature }
        return HStack(spacing: 12) {
            Button {
                model.selectedMode = mode.id
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 16)).foregroundStyle(isSelected ? accent : Color.secondary)
                        .frame(width: 20)
                        .scaleEffect(isSelected && !reduceMotion ? 1.08 : 1)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(mode.sizeLabel).font(.system(size: 14, weight: .medium)).monospacedDigit()
                        HStack(spacing: 7) {
                            Text(mode.isHiDPI ? "HiDPI · 2×" : "低分辨率")
                                .foregroundStyle(mode.isHiDPI ? accent : Color.secondary)
                            if let current { Text("当前 " + current.rateLabel).foregroundStyle(.secondary) }
                        }.font(.system(size: 10))
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Text(mode.backingLabel).font(.system(size: 13)).monospacedDigit()
                        .foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
                }.contentShape(Rectangle())
            }.buttonStyle(StudioPressStyle())
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityLabel("选择 " + mode.sizeLabel + (mode.isHiDPI ? " HiDPI" : " 低分辨率"))
            Picker("刷新率", selection: Binding(get: { mode.id }, set: { model.selectedMode = $0 })) {
                ForEach(group.modes) { option in
                    Text(option.rateLabel + (option.signature == display.current?.signature ? " · 当前" : "")).tag(
                        option.id)
                }
            }.labelsHidden().pickerStyle(.menu).frame(width: 126)
                .accessibilityLabel(mode.sizeLabel + (mode.isHiDPI ? " HiDPI 刷新率" : " 低分辨率刷新率"))
        }.padding(.horizontal, 10).padding(.vertical, 10)
            .background(
                isSelected ? accent.opacity(0.09) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .animation(selectionAnimation, value: isSelected)
            .disabled(model.hasTrial || model.isBusy)
    }

    private func customSection(_ display: DisplayInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("自定义 HiDPI").font(.system(size: 15, weight: .semibold))
                Text("虚拟屏幕镜像").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("SDR").font(.caption).foregroundStyle(.secondary)
            }
            Text("没有合适的系统模式时，可指定桌面尺寸和刷新率。系统有匹配模式时会优先直接使用。")
                .font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .bottom, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("桌面宽度").font(.caption).foregroundStyle(.secondary)
                    TextField("2560", text: $model.customWidth).textFieldStyle(.roundedBorder).frame(width: 95)
                        .accessibilityLabel("自定义桌面宽度")
                }
                Text("×").foregroundStyle(.secondary).padding(.bottom, 5)
                VStack(alignment: .leading, spacing: 6) {
                    Text("桌面高度").font(.caption).foregroundStyle(.secondary)
                    TextField("1440", text: $model.customHeight).textFieldStyle(.roundedBorder).frame(width: 95)
                        .accessibilityLabel("自定义桌面高度")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("刷新率（Hz）").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 3) {
                        TextField("60", text: $model.customRefreshRate).textFieldStyle(.roundedBorder)
                            .frame(width: 66).accessibilityLabel("自定义刷新率 Hz")
                        Menu {
                            ForEach([24, 30, 50, 60, 75, 90, 100, 120, 144, 165, 180, 200, 240], id: \.self) { rate in
                                Button(String(rate) + " Hz") { model.customRefreshRate = String(rate) }
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 20).accessibilityLabel(
                            "常用刷新率")
                    }
                }
                Spacer(minLength: 8)
                Button("试用自定义 HiDPI") { Task { @MainActor in await model.startVirtual() } }
                    .disabled(!model.customAvailable)
            }.disabled(model.isBusy || model.hasTrial)
            Text("支持输入 24–240 Hz。虚拟刷新率不代表面板实际输出；系统不接受请求时会恢复。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(customFootnote(display)).font(.caption).foregroundStyle(.secondary).fixedSize(
                horizontal: false, vertical: true)
        }
    }
    private func customFootnote(_ display: DisplayInfo) -> String {
        if display.isBuiltin { return "自定义镜像用于外接显示器。内置 Retina 屏幕请使用上方的系统模式。" }
        if !HDVirtualDisplay.isAvailable() { return "当前 macOS 不支持此虚拟屏幕接口，请使用上方的系统模式。" }
        return "4K 屏可先试 2560 × 1440 HiDPI；更大的文字可选 1920 × 1080。2K 面板的清晰度仍受物理像素限制。"
    }
    private var activeVirtual: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("自定义 HiDPI 正在运行", systemImage: "display.2").font(.headline)
            if let size = model.virtualSize {
                Text(
                    String(
                        format: "%d × %d 桌面  →  %d × %d 渲染  →  外接屏", size.width, size.height, size.width * 2,
                        size.height * 2)
                )
                .font(.callout).monospacedDigit()
            }
            if let mode = model.virtualCurrentMode {
                Text("虚拟桌面实际刷新率：" + mode.rateLabel).font(.callout).monospacedDigit()
            }
            Text("面板输出仍受显示器与连接带宽限制。关闭窗口可继续运行，退出应用会停止镜像。")
                .font(.caption).foregroundStyle(.secondary)
            Button("停止自定义 HiDPI") { Task { @MainActor in await model.stopVirtual() } }
                .disabled(model.isBusy || model.hasTrial)
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
    private var trialBanner: some View {
        HStack(spacing: 14) {
            Text("\(model.remaining)").font(.system(size: 27, weight: .semibold, design: .rounded)).monospacedDigit()
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text("显示效果是否正常？").font(.system(size: 13, weight: .semibold))
                Text("倒计时结束会自动恢复。").font(.caption)
            }
            Spacer()
            Button("恢复") { Task { @MainActor in await model.revertTrial() } }.disabled(model.isBusy)
            Button("保留设置") { model.confirmTrial() }.buttonStyle(.borderedProminent).disabled(model.isBusy)
        }.padding(15).background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
