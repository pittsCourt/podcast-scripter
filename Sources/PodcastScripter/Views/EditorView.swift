import AppKit
import SwiftUI

struct EditorView: View {
    @Environment(AppStore.self) private var store
    var projectID: Project.ID
    /// Shared by the editor and the sidebar, which inserts stories into the script.
    @State private var controller = RichTextController()

    var body: some View {
        if let project = store.project(projectID) {
            HStack(spacing: 12) {
                ScriptEditor(project: project, controller: controller)
                StorySidebar(project: project, controller: controller)
                    .frame(width: 340)
            }
            .padding(12)
        } else {
            EmptyState(title: "Project not found", systemImage: "questionmark.folder")
        }
    }
}

private struct ScriptEditor: View {
    @Environment(AppStore.self) private var store
    var project: Project
    var controller: RichTextController
    @State private var editingDetails = false

    var body: some View {
        @Bindable var controller = controller
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(project.episodeDate.formatted(date: .complete, time: .omitted))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                IconButton(systemName: "pencil", help: "Edit details") { editingDetails = true }
                IconButton(systemName: "arrow.down.doc", help: "Download script (⇧⌘S)") { ScriptExporter.export(project) }
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
                documentID: project.id,
                initialText: { ScriptStyle.load(project) },
                controller: controller
            ) { text in
                var updated = store.project(project.id) ?? project
                updated.script = text.string
                updated.richText = ScriptStyle.rtfData(text)
                store.updateProject(updated, debounced: true)
            }
            .frame(maxWidth: 760)
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().overlay(Theme.border)
            HStack(spacing: 14) {
                Label("\(project.wordCount.formatted()) words", systemImage: "text.alignleft")
                Label(String(format: "~%.1f min", project.estimatedMinutes), systemImage: "clock")
                Spacer()
                Text("Edited \(project.updatedAt.formatted(.relative(presentation: .named)))")
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 16)
            .frame(height: 34)
        }
        .card()
        .focusedSceneValue(\.richTextController, controller)
        .sheet(isPresented: $editingDetails) {
            ProjectDetailsSheet(title: "Edit Project", project: project) { store.updateProject($0) }
        }
        .sheet(isPresented: $controller.isEditingLink) {
            LinkSheet(controller: controller)
        }
    }
}

/// The stories picked for this project when it was created.
private struct StorySidebar: View {
    var project: Project
    var controller: RichTextController
    @State private var reading: StoryItem?

    var body: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "Selected Stories", count: project.notes.count)
            Divider().overlay(Theme.border)

            if project.notes.isEmpty {
                EmptyState(
                    title: "No stories attached",
                    systemImage: "tray",
                    message: "Select stories on the home page and click New Project to bring them in."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(project.notes) { story in
                            StoryCard(story: story, controller: controller) { reading = story }
                        }
                    }
                    .padding(8)
                }
            }
        }
        .card()
        .sheet(item: $reading) { story in
            ArticleReaderSheet(story: story, controller: controller)
        }
    }
}

private struct StoryCard: View {
    var story: StoryItem
    var controller: RichTextController
    var onRead: () -> Void

    var body: some View {
        HoverRow { _ in
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(story.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: 4)
                    KindBadge(kind: story.kind)
                }
                if !story.body.isEmpty {
                    Text(story.body)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                }
                Text([story.source, story.createdAt.formatted(date: .abbreviated, time: .omitted)].compactMap { $0 }.joined(separator: "  ·  "))
                    .font(.system(size: 11))
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
                .font(.system(size: 11, weight: .medium))
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
