import SwiftUI

struct HomeView: View {
    @Environment(AppStore.self) private var store
    // Column proportions, saved between launches. Drag the borders to change them.
    @AppStorage("home.scriptsFraction") private var scriptsFraction = HomeView.defaultScriptsFraction
    @AppStorage("home.queueFraction") private var queueFraction = HomeView.defaultQueueFraction
    // Heights of the stacked panels (top pane's share of the column).
    @AppStorage("home.queueHeightFraction") private var queueHeightFraction = 0.5
    @AppStorage("home.newsHeightFraction") private var newsHeightFraction = 0.5
    static let defaultScriptsFraction = 0.22
    static let defaultQueueFraction = 0.5

    var body: some View {
        @Bindable var store = store
        SplitPair(fraction: $scriptsFraction, defaultFraction: Self.defaultScriptsFraction, minLeading: Zoom.s(220), minTrailing: Zoom.s(612)) {
            ScriptsPanel()
        } trailing: {
            VStack(spacing: 12) {
                SplitPair(fraction: $queueFraction, defaultFraction: Self.defaultQueueFraction, minLeading: Zoom.s(300), minTrailing: Zoom.s(300)) {
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

// MARK: - Scripts

private struct ScriptsPanel: View {
    @Environment(AppStore.self) private var store
    @State private var editing: Script?
    @State private var creating = false
    @State private var pendingDelete: Script?

    var body: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "Scripts", count: store.scripts.count) {
                Button { creating = true } label: {
                    Label("New Script", systemImage: "plus")
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut("n", modifiers: .command)
            }
            Divider().overlay(Theme.border)

            if store.filteredScripts.isEmpty {
                EmptyState(
                    title: store.searchText.isEmpty ? "No scripts yet" : "No matching scripts",
                    systemImage: "doc.text",
                    message: store.searchText.isEmpty ? "Create one, or start from stories in the queue." : nil
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(store.filteredScripts) { script in
                            ScriptRow(
                                script: script,
                                onEdit: { editing = script },
                                onDelete: { pendingDelete = script }
                            )
                        }
                    }
                    .padding(8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .card()
        .sheet(item: $editing) { script in
            ScriptDetailsSheet(title: "Edit Script", script: script) { store.updateScript($0) }
        }
        .sheet(isPresented: $creating) {
            ScriptDetailsSheet(title: "New Script", script: Script(name: "", episodeDate: Date())) { new in
                let created = store.createScript(name: new.name, date: new.episodeDate)
                store.open(created.id)
            }
        }
        .confirmationDialog(
            "Delete \"\(pendingDelete?.name ?? "")\"?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { script in
            Button("Delete", role: .destructive) { store.deleteScript(script.id) }
        } message: { script in
            Text("“\(script.name)”, its script and its \(script.notes.count) selected \(script.notes.count == 1 ? "story" : "stories") will be permanently deleted and no longer stored. This can’t be undone. Passages you tagged in the Story Tracker are kept.")
        }
    }
}

private struct ScriptRow: View {
    @Environment(AppStore.self) private var store
    var script: Script
    var onEdit: () -> Void
    var onDelete: () -> Void

    var body: some View {
        HoverRow { hovering in
            HStack(spacing: 12) {
                Image(systemName: "waveform")
                    .font(.system(size: Zoom.s(13), weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 32, height: 32)
                    .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(script.name)
                        .font(.system(size: Zoom.s(13), weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(metadata)
                        .font(.system(size: Zoom.s(12)))
                        .foregroundStyle(Theme.textSecondary)
                }

                Spacer()

                HStack(spacing: 2) {
                    IconButton(systemName: "pencil", help: "Edit details", action: onEdit)
                    IconButton(systemName: "arrow.down.doc", help: "Download script") { ScriptExporter.export(script) }
                    IconButton(systemName: "trash", help: "Delete", role: .destructive, action: onDelete)
                }
                .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        }
        .onTapGesture { store.open(script.id) }
        .contextMenu {
            Button("Open") { store.open(script.id) }
            Button("Edit Details…", action: onEdit)
            Button("Download Script…") { ScriptExporter.export(script) }
            Divider()
            Button("Delete…", role: .destructive, action: onDelete)
        }
    }

    private var metadata: String {
        let date = script.episodeDate.formatted(.dateTime.month(.abbreviated).day().year())
        let edited = script.updatedAt.formatted(.relative(presentation: .named))
        return "\(date)  ·  \(script.wordCount.formatted()) words  ·  edited \(edited)"
    }
}

/// Used for both creating and editing a script's name and date.
struct ScriptDetailsSheet: View {
    @Environment(\.dismiss) private var dismiss
    var title: String
    @State var script: Script
    var onSave: (Script) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: Zoom.s(15), weight: .semibold))
                .padding([.horizontal, .top], 20)
            Form {
                TextField("Name", text: $script.name)
                DatePicker("Episode date", selection: $script.episodeDate, displayedComponents: .date)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(script)
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(script.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 400)
    }
}
