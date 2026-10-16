import SwiftUI

/// Tags a highlighted script passage as part of a tracked story, existing or new.
struct TrackStorySheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var excerpt: String
    var scriptID: Script.ID
    /// The passage's own mark in the script, if any; suggested as the story's status.
    var passageStatus: StoryStatus? = nil
    @State private var storyStatus: StoryStatus?

    @State private var choice: Choice = .new
    @State private var newTitle = ""
    /// The update added to the story. Starts as the highlighted text.
    @State private var update = ""
    @State private var search = ""
    @State private var suggestion: StorySuggestion?
    @State private var suggesting = false
    @State private var suggestionError: String?

    enum Choice: Hashable {
        case new
        case existing(TrackedStory.ID)
    }

    private var matches: [TrackedStory] {
        let stories = store.trackedStories.filter { !$0.isResolved }.sorted { $0.lastUpdated > $1.lastUpdated }
        guard !search.isEmpty else { return stories }
        return stories.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }

    private var canSave: Bool {
        guard !update.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch choice {
        case .new: return !newTitle.trimmingCharacters(in: .whitespaces).isEmpty
        case .existing: return true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Track as Story")
                .font(.system(size: Zoom.s(15), weight: .semibold))
                .padding([.horizontal, .top], 20)

            gemmaBanner
                .padding(.horizontal, 20)
                .padding(.top, 10)

            Form {
                Section {
                    TextField("Update", text: $update, axis: .vertical)
                        .lineLimit(3...8)
                        .labelsHidden()
                    if let summary = suggestion?.update, !summary.isEmpty, summary != update {
                        Button {
                            update = summary
                        } label: {
                            Label("Use Gemma’s summary: “\(summary)”", systemImage: "sparkles")
                                .font(.system(size: Zoom.s(11.5)))
                                .multilineTextAlignment(.leading)
                        }
                        .buttonStyle(.link)
                    }
                } header: {
                    Text("Update")
                } footer: {
                    Text("Added to the story’s history and shown as its latest update in the Story Tracker.")
                        .foregroundStyle(.secondary)
                }

                Section("Story") {
                    if choice == .new {
                        TextField("Story name", text: $newTitle, prompt: Text("e.g. Justen Glad Injury"))
                    }
                    if store.trackedStories.count > 6 {
                        TextField("Filter stories", text: $search)
                    }
                    Picker("Story", selection: $choice) {
                        Text("New story…").tag(Choice.new)
                        ForEach(matches) { story in
                            Text(story.mentions.isEmpty ? story.title : "\(story.title)  ·  \(story.mentions.count) mentions")
                                .tag(Choice.existing(story.id))
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }

                Section {
                    StatusPicker(status: $storyStatus)
                } header: {
                    Text("Story status (optional)")
                } footer: {
                    Text(passageStatus.map { "Suggested from the passage’s \($0.label.lowercased()) mark. " } ?? "")
                        + Text("Changes are kept in the story’s history.")
                }
            }
            .formStyle(.grouped)
            .frame(maxHeight: 420)

            SheetButtons(confirmTitle: "Track", canConfirm: canSave) {
                var storyID: TrackedStory.ID?
                if case .existing(let id) = choice { storyID = id }
                // The passage is kept as the mention; a different update text is saved as its note.
                let text = update.trimmingCharacters(in: .whitespacesAndNewlines)
                store.tagPassage(excerpt, in: scriptID, story: storyID, newTitle: newTitle, note: text == excerpt ? nil : text,
                                 passageStatus: passageStatus, storyStatus: .some(storyStatus))
            }
        }
        .frame(width: 460)
        .onChange(of: choice) { suggestStatus() }
        .onAppear {
            update = excerpt
            suggestStatus()
            // Until Gemma answers, suggest the story most recently tagged in this episode.
            if let recent = store.trackedStories(in: scriptID).first { choice = .existing(recent.id) }
        }
        .task { await suggest() }
    }

    /// The passage's mark if it has one, else the chosen story's current status.
    private func suggestStatus() {
        if let passageStatus {
            storyStatus = passageStatus
        } else if case .existing(let id) = choice {
            storyStatus = store.trackedStories.first { $0.id == id }?.status
        } else {
            storyStatus = nil
        }
    }

    @ViewBuilder
    private var gemmaBanner: some View {
        if suggesting {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Gemma is matching this to your tracked stories…")
            }
            .font(.system(size: Zoom.s(11.5)))
            .foregroundStyle(.secondary)
        } else if let suggestion {
            VStack(alignment: .leading, spacing: 6) {
                Label(suggestionSummary(suggestion), systemImage: "sparkles")
                    .font(.system(size: Zoom.s(11.5)))
                    .foregroundStyle(.secondary)
                if let contradiction = suggestion.contradiction {
                    Label(contradiction, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: Zoom.s(12)))
                        .foregroundStyle(Color(hex: 0xFBBF24))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(hex: 0xFBBF24).opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        } else if let suggestionError {
            Label("Gemma couldn’t suggest a story: \(suggestionError)", systemImage: "sparkles")
                .font(.system(size: Zoom.s(11)))
                .foregroundStyle(.tertiary)
                .lineLimit(2)
        }
    }

    private func suggestionSummary(_ suggestion: StorySuggestion) -> String {
        if let id = suggestion.storyId, let story = store.trackedStories.first(where: { $0.id.uuidString == id }) {
            return "Gemma suggests this belongs to “\(story.title)”."
        }
        return "Gemma suggests a new story\(suggestion.newTitle.map { ": “\($0)”" } ?? "")."
    }

    /// Asks Gemma which story this belongs to, then pre-fills the choices (still editable).
    private func suggest() async {
        suggesting = true
        defer { suggesting = false }
        do {
            guard let result = try await store.suggestStory(for: excerpt, in: scriptID) else { return }
            suggestion = result
            if let id = result.storyId, let uuid = UUID(uuidString: id), store.trackedStories.contains(where: { $0.id == uuid }) {
                choice = .existing(uuid)
            } else if let title = result.newTitle, !title.isEmpty {
                choice = .new
                if newTitle.isEmpty { newTitle = title }
            }
        } catch {
            suggestionError = error.localizedDescription
        }
    }
}
