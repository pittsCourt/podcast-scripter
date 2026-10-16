import SwiftUI

/// Tags a highlighted script passage as part of a tracked story, existing or new.
struct TrackStorySheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var excerpt: String
    var projectID: Project.ID

    @State private var choice: Choice = .new
    @State private var newTitle = ""
    @State private var note = ""
    @State private var search = ""
    @State private var suggestion: StorySuggestion?
    @State private var suggesting = false
    @State private var suggestionError: String?

    enum Choice: Hashable {
        case new
        case existing(TrackedStory.ID)
    }

    private var matches: [TrackedStory] {
        let stories = store.trackedStories.sorted { $0.lastUpdated > $1.lastUpdated }
        guard !search.isEmpty else { return stories }
        return stories.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }

    private var canSave: Bool {
        switch choice {
        case .new: !newTitle.trimmingCharacters(in: .whitespaces).isEmpty
        case .existing: true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Track as Story")
                .font(.system(size: 15, weight: .semibold))
                .padding([.horizontal, .top], 20)

            Text("“\(excerpt)”")
                .font(.system(size: 12))
                .italic()
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .padding(.horizontal, 20)
                .padding(.top, 8)

            gemmaBanner
                .padding(.horizontal, 20)
                .padding(.top, 10)

            Form {
                Section("Story") {
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
                    if choice == .new {
                        TextField("New story title", text: $newTitle, prompt: Text("e.g. Justen Glad Injury"))
                    }
                }
                Section {
                    TextField("Update (optional)", text: $note, prompt: Text("e.g. Back in full training, expected for SKC"), axis: .vertical)
                        .lineLimit(2...4)
                } footer: {
                    Text("Shown as the story’s latest update in the Story Tracker. Leave empty to use the passage.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(maxHeight: 420)

            SheetButtons(confirmTitle: "Track", canConfirm: canSave) {
                var storyID: TrackedStory.ID?
                if case .existing(let id) = choice { storyID = id }
                store.tagPassage(excerpt, in: projectID, story: storyID, newTitle: newTitle, note: note)
            }
        }
        .frame(width: 460)
        .onAppear {
            // Until Gemma answers, suggest the story most recently tagged in this episode.
            if let recent = store.trackedStories(in: projectID).first { choice = .existing(recent.id) }
        }
        .task { await suggest() }
    }

    @ViewBuilder
    private var gemmaBanner: some View {
        if suggesting {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Gemma is matching this to your tracked stories…")
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
        } else if let suggestion {
            VStack(alignment: .leading, spacing: 6) {
                Label(suggestionSummary(suggestion), systemImage: "sparkles")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                if let contradiction = suggestion.contradiction {
                    Label(contradiction, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(hex: 0xFBBF24))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(hex: 0xFBBF24).opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        } else if let suggestionError {
            Label("Gemma couldn’t suggest a story: \(suggestionError)", systemImage: "sparkles")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(2)
        }
    }

    private func suggestionSummary(_ suggestion: StorySuggestion) -> String {
        if let id = suggestion.storyId, let story = store.trackedStories.first(where: { $0.id.uuidString == id }) {
            return "Gemma suggests “\(story.title)” and drafted the update."
        }
        return "Gemma suggests a new story\(suggestion.newTitle.map { ": “\($0)”" } ?? "") and drafted the update."
    }

    /// Asks Gemma which story this belongs to, then pre-fills the choices (still editable).
    private func suggest() async {
        suggesting = true
        defer { suggesting = false }
        do {
            guard let result = try await store.suggestStory(for: excerpt, in: projectID) else { return }
            suggestion = result
            if let id = result.storyId, let uuid = UUID(uuidString: id), store.trackedStories.contains(where: { $0.id == uuid }) {
                choice = .existing(uuid)
            } else if let title = result.newTitle, !title.isEmpty {
                choice = .new
                if newTitle.isEmpty { newTitle = title }
            }
            if note.isEmpty { note = result.update }
        } catch {
            suggestionError = error.localizedDescription
        }
    }
}
