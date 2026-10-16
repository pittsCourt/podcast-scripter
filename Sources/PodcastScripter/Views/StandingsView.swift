import SwiftUI

/// MLS tables (West, East, Overall) with the club's row highlighted. Shown in the info sidebar.
struct StandingsView: View {
    @Environment(AppStore.self) private var store
    @AppStorage("standingsTable") private var selected = "Western"

    private static let overall = "Overall"

    var body: some View {
        if let standings = store.standings {
            VStack(spacing: 0) {
                Picker("Table", selection: $selected) {
                    ForEach(standings.conferences) { Text(shortName($0.name)).tag($0.name) }
                    Text(Self.overall).tag(Self.overall)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

                header
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows(in: standings)) { StandingsRowView(row: $0) }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                Divider().overlay(Theme.border)
                HStack(spacing: 14) {
                    if selected != Self.overall {
                        LegendDot(color: Theme.positive, label: "Playoffs")
                        LegendDot(color: Color(hex: 0xFBBF24), label: "Wild card")
                    }
                    Spacer()
                    Text(standings.season)
                }
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 16)
                .frame(height: 30)
            }
        } else {
            SidebarPlaceholder(what: "Standings", systemImage: "tablecells")
        }
    }

    private func rows(in standings: Standings) -> [StandingsRow] {
        if selected == Self.overall { return standings.combined }
        return standings.conferences.first { $0.name == selected }?.rows
            ?? standings.conferences.first?.rows ?? []
    }

    private func shortName(_ conference: String) -> String {
        switch conference {
        case "Western": "West"
        case "Eastern": "East"
        default: conference
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text("#").frame(width: 26, alignment: .leading)
            Text("Team").frame(maxWidth: .infinity, alignment: .leading)
            ForEach(["P", "W", "D", "L", "GD"], id: \.self) { Text($0).frame(width: StandingsRowView.statWidth) }
            Text("Pts").frame(width: StandingsRowView.pointsWidth)
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(Theme.textTertiary)
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }
}

private struct StandingsRowView: View {
    static let statWidth: CGFloat = 26
    static let pointsWidth: CGFloat = 32

    var row: StandingsRow

    private var isClub: Bool { row.abbreviation == ShowConfig.teamName }

    var body: some View {
        HStack(spacing: 0) {
            Text("\(row.rank)")
                .frame(width: 26, alignment: .leading)
                .foregroundStyle(Theme.textSecondary)
            HStack(spacing: 7) {
                AsyncImage(url: row.logo) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    Circle().fill(Color.white.opacity(0.06))
                }
                .frame(width: 16, height: 16)
                Text(row.shortName)
                    .foregroundStyle(Theme.textPrimary)
                    .fontWeight(isClub ? .semibold : .regular)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(row.team)
            stat(row.played)
            stat(row.wins)
            stat(row.draws)
            stat(row.losses)
            Text(row.goalDifference > 0 ? "+\(row.goalDifference)" : "\(row.goalDifference)")
                .frame(width: Self.statWidth)
                .foregroundStyle(Theme.textSecondary)
            Text("\(row.points)")
                .fontWeight(.semibold)
                .frame(width: Self.pointsWidth)
                .foregroundStyle(Theme.textPrimary)
        }
        .font(.system(size: 12).monospacedDigit())
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isClub ? Theme.accent.opacity(0.14) : .clear)
        )
        .overlay(alignment: .leading) {
            if let color = qualificationColor {
                Capsule().fill(color).frame(width: 3, height: 16)
            }
        }
    }

    private func stat(_ value: Int) -> some View {
        Text("\(value)")
            .frame(width: Self.statWidth)
            .foregroundStyle(Theme.textSecondary)
    }

    private var qualificationColor: Color? {
        switch row.qualification {
        case "playoffs": Theme.positive
        case "wild_card": Color(hex: 0xFBBF24)
        default: nil
        }
    }
}

private struct LegendDot: View {
    var color: Color
    var label: String

    var body: some View {
        HStack(spacing: 5) {
            Capsule().fill(color).frame(width: 3, height: 10)
            Text(label)
        }
    }
}
