import Charts
import SwiftUI

/// One small line chart per ranking source across the season (small multiples).
/// Rank 1 is at the top; hover a chart to read any week.
struct RankingsChartsView: View {
    @Environment(AppStore.self) private var store
    /// nil = the current season.
    @State private var season: Int?
    @State private var past: RankingsSummary?

    private var shown: RankingsSummary? {
        guard let season, season != store.rankings?.season else { return store.rankings }
        return past
    }

    var body: some View {
        if let summary = shown, !summary.sources.isEmpty {
            ScrollView {
                VStack(spacing: 10) {
                    seasonPicker(summary)
                    ForEach(summary.sources) { RankingChartCard(source: $0) }
                }
                .padding(10)
            }
        } else if season != nil {
            EmptyState(title: "Loading season…", systemImage: "chart.line.uptrend.xyaxis")
        } else {
            switch store.rankingsSync {
            case .failed(let message):
                EmptyState(title: "Rankings unavailable", systemImage: "chart.line.uptrend.xyaxis", message: message)
            default:
                EmptyState(title: "Loading…", systemImage: "chart.line.uptrend.xyaxis")
            }
        }
    }

    /// Lists only seasons with saved rankings; 2026 is the first recorded.
    private func seasonPicker(_ summary: RankingsSummary) -> some View {
        let seasons = store.rankings?.seasons ?? summary.seasons
        return HStack {
            GroupLabel(text: "\(summary.season) season")
            Spacer()
            if seasons.count > 1 {
                Picker("Season", selection: Binding(
                    get: { season ?? summary.season },
                    set: { picked in
                        season = picked
                        Task { past = await store.rankings(for: picked) }
                    }
                )) {
                    ForEach(seasons, id: \.self) { Text(String($0)).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
        .padding(.horizontal, 2)
    }
}

private struct RankingChartCard: View {
    var source: RankingSource
    @State private var hovered: RankPoint?

    /// Plotted as -rank so a fixed, top-is-best domain is easy to express.
    private var points: [(date: Date, point: RankPoint)] {
        source.history.compactMap { point in point.day.map { ($0, point) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if points.count >= 2 {
                chart
                footer
            } else if let only = source.latest {
                Text("Tracking started \(only.day?.formatted(date: .abbreviated, time: .omitted) ?? only.date). The graph fills in as new rankings come out.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(source.error ?? "No rankings yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(source.error == nil ? Theme.textTertiary : Theme.negative)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(source.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(readout)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer()
            if let shown = hovered ?? source.latest {
                Text(shown.rank.ordinal)
                    .font(.system(size: 20, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
                if hovered == nil {
                    ChangeBadge(change: source.change)
                        .font(.system(size: 11.5).monospacedDigit())
                }
            }
        }
    }

    /// The hovered week, or what the latest ranking is.
    private var readout: String {
        let point = hovered ?? source.latest
        guard let point else { return source.group }
        let date = point.day?.formatted(.dateTime.month(.abbreviated).day()) ?? point.date
        let scope = source.scale.map { "of \($0)" } ?? source.group.lowercased()
        if let label = point.label, !label.isEmpty, hovered != nil {
            return "\(date) · \(label)"
        }
        return "\(date) · \(scope)"
    }

    private var yDomain: ClosedRange<Int> {
        if let scale = source.scale { return -scale ... -1 }
        let ranks = source.history.map(\.rank)
        let low = ranks.min() ?? 1, high = ranks.max() ?? 1
        let pad = max(2, (high - low) / 5)
        return -(high + pad) ... -max(1, low - pad)
    }

    private var yTicks: [Int] {
        if let scale = source.scale { return [1, 10, 20, scale].map { -$0 } }
        return [] // automatic
    }

    private var chart: some View {
        Chart {
            ForEach(points, id: \.point.id) { item in
                LineMark(x: .value("Date", item.date), y: .value("Rank", -item.point.rank))
                    .foregroundStyle(Theme.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            if let last = points.last {
                PointMark(x: .value("Date", last.date), y: .value("Rank", -last.point.rank))
                    .foregroundStyle(Theme.accent)
                    .symbolSize(60)
            }
            if let hovered, let date = hovered.day {
                RuleMark(x: .value("Date", date))
                    .foregroundStyle(Theme.textTertiary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(x: .value("Date", date), y: .value("Rank", -hovered.rank))
                    .foregroundStyle(Theme.textPrimary)
                    .symbolSize(70)
            }
        }
        .chartYScale(domain: yDomain)
        .chartYAxis {
            if yTicks.isEmpty {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(Theme.border)
                    AxisValueLabel { if let v = value.as(Int.self) { Text("\(-v)") } }
                }
            } else {
                AxisMarks(position: .leading, values: yTicks) { value in
                    AxisGridLine().foregroundStyle(Theme.border)
                    AxisValueLabel { if let v = value.as(Int.self) { Text("\(-v)") } }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .month)) { _ in
                AxisValueLabel(format: .dateTime.month(.narrow))
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            hovered = nearest(to: location, proxy: proxy, geo: geo)
                        case .ended:
                            hovered = nil
                        }
                    }
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(Theme.textTertiary)
        .frame(height: 110)
    }

    private func nearest(to location: CGPoint, proxy: ChartProxy, geo: GeometryProxy) -> RankPoint? {
        guard let plotFrame = proxy.plotFrame else { return nil }
        let x = location.x - geo[plotFrame].origin.x
        guard let date: Date = proxy.value(atX: x) else { return nil }
        return points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }?.point
    }

    private var footer: some View {
        let ranks = source.history.map(\.rank)
        return HStack(spacing: 12) {
            if let best = ranks.min() { Text("Best \(best.ordinal)") }
            if let worst = ranks.max() { Text("Worst \(worst.ordinal)") }
            Spacer()
            Text("\(ranks.count) rankings")
        }
        .font(.system(size: 10.5).monospacedDigit())
        .foregroundStyle(Theme.textTertiary)
    }
}
