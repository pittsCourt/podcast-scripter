import AppKit
import SwiftUI

struct EditorView: View {
    @Environment(AppStore.self) private var store
    var scriptID: Script.ID
    /// Shared by the editor and the sidebar, which inserts stories into the script.
    @State private var controller = RichTextController()

    var body: some View {
        if let script = store.script(scriptID) {
            HStack(spacing: 12) {
                ScriptEditor(script: script, controller: controller)
                StorySidebar(script: script, controller: controller)
                    .frame(width: Zoom.s(340))
            }
            .padding(12)
        } else {
            EmptyState(title: "Script not found", systemImage: "questionmark.folder")
        }
    }
}

private struct ScriptEditor: View {
    @Environment(AppStore.self) private var store
    var script: Script
    var controller: RichTextController
    @State private var editingDetails = false
    @State private var draftingBullets = false

    var body: some View {
        @Bindable var controller = controller
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(script.name)
                        .font(.system(size: Zoom.s(15), weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(script.episodeDate.formatted(date: .complete, time: .omitted))
                        .font(.system(size: Zoom.s(12)))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button { draftingBullets = true } label: {
                    Label("Draft Bullets", systemImage: "sparkles")
                }
                .buttonStyle(SecondaryButtonStyle())
                .help("Gemma drafts the intro's three top-story bullets")
                IconButton(systemName: "pencil", help: "Edit details") { editingDetails = true }
                IconButton(systemName: "arrow.down.doc", help: "Download script (⇧⌘S)") { ScriptExporter.export(script) }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
            .padding(.horizontal, 16)
            .frame(height: 60)
            Divider().overlay(Theme.border)

            FormatBar(controller: controller)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 42)
            Divider().overlay(Theme.border)

            RichTextEditor(
                documentID: script.id,
                initialText: { ScriptStyle.load(script) },
                controller: controller
            ) { text in
                var updated = store.script(script.id) ?? script
                updated.plainText = text.string
                updated.richText = ScriptStyle.rtfData(text)
                store.updateScript(updated, debounced: true)
            }
            .frame(maxWidth: Zoom.s(760))
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().overlay(Theme.border)
            HStack(spacing: 14) {
                Label("\(script.wordCount.formatted()) words", systemImage: "text.alignleft")
                Label(String(format: "~%.1f min", script.estimatedMinutes), systemImage: "clock")
                Spacer()
                Text("Edited \(script.updatedAt.formatted(.relative(presentation: .named)))")
            }
            .font(.system(size: Zoom.s(11.5)))
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 16)
            .frame(height: 34)
        }
        .card()
        .focusedSceneValue(\.richTextController, controller)
        .sheet(isPresented: $editingDetails) {
            ScriptDetailsSheet(title: "Edit Script", script: script) { store.updateScript($0) }
        }
        .sheet(isPresented: Binding(
            get: { controller.taggingExcerpt != nil },
            set: { if !$0 { controller.taggingExcerpt = nil } }
        )) {
            if let excerpt = controller.taggingExcerpt {
                TrackStorySheet(excerpt: excerpt, scriptID: script.id)
            }
        }
        .sheet(isPresented: $draftingBullets) {
            IntroBulletsSheet(scriptID: script.id, controller: controller)
        }
        .sheet(isPresented: $controller.isEditingLink) {
            LinkSheet(controller: controller)
        }
    }
}

/// The stories picked for this script when it was created.
private struct StorySidebar: View {
    @Environment(AppStore.self) private var store
    var script: Script
    var controller: RichTextController
    @State private var reading: StoryItem?
    @State private var selected: Set<UUID> = []
    @State private var returning = false
    @AppStorage("editorSidebarMode") private var mode = Mode.stories

    enum Mode: String {
        case stories
        case briefing
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Show", selection: $mode) {
                    Text("Stories (\(script.notes.count))").tag(Mode.stories)
                    Label("Briefing", systemImage: "sparkles").tag(Mode.briefing)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.horizontal, 12)
            .frame(height: 48)
            Divider().overlay(Theme.border)

