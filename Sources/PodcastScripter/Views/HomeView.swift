import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 8) {
                VStack(spacing: 8) {
                    ProjectsPanel()
                    InstructionFilesPanel()
                        .frame(height: 230)
                }
                .overlay(alignment: .bottomTrailing) {
                    ClaudeButton().padding(12)
                }

                VStack(spacing: 8) {
                    StoryQueuePanel()
                    StoryTrackerPanel()
                }
                .frame(width: max(340, geo.size.width * 0.37))
            }
        }
        .padding(6)
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
            PanelHeader("Projects", centered: true, trailing: AnyView(
                Button { creating = true } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain)
                    .help("New project")
                    .keyboardShortcut("n", modifiers: .command)
            ))
            .panel(Theme.panelHeader)
            .padding(6)

            if store.filteredProjects.isEmpty {
                ContentUnavailableView(
                    store.searchText.isEmpty ? "No projects yet" : "No matching projects",
                    systemImage: "doc.text",
                    description: Text(store.searchText.isEmpty ? "Create one with + or from the story queue." : "")
                )
                .foregroundStyle(Theme.secondaryText)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(store.filteredProjects) { project in
                            ProjectRow(
                                project: project,
                                onEdit: { editing = project },
                                onDelete: { pendingDelete = project }
                            )
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .panel()
        .sheet(item: $editing) { project in
            ProjectDetailsSheet(project: project) { store.updateProject($0) }
        }
        .sheet(isPresented: $creating) {
            ProjectDetailsSheet(project: Project(name: "", episodeDate: Date())) { new in
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
        Button { store.open(project.id) } label: {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.name).font(.title3)
                    Text("\(project.episodeDate.formatted(date: .abbreviated, time: .omitted)) · \(project.wordCount) words")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    HStack(spacing: 24) {
                        Button("Edit", action: onEdit)
                        Button("Delete", action: onDelete)
                    }
                    Button("Download Script") { ScriptExporter.export(project) }
                }
                .buttonStyle(.plain)
                .font(.title3)
            }
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 18)
            .frame(height: 90)
        }
        .buttonStyle(CardButtonStyle())
    }
}

/// Used for both creating and editing a project's name and date.
struct ProjectDetailsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var project: Project
    var onSave: (Project) -> Void

    var body: some View {
        Form {
            TextField("Name", text: $project.name)
            DatePicker("Episode date", selection: $project.episodeDate, displayedComponents: .date)
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    onSave(project)
                    dismiss()
                }
                .disabled(project.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

// MARK: - Instruction files

private struct InstructionFilesPanel: View {
    @Environment(AppStore.self) private var store
    @State private var importing = false
    @State private var previewing: InstructionFile?

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader("Instructions Files", centered: true)
                .panel(Theme.panelHeader)
                .padding(6)

            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(store.instructionFiles) { file in
                        Button { previewing = file } label: {
                            tile {
                                Image(systemName: "doc.plaintext").font(.title)
                                Text(file.name).font(.caption).lineLimit(2).multilineTextAlignment(.center)
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Remove", role: .destructive) { store.deleteInstructionFile(file.id) }
                        }
                    }
                    Button { importing = true } label: {
                        tile {
                            Image(systemName: "plus").font(.title)
                            Text("Add file").font(.caption)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Import a text or Markdown file")
                }
                .padding(.horizontal, 10)
            }
            Spacer(minLength: 0)
        }
        .panel()
        .fileImporter(isPresented: $importing, allowedContentTypes: Self.importTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                urls.forEach(store.importInstructionFile)
            }
        }
        .sheet(item: $previewing) { file in
            InstructionFilePreview(file: file)
        }
    }

    private static let importTypes: [UTType] = [.plainText, .text] + [UTType(filenameExtension: "md")].compactMap { $0 }

    private func tile<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 6, content: content)
            .foregroundStyle(Theme.text)
            .padding(8)
            .frame(width: 120, height: 100)
            .panel(Theme.card)
    }
}

private struct InstructionFilePreview: View {
    @Environment(\.dismiss) private var dismiss
    var file: InstructionFile

    var body: some View {
        ScrollView {
            Text(file.content)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .frame(width: 600, height: 500)
        .navigationTitle(file.name)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
    }
}
