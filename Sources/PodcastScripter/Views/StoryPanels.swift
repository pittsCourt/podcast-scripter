import SwiftUI

struct StoryQueuePanel: View {
    @Environment(AppStore.self) private var store
    @State private var adding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader("Story queue", trailing: AnyView(
                Button { adding = true } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain)
                    .help("Add a note to the queue")
            ))

            if store.filteredQueue.isEmpty {
                ContentUnavailableView("Queue is empty", systemImage: "tray")
                    .foregroundStyle(Theme.secondaryText)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(store.filteredQueue) { item in
                            StoryQueueRow(item: item, isSelected: store.selectedQueueIDs.contains(item.id)) {
                                store.toggleSelection(item.id)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                }
            }

            HStack(spacing: 20) {
                Button("Create new project with selected") { store.createProjectFromSelected() }
                Button("Delete Selected") { store.deleteSelected() }
            }
            .buttonStyle(ActionButtonStyle())
            .disabled(store.selectedQueueIDs.isEmpty)
            .padding(14)
        }
        .frame(maxHeight: .infinity)
        .panel()
        .sheet(isPresented: $adding) {
            AddStorySheet { store.addStory($0) }
        }
    }
}

private struct StoryQueueRow: View {
    var item: StoryItem
    var isSelected: Bool
    var toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.title2)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(item.title).font(.title3)
                        Spacer()
                        Label(item.kind.label, systemImage: item.kind.symbol)
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                    }
                    Text(item.body)
                        .font(.callout)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(2)
                }
            }
            .foregroundStyle(Theme.text)
            .padding(12)
            .frame(minHeight: 80, alignment: .top)
        }
        .buttonStyle(CardButtonStyle())
    }
}

private struct AddStorySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var item = StoryItem(kind: .storyNote, title: "", body: "")
    var onAdd: (StoryItem) -> Void

    var body: some View {
        Form {
            Picker("Type", selection: $item.kind) {
                ForEach(StoryKind.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            TextField("Title", text: $item.title)
            TextField("Details", text: $item.body, axis: .vertical)
                .lineLimit(4...8)
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
                    onAdd(item)
                    dismiss()
                }
                .disabled(item.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

struct StoryTrackerPanel: View {
    @Environment(AppStore.self) private var store
    @State private var newTitle = ""
    @State private var adding = false
    @State private var editing: TrackedStory?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader("Story Tracker", trailing: AnyView(
                Button { adding = true } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain)
                    .help("Track a new story")
            ))

            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(store.filteredTrackedStories) { story in
                        Button { editing = story } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(story.title).font(.title3)
                                if !story.latestUpdate.isEmpty {
                                    Text(story.latestUpdate)
                                        .font(.callout)
                                        .foregroundStyle(Theme.secondaryText)
                                        .lineLimit(2)
                                }
                                Text("Updated \(story.lastUpdated.formatted(.relative(presentation: .named)))")
                                    .font(.caption)
                                    .foregroundStyle(Theme.secondaryText)
                            }
                            .foregroundStyle(Theme.text)
                            .padding(14)
                            .frame(minHeight: 80, alignment: .topLeading)
                        }
                        .buttonStyle(CardButtonStyle())
                        .contextMenu {
                            Button("Stop tracking", role: .destructive) { store.deleteTrackedStory(story.id) }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
        }
        .frame(maxHeight: .infinity)
        .panel()
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

private struct TrackedStorySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var story: TrackedStory
    var onSave: (TrackedStory) -> Void

    var body: some View {
        Form {
            TextField("Story", text: $story.title)
            TextField("Latest update", text: $story.latestUpdate, axis: .vertical)
                .lineLimit(4...10)
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    onSave(story)
                    dismiss()
                }
            }
        }
    }
}
