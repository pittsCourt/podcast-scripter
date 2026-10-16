import AppKit
import SwiftUI

/// Two columns with a draggable border between them. The split is stored as a fraction, so the
/// columns keep their proportions as the window resizes. Double-click the border to reset it.
struct SplitPair<Leading: View, Trailing: View>: View {
    @Binding var fraction: Double
    var defaultFraction: Double
    var minLeading: CGFloat
    var minTrailing: CGFloat
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    static var handleWidth: CGFloat { 12 }

    var body: some View {
        GeometryReader { geo in
            let available = max(0, geo.size.width - Self.handleWidth)
            let leadingWidth = clamp(available * fraction, available: available)
            HStack(spacing: 0) {
                leading.frame(width: leadingWidth)
                SplitHandle(
                    onDrag: { start, translation in
                        guard available > 0 else { return }
                        fraction = clamp(start + translation, available: available) / available
                    },
                    currentWidth: leadingWidth,
                    onReset: { fraction = defaultFraction }
                )
                .frame(width: Self.handleWidth)
                trailing.frame(width: max(0, available - leadingWidth))
            }
        }
    }

    private func clamp(_ width: CGFloat, available: CGFloat) -> CGFloat {
        guard available >= minLeading + minTrailing else {
            // Too narrow for both minimums: share the space by their minimums' ratio.
            return available * minLeading / max(1, minLeading + minTrailing)
        }
        return min(max(width, minLeading), available - minTrailing)
    }
}

private struct SplitHandle: View {
    var onDrag: (_ startWidth: CGFloat, _ translation: CGFloat) -> Void
    var currentWidth: CGFloat
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
                    .frame(width: 3, height: 40)
                    .opacity(hovering || dragStart != nil ? 1 : 0)
                    .animation(.easeOut(duration: 0.12), value: hovering)
            }
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .onTapGesture(count: 2, perform: onReset)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if dragStart == nil { dragStart = currentWidth }
                        onDrag(dragStart ?? currentWidth, value.translation.width)
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .help("Drag to resize. Double-click to reset.")
    }
}