            if mode == .briefing {
                BriefingView(script: script)
            } else if script.notes.isEmpty {
                EmptyState(
                    title: "No stories attached",
                    systemImage: "tray",
                    message: "Select stories on the home page and click New Script to bring them in."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(script.notes) { story in
                            StoryCard(
                                story: story,
                                controller: controller,
                                isSelected: selected.contains(story.id),
                                onToggle: { toggle(story.id) },
                                onRead: { reading = story }
                            )
                        }
                    }
                    .padding(8)
                }

                Divider().overlay(Theme.border)
                HStack(spacing: 8) {
                    if selected.isEmpty {
                        Text("Check stories to send back to the queue")
                            .foregroundStyle(Theme.textTertiary)
                    } else {
                        Text("\(selected.count) selected")
                            .foregroundStyle(Theme.textPrimary)
                        Button("Clear") { selected.removeAll() }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    if returning { ProgressView().controlSize(.small) }
                    Button("Return to Queue") {
                        let ids = selected
                        returning = true
                        Task {
                            await store.returnToQueue(ids, from: script.id)
                            selected.removeAll()
                            returning = false
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(selected.isEmpty || returning)
                    .help("Remove from this script and put back in the Story Queue or news columns")
                }
                .font(.system(size: Zoom.s(12)))
                .padding(.horizontal, 12)
                .frame(height: 46)
            }
        }
        .card()
        .onChange(of: script.notes.map(\.id)) { _, ids in
            selected.formIntersection(ids)
        }
        .sheet(item: $reading) { story in
            ArticleReaderSheet(story: story, controller: controller)
        }
    }

    private func toggle(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }
}

private struct StoryCard: View {
    var story: StoryItem
    var controller: RichTextController
    var isSelected: Bool
    var onToggle: () -> Void
    var onRead: () -> Void

