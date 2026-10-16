import AppKit
import SwiftUI

/// Two panes with a draggable border between them: side by side (`.horizontal`) or stacked
/// (`.vertical`). The split is stored as a fraction, so the panes keep their proportions as the
/// window resizes. Double-click the border to reset it.
struct SplitPair<Leading: View, Trailing: View>: View {
    var axis: Axis = .horizontal
    @Binding var fraction: Double
    var defaultFraction: Double
    /// Minimum width (horizontal) or height (vertical) of each pane.
    var minLeading: CGFloat
    var minTrailing: CGFloat
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    static var handleSize: CGFloat { 12 }

    var body: some View {
        GeometryReader { geo in
            let length = axis == .horizontal ? geo.size.width : geo.size.height
            let available = max(0, length - Self.handleSize)
            let leadingLength = clamp(available * fraction, available: available)
            let handle = SplitHandle(
                axis: axis,
                currentLength: leadingLength,
                onDrag: { start, translation in
                    guard available > 0 else { return }
                    fraction = clamp(start + translation, available: available) / available
                },
                onReset: { fraction = defaultFraction }
            )

            if axis == .horizontal {
                HStack(spacing: 0) {
                    leading.frame(width: leadingLength)
                    handle.frame(width: Self.handleSize)
                    trailing.frame(width: max(0, available - leadingLength))
                }
            } else {
                VStack(spacing: 0) {
                    leading.frame(height: leadingLength)
                    handle.frame(height: Self.handleSize)
                    trailing.frame(height: max(0, available - leadingLength))
                }
            }
        }
    }

    private func clamp(_ length: CGFloat, available: CGFloat) -> CGFloat {
        guard available >= minLeading + minTrailing else {
            // Too small for both minimums: share the space by their minimums' ratio.
            return available * minLeading / max(1, minLeading + minTrailing)
        }
        return min(max(length, minLeading), available - minTrailing)
    }
}

private struct SplitHandle: View {
    var axis: Axis
    var currentLength: CGFloat
    var onDrag: (_ startLength: CGFloat, _ translation: CGFloat) -> Void
    var onReset: () -> Void

    @State private var hovering = false
    @State private var dragStart: CGFloat?

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .overlay {
                Capsule()
                    .fill(dragStart != nil ? Theme.accent : Theme.borderStrong)
                    .frame(width: axis == .horizontal ? 3 : 40, height: axis == .horizontal ? 40 : 3)
                    .opacity(hovering || dragStart != nil ? 1 : 0)
                    .animation(.easeOut(duration: 0.12), value: hovering)
            }
            .onHover { inside in
                hovering = inside
                if inside {
                    (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                } else {
                    NSCursor.pop()
                }
            }
            .onTapGesture(count: 2, perform: onReset)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if dragStart == nil { dragStart = currentLength }
                        let translation = axis == .horizontal ? value.translation.width : value.translation.height
                        onDrag(dragStart ?? currentLength, translation)
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .help("Drag to resize. Double-click to reset.")
    }
}
