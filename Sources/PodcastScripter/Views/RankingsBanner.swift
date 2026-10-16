import SwiftUI

/// Power rankings shown in the window toolbar.
struct RankingsBanner: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Group {
            if store.rankings.isEmpty {
                // Toolbar items need a non-zero size before rankings load.
                Text("Loading rankings…")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            } else {
                ViewThatFits(in: .horizontal) {
                    row(showGroupTitles: true)
                    row(showGroupTitles: false)
                    ScrollView(.horizontal, showsIndicators: false) { row(showGroupTitles: false) }
                }
            }
        }
        .frame(height: 26)
    }

    private func row(showGroupTitles: Bool) -> some View {
        HStack(spacing: 10) {
            ForEach(Array(store.rankings.enumerated()), id: \.element.id) { index, group in
                if index > 0 {
                    Rectangle().fill(Theme.borderStrong).frame(width: 1, height: 14)
                }
                HStack(spacing: 6) {
                    if showGroupTitles {
                        GroupLabel(text: group.title)
                    }
                    ForEach(group.entries) { RankingChip(entry: $0, group: group.title) }
                }
            }
        }
        .fixedSize()
    }
}

private struct RankingChip: View {
    var entry: RankingEntry
    var group: String

    var body: some View {
        HStack(spacing: 5) {
            Text(entry.source)
                .foregroundStyle(Theme.textSecondary)
            Text(entry.rank.ordinalIfSmall)
                .fontWeight(.semibold)
                .foregroundStyle(Theme.textPrimary)
            if entry.change != 0 {
                HStack(spacing: 1) {
                    Image(systemName: entry.change > 0 ? "arrow.up" : "arrow.down")
                        .font(.system(size: 8, weight: .bold))
                    Text("\(abs(entry.change))")
                }
                .foregroundStyle(entry.change > 0 ? Theme.positive : Theme.negative)
            }
        }
        .font(.system(size: 12).monospacedDigit())
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .help("\(group) · \(entry.source): \(entry.rank) (\(entry.change >= 0 ? "+" : "")\(entry.change))")
    }
}

private extension Int {
    /// "7th" for league-sized ranks, plain numbers for big world rankings.
    var ordinalIfSmall: String {
        guard self < 100 else { return "#\(self)" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        return formatter.string(from: NSNumber(value: self)) ?? String(self)
    }
}