    var body: some View {
        HoverRow(isSelected: isSelected) { _ in
            VStack(alignment: .leading, spacing: 4) {
                // The whole title row toggles selection (the body text stays selectable for copying).
                HStack(alignment: .center, spacing: 8) {
                    Checkbox(isOn: isSelected)
                    Text(story.title)
                        .font(.system(size: Zoom.s(13), weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: 4)
                    KindBadge(kind: story.kind)
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: onToggle)
                .help(isSelected ? "Click to deselect" : "Click to select, then Return to Queue")
                if !story.body.isEmpty {
                    Text(story.body)
                        .font(.system(size: Zoom.s(12)))
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                }
                Text([story.source, story.createdAt.formatted(date: .abbreviated, time: .omitted)].compactMap { $0 }.joined(separator: "  ·  "))
                    .font(.system(size: Zoom.s(11)))
                    .foregroundStyle(Theme.textTertiary)
                HStack(spacing: 6) {
                    primaryAction
                    Spacer()
                    if let url = story.url {
                        CardAction(title: "Open", systemImage: "arrow.up.right", help: url.absoluteString) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                .padding(.top, 2)
            }
            .padding(10)
        }
    }
}

private extension StoryCard {
    @ViewBuilder
    var primaryAction: some View {
        switch story.kind {
        case .xPost:
            CardAction(title: "Insert Quote", systemImage: "text.quote", help: "Insert the post and its link as a quote at the cursor", isProminent: true) {
                controller.insertQuote(
                    story.body.isEmpty ? [story.title] : story.body.components(separatedBy: .newlines).filter { !$0.isEmpty },
                    attribution: "— \(story.title) on X",
                    link: story.url
                )
            }
        case .article, .news:
            if story.url != nil {
                CardAction(title: "Read & Quote", systemImage: "doc.text.magnifyingglass", help: "Open the article, select text, and insert it as a quote", isProminent: true, action: onRead)
            }
        case .storyNote:
            CardAction(title: "Insert", systemImage: "text.insert", help: "Insert the note as text at the cursor", isProminent: true) {
                controller.insertBody(story.body.isEmpty ? story.title : "\(story.title)\n\(story.body)")
            }
        }
    }
}

/// Small text button used on story cards.
private struct CardAction: View {
    var title: String
    var systemImage: String
    var help: String
    var isProminent = false
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: Zoom.s(11), weight: .medium))
                .foregroundStyle(isProminent ? Theme.accent : hovering ? Theme.textPrimary : Theme.textTertiary)
                .padding(.horizontal, 7)
                .frame(height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isProminent ? Theme.accent.opacity(hovering ? 0.22 : 0.12) : hovering ? Color.white.opacity(0.08) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

// MARK: - Gemma in the editor

/// Per tracked story: what the show has said so far, and what's new in the queue and news.
private struct BriefingView: View {
    @Environment(AppStore.self) private var store
    var script: Script
    @State private var briefings: [StoryBriefing] = []
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        let stories = store.briefingStories(for: script.id)
        VStack(spacing: 0) {
            if stories.isEmpty {
                EmptyState(
                    title: "No tracked stories yet",
                    systemImage: "binoculars",
                    message: "Highlight part of a script and choose Track Story to start following it."
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(store.trackedStories(in: script.id).isEmpty
                             ? "Your most recently updated stories. Tag passages in this episode to focus the briefing."
                             : "Stories tagged in this episode.")
                            .font(.system(size: Zoom.s(11)))
                            .foregroundStyle(Theme.textTertiary)
                        if let error {
                            Text(error).font(.system(size: Zoom.s(12))).foregroundStyle(Theme.negative)
                        }
                        ForEach(stories) { story in
                            BriefingCard(story: story, briefing: briefings.first { $0.storyId == story.id.uuidString })
                        }
                    }
                    .padding(10)
                }
                Divider().overlay(Theme.border)
                HStack {
                    if loading {
                        ProgressView().controlSize(.small)
                        Text("Gemma is reading back through the season…")
                            .font(.system(size: Zoom.s(11.5)))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                    Button(briefings.isEmpty ? "Brief Me" : "Refresh") { Task { await load() } }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(loading)
                }
                .padding(.horizontal, 12)
                .frame(height: 46)
            }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            briefings = try await store.briefing(for: script.id)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct BriefingCard: View {
    var story: TrackedStory
    var briefing: StoryBriefing?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(story.title)
                    .font(.system(size: Zoom.s(13), weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("\(story.mentions.count) mentions")
                    .font(.system(size: Zoom.s(10.5)))
                    .foregroundStyle(Theme.textTertiary)
            }
            if let briefing {
                Text(briefing.summary)
                    .font(.system(size: Zoom.s(12)))
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                if let whatsNew = briefing.whatsNew {
                    Label(whatsNew, systemImage: "sparkle")
                        .font(.system(size: Zoom.s(12)))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .textSelection(.enabled)
                }
            } else {
                Text(story.latestUpdate.isEmpty ? "No updates yet." : "Latest: \(story.latestUpdate)")
                    .font(.system(size: Zoom.s(12)))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Gemma drafts the intro's three top-story bullets; edit them, then fill in the template's placeholders.
private struct IntroBulletsSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var scriptID: Script.ID
    var controller: RichTextController
    @State private var bullets: [String] = []
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("Draft Intro Bullets", systemImage: "sparkles")
                .font(.system(size: Zoom.s(15), weight: .semibold))
                .padding([.horizontal, .top], 20)
            Text("Three short, punchy top stories ranked by importance; the latest match result normally leads. Edit before inserting.")
                .font(.system(size: Zoom.s(12)))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.top, 6)

            Form {
                if loading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Gemma is reading this episode, results and rankings…").foregroundStyle(.secondary)
                    }
                } else if let error {
                    Text(error).foregroundStyle(Theme.negative)
                } else {
                    ForEach(bullets.indices, id: \.self) { index in
                        TextField("Bullet \(index + 1)", text: $bullets[index], axis: .vertical)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: 180)

            HStack {
                Button("Try Again") { Task { await draft() } }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(loading)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Insert") {
                    controller.fillBullets(bullets.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(bullets.count != 3 || bullets.contains { $0.trimmingCharacters(in: .whitespaces).isEmpty })
            }
            .padding(20)
        }
        .frame(width: 500)
        .task { await draft() }
    }

    private func draft() async {
        loading = true
        defer { loading = false }
        do {
            bullets = try await store.introBullets(for: scriptID)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
