import AppKit
import SwiftUI

struct StoryQueuePanel: View {
    @Environment(AppStore.self) private var store
    @State private var adding = false

    var body: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "Story Queue", count: store.storyQueue.count) {
                SelectAllCheckbox(ids: store.filteredQueue.map(\.id))
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
            SectionHeader(title: title, count: items.count) {
                SelectAllCheckbox(ids: items.map(\.id))
            }
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

/// Count, Clear, Delete and New Script for everything selected across the queue and news columns.
struct SelectionBar: View {
    @Environment(AppStore.self) private var store
    @State private var choosingScript = false
    @State private var confirmingDelete = false

    var body: some View {
        let count = store.selectedStoryIDs.count
        HStack(spacing: 8) {
            if count == 0 {
                Text("Select stories from the queue or news to add to a script")
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
                Button("Delete") { confirmingDelete = true }
                    .buttonStyle(SecondaryButtonStyle())
                    .help("Remove from the queue and news (it stays in the inbox page's history)")
                    .confirmationDialog(
                        "Remove \(count) \(count == 1 ? "story" : "stories")?",
                        isPresented: $confirmingDelete
                    ) {
                        Button("Remove", role: .destructive) { Task { await store.deleteSelected() } }
                    } message: {
                        Text("They’ll be removed from the Story Queue and news columns and won’t come back. They’re still kept in the inbox page’s history (localhost:3030), where you can restore them or delete them permanently.")
                    }
                Button("Add to Script…") { choosingScript = true }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(store.scripts.isEmpty)
                    .help("Add the selected stories to an existing script")
                    .popover(isPresented: $choosingScript, arrowEdge: .top) {
                        ScriptPicker { id in
                            choosingScript = false
                            Task { await store.addSelected(toScript: id) }
                        }
                    }
                Button("New Script") { Task { await store.createScriptFromSelected() } }
                    .buttonStyle(PrimaryButtonStyle())
            }
            .disabled(count == 0)
        }
        .font(.system(size: Zoom.s(12)))
        .padding(.horizontal, 16)
        .frame(height: 48)
        .card()
    }
}

/// Scripts to add the selection to, newest episode first.
private struct ScriptPicker: View {
    @Environment(AppStore.self) private var store
    var onPick: (Script.ID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupLabel(text: "Add to script")
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 6)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(store.scripts.sorted { $0.episodeDate > $1.episodeDate }) { script in
                        HoverRow { _ in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(script.name)
                                    .font(.system(size: Zoom.s(13), weight: .medium))
                                    .foregroundStyle(Theme.textPrimary)
                                Text("\(script.episodeDate.formatted(date: .abbreviated, time: .omitted))  ·  \(script.notes.count) stories")
                                    .font(.system(size: Zoom.s(11)))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                        }
                        .onTapGesture { onPick(script.id) }
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
                            .font(.system(size: Zoom.s(13), weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(kind == nil ? 3 : 1)
                        Spacer(minLength: 4)
                        if let kind { KindBadge(kind: kind) }
                    }
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: Zoom.s(12)))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(3)
                    }
                    HStack(spacing: 6) {
                        Text(meta.joined(separator: "  ·  "))
                            .font(.system(size: Zoom.s(11)))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                        if let url {
                            Button {
                                NSWorkspace.shared.open(url)
                            } label: {
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: Zoom.s(11)))
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
    /// Some but not all selected (shown as a dash), for "select all".
    var isMixed = false

    var body: some View {
        let filled = isOn || isMixed
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(filled ? Theme.accent : .clear)
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(filled ? Theme.accent : Theme.textTertiary, lineWidth: 1.25)
            )
            .overlay {
                if isOn || isMixed {
                    Image(systemName: isOn ? "checkmark" : "minus")
                        .font(.system(size: Zoom.s(9), weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 15, height: 15)
            // The inside is transparent when unchecked; make the whole box clickable.
            .contentShape(Rectangle())
    }
}

struct KindBadge: View {
    var kind: StoryKind

    var body: some View {
        Label(kind.label, systemImage: kind.symbol)
            .font(.system(size: Zoom.s(10.5), weight: .medium))
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
                .font(.system(size: Zoom.s(15), weight: .semibold))
                .padding([.horizontal, .top], 20)
            Form {
                Section {
                    TextField("Link or note", text: $input, prompt: Text("Paste an X post or article link, or type a note"), axis: .vertical)
                        .lineLimit(3...8)
                        .labelsHidden()
                } footer: {
                    Text("Links are fetched by the notes service. Anything else becomes a note.")
                        .font(.system(size: Zoom.s(11)))
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
    @State private var pendingStop: TrackedStory?
    @AppStorage("trackerShowsResolved") private var showResolved = false

    var body: some View {
        let stories = showResolved ? store.resolvedStories : store.filteredTrackedStories
        VStack(spacing: 0) {
            SectionHeader(title: "Story Tracker", count: store.filteredTrackedStories.count) {
                Picker("Show", selection: $showResolved) {
                    Text("Active").tag(false)
                    Text("Resolved (\(store.resolvedStories.count))").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
                IconButton(systemName: "plus", help: "Track a new story") {
                    showResolved = false
                    adding = true
                }
            }
            Divider().overlay(Theme.border)

            if stories.isEmpty {
                EmptyState(
                    title: showResolved ? "No resolved stories" : "Nothing tracked",
                    systemImage: showResolved ? "checkmark.seal" : "binoculars",
                    message: showResolved ? "Open a tracked story and choose Resolve Story when it’s over." : nil
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(stories) { story in
                            TrackedStoryRow(story: story)
                                .onTapGesture { editing = story }
                                .contextMenu {
                                    Button("Open…") { editing = story }
                                    if story.isResolved {
                                        Button("Reopen") { store.reopenStory(story.id) }
                                    } else {
                                        Button("Resolve") { store.resolveStory(story.id, resolution: nil) }
                                    }
                                    Menu("Status") {
                                        ForEach(StoryStatus.allCases) { status in
                                            Button("\(status.emoji)  \(status.label)") { store.setStatus(status, ofStory: story.id) }
                                        }
                                        Divider()
                                        Button("No Status") { store.setStatus(nil, ofStory: story.id) }
                                            .disabled(story.status == nil)
                                    }
                                    Divider()
                                    Button("Stop Tracking…", role: .destructive) { pendingStop = story }
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
            TrackedStorySheet(
                story: story,
                onSave: { store.updateTrackedStory($0) },
                onResolve: { updated, note in
                    store.updateTrackedStory(updated)
                    store.resolveStory(updated.id, resolution: note)
                },
                onReopen: { updated in
                    store.updateTrackedStory(updated)
                    store.reopenStory(updated.id)
                }
            )
        }
        .confirmationDialog(
            "Stop tracking “\(pendingStop?.title ?? "")”?",
            isPresented: Binding(get: { pendingStop != nil }, set: { if !$0 { pendingStop = nil } }),
            presenting: pendingStop
        ) { story in
            Button("Stop Tracking", role: .destructive) { store.deleteTrackedStory(story.id) }
        } message: { story in
            Text("The story and its \(story.mentions.count) tagged \(story.mentions.count == 1 ? "mention" : "mentions") will be permanently deleted and no longer stored. This can’t be undone. Your scripts aren’t changed.")
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
                    HStack(spacing: 5) {
                        if let status = story.status {
                            Text(status.emoji)
                                .font(.system(size: Zoom.s(11)))
                                .help(status.label)
                        }
                        Text(story.title)
                            .font(.system(size: Zoom.s(13), weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                    }
                    Text(story.latestUpdate.isEmpty ? "No updates yet" : story.latestUpdate)
                        .font(.system(size: Zoom.s(12)))
                        .foregroundStyle(story.latestUpdate.isEmpty ? Theme.textTertiary : Theme.textSecondary)
                        .lineLimit(2)
                    if let last = story.mentions.last {
                        Text("\(story.mentions.count) \(story.mentions.count == 1 ? "mention" : "mentions")  ·  last in \(last.scriptName), \(last.episodeDate.formatted(.dateTime.month(.abbreviated).day()))")
                            .font(.system(size: Zoom.s(11)))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Text(story.resolvedAt.map { "Resolved \($0.formatted(.dateTime.month(.abbreviated).day()))" }
                     ?? story.lastUpdated.formatted(.relative(presentation: .named)))
                    .font(.system(size: Zoom.s(11)))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(10)
        }
    }
}

private struct TrackedStorySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var story: TrackedStory
    @State private var pendingRemoval: StoryMention?
    @State private var resolution = ""
    var onSave: (TrackedStory) -> Void
    var onResolve: (TrackedStory, String) -> Void
    var onReopen: (TrackedStory) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Tracked Story")
                .font(.system(size: Zoom.s(15), weight: .semibold))
                .padding([.horizontal, .top], 20)
            Form {
                TextField("Story", text: $story.title)
                TextField("Latest update", text: $story.latestUpdate, axis: .vertical)
                    .lineLimit(4...10)
                Section {
                    StatusPicker(status: $story.status)
                    if !story.statusHistory.isEmpty {
                        Text(story.statusHistory.map { "\($0.status.map { "\($0.emoji) \($0.label)" } ?? "No status") (\($0.changedAt.formatted(.dateTime.month(.abbreviated).day())))" }.joined(separator: "  →  "))
                            .font(.system(size: Zoom.s(11)))
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Status (optional)")
                } footer: {
                    Text("Update it as the story develops; each change is kept with its date.")
                        .foregroundStyle(.secondary)
                }
                if !story.mentions.isEmpty {
                    Section("What you’ve said (\(story.mentions.count))") {
                        ForEach(story.mentions.reversed()) { mention in
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(mention.scriptName)  ·  \(mention.episodeDate.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.system(size: Zoom.s(11), weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Text("“\(mention.excerpt)”")
                                    .font(.system(size: Zoom.s(12)))
                                    .italic()
                                if let note = mention.note {
                                    Text(note).font(.system(size: Zoom.s(12)))
                                }
                            }
                            .padding(.vertical, 2)
                            .contextMenu {
                                Button("Remove Mention…", role: .destructive) { pendingRemoval = mention }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(maxHeight: 520)
            resolveRow
            SheetButtons(confirmTitle: "Save", canConfirm: true) { onSave(story) }
        }
        .frame(width: 500)
        .confirmationDialog(
            "Remove this mention?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { mention in
            Button("Remove", role: .destructive) { story.mentions.removeAll { $0.id == mention.id } }
        } message: { mention in
            Text("The passage from \(mention.scriptName) will no longer be stored with this story once you click Save. The script itself isn’t changed.")
        }
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

/// None / Rumor / Reported / Confirmed, as a segmented control.
struct StatusPicker: View {
    @Binding var status: StoryStatus?

    var body: some View {
        Picker("Status", selection: $status) {
            Text("None").tag(StoryStatus?.none)
            ForEach(StoryStatus.allCases) { Text("\($0.emoji) \($0.label)").tag(StoryStatus?.some($0)) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}

private extension TrackedStorySheet {
    /// Resolve (with how it ended) or, for a resolved story, its resolution and Reopen.
    @ViewBuilder
    var resolveRow: some View {
        if let resolvedAt = story.resolvedAt {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label("Resolved \(resolvedAt.formatted(date: .abbreviated, time: .omitted))\(story.resolution.map { ": \($0)" } ?? "")",
                      systemImage: "checkmark.seal.fill")
                    .font(.system(size: Zoom.s(12)))
                    .foregroundStyle(Theme.positive)
                Spacer()
                Button("Reopen") {
                    onReopen(story)
                    dismiss()
                }
                .buttonStyle(SecondaryButtonStyle())
                .help("Move it back to the active Story Tracker")
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 4)
        } else {
            HStack(spacing: 8) {
                TextField("How it ended (optional)", text: $resolution, prompt: Text("e.g. Back in the lineup vs SKC"))
                    .textFieldStyle(.roundedBorder)
                Button("Resolve Story") {
                    onResolve(story, resolution)
                    dismiss()
                }
                .buttonStyle(SecondaryButtonStyle())
                .help("Moves it to the Resolved list, keeping all its history")
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 4)
        }
    }
}

/// Header checkbox: selects every story in a section, or clears them if all are selected.
struct SelectAllCheckbox: View {
    @Environment(AppStore.self) private var store
    var ids: [UUID]

    var body: some View {
        let selected = ids.filter { store.selectedStoryIDs.contains($0) }.count
        Button {
            store.toggleSelectAll(ids)
        } label: {
            HStack(spacing: 5) {
                Checkbox(isOn: !ids.isEmpty && selected == ids.count, isMixed: selected > 0 && selected < ids.count)
                Text("All")
                    .font(.system(size: Zoom.s(11)))
                    .foregroundStyle(Theme.textSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(ids.isEmpty)
        .help(selected == ids.count && !ids.isEmpty ? "Deselect all" : "Select all \(ids.count)")
    }
}
