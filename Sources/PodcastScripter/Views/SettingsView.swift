import SwiftUI

/// Settings (⌘,). Show, template, team and source settings are saved in Newsdesk so every
/// device shares them; the service address and token are stored on this Mac.
struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var draft: AppConfig = .fallback
    @State private var loaded = false
    @State private var status: Status = .idle

    enum Status: Equatable {
        case idle
        case saving
        case saved
        case failed(String)
    }

    private var hasChanges: Bool { loaded && draft != store.config }

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                ShowSettings(draft: $draft)
                    .tabItem { Label("Show", systemImage: "mic") }
                TemplateSettings(draft: $draft)
                    .tabItem { Label("Script Template", systemImage: "doc.text") }
                TeamSettings(draft: $draft)
                    .tabItem { Label("Team & League", systemImage: "sportscourt") }
                RankingsSettings(draft: $draft)
                    .tabItem { Label("Power Rankings", systemImage: "chart.line.uptrend.xyaxis") }
                AISettings(draft: $draft, hasUnsavedChanges: hasChanges)
                    .tabItem { Label("AI", systemImage: "sparkles") }
                ServiceSettingsTab()
                    .tabItem { Label("Newsdesk", systemImage: "server.rack") }
            }
            .padding(.top, 8)

            Divider()
            HStack(spacing: 10) {
                statusText
                Spacer()
                Button("Reset to Defaults…") { Task { await reset() } }
                    .help("Restore the defaults from services/newsdesk/config.default.json")
                Button("Revert") { draft = store.config }
                    .disabled(!hasChanges)
                Button("Save") { Task { await save() } }
                    .keyboardShortcut("s")
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasChanges || status == .saving)
            }
            .padding(12)
        }
        .frame(width: 680, height: 620)
        .task(id: store.currentProjectID) {
            await store.loadConfig()
            draft = store.config
            loaded = true
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch status {
        case .idle:
            Text(hasChanges ? "Unsaved changes" : "Saved in Newsdesk and shared by every device.")
                .foregroundStyle(.secondary)
        case .saving:
            ProgressView().controlSize(.small)
        case .saved:
            Label("Saved", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.positive)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.negative)
                .lineLimit(2)
        }
    }

    private func save() async {
        status = .saving
        do {
            try await store.saveConfig(draft)
            draft = store.config
            status = .saved
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func reset() async {
        status = .saving
        do {
            try await store.resetConfig()
            draft = store.config
            status = .saved
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}

// MARK: - Show

private struct ShowSettings: View {
    @Environment(AppStore.self) private var store
    @Binding var draft: AppConfig
    @State private var projectName = ""
    @State private var confirmingDelete = false
    @State private var projectError: String?

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Project name", text: $projectName)
                    Button("Rename") {
                        Task {
                            do { try await store.renameCurrentProject(to: projectName) } catch { projectError = error.localizedDescription }
                        }
                    }
                    .disabled(projectName.trimmingCharacters(in: .whitespaces).isEmpty || projectName == store.currentProjectName)
                }
                if let projectError { Text(projectError).foregroundStyle(Theme.negative) }
            } header: {
                Text("Project")
            } footer: {
                Text("Settings on every tab apply to this project only. Switch projects from the name in the toolbar.")
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField("Show name", text: $draft.show.name, prompt: Text("Riot Report"))
                TextField("Full show name", text: $draft.show.fullName, prompt: Text("RSL Riot Report"))
                TextField("Host", text: $draft.show.host)
                TextField("X handle", text: $draft.show.xHandle, prompt: Text("@yourshow"))
            } footer: {
                Text("The full name, host and handle fill in {show}, {host} and {handle} in the script template. New scripts are named after the full show name.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Delete This Project…", role: .destructive) { confirmingDelete = true }
                    .disabled(store.projectData.count < 2)
            } footer: {
                Text(store.projectData.count < 2 ? "This is your only project." : "Removes this project and everything in it.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { projectName = store.currentProjectName }
        .onChange(of: store.currentProjectID) { projectName = store.currentProjectName }
        .confirmationDialog("Delete “\(store.currentProjectName)”?", isPresented: $confirmingDelete) {
            Button("Delete Project", role: .destructive) {
                Task {
                    do { try await store.deleteCurrentProject() } catch { projectError = error.localizedDescription }
                }
            }
        } message: {
            Text("Its \(store.scripts.count) scripts, Story Queue, Story Tracker, news, saved power rankings and settings will be permanently deleted and no longer stored, on this Mac and in Newsdesk. This can’t be undone.")
        }
    }
}

// MARK: - Script template

private struct TemplateSettings: View {
    @Binding var draft: AppConfig
    @State private var selection: AppConfig.Template.Section.ID?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(draft.template.sections) { section in
                        Text(section.title.isEmpty ? "Untitled" : section.title).tag(section.id)
                    }
                    .onMove { draft.template.sections.move(fromOffsets: $0, toOffset: $1) }
                }
                HStack(spacing: 0) {
                    Button {
                        let section = AppConfig.Template.Section(title: "New Section", body: "")
                        draft.template.sections.append(section)
                        selection = section.id
                    } label: { Image(systemName: "plus").frame(width: 24, height: 20) }
                    Button {
                        draft.template.sections.removeAll { $0.id == selection }
                        selection = draft.template.sections.first?.id
                    } label: { Image(systemName: "minus").frame(width: 24, height: 20) }
                    .disabled(selection == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(6)
            }
            .frame(width: 190)
            Divider()

            if let index = draft.template.sections.firstIndex(where: { $0.id == selection }) {
                Form {
                    Section("Heading") {
                        TextField("Heading", text: $draft.template.sections[index].title)
                            .labelsHidden()
                    }
                    Section {
                        TextEditor(text: $draft.template.sections[index].body)
                            .font(.system(size: Zoom.s(13)))
                            .frame(minHeight: 150)
                    } header: {
                        Text("Starting text")
                    } footer: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Lines starting with “• ” become indented bullets. Leave empty for a blank line to write in.")
                            ForEach(ScriptTemplate.placeholders, id: \.token) { item in
                                Text("\(item.token)  \(item.meaning)").font(.system(size: Zoom.s(11)).monospaced())
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
            } else {
                Text("Select a section to edit it. Drag to reorder.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { if selection == nil { selection = draft.template.sections.first?.id } }
    }
}

// MARK: - Team & league

private struct TeamSettings: View {
    @Environment(AppStore.self) private var store
    @Binding var draft: AppConfig
    @State private var teams: [TeamOption] = []
    @State private var loadingTeams = false
    @State private var teamsError: String?

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("ESPN league", text: $draft.team.espnLeague, prompt: Text("usa.1"))
                    Button(loadingTeams ? "Loading…" : "Find Teams") { Task { await loadTeams() } }
                        .disabled(loadingTeams)
                }
                if !teams.isEmpty {
                    Picker("Team", selection: Binding(
                        get: { draft.team.espnTeamId },
                        set: { id in pick(teams.first { $0.id == id }) }
                    )) {
                        ForEach(teams) { Text($0.name).tag($0.id) }
                    }
                } else {
                    TextField("ESPN team ID", text: $draft.team.espnTeamId)
                }
                if let teamsError { Text(teamsError).foregroundStyle(Theme.negative) }
                TextField("Team name", text: $draft.team.name)
                TextField("Short name", text: $draft.team.shortName, prompt: Text("RSL"))
                TextField("Also known as", text: list($draft.team.aliases), prompt: Text("RSL, Claret and Cobalt"))
            } header: {
                Text("Team")
            } footer: {
                Text("League codes are ESPN’s, e.g. usa.1 (MLS), eng.1 (Premier League), mex.1 (Liga MX). The team name and nicknames must match how ranking sources write them.")
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach($draft.competitions) { $competition in
                    HStack {
                        Toggle("", isOn: $competition.enabled).labelsHidden()
                        TextField("Name", text: $competition.name).labelsHidden()
                        TextField("ESPN code", text: $competition.espnLeague).labelsHidden().frame(width: 170)
                        Button {
                            draft.competitions.removeAll { $0.id == competition.id }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                }
                Button("Add Competition") {
                    draft.competitions.append(.init(name: "", espnLeague: "", enabled: true))
                }
            } header: {
                Text("Competitions to track")
            } footer: {
                Text("Matches from these show in the sidebar’s Matches tab. Cups the team isn’t in just show nothing.")
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField("Team news search", text: $draft.news.teamQuery)
                TextField("League news search", text: $draft.news.leagueQuery)
            } header: {
                Text("News (Google News searches)")
            } footer: {
                Text("Use quotes for exact names and OR between alternatives.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func loadTeams() async {
        loadingTeams = true
        defer { loadingTeams = false }
        do {
            teams = try await store.teams(inLeague: draft.team.espnLeague.trimmingCharacters(in: .whitespaces))
            teamsError = teams.isEmpty ? "No teams found for that league code." : nil
        } catch {
            teamsError = error.localizedDescription
        }
    }

    private func pick(_ team: TeamOption?) {
        guard let team else { return }
        draft.team.espnTeamId = team.id
        draft.team.name = team.name
        if let abbreviation = team.abbreviation { draft.team.shortName = abbreviation }
    }
}

// MARK: - Power rankings

private struct RankingsSettings: View {
    @Binding var draft: AppConfig

    private static let days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    var body: some View {
        Form {
            Section {
                Toggle("MLSsoccer.com weekly rankings", isOn: $draft.rankings.sources.mls.enabled)
                Toggle("ESPN column", isOn: $draft.rankings.sources.espn.enabled)
                if draft.rankings.sources.espn.enabled {
                    TextField("Headline starts with", text: $draft.rankings.sources.espn.query)
                }
                Toggle("TacticsFreeZone newsletter (Gmail)", isOn: $draft.rankings.sources.tfz.enabled)
                if draft.rankings.sources.tfz.enabled {
                    TextField("Sent from", text: $draft.rankings.sources.tfz.sender)
                    TextField("Also forwarded from", text: list($draft.rankings.sources.tfz.forwardedFrom), prompt: Text("you@example.com"))
                }
                Toggle("Concacaf club ranking", isOn: $draft.rankings.sources.concacaf.enabled)
                Toggle("Opta Power Rankings", isOn: $draft.rankings.sources.opta.enabled)
            } header: {
                Text("Sources")
            } footer: {
                Text("Each source has its own reader in Newsdesk, built for that publication. Gmail’s address and app password stay in .env.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Sync automatically every week", isOn: Binding(
                    get: { !draft.rankings.schedule.isEmpty },
                    set: { draft.rankings.schedule = $0 ? "Tue 16:00" : "" }
                ))
                if !draft.rankings.schedule.isEmpty {
                    Picker("Day", selection: schedulePart(0)) {
                        ForEach(Self.days, id: \.self) { Text($0).tag($0) }
                    }
                    TextField("Time (24-hour)", text: schedulePart(1), prompt: Text("16:00"))
                    TextField("Time zone", text: $draft.rankings.timeZone, prompt: Text("UTC"))
                }
            } header: {
                Text("Weekly sync")
            } footer: {
                Text("UTC keeps the time fixed through daylight saving: 16:00 UTC is 10 a.m. MDT / 9 a.m. MST. Use a zone like America/Denver to follow local time instead.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Edits the day (0) or time (1) part of "Tue 16:00".
    private func schedulePart(_ index: Int) -> Binding<String> {
        Binding(
            get: {
                let parts = draft.rankings.schedule.split(separator: " ").map(String.init)
                return parts.indices.contains(index) ? parts[index] : (index == 0 ? "Tue" : "16:00")
            },
            set: { value in
                var parts = draft.rankings.schedule.split(separator: " ").map(String.init)
                while parts.count < 2 { parts.append(parts.isEmpty ? "Tue" : "16:00") }
                parts[index] = value.trimmingCharacters(in: .whitespaces)
                draft.rankings.schedule = parts.joined(separator: " ")
            }
        )
    }
}

// MARK: - AI (Gemma)

private struct AISettings: View {
    @Environment(AppStore.self) private var store
    @Binding var draft: AppConfig
    var hasUnsavedChanges: Bool
    @State private var status: AIStatus?
    @State private var testResult: String?
    @State private var testOK = false
    @State private var testing = false

    private static let geminiModels = ["gemma-4-26b-a4b-it", "gemma-4-31b-it"]
    private static let ollamaModels = ["gemma4:e4b", "gemma4:12b", "gemma4:26b", "gemma4:31b"]

    var body: some View {
        Form {
            Section {
                Picker("Run Gemma with", selection: $draft.aiSettings.provider) {
                    Text("Gemini API (Google AI Studio)").tag("gemini")
                    Text("This computer (Ollama)").tag("ollama")
                }
                .pickerStyle(.radioGroup)
            } footer: {
                Text("Gemma powers story suggestions, briefings, intro bullets and Ask Gemma. Requests go through Newsdesk.")
                    .foregroundStyle(.secondary)
            }

            if draft.aiSettings.provider == "gemini" {
                Section {
                    modelField($draft.aiSettings.gemini.model, suggestions: Self.geminiModels)
                    if let status, status.provider == "gemini" {
                        LabeledContent("API key") {
                            Label(status.ready ? "Set in .env" : "Missing", systemImage: status.ready ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(status.ready ? Theme.positive : Theme.negative)
                        }
                    }
                } header: {
                    Text("Gemini API")
                } footer: {
                    Text("Put your Google AI Studio key in .env as GEMINI_API_KEY=…, then run docker compose up -d. The key never leaves Newsdesk. 26B is faster; 31B is a little stronger.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    TextField("Ollama address", text: $draft.aiSettings.ollama.url, prompt: Text("http://host.docker.internal:11434"))
                    modelField($draft.aiSettings.ollama.model, suggestions: Self.ollamaModels)
                } header: {
                    Text("Local model (Ollama)")
                } footer: {
                    Text("Run `ollama serve` and `ollama pull \(draft.aiSettings.ollama.model)` on the machine running Ollama. From Newsdesk’s container, this Mac is host.docker.internal. On an Intel Mac a local model is slow; the Gemini API is faster.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Stepper(value: Binding(
                    get: { draft.aiSettings.contextChars ?? 60_000 },
                    set: { draft.aiSettings.contextChars = $0 }
                ), in: 10_000...600_000, step: 10_000) {
                    LabeledContent("App data sent per question", value: "\((draft.aiSettings.contextChars ?? 60_000) / 1000)K characters")
                }
            } footer: {
                Text("About 4 characters per token. Larger answers more from your archive but uses more of your API limits.")
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    if let testResult {
                        Label(testResult, systemImage: testOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(testOK ? Theme.positive : Theme.negative)
                            .lineLimit(3)
                    } else if hasUnsavedChanges {
                        Text("Save first to test these settings.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    if testing { ProgressView().controlSize(.small) }
                    Button("Test Gemma") { Task { await test() } }
                        .disabled(testing || hasUnsavedChanges)
                }
            }
        }
        .formStyle(.grouped)
        .task { status = try? await store.aiStatus() }
    }

    private func modelField(_ model: Binding<String>, suggestions: [String]) -> some View {
        HStack {
            TextField("Model", text: model)
            Menu("Choose") {
                ForEach(suggestions, id: \.self) { name in Button(name) { model.wrappedValue = name } }
            }
            .fixedSize()
        }
    }

    private func test() async {
        testing = true
        defer { testing = false }
        do {
            let reply = try await store.testAI()
            testOK = true
            testResult = "\(reply.model) answered in \(String(format: "%.1f", Double(reply.ms) / 1000))s: “\(reply.text)”"
        } catch {
            testOK = false
            testResult = error.localizedDescription
        }
        status = try? await store.aiStatus()
    }
}

// MARK: - Newsdesk (this Mac only)

private struct ServiceSettingsTab: View {
    @Environment(AppStore.self) private var store
    @AppStorage(ServiceSettings.urlKey) private var serviceURL = ServiceSettings.defaultURL
    @AppStorage(ServiceSettings.tokenKey) private var token = ""
    @State private var testResult: String?
    @State private var testOK = false
    @State private var testing = false

    var body: some View {
        Form {
            Section {
                TextField("Address", text: $serviceURL, prompt: Text(ServiceSettings.defaultURL))
                SecureField("Token", text: $token, prompt: Text("NOTES_TOKEN from .env"))
                HStack {
                    if let testResult {
                        Label(testResult, systemImage: testOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(testOK ? Theme.positive : Theme.negative)
                    }
                    Spacer()
                    if testing { ProgressView().controlSize(.small) }
                    Button("Connect & Test") { Task { await test() } }
                }
            } header: {
                Text("Newsdesk")
            } footer: {
                Text("Stored on this Mac only. Use http://localhost:3030 when the service runs here, or the server’s home-network address.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func test() async {
        testing = true
        defer { testing = false }
        await store.reconfigureService()
        if let error = await store.testConnection() {
            testOK = false
            testResult = error
        } else {
            testOK = true
            testResult = "Connected"
            await store.loadConfig()
        }
    }
}

/// Edits a list of strings as comma-separated text.
private func list(_ binding: Binding<[String]>) -> Binding<String> {
    Binding(
        get: { binding.wrappedValue.joined(separator: ", ") },
        set: { binding.wrappedValue = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    )
}
