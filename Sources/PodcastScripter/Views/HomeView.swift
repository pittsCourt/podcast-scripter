import SwiftUI

struct HomeView: View {
    @Environment(AppStore.self) private var store
    // Column proportions, saved between launches. Drag the borders to change them.
    @AppStorage("home.projectsFraction") private var projectsFraction = HomeView.defaultProjectsFraction
    @AppStorage("home.queueFraction") private var queueFraction = HomeView.defaultQueueFraction
    // Heights of the stacked panels (top pane's share of the column).
    @AppStorage("home.queueHeightFraction") private var queueHeightFraction = 0.5
    @AppStorage("home.newsHeightFraction") private var newsHeightFraction = 0.5
    static let defaultProjectsFraction = 0.22
    static let defaultQueueFraction = 0.5

    var body: some View {
        @Bindable var store = store
        SplitPair(fraction: $projectsFraction, defaultFraction: Self.defaultProjectsFraction, minLeading: 220, minTrailing: 612) {
            ProjectsPanel()
        } trailing: {
            VStack(spacing: 12) {
                SplitPair(fraction: $queueFraction, defaultFraction: Self.defaultQueueFraction, minLeading: 300, minTrailing: 300) {
                    SplitPair(axis: .vertical, fraction: $queueHeightFraction, defaultFraction: 0.5, minLeading: 150, minTrailing: 120) {
                        StoryQueuePanel()
                    } trailing: {
                        StoryTrackerPanel()
                    }
                } trailing: {
                    SplitPair(axis: .vertical, fraction: $newsHeightFraction, defaultFraction: 0.5, minLeading: 140, minTrailing: 140) {
                        NewsPanel(category: .team)
                    } trailing: {
                        NewsPanel(category: .league)
                    }
                }
                SelectionBar()
            }
        }
        .padding(12)
        .searchable(text: $store.searchText, placement: .toolbar, prompt: "Search")
    }
}

// MARK: - Projects

private struct ProjectsPanel: View {
    @Environment(AppStore.self) private var store
    @State private var editing: Project?
    @State private var creating = false
    @State private var pendingDelete: Project?

    var body: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "Projects", count: store.projects.count) {
                Button { creating = true } label: {
                    Label("New Project", systemImage: "plus")
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut("n", modifiers: .command)
            }
            Divider().overlay(Theme.border)

            if store.filteredProjects.isEmpty {
                EmptyState(
                    title: store.searchText.isEmpty ? "No projects yet" : "No matching projects",
                    systemImage: "doc.text",
                    message: store.searchText.isEmpty ? "Create one, or start from stories in the queue." : nil
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(store.filteredProjects) { project in
                            ProjectRow(
                                project: project,
                                onEdit: { editing = project },
                                onDelete: { pendingDelete = project }
                            )
                        }
                    }
                    .padding(8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .card()
        .sheet(item: $editing) { project in
            ProjectDetailsSheet(title: "Edit Project", project: project) { store.updateProject($0) }
        }
        .sheet(isPresented: $creating) {
            ProjectDetailsSheet(title: "New Project", project: Project(name: "", episodeDate: Date())) { new in
                let created = store.createProject(name: new.name, date: new.episodeDate)
                store.open(created.id)
            }
        }
        .confirmationDialog(
            "Delete \"\(pendingDelete?.name ?? "")\"?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { project in
            Button("Delete", role: .destructive) { store.deleteProject(project.id) }
        } message: { _ in
            Text("The script will be permanently removed.")
        }
    }
}

private struct ProjectRow: View {
    @Environment(AppStore.self) private var store
    var project: Project
    var onEdit: () -> Void
    var onDelete: () -> Void

    var body: some View {
        HoverRow { hovering in
            HStack(spacing: 12) {
                Image(systemName: "waveform")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 32, height: 32)
                    .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(project.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(metadata)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }

                Spacer()

                HStack(spacing: 2) {
                    IconButton(systemName: "pencil", help: "Edit details", action: onEdit)
                    IconButton(systemName: "arrow.down.doc", help: "Download script") { ScriptExporter.export(project) }
                    IconButton(systemName: "trash", help: "Delete", role: .destructive, action: onDelete)
                }
                .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        }
        .onTapGesture { store.open(project.id) }
        .contextMenu {
            Button("Open") { store.open(project.id) }
            Button("Edit Details…", action: onEdit)
            Button("Download Script…") { ScriptExporter.export(project) }
            Divider()
            Button("Delete…", role: .destructive, action: onDelete)
        }
    }

    private var metadata: String {
        let date = project.episodeDate.formatted(.dateTime.month(.abbreviated).day().year())
        let edited = project.updatedAt.formatted(.relative(presentation: .named))
        return "\(date)  ·  \(project.wordCount.formatted()) words  ·  edited \(edited)"
    }
}

/// Used for both creating and editing a project's name and date.
struct ProjectDetailsSheet: View {
    @Environment(\.dismiss) private var dismiss
    var title: String
    @State var project: Project
    var onSave: (Project) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .padding([.horizontal, .top], 20)
            Form {
                TextField("Name", text: $project.name)
                DatePicker("Episode date", selection: $project.episodeDate, displayedComponents: .date)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(project)
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(project.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 400)
    }
}
