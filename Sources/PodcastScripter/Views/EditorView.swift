import SwiftUI

struct EditorView: View {
    @Environment(AppStore.self) private var store
    var projectID: Project.ID

    var body: some View {
        if let project = store.project(projectID) {
            GeometryReader { geo in
                HStack(spacing: 8) {
                    ScriptEditor(project: project)
                        .overlay(alignment: .bottomTrailing) {
                            ClaudeButton().padding(12)
                        }
                    EditorSidebar(project: project)
                        .frame(width: max(320, geo.size.width * 0.37))
                }
            }
            .padding(6)
        } else {
            ContentUnavailableView("Project not found", systemImage: "questionmark.folder")
        }
    }
}

private struct ScriptEditor: View {
    @Environment(AppStore.self) private var store
    var project: Project

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Text("Project Name: \(project.displayTitle)")
                    .font(.title3)
                Spacer()
                Button { ScriptExporter.export(project) } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .buttonStyle(.plain)
                .help("Download script")
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.panelHeader)
            .padding(6)

            TextEditor(text: Binding(
                get: { project.script },
                set: { newValue in
                    var updated = project
                    updated.script = newValue
                    store.updateProject(updated, debounced: true)
                }
            ))
            .font(.system(size: 15))
            .lineSpacing(4)
            .scrollContentBackground(.hidden)
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 32)
            .padding(.vertical, 8)
            .overlay(alignment: .topLeading) {
                if project.script.isEmpty {
                    Text("Start writing your script…")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.horizontal, 37)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }

            HStack {
                Text("\(project.wordCount) words · ~\(project.estimatedMinutes, specifier: "%.1f") min read")
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(Theme.secondaryText)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .padding(.trailing, 70) // clear the Claude button
        }
        .panel(Color(white: 0.24))
    }
}

private struct EditorSidebar: View {
    @Environment(AppStore.self) private var store
    var project: Project

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !project.notes.isEmpty {
                    section("Project Notes") {
                        ForEach(project.notes) { note in
                            card(title: note.title, detail: note.body, caption: note.kind.label)
                        }
                    }
                }
                section("\(ShowConfig.teamName) News") {
                    ForEach(store.news(in: .team)) { newsCard($0) }
                }
                section("League News") {
                    ForEach(store.news(in: .league)) { newsCard($0) }
                }
            }
            .padding(14)
        }
        .panel()
    }

    private func newsCard(_ item: NewsItem) -> some View {
        card(
            title: item.headline,
            detail: item.summary,
            caption: "\(item.source) · \(item.publishedAt.formatted(.relative(presentation: .named)))"
        )
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3.weight(.medium))
                .foregroundStyle(Theme.text)
                .padding(.top, 6)
            content()
        }
    }

    private func card(title: String, detail: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title3)
            Text(detail)
                .font(.callout)
                .foregroundStyle(Theme.secondaryText)
            Spacer(minLength: 0)
            Text(caption)
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
        }
        .foregroundStyle(Theme.text)
        .textSelection(.enabled)
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .panel(Theme.card)
    }
}
