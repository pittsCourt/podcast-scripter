import SwiftUI

struct TopBar: View {
    @Environment(AppStore.self) private var store
    @State private var showingSearch = false

    var body: some View {
        @Bindable var store = store
        HStack(spacing: 6) {
            leading
                .frame(width: 200)

            rankings
                .frame(maxWidth: .infinity)

            HStack(spacing: 18) {
                if showingSearch {
                    TextField("Search", text: $store.searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                        .onExitCommand { closeSearch() }
                }
                Button(showingSearch ? "Done" : "Search") {
                    showingSearch ? closeSearch() : (showingSearch = true)
                }
                .keyboardShortcut("f", modifiers: .command)
                Menu("User") {
                    Text("Local user")
                    Divider()
                    Button("Reveal data folder in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([AppStore.defaultFileURL])
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .buttonStyle(.plain)
            .font(.title3)
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 16)
            .frame(height: 34)
            .panel(.black.opacity(0.35))
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
    }

    private func closeSearch() {
        store.searchText = ""
        showingSearch = false
    }

    @ViewBuilder
    private var leading: some View {
        switch store.route {
        case .home:
            Text(ShowConfig.showName)
                .font(.headline)
                .foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .panel(Theme.panelHeader)
        case .editor:
            Button {
                store.route = .home
            } label: {
                Label("Back to projects", systemImage: "chevron.left")
                    .font(.title3)
                    .foregroundStyle(Theme.text)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .panel(Theme.panelHeader)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("[", modifiers: .command)
        }
    }

    private var rankings: some View {
        ViewThatFits(in: .horizontal) {
            rankingsRow(spacing: 28)
            rankingsRow(spacing: 14)
            ScrollView(.horizontal, showsIndicators: false) { rankingsRow(spacing: 14) }
        }
        .font(.callout)
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 16)
        .frame(height: 34)
        .panel(.black.opacity(0.35))
    }

    private func rankingsRow(spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            Text("Power Rankings").fontWeight(.semibold)
            ForEach(store.rankings) { group in
                HStack(spacing: 4) {
                    Text("\(group.title):")
                    ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                        RankingText(entry: entry, trailingComma: index < group.entries.count - 1)
                    }
                }
            }
        }
        .lineLimit(1)
        .fixedSize()
    }
}

private struct RankingText: View {
    var entry: RankingEntry
    var trailingComma: Bool

    var body: some View {
        HStack(spacing: 3) {
            Text("\(entry.source): \(entry.rank.ordinalIfSmall)")
            Text(changeText)
                .foregroundStyle(entry.change > 0 ? Theme.up : entry.change < 0 ? Theme.down : Theme.secondaryText)
            + Text(trailingComma ? "," : "")
        }
    }

    private var changeText: String {
        entry.change == 0 ? "(–)" : "(\(entry.change > 0 ? "+" : "")\(entry.change))"
    }
}

private extension Int {
    /// "7th" for league-sized ranks, plain numbers for big world rankings.
    var ordinalIfSmall: String {
        guard self < 100 else { return String(self) }
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        return formatter.string(from: NSNumber(value: self)) ?? String(self)
    }
}
