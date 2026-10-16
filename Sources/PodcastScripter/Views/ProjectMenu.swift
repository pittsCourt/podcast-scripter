import SwiftUI

/// The current project's name in the toolbar. Click to switch projects or start a new one.
struct ProjectMenu: View {
    @Environment(AppStore.self) private var store
    @State private var creating = false
    @State private var renaming = false
    @State private var newName = ""

    var body: some View {
        Menu {
            Section("Projects") {
                ForEach(store.projectData, id: \.id) { project in
                    Button {
                        Task { await store.switchProject(to: project.id) }
                    } label: {
                        if project.id == store.currentProjectID {
                            Label(project.name, systemImage: "checkmark")
                        } else {
                            Text(subtitle(for: project))
                        }
                    }
                }
            }
            Divider()
            Button("New Project…") { creating = true }
            Button("Rename Project…") {
                newName = store.currentProjectName
                renaming = true
            }
            .disabled(store.currentProjectID.isEmpty)
            SettingsLink { Text("Project Settings…") }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: Zoom.s(11), weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text(store.currentProjectName)
                    .font(.system(size: Zoom.s(13), weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Switch projects or start one for another team")
        .sheet(isPresented: $creating) {
            NewProjectSheet()
        }
        .alert("Rename Project", isPresented: $renaming) {
            TextField("Project name", text: $newName)
            Button("Rename") {
                let name = newName
                Task {
                    do { try await store.renameCurrentProject(to: name) } catch { store.lastError = error.localizedDescription }
                }
            }
            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Shown in the toolbar and the inbox page’s project picker. The show name used in scripts is set in Project Settings → Show.")
        }
    }

    private func subtitle(for project: ProjectData) -> String {
        guard let team = store.serviceProjects.first(where: { $0.id == project.id })?.team?.name else { return project.name }
        return "\(project.name)  ·  \(team)"
    }
}

/// A new show for another team: pick the league and team from ESPN, name the show.
struct NewProjectSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var sport = "soccer"
    @State private var league = "usa.1"
    @State private var teams: [TeamOption] = []
    @State private var teamID = ""
    @State private var host = ""
    @State private var xHandle = ""
    @State private var copySettings = true
    @State private var loadingTeams = false
    @State private var creating = false
    @State private var error: String?

    private static let leagues: [(code: String, name: String)] = [
        ("usa.1", "MLS"), ("usa.nwsl", "NWSL"), ("usa.usl.1", "USL Championship"),
        ("eng.1", "Premier League"), ("esp.1", "LaLiga"), ("ger.1", "Bundesliga"),
        ("ita.1", "Serie A"), ("fra.1", "Ligue 1"), ("mex.1", "Liga MX"),
    ]

    private var team: TeamOption? { teams.first { $0.id == teamID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New Project")
                .font(.system(size: Zoom.s(15), weight: .semibold))
                .padding([.horizontal, .top], 20)
            Text("A separate show for a team, with its own scripts, Story Queue, Story Tracker, news, table, matches and power rankings.")
                .font(.system(size: Zoom.s(12)))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.top, 4)

            Form {
                Section("Team") {
                    Picker("League", selection: $league) {
                        ForEach(Self.leagues, id: \.code) { Text($0.name).tag($0.code) }
                        if !Self.leagues.contains(where: { $0.code == league }) { Text(league).tag(league) }
                    }
                    TextField("ESPN league code", text: $league, prompt: Text("usa.1"))
                    if loadingTeams {
                        HStack { ProgressView().controlSize(.small); Text("Loading teams…").foregroundStyle(.secondary) }
                    } else if teams.isEmpty {
                        Text(error ?? "No teams loaded for that league yet.").foregroundStyle(.secondary)
                    } else {
                        Picker("Team", selection: $teamID) {
                            Text("Choose a team").tag("")
                            ForEach(teams) { Text($0.name).tag($0.id) }
                        }
                    }
                }
                Section("Show") {
                    TextField("Show name", text: $name, prompt: Text(team.map { "\($0.abbreviation ?? $0.name) Weekly" } ?? "e.g. Sounders Sound Off"))
                    TextField("Host", text: $host, prompt: Text(store.config.show.host))
                    TextField("X handle", text: $xHandle, prompt: Text("@yourshow"))
                }
                Section {
                    Toggle("Copy settings from \(store.currentProjectName)", isOn: $copySettings)
                } footer: {
                    Text("Copies the script template, competitions, power-ranking sources and AI settings, with the new team swapped in. You can change any of it in Project Settings. Ranking sources built for MLS only work for MLS teams.")
                        .foregroundStyle(.secondary)
                }
                if let error, !teams.isEmpty {
                    Text(error).foregroundStyle(Theme.negative)
                }
            }
            .formStyle(.grouped)
            .frame(height: 430)

            HStack {
                if creating { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Create Project") { Task { await create() } }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(team == nil || creating)
            }
            .padding(20)
        }
        .frame(width: 500)
        .task(id: league) { await loadTeams() }
    }

    private func loadTeams() async {
        let code = league.trimmingCharacters(in: .whitespaces)
        guard !code.isEmpty else { return }
        loadingTeams = true
        defer { loadingTeams = false }
        do {
            teams = try await store.teams(inLeague: code)
            error = teams.isEmpty ? "No teams found for \(code)." : nil
            if !teams.contains(where: { $0.id == teamID }) { teamID = "" }
        } catch {
            teams = []
            self.error = error.localizedDescription
        }
    }

    private func create() async {
        guard let team else { return }
        creating = true
        defer { creating = false }
        let showName = name.trimmingCharacters(in: .whitespaces).isEmpty
            ? "\(team.abbreviation ?? team.name) Weekly"
            : name.trimmingCharacters(in: .whitespaces)
        let request = NewProjectRequest(
            name: showName,
            fromProject: copySettings && !store.currentProjectID.isEmpty ? store.currentProjectID : nil,
            team: .init(
                name: team.name,
                shortName: team.abbreviation ?? team.shortName ?? team.name,
                espnTeamId: team.id,
                espnLeague: league.trimmingCharacters(in: .whitespaces),
                espnSport: sport
            ),
            show: .init(
                name: showName,
                fullName: showName,
                host: host.isEmpty ? store.config.show.host : host,
                xHandle: xHandle
            )
        )
        do {
            try await store.createProject(request)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
