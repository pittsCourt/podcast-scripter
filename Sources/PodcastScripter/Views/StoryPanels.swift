import AppKit
import SwiftUI

struct StoryQueuePanel: View {
    @Environment(AppStore.self) private var store
    @State private var adding = false

    var body: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "Story Queue", count: store.storyQueue.count) {
                ConnectionIndicator(state: store.connection)
                IconButton(systemName: "arrow.clockwise", help: "Refresh from the notes service") {
                    Task { await store.refresh() }
                }
                IconButton(systemName: "plus", help: "Add a link or note") { adding = true }
            }
            Divider().overlay(Theme.border)

            if store.filteredQueue.isEmpty {
                EmptyState(title: "Queue is empty", systemImage: "tray")
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(store.filteredQueue) { item in
                            SelectableStoryRow(
                                title: item.title,
                                detail: item.body,
                                meta: [item.source, item.createdAt.formatted(.relative(presentation: .named))].compactMap { $0 },
                                kind: item.kind,
                                url: item.url,
                                isSelected: store.selectedStoryIDs.contains(item.id)
                            ) {
                                store.toggleSelection(item.id)
                            }
                        }
                    }
                    .padding(8)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .card()
        .sheet(isPresented: $adding) {
            AddStorySheet()
        }
    }
}

/// RSL News or League News, pulled from the notes service's RSS feeds.
struct NewsPanel: View {
    @Environment(AppStore.self) private var store
    var category: NewsCategory

    private var title: String {
        category == .team ? "\(store.config.team.shortName) News" : "League News"
    }

    var body: some View {
        let items = store.news(in: category)
        VStack(spacing: 0) {
            SectionHeader(title: title, count: items.count)
            Divider().overlay(Theme.border)

            if items.isEmpty {
                EmptyState(
                    title: store.connection == .connecting ? "Loading…" : "No news",
                    systemImage: "newspaper",
                    message: store.searchText.isEmpty ? nil : "Nothing matches your search."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(items) { news in
                            SelectableStoryRow(
                                title: news.headline,
                                detail: news.summary,
                                meta: [news.source, news.publishedAt.formatted(.relative(presentation: .named))].filter { !$0.isEmpty },
                                kind: nil,
                                url: news.url,
                                isSelected: store.selectedStoryIDs.contains(news.id)
                            ) {
                                store.toggleSelection(news.id)
                            }
                        }
                    }
                    .padding(8)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .card()
    }
}

/// Count, Clear, Delete and New Project for everything selected across the queue and news columns.
struct SelectionBar: View {
    @Environment(AppStore.self) private var store
    @State private var choosingProject = false

    var body: some View {
        let count = store.selectedStoryIDs.count
        HStack(spacing: 8) {
            if count == 0 {
                Text("Select stories from the queue or news to add to a project")
                    .foregroundStyle(Theme.textTertiary)
            } else {
                Text("\(count) \(count == 1 ? "story" : "stories") selected")
                    .foregroundStyle(Theme.textPrimary)
                Button("Clear") { store.clearSelection() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Group {
                Button("Delete") { Task { await store.deleteSelected() } }
                    .buttonStyle(SecondaryButtonStyle())
                    .help("Remove from the queue and news (it stays in the inbox page's history)")
                Button("Add to Project…") { choosingProject = true }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(store.projects.isEmpty)
                    .help("Add the selected stories to an existing project")
                    .popover(isPresented: $choosingProject, arrowEdge: .top) {
                        ProjectPicker { id in
                            choosingProject = false
                            Task { await store.addSelected(toProject: id) }
                        }
                    }
                Button("New Project") { Task { await store.createProjectFromSelected() } }
                    .buttonStyle(PrimaryButtonStyle())
            }
            .disabled(count == 0)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 16)
        .frame(height: 48)
        .card()
    }
}

/// Projects to add the selection to, newest episode first.
private struct ProjectPicker: View {
    @Environment(AppStore.self) private var store
    var onPick: (Project.ID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupLabel(text: "Add to project")
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 6)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(store.projects.sorted { $0.episodeDate > $1.episodeDate }) { project in
                        HoverRow { _ in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(project.name)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Theme.textPrimary)
                                Text("\(project.episodeDate.formatted(date: .abbreviated, time: .omitted))  ·  \(project.notes.count) stories")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                        }
                        .onTapGesture { onPick(project.id) }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
            .frame(maxHeight: 320)
        }
        .frame(width: 280)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A checkbox row used by the queue and news panels.
private struct SelectableStoryRow: View {
    var title: String
    var detail: String
    var meta: [String]
    var kind: StoryKind?
    var url: URL?
    var isSelected: Bool
    var toggle: () -> Void

    var body: some View {
        HoverRow(isSelected: isSelected) { _ in
            HStack(alignment: .top, spacing: 10) {
                Checkbox(isOn: isSelected)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(kind == nil ? 3 : 1)
                        Spacer(minLength: 4)
                        if let kind { KindBadge(kind: kind) }
                    }
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(3)
                    }
                    HStack(spacing: 6) {
                        Text(meta.joined(separator: "  ·  "))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                        if let url {
                            Button {
                                NSWorkspace.shared.open(url)
                            } label: {
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            .buttonStyle(.plain)
                            .help("Open in browser")
                        }
                    }
                }
            }
            .padding(10)
        }
        .onTapGesture(perform: toggle)
    }
}

/// Small dot showing whether the notes service is reachable.
private struct ConnectionIndicator: View {
    var state: ConnectionState

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .padding(.horizontal, 4)
            .help(help)
    }

    private var color: Color {
        switch state {
        case .connecting: Theme.textTertiary
        case .online: Theme.positive
        case .offline: Theme.negative
        }
    }

    private var help: String {
        switch state {
        case .connecting: "Connecting to the notes service…"
        case .online(let date): "Synced \(date.formatted(date: .omitted, time: .shortened))"
        case .offline(let reason): "Offline — showing cached stories. \(reason)"
        }
    }
}

struct Checkbox: View {
    var isOn: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(isOn ? Theme.accent : .clear)
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(isOn ? Theme.accent : Theme.textTertiary, lineWidth: 1.25)
            )
            .overlay {
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 15, height: 15)
    }
}

