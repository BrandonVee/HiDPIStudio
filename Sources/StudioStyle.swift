import AppKit
import SwiftUI

/// Shared presentation values; display operations never depend on animation state.
enum StudioStyle {
    static let accent = Color.accentColor
    static let selection = Animation.spring(response: 0.34, dampingFraction: 0.84)
    static let press = Animation.spring(response: 0.24, dampingFraction: 0.76)

    static func sectionColor(_ section: StudioSection) -> Color {
        switch section {
        case .resolution: return .blue
        case .daily: return .orange
        case .automation: return .teal
        case .virtual: return .purple
        case .layouts: return .indigo
        case .shortcuts: return .gray
        }
    }
}

struct StudioSidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct StudioPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .scaleEffect(configuration.isPressed && isEnabled && !reduceMotion ? 0.975 : 1)
            .opacity(!isEnabled ? 0.45 : configuration.isPressed ? 0.8 : 1)
            .animation(reduceMotion ? nil : StudioStyle.press, value: configuration.isPressed)
    }
}

struct StudioNavigationLabel: View {
    let section: StudioSection
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: section.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(
                    StudioStyle.sectionColor(section).gradient,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
                )
                .accessibilityHidden(true)
            Text(section.title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}
