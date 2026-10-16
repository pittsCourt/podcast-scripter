import SwiftUI

enum Theme {
    // Surfaces, darkest to lightest
    static let background = Color(hex: 0x0F0F11)
    static let surface = Color(hex: 0x17171A)
    static let raised = Color(hex: 0x1E1E22)
    static let hover = Color(hex: 0x26262B)

    static let border = Color.white.opacity(0.07)
    static let borderStrong = Color.white.opacity(0.13)

    static let textPrimary = Color(hex: 0xEDEDEF)
    static let textSecondary = Color(hex: 0xA1A1AA)
    static let textTertiary = Color(hex: 0x6E6E78)

    /// RSL claret, brightened to read on dark backgrounds.
    static let accent = Color(hex: 0xD6304F)
    static let positive = Color(hex: 0x4ADE80)
    static let negative = Color(hex: 0xF87171)

    static let radius: CGFloat = 12
    static let rowRadius: CGFloat = 8
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

// MARK: - Containers

extension View {
    /// Top-level panel: subtle surface with a hairline border.
    func card() -> some View {
        background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .strokeBorder(Theme.border)
            )
    }
}

struct SectionHeader<Trailing: View>: View {
    var title: String
    var count: Int?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: Zoom.s(13), weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            if let count {
                Text("\(count)")
                    .font(.system(size: Zoom.s(11), weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Theme.hover, in: Capsule())
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String, count: Int? = nil) {
        self.init(title: title, count: count) { EmptyView() }
    }
}

/// Small uppercase label used to group items inside a panel.
struct GroupLabel: View {
    var text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: Zoom.s(11), weight: .semibold))
            .kerning(0.6)
            .foregroundStyle(Theme.textTertiary)
    }
}

/// A row that highlights on hover. Selection draws an accent tint.
struct HoverRow<Content: View>: View {
    var isSelected = false
    @ViewBuilder var content: (_ hovering: Bool) -> Content
    @State private var hovering = false

    var body: some View {
        content(hovering)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                    .fill(isSelected ? Theme.accent.opacity(0.10) : hovering ? Theme.hover : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                    .strokeBorder(isSelected ? Theme.accent.opacity(0.35) : .clear)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Buttons

struct IconButton: View {
    var systemName: String
    var help: String
    var role: ButtonRole?
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: systemName)
                .font(.system(size: Zoom.s(12), weight: .medium))
                .foregroundStyle(hovering ? (role == .destructive ? Theme.negative : Theme.textPrimary) : Theme.textSecondary)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovering ? Color.white.opacity(0.08) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: Zoom.s(12), weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Theme.accent.opacity(configuration.isPressed ? 0.8 : 1))
            )
            .opacity(isEnabled ? 1 : 0.4)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: Zoom.s(12), weight: .medium))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.12 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Theme.border)
            )
            .opacity(isEnabled ? 1 : 0.4)
    }
}

// MARK: - Empty state

struct EmptyState: View {
    var title: String
    var systemImage: String
    var message: String?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: Zoom.s(22), weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text(title)
                .font(.system(size: Zoom.s(13), weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            if let message {
                Text(message)
                    .font(.system(size: Zoom.s(12)))
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
