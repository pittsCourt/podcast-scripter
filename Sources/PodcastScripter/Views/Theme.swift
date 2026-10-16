import SwiftUI

enum Theme {
    static let window = Color(red: 0.11, green: 0.10, blue: 0.13)
    static let panel = Color(white: 0.20)
    static let panelHeader = Color(white: 0.30)
    static let card = Color(white: 0.27)
    static let cardHover = Color(white: 0.32)
    static let border = Color.black.opacity(0.6)
    static let text = Color(white: 0.95)
    static let secondaryText = Color(white: 0.65)
    static let up = Color.green
    static let down = Color(red: 1.0, green: 0.45, blue: 0.45)
    static let corner: CGFloat = 6
}

/// Rounded, bordered container used for every panel in the mockups.
struct PanelBackground: ViewModifier {
    var color: Color = Theme.panel

    func body(content: Content) -> some View {
        content
            .background(color, in: RoundedRectangle(cornerRadius: Theme.corner))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner).stroke(Theme.border, lineWidth: 1.5))
    }
}

extension View {
    func panel(_ color: Color = Theme.panel) -> some View {
        modifier(PanelBackground(color: color))
    }
}

struct PanelHeader: View {
    var title: String
    var centered = false
    var trailing: AnyView?

    init(_ title: String, centered: Bool = false, trailing: AnyView? = nil) {
        self.title = title
        self.centered = centered
        self.trailing = trailing
    }

    var body: some View {
        HStack {
            if centered { Spacer() }
            Text(title).font(.title3.weight(.medium))
            Spacer()
            if let trailing { trailing }
        }
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// Card style for list rows; brightens on hover.
struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverCard(isPressed: configuration.isPressed) { configuration.label }
    }

    private struct HoverCard<Content: View>: View {
        var isPressed: Bool
        @ViewBuilder var content: Content
        @State private var hovering = false

        var body: some View {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .panel(hovering || isPressed ? Theme.cardHover : Theme.card)
                .onHover { hovering = $0 }
        }
    }
}

struct ActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout)
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(Color.black.opacity(configuration.isPressed ? 0.6 : 0.85), in: RoundedRectangle(cornerRadius: 4))
            .opacity(isEnabled ? 1 : 0.4)
    }
}
