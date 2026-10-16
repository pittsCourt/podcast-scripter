import SwiftUI

/// App-wide zoom (View → Zoom In/Out, ⌘+ / ⌘− / ⌘0). Text sizes and key widths are multiplied by
/// `factor`; the script editor zooms its page with NSScrollView magnification instead, so the
/// saved formatting is untouched. Changing the zoom rebuilds the window's views.
@MainActor
enum Zoom {
    static let key = "zoom"
    static let steps: [Double] = [0.8, 0.9, 1.0, 1.1, 1.2, 1.35, 1.5, 1.6]

    /// Set from the saved zoom before views are built.
    static var factor: CGFloat = CGFloat(UserDefaults.standard.double(forKey: key)).clampedZoom

    /// A size scaled by the current zoom.
    static func s(_ value: CGFloat) -> CGFloat { value * factor }

    static func next(after value: Double, up: Bool) -> Double {
        if up { return steps.first { $0 > value + 0.001 } ?? steps.last! }
        return steps.last { $0 < value - 0.001 } ?? steps.first!
    }
}

private extension CGFloat {
    var clampedZoom: CGFloat { self == 0 ? 1 : Swift.min(1.6, Swift.max(0.8, self)) }
}

/// The View menu's zoom commands.
struct ZoomCommands: Commands {
    @AppStorage(Zoom.key) private var zoom = 1.0

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Divider()
            Button("Zoom In") { zoom = Zoom.next(after: zoom, up: true) }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(zoom >= Zoom.steps.last!)
            Button("Zoom Out") { zoom = Zoom.next(after: zoom, up: false) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(zoom <= Zoom.steps.first!)
            Button("Actual Size") { zoom = 1.0 }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(zoom == 1.0)
            Divider()
        }
    }
}
