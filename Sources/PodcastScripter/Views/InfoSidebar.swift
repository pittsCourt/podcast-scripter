import SwiftUI

/// Collapsible right-hand sidebar with reference info (MLS table, club matches).
/// Synced when the app opens and with the Sync button; nothing polls in the background.
struct InfoSidebar: View {
    @Environment(AppStore.self) private var store
    @AppStorage("infoSidebarTab") private var tab = Tab.table

    enum Tab: String, CaseIterable {
        case table
        case matches
        case rankings

        var label: String {
            switch self {
            case .table: "Table"
            case .matches: "Matches"
            case .rankings: "Rankings"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("Show", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                SyncButton()
            }
            .padding(.horizontal, 12)
            .frame(height: 48)
            Divider().overlay(Theme.border)

            switch tab {
            case .table: StandingsView()
            case .matches: MatchesView()
            case .rankings: RankingsChartsView()
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .card()
    }
}

private struct SyncButton: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Group {
            if store.sidebarSync == .syncing || store.rankingsSync == .syncing {
                ProgressView().controlSize(.small).frame(width: 26, height: 26)
            } else {
                IconButton(systemName: isFailed ? "exclamationmark.arrow.triangle.2.circlepath" : "arrow.triangle.2.circlepath", help: help) {
                    Task {
                        async let sidebar: Void = store.syncSidebar(force: true)
                        async let rankings: Void = store.syncRankings()
                        _ = await (sidebar, rankings)
                    }
                }
                .foregroundStyle(isFailed ? Theme.negative : Theme.textSecondary)
            }
        }
    }

    private var isFailed: Bool {
        if case .failed = store.sidebarSync { return true }
        return false
    }

    private var help: String {
        switch store.sidebarSync {
        case .synced(let date): "Sync now (last synced \(date.formatted(date: .omitted, time: .shortened)))"
        case .failed(let message): "Sync failed: \(message). Click to try again."
        case .idle, .syncing: "Sync now"
        }
    }
}

/// Empty state for sidebar tabs: loading, or why there's nothing to show.
struct SidebarPlaceholder: View {
    @Environment(AppStore.self) private var store
    var what: String
    var systemImage: String

    var body: some View {
        switch store.sidebarSync {
        case .idle, .syncing:
            EmptyState(title: "Loading…", systemImage: systemImage)
        case .failed(let message):
            EmptyState(title: "\(what) unavailable", systemImage: systemImage, message: message)
        case .synced:
            EmptyState(title: "No \(what.lowercased())", systemImage: systemImage)
        }
    }
}

// MARK: - Matches

struct MatchesView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        if let matches = store.matches {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if matches.stale {
                        Text("Couldn't reach ESPN; showing the last synced matches.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.negative)
                            .padding(.horizontal, 10)
                    }
                    section("Upcoming", matches.upcoming, empty: "No upcoming matches scheduled.")
                    section("Results", matches.results, empty: "No results yet this season.")
                }
                .padding(.vertical, 14)
                .padding(.horizontal, 8)
            }
        } else {
            SidebarPlaceholder(what: "Matches", systemImage: "sportscourt")
        }
    }

    private func section(_ title: String, _ items: [Match], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            GroupLabel(text: title)
                .padding(.horizontal, 10)
                .padding(.bottom, 2)
            if items.isEmpty {
                Text(empty)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 10)
            } else {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, match in
                    MatchRow(match: match, isNext: title == "Upcoming" && index == 0)
                }
            }
        }
    }
}

private struct MatchRow: View {
    var match: Match
    var isNext: Bool

    var body: some View {
        HoverRow(isSelected: isNext) { _ in
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(match.kickoff?.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) ?? "")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                    if match.result == nil {
                        Text(match.kickoff?.formatted(date: .omitted, time: .shortened) ?? match.status)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .frame(width: 74, alignment: .leading)

                HStack(spacing: 6) {
                    Text(match.isHome ? "vs" : "@")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 16)
                    AsyncImage(url: match.opponent.logo) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        Circle().fill(Color.white.opacity(0.06))
                    }
                    .frame(width: 18, height: 18)
                    Text(match.opponent.shortName ?? match.opponent.name ?? "TBD")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                trailing
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .help(detail)
    }

    @ViewBuilder
    private var trailing: some View {
        if let result = match.result, let goalsFor = match.goalsFor, let goalsAgainst = match.goalsAgainst {
            HStack(spacing: 8) {
                Text("\(goalsFor)–\(goalsAgainst)")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
                Text(result)
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(resultColor(result))
                    .frame(width: 20, height: 18)
                    .background(resultColor(result).opacity(0.15), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
        } else if let broadcast = match.broadcast {
            Text(broadcast)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
        }
    }

    private func resultColor(_ result: String) -> Color {
        switch result {
        case "W": Theme.positive
        case "L": Theme.negative
        default: Theme.textSecondary
        }
    }

    private var detail: String {
        [match.opponent.name, match.venue, match.competition, match.broadcast]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}