struct KindBadge: View {
    var kind: StoryKind

    var body: some View {
        Label(kind.label, systemImage: kind.symbol)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private var color: Color {
        switch kind {
        case .xPost: Color(hex: 0x60A5FA)
        case .storyNote: Color(hex: 0xFBBF24)
        case .article: Color(hex: 0xA78BFA)
        case .news: Color(hex: 0x34D399)
        }
    }
}

private struct AddStorySheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var sending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add to Story Queue")
                .font(.system(size: 15, weight: .semibold))
                .padding([.horizontal, .top], 20)
            Form {
                Section {
                    TextField("Link or note", text: $input, prompt: Text("Paste an X post or article link, or type a note"), axis: .vertical)
                        .lineLimit(3...8)
                        .labelsHidden()
                } footer: {
                    Text("Links are fetched by the notes service. Anything else becomes a note.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .formStyle(.grouped)
            HStack {
                if sending { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    Task {
                        sending = true
                        if await store.addStory(input: input) { dismiss() }
                        sending = false
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(sending || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 460)
    }
}

struct StoryTrackerPanel: View {
    @Environment(AppStore.self) private var store
    @State private var newTitle = ""
    @State private var adding = false
    @State private var editing: TrackedStory?

    var body: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "Story Tracker", count: store.trackedStories.count) {
                IconButton(systemName: "plus", help: "Track a new story") { adding = true }
            }
            Divider().overlay(Theme.border)

            if store.filteredTrackedStories.isEmpty {
                EmptyState(title: "Nothing tracked", systemImage: "binoculars")
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(store.filteredTrackedStories) { story in
                            TrackedStoryRow(story: story)
                                .onTapGesture { editing = story }
                                .contextMenu {
                                    Button("Edit…") { editing = story }
                                    Button("Stop Tracking", role: .destructive) { store.deleteTrackedStory(story.id) }
                                }
                        }
                    }
                    .padding(8)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .card()
        .alert("Track a story", isPresented: $adding) {
            TextField("e.g. Justen Glad Injury", text: $newTitle)
            Button("Track") {
                store.addTrackedStory(title: newTitle)
                newTitle = ""
            }
            Button("Cancel", role: .cancel) { newTitle = "" }
        }
        .sheet(item: $editing) { story in
            TrackedStorySheet(story: story) { store.updateTrackedStory($0) }
        }
    }
}

private struct TrackedStoryRow: View {
    var story: TrackedStory

    var body: some View {
        HoverRow { _ in
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 6, height: 6)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                VStack(alignment: .leading, spacing: 3) {
                    Text(story.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(story.latestUpdate.isEmpty ? "No updates yet" : story.latestUpdate)
                        .font(.system(size: 12))
                        .foregroundStyle(story.latestUpdate.isEmpty ? Theme.textTertiary : Theme.textSecondary)
                        .lineLimit(2)
                    if let last = story.mentions.last {
                        Text("\(story.mentions.count) \(story.mentions.count == 1 ? "mention" : "mentions")  ·  last in \(last.projectName), \(last.episodeDate.formatted(.dateTime.month(.abbreviated).day()))")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Text(story.lastUpdated.formatted(.relative(presentation: .named)))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(10)
        }
    }
}

private struct TrackedStorySheet: View {
    @State var story: TrackedStory
    var onSave: (TrackedStory) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Tracked Story")
                .font(.system(size: 15, weight: .semibold))
                .padding([.horizontal, .top], 20)
            Form {
                TextField("Story", text: $story.title)
                TextField("Latest update", text: $story.latestUpdate, axis: .vertical)
                    .lineLimit(4...10)
                if !story.mentions.isEmpty {
                    Section("What you’ve said (\(story.mentions.count))") {
                        ForEach(story.mentions.reversed()) { mention in
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(mention.projectName)  ·  \(mention.episodeDate.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Text("“\(mention.excerpt)”")
                                    .font(.system(size: 12))
                                    .italic()
                                if let note = mention.note {
                                    Text(note).font(.system(size: 12))
                                }
                            }
                            .padding(.vertical, 2)
                            .contextMenu {
                                Button("Remove Mention", role: .destructive) {
                                    story.mentions.removeAll { $0.id == mention.id }
                                }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(maxHeight: 520)
            SheetButtons(confirmTitle: "Save", canConfirm: true) { onSave(story) }
        }
        .frame(width: 500)
    }
}

/// Cancel / confirm row used at the bottom of sheets.
struct SheetButtons: View {
    @Environment(\.dismiss) private var dismiss
    var confirmTitle: String
    var canConfirm: Bool
    var onConfirm: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button(confirmTitle) {
                onConfirm()
                dismiss()
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(!canConfirm)
        }
        .padding([.horizontal, .bottom], 20)
    }
}
