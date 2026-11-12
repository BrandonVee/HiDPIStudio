import AppKit
import ColorSync
import CoreGraphics
import SwiftUI

/// A read-only display inspector inspired by BetterDisplay's device details.
/// It deliberately uses public CoreGraphics information and never changes the
/// display configuration while the user is inspecting it.
struct DisplayDetailsView: View {
    @ObservedObject var displayModel: DisplayModel
    @State private var didCopy = false
    @State private var aliasDraft = ""
    @State private var aliasSaved = false

    private var display: DisplayInfo? { displayModel.currentDisplay }

    var body: some View {
        if let display {
            VStack(alignment: .leading, spacing: 20) {
                overview(display)
                aliasEditor(display)
                HStack(alignment: .top, spacing: 14) {
                    identityCard(display)
                    capabilityCard(display)
                }
                configurationCard(display)
                colorProfileCard(display)
                HStack(spacing: 10) {
                    Button {
                        copyReport(display)
                    } label: {
                        Label(didCopy ? "已复制设备信息" : "复制设备信息", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    Button {
                        displayModel.exportDiagnostics()
                    } label: {
                        Label("导出全部诊断", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    Spacer()
                    Button("刷新") { displayModel.refresh() }
                        .buttonStyle(.borderless)
                }
            }
            .onAppear { syncAlias(for: display) }
            .onChange(of: displayModel.selectedDisplay) { _ in
                didCopy = false
                if let display = displayModel.currentDisplay { syncAlias(for: display) }
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "display.trianglebadge.exclamationmark")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text("尚未检测到显示器").font(.headline)
                Text("连接显示器后重新检测，即可查看设备详情。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("重新检测") { displayModel.refresh() }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 64)
        }
    }

    private func aliasEditor(_ display: DisplayInfo) -> some View {
        HStack(spacing: 12) {
            Label("显示器名称", systemImage: "character.cursor.ibeam")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 105, alignment: .leading)
            TextField("例如：办公桌 4K", text: $aliasDraft)
                .textFieldStyle(.roundedBorder)
                .onSubmit { saveAlias(display) }
            Button("保存") { saveAlias(display) }
                .buttonStyle(.borderedProminent)
                .disabled(aliasDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && displayModel.alias(for: display.id) == nil)
            if aliasSaved {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("已保存")
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.07), lineWidth: 1))
    }

    private func syncAlias(for display: DisplayInfo) {
        aliasDraft = displayModel.alias(for: display.id) ?? ""
        aliasSaved = false
    }

    private func saveAlias(_ display: DisplayInfo) {
        displayModel.setAlias(aliasDraft, for: display.id)
        aliasDraft = displayModel.alias(for: display.id) ?? ""
        aliasSaved = true
    }

    private func overview(_ display: DisplayInfo) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: display.isBuiltin ? "laptopcomputer" : "display")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(StudioStyle.sectionColor(.details))
                .frame(width: 50, height: 50)
                .background(StudioStyle.sectionColor(.details).opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text(display.name).font(.system(size: 18, weight: .semibold))
                Text(display.isBuiltin ? "内置显示器" : "外接显示器")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                statusBadge(display.isMirrored ? "镜像组" : "扩展桌面", symbol: display.isMirrored ? "rectangle.on.rectangle" : "rectangle.on.rectangle.slash")
                if CGDisplayIsMain(display.id) != 0 {
                    statusBadge("主显示器", symbol: "star.fill")
                }
            }
        }
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.primary.opacity(0.07), lineWidth: 1))
    }

    private func identityCard(_ display: DisplayInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("设备身份").font(.system(size: 15, weight: .semibold))
            detailRow("显示器 ID", String(display.id))
            detailRow("厂商 ID", hex(CGDisplayVendorNumber(display.id)))
            detailRow("产品 ID", hex(CGDisplayModelNumber(display.id)))
            detailRow("序列号", String(CGDisplaySerialNumber(display.id)))
            if let identity = DisplayIdentity.capture(display.id) {
                detailRow("ColorSync UUID", identity.uuid, monospaced: false)
            }
        }
        .cardSurface()
    }

    private func capabilityCard(_ display: DisplayInfo) -> some View {
        let rates = Set(display.modes.compactMap { mode -> Double? in mode.refreshRate > 0 ? mode.refreshRate : nil })
        let sortedRates = rates.sorted()
        let hiDPI = display.modes.filter(\.isHiDPI).count
        return VStack(alignment: .leading, spacing: 12) {
            Text("模式能力").font(.system(size: 15, weight: .semibold))
            detailRow("可用模式", "\(display.modes.count) 项")
            detailRow("HiDPI 模式", "\(hiDPI) 项")
            detailRow("刷新率范围", refreshRange(sortedRates))
            detailRow("当前桌面", display.current?.sizeLabel ?? "—")
            detailRow("当前渲染", display.current?.backingLabel ?? "—")
        }
        .cardSurface()
    }

    private func configurationCard(_ display: DisplayInfo) -> some View {
        let millimeters = CGDisplayScreenSize(display.id)
        let inches = sqrt(pow(millimeters.width / 25.4, 2) + pow(millimeters.height / 25.4, 2))
        let rotation = Int(CGDisplayRotation(display.id).rounded())
        let mirror = CGDisplayMirrorsDisplay(display.id)
        return VStack(alignment: .leading, spacing: 12) {
            Text("当前连接状态").font(.system(size: 15, weight: .semibold))
            HStack(spacing: 24) {
                metric("面板尺寸", sizeLabel(millimeters) + (inches > 0 ? String(format: " · %.1f 英寸", inches) : ""))
                Divider().frame(height: 32)
                metric("旋转方向", rotation == 0 ? "横向" : "\(rotation)°")
                Divider().frame(height: 32)
                metric("镜像来源", mirror == 0 ? "无" : String(mirror))
            }
            Text("尺寸来自 macOS 的显示器描述，可能因 EDID 或转接器信息缺失而显示为 0。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .cardSurface()
    }

    private func colorProfileCard(_ display: DisplayInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ColorSync 色彩配置").font(.system(size: 15, weight: .semibold))
            if let profile = colorProfile(for: display.id) {
                detailRow("配置名称", profile.name, monospaced: false)
                detailRow("色域", profile.isWideGamut ? "广色域" : "标准色域", monospaced: false)
                detailRow("高动态范围", profile.dynamicRangeLabel, monospaced: false)
                detailRow("配置 MD5", profile.md5)
            } else {
                Text("macOS 未返回此显示器的 ColorSync 配置。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text("这里只读当前系统配置；切换色彩配置仍由 macOS 显示器设置管理。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .cardSurface()
    }

    private struct ColorProfileSummary {
        let name: String
        let isWideGamut: Bool
        let isPQBased: Bool
        let isHLGBased: Bool
        let md5: String

        var dynamicRangeLabel: String {
            if isPQBased && isHLGBased { return "PQ / HLG" }
            if isPQBased { return "PQ" }
            if isHLGBased { return "HLG" }
            return "SDR"
        }
    }

    private func colorProfile(for displayID: CGDirectDisplayID) -> ColorProfileSummary? {
        guard let unmanaged = ColorSyncProfileCreateWithDisplayID(displayID) else { return nil }
        let profile = unmanaged.takeRetainedValue()
        let name = ColorSyncProfileCopyDescriptionString(profile)?.takeRetainedValue() as String? ?? "未命名配置"
        let md5 = ColorSyncProfileGetMD5(profile)
        let digest = withUnsafeBytes(of: md5.digest) { Data($0) }
            .map { String(format: "%02x", $0) }
            .joined()
        return ColorProfileSummary(
            name: name,
            isWideGamut: ColorSyncProfileIsWideGamut(profile),
            isPQBased: ColorSyncProfileIsPQBased(profile),
            isHLGBased: ColorSyncProfileIsHLGBased(profile),
            md5: digest)
    }

    private func statusBadge(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(StudioStyle.sectionColor(.details))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(StudioStyle.sectionColor(.details).opacity(0.1), in: Capsule())
    }

    private func detailRow(_ label: String, _ value: String, monospaced: Bool = true) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 86, alignment: .leading)
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .monospaced(monospaced)
                .textSelection(.enabled)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 13, weight: .medium)).monospacedDigit()
        }
    }

    private func copyReport(_ display: DisplayInfo) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report(for: display), forType: .string)
        didCopy = true
    }

    private func report(for display: DisplayInfo) -> String {
        let identity = DisplayIdentity.capture(display.id)
        let rotation = Int(CGDisplayRotation(display.id).rounded())
        let size = CGDisplayScreenSize(display.id)
        let modes = display.modes.map { "  - \($0.sizeLabel) · \($0.backingLabel) · \($0.rateLabel)\($0.isHiDPI ? " · HiDPI" : "")" }
        var lines = [
            "HiDPI Studio 显示器诊断",
            "名称：\(display.name)",
            "显示器 ID：\(display.id)",
            "厂商 ID：\(hex(CGDisplayVendorNumber(display.id)))",
            "产品 ID：\(hex(CGDisplayModelNumber(display.id)))",
            "序列号：\(CGDisplaySerialNumber(display.id))",
            "ColorSync UUID：\(identity?.uuid ?? "—")",
            "主显示器：\(CGDisplayIsMain(display.id) != 0 ? "是" : "否")",
            "镜像来源：\(CGDisplayMirrorsDisplay(display.id) == 0 ? "无" : String(CGDisplayMirrorsDisplay(display.id)))",
            String(format: "物理尺寸：%.0f × %.0f mm", size.width, size.height),
            "旋转：\(rotation)°",
            "当前模式：\(display.current?.sizeLabel ?? "—") · \(display.current?.backingLabel ?? "—") · \(display.current?.rateLabel ?? "—")",
        ]
        if let profile = colorProfile(for: display.id) {
            lines += [
                "ColorSync 配置：\(profile.name)",
                "色域：\(profile.isWideGamut ? "广色域" : "标准色域")",
                "高动态范围：\(profile.dynamicRangeLabel)",
                "配置 MD5：\(profile.md5)",
            ]
        }
        lines += [
            "可用模式：",
        ]
        lines += modes
        return lines.joined(separator: "\n")
    }

    private func hex(_ value: UInt32) -> String { String(format: "0x%04X", value) }

    private func sizeLabel(_ size: CGSize) -> String {
        guard size.width > 0, size.height > 0 else { return "未知" }
        return String(format: "%.0f × %.0f mm", size.width, size.height)
    }

    private func refreshRange(_ rates: [Double]) -> String {
        guard let first = rates.first, let last = rates.last else { return "未报告" }
        if abs(first - last) < 0.01 { return String(format: "%.0f Hz", first) }
        return String(format: "%.0f–%.0f Hz", first, last)
    }
}

private extension View {
    func cardSurface() -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.07), lineWidth: 1))
    }
}
