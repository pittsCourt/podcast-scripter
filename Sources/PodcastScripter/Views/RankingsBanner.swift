import AppKit
import SwiftUI

/// Power rankings across the window toolbar, with a Sync button. Synced on launch and on demand.
struct RankingsBanner: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let sources = store.rankings?.sources, !sources.isEmpty {
                    ViewThatFits(in: .horizontal) {
                        row(sources, showGroups: true)
                        row(sources, showGroups: false)
                        ScrollView(.horizontal, showsIndicators: false) { row(sources, showGroups: false) }
                    }
                } else {
                    Text(placeholder)
                        .font(.system(size: Zoom.s(12)))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            RankingsSyncButton()
        }
        .frame(height: 30)
        // Extra room so the toolbar doesn't clip the last chip's text.
        .padding(.horizontal, 25)
    }

    private var placeholder: String {
        if case .failed(let message) = store.rankingsSync { return "Power rankings unavailable: \(message)" }
        return "Loading power rankings…"
    }

    private func row(_ sources: [RankingSource], showGroups: Bool) -> some View {
        let groups = Dictionary(grouping: sources, by: \.group)
        let order = ["League", "Region", "World"].filter { groups[$0] != nil }
            + groups.keys.filter { !["League", "Region", "World"].contains($0) }.sorted()
        return HStack(spacing: 12) {
            if showGroups {
                Text("POWER RANKINGS")
                    .font(.system(size: Zoom.s(10.5), weight: .bold))
                    .kerning(0.6)
                    .foregroundStyle(Theme.textTertiary)
            }
            ForEach(Array(order.enumerated()), id: \.element) { index, group in
                if index > 0 || showGroups {
                    Rectangle().fill(Theme.borderStrong).frame(width: 1, height: 16)
                }
                HStack(spacing: 6) {
                    if showGroups { GroupLabel(text: group) }
                    ForEach(groups[group] ?? []) { RankingChip(source: $0) }
                }
            }
        }
        .fixedSize()
    }
}

private struct RankingChip: View {
    var source: RankingSource
    @State private var hovering = false

    var body: some View {
        Button {
            if let url = source.latest?.url { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 6) {
                Text(source.name)
                    .foregroundStyle(Theme.textSecondary)
                if let latest = source.latest {
                    Text(latest.rank.ordinal)
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.textPrimary)
                    ChangeBadge(change: source.change)
                } else {
                    Text("—").foregroundStyle(Theme.textTertiary)
                }
                if source.error != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: Zoom.s(9)))
                        .foregroundStyle(Color(hex: 0xFBBF24))
                }
            }
            .font(.system(size: Zoom.s(12.5)).monospacedDigit())
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(hovering && source.latest?.url != nil ? 0.10 : 0.05))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }

    private var help: String {
        var lines: [String] = []
        if let latest = source.latest {
            let date = latest.day?.formatted(date: .abbreviated, time: .omitted) ?? latest.date
            lines.append("\(source.name): \(latest.rank.ordinal) as of \(date)")
            if let label = latest.label, !label.isEmpty { lines.append(label) }
            if let previous = source.previousRank { lines.append("Previously \(previous.ordinal)") }
            if latest.url != nil { lines.append("Click to open the source") }
        }
        if let error = source.error { lines.append("Last sync failed: \(error)") }
        return lines.joined(separator: "\n")
    }
}

/// ▲3 / ▼2 / – for movement since the previous ranking.
struct ChangeBadge: View {
    var change: Int?

    var body: some View {
        if let change, change != 0 {
            HStack(spacing: 1) {
                Image(systemName: change > 0 ? "arrow.up" : "arrow.down")
                    .font(.system(size: Zoom.s(8), weight: .bold))
                Text("\(abs(change))")
            }
            .foregroundStyle(change > 0 ? Theme.positive : Theme.negative)
        } else if change == 0 {
            Text("–").foregroundStyle(Theme.textTertiary)
        }
    }
}

private struct RankingsSyncButton: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        if store.rankingsSync == .syncing {
            ProgressView().controlSize(.small).frame(width: 26, height: 26)
                .help("Syncing power rankings…")
        } else {
            IconButton(systemName: isFailed ? "exclamationmark.arrow.triangle.2.circlepath" : "arrow.triangle.2.circlepath", help: help) {
                Task { await store.syncRankings() }
            }
        }
    }

    private var isFailed: Bool {
        if case .failed = store.rankingsSync { return true }
        return false
    }

    private var help: String {
        switch store.rankingsSync {
        case .synced(let date): "Sync power rankings (last synced \(date.formatted(date: .omitted, time: .shortened)))"
        case .failed(let message): "Sync failed: \(message). Click to try again."
        case .idle, .syncing: "Sync power rankings"
        }
    }
}
