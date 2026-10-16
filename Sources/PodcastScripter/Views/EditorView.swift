import AppKit
import SwiftUI

struct EditorView: View {
    @Environment(AppStore.self) private var store
    var projectID: Project.ID

    var body: some View {
        if let project = store.project(projectID) {
            HStack(spacing: 12) {
                ScriptEditor(project: project)
                EditorSidebar(project: project)
                    .frame(width: 360)
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
    @State private var editingDetails = false

    var body: some View {
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

            TextEditor(text: Binding(
                get: { project.script },
                set: { newValue in
                    var updated = project
                    updated.script = newValue
                    store.updateProject(updated, debounced: true)
                }
            ))
            .font(.system(size: 16))
            .lineSpacing(6)
            .scrollContentBackground(.hidden)
            .foregroundStyle(Theme.textPrimary)
            .frame(maxWidth: 760)
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .overlay(alignment: .topLeading) {
                if project.script.isEmpty {
                    Text("Start writing your script…")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 37)
                        .padding(.vertical, 24)
                        .allowsHitTesting(false)
                }
            }
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
        .sheet(isPresented: $editingDetails) {
            ProjectDetailsSheet(title: "Edit Project", project: project) { store.updateProject($0) }
        }
    }
}

private struct EditorSidebar: View {
    @Environment(AppStore.self) private var store
    var project: Project

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !project.notes.isEmpty {
                    section("Project Notes") {
                        ForEach(project.notes) { note in
                            item(title: note.title, detail: note.body, meta: [note.kind.label, note.source].compactMap { $0 }.joined(separator: "  ·  "), url: note.url)
                        }
                    }
                }
                section("\(ShowConfig.teamName) News") {
                    newsList(store.news(in: .team))
                }
                section("League News") {
                    newsList(store.news(in: .league))
                }
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 8)
        }
        .card()
    }

    @ViewBuilder
    private func newsList(_ items: [NewsItem]) -> some View {
        if items.isEmpty {
            Text(store.connection == .connecting ? "Loading…" : "No news yet. Check the notes service connection.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 10)
        } else {
            ForEach(items) { newsItem($0) }
        }
    }

    private func newsItem(_ news: NewsItem) -> some View {
        item(
            title: news.headline,
            detail: news.summary,
            meta: "\(news.source)  ·  \(news.publishedAt.formatted(.relative(presentation: .named)))",
            url: news.url
        )
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            GroupLabel(text: title)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
            content()
        }
    }

    private func item(title: String, detail: String, meta: String, url: URL?) -> some View {
        HoverRow { hovering in
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: 4)
                    if url != nil {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                            .opacity(hovering ? 1 : 0)
                    }
                }
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(3)
                }
                Text(meta)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(10)
        }
        .onTapGesture { if let url { NSWorkspace.shared.open(url) } }
        .help(url == nil ? "" : "Open in browser")
    }
}
