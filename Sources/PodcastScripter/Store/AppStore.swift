import Foundation
import Observation

enum Route: Hashable {
    case home
    case editor(Script.ID)
}

enum SidebarSyncState: Equatable {
    case idle
    case syncing
    case synced(Date)
    case failed(String)
}

enum ConnectionState: Equatable {
    case connecting
    case online(lastSync: Date)
    case offline(reason: String)
}

/// One project's data kept on this Mac (a show about one team). Its id matches the notes
/// service's project; it's empty until the first connection links it.
struct ProjectData: Codable, Equatable {
    var id: String
    var name: String
    var scripts: [Script] = []
    /// Mirrors the notes service inbox, cached for offline use.
    var storyQueue: [StoryItem] = []
    var trackedStories: [TrackedStory] = []
    /// Last settings seen from the notes service.
    var config: AppConfig?

    init(id: String, name: String, scripts: [Script] = [], storyQueue: [StoryItem] = [], trackedStories: [TrackedStory] = [], config: AppConfig? = nil) {
        self.id = id
        self.name = name
        self.scripts = scripts
        self.storyQueue = storyQueue
        self.trackedStories = trackedStories
        self.config = config
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "My Show"
        scripts = try c.decodeIfPresent([Script].self, forKey: .scripts) ?? []
        storyQueue = try c.decodeIfPresent([StoryItem].self, forKey: .storyQueue) ?? []
        trackedStories = try c.decodeIfPresent([TrackedStory].self, forKey: .trackedStories) ?? []
        // An old settings copy must never stop a project's scripts from loading.
        config = try? c.decodeIfPresent(AppConfig.self, forKey: .config)
    }
}

/// Everything the user creates; written to disk as JSON.
private struct PersistedState: Codable {
    var projects: [ProjectData]
    var currentProject: String

    private enum CodingKeys: String, CodingKey {
        case version, showProjects, currentProject
    }

    /// Before projects existed the file held one show's data at the top level, with scripts
    /// saved under "projects".
    private enum LegacyKeys: String, CodingKey {
        case projects, storyQueue, trackedStories, config
    }

    init(projects: [ProjectData], currentProject: String) {
        self.projects = projects
        self.currentProject = currentProject
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if (try c.decodeIfPresent(Int.self, forKey: .version)) ?? 1 >= 2 {
            projects = try c.decodeIfPresent([ProjectData].self, forKey: .showProjects) ?? []
            currentProject = try c.decodeIfPresent(String.self, forKey: .currentProject) ?? ""
            return
        }
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        let config = try? legacy.decodeIfPresent(AppConfig.self, forKey: .config)
        projects = [ProjectData(
            id: "",
            name: config?.show.fullName ?? "My Show",
            scripts: try legacy.decodeIfPresent([Script].self, forKey: .projects) ?? [],
            storyQueue: try legacy.decodeIfPresent([StoryItem].self, forKey: .storyQueue) ?? [],
            trackedStories: try legacy.decodeIfPresent([TrackedStory].self, forKey: .trackedStories) ?? [],
            config: config
        )]
        currentProject = ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(2, forKey: .version)
        try c.encode(projects, forKey: .showProjects)
        try c.encode(currentProject, forKey: .currentProject)
    }
}

@MainActor
@Observable
final class AppStore {
    // MARK: Projects
    /// Every project's local data. The properties below read and write the current one.
    var projectData: [ProjectData] = [ProjectData(id: "", name: AppConfig.fallback.show.fullName)]
    var currentProjectID = ""
    /// Projects known to the notes service (name, team), for the switcher.
    var serviceProjects: [ProjectInfo] = []

    private var currentIndex: Int {
        projectData.firstIndex { $0.id == currentProjectID } ?? 0
    }

    private var current: ProjectData {
        get { projectData[currentIndex] }
        set { projectData[currentIndex] = newValue }
    }

    var currentProjectName: String { current.name }

    /// Show, template, team and source settings (from the notes service; cached for offline use).
    var config: AppConfig {
        get { current.config ?? .fallback }
        set { current.config = newValue }
    }

    var scripts: [Script] {
        get { current.scripts }
        set { current.scripts = newValue }
    }

    var storyQueue: [StoryItem] {
        get { current.storyQueue }
        set { current.storyQueue = newValue }
    }

    var trackedStories: [TrackedStory] {
        get { current.trackedStories }
        set { current.trackedStories = newValue }
    }

    // Fetched from the notes service; not persisted
    /// Power rankings, synced on launch and with the banner's Sync button.
    var rankings: RankingsSummary?
    var rankingsSync: SidebarSyncState = .idle
    /// Earlier seasons, loaded when picked in the Rankings tab.
    var pastRankings: [Int: RankingsSummary] = [:]
    var news: [NewsItem] = []
    // Sidebar data (standings, matches): synced on launch and with the Sync button only.
    var standings: Standings?
    var matches: Matches?
    var sidebarSync: SidebarSyncState = .idle
    var connection: ConnectionState = .connecting

    // UI state
    /// The open screen. Remembered so the app reopens where you left off.
    var route: Route = .home {
        didSet {
            if case .editor(let id) = route {
                UserDefaults.standard.set(id.uuidString, forKey: Self.lastScriptKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.lastScriptKey)
            }
        }
    }
    private static let lastScriptKey = "lastOpenScript"
    var searchText = ""
    /// Selected story-queue items and news stories (their IDs never collide).
    var selectedStoryIDs: Set<UUID> = []
    var lastError: String?

    private var service: NotesService
    /// Tests pass a fake service; it's kept as-is when switching projects.
    private let injectedService: Bool
    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    init(service: NotesService? = nil, fileURL: URL = AppStore.defaultFileURL) {
        self.service = service ?? NotesServiceClient(baseURL: ServiceSettings.baseURL, token: ServiceSettings.token)
        self.injectedService = service != nil
        self.fileURL = fileURL
        load()
        if !injectedService { self.service = makeClient() }
        if let saved = UserDefaults.standard.string(forKey: Self.lastScriptKey),
           let id = UUID(uuidString: saved), script(id) != nil {
            route = .editor(id)
        }
    }

    /// A client for the current project (requests carry its id).
    private func makeClient() -> NotesService {
        var client = NotesServiceClient(baseURL: ServiceSettings.baseURL, token: ServiceSettings.token)
        client.projectID = currentProjectID
        return client
    }

    /// Call after the service URL or token changes in Settings.
    func reconfigureService() async {
        if !injectedService { service = makeClient() }
        connection = .connecting
        await refresh()
    }

    // MARK: - Projects

    /// Loads the service's projects, links this Mac's data to them, and adds any created elsewhere.
    func refreshProjects() async {
        guard let list = try? await service.listProjects(), !list.isEmpty else { return }
        serviceProjects = list
        // Data from before projects (or a new install) belongs to the default project.
        if let index = projectData.firstIndex(where: { $0.id.isEmpty }), let primary = list.first(where: \.isDefault) ?? list.first,
           !projectData.contains(where: { $0.id == primary.id }) {
            let wasCurrent = currentProjectID == projectData[index].id
            projectData[index].id = primary.id
            projectData[index].name = primary.name
            if wasCurrent { currentProjectID = primary.id }
        }
        for project in list {
            if let index = projectData.firstIndex(where: { $0.id == project.id }) {
                projectData[index].name = project.name
            } else {
                projectData.append(ProjectData(id: project.id, name: project.name))
            }
        }
        if !injectedService { service = makeClient() }
        save()
    }

    /// Switches to another project and reloads everything for it.
    func switchProject(to id: String) async {
        guard id != currentProjectID, projectData.contains(where: { $0.id == id }) else { return }
        save()
        currentProjectID = id
        route = .home
        // Nothing fetched for the previous project carries over.
        news = []
        standings = nil
        matches = nil
        rankings = nil
        pastRankings = [:]
        chat = []
        selectedStoryIDs = []
        searchText = ""
        sidebarSync = .idle
        rankingsSync = .idle
        if !injectedService { service = makeClient() }
        save()
        await loadConfig()
        async let queue: Void = refresh()
        async let sidebar: Void = syncSidebar(force: false)
        async let ranks: Void = syncRankings()
        _ = await (queue, sidebar, ranks)
    }

    /// Creates a project for another team on the notes service, then switches to it.
    func createProject(_ request: NewProjectRequest) async throws {
        let created = try await service.createProject(request)
        projectData.append(ProjectData(id: created.id, name: created.name))
        serviceProjects.append(created)
        save()
        await switchProject(to: created.id)
    }

    func renameCurrentProject(to name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !currentProjectID.isEmpty else { return }
        let updated = try await service.updateProject(id: currentProjectID, name: trimmed, makeDefault: false)
        current.name = updated.name
        save()
        await refreshProjects()
    }

    /// Deletes the current project everywhere (its scripts on this Mac and its data in the service).
    func deleteCurrentProject() async throws {
        let id = currentProjectID
        guard projectData.count > 1, !id.isEmpty else { return }
        try await service.deleteProject(id: id)
        projectData.removeAll { $0.id == id }
        serviceProjects.removeAll { $0.id == id }
        currentProjectID = ""
        let next = serviceProjects.first(where: \.isDefault)?.id ?? projectData[0].id
        currentProjectID = next
        if !injectedService { service = makeClient() }
        route = .home
        save()
        await loadConfig()
        await refresh()
        await syncSidebar(force: false)
        await syncRankings()
    }

    /// `PODCAST_SCRIPTER_DATA=/path/data.json` overrides the location (handy for testing).
    static var defaultFileURL: URL {
        if let override = ProcessInfo.processInfo.environment["PODCAST_SCRIPTER_DATA"] {
            return URL(fileURLWithPath: override)
        }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PodcastScripter", isDirectory: true)
        return dir.appendingPathComponent("data.json")
    }

    // MARK: - Loading & saving

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            seedSampleData()
            return
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let state = try decoder.decode(PersistedState.self, from: data)
            if !state.projects.isEmpty { projectData = state.projects }
            currentProjectID = state.projects.contains { $0.id == state.currentProject } ? state.currentProject : projectData[0].id
        } catch {
            lastError = "Couldn't read saved data: \(error.localizedDescription)"
        }
    }

    /// Pulls the inbox and news. Failures only change `connection`; the cached queue stays.
    func refresh() async {
        do {
            async let inbox = service.fetchInbox()
            async let teamNews = service.fetchNews(category: .team, limit: 40)
            async let leagueNews = service.fetchNews(category: .league, limit: 40)
            let (items, team, league) = try await (inbox, teamNews, leagueNews)

            if items != storyQueue {
                storyQueue = items
                save()
            }
            news = team + league
            selectedStoryIDs.formIntersection(storyQueue.map(\.id) + news.map(\.id))
            connection = .online(lastSync: Date())
        } catch {
            connection = .offline(reason: error.localizedDescription)
        }
    }

    // MARK: - Settings

    /// Refreshes settings from the notes service; keeps the cached copy if it can't be reached.
    func loadConfig() async {
        guard let latest = try? await service.fetchConfig(), latest != config else { return }
        config = latest
        save()
    }

    /// Saves settings to the notes service, then re-syncs everything that depends on the team.
    func saveConfig(_ updated: AppConfig) async throws {
        let teamChanged = updated.team != config.team || updated.competitions != config.competitions
        config = try await service.saveConfig(updated)
        save()
        if teamChanged {
            standings = nil
            matches = nil
            async let sidebar: Void = syncSidebar(force: true)
            async let queue: Void = refresh()
            _ = await (sidebar, queue)
        }
    }

    func resetConfig() async throws {
        config = try await service.resetConfig()
        save()
        await syncSidebar(force: true)
    }

    // MARK: - Gemma

    /// The Ask Gemma conversation (kept while the app is open).
    var chat: [ChatMessage] = []
    var isAsking = false

    private static func isoDay(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day())
    }

    func aiStory(_ story: TrackedStory) -> AIStory {
        AIStory(
            id: story.id.uuidString,
            title: story.title,
            latestUpdate: story.latestUpdate,
            mentions: story.mentions.map {
                AIMention(episode: $0.scriptName, date: Self.isoDay($0.episodeDate), excerpt: $0.excerpt, note: $0.note, status: $0.status?.rawValue)
            },
            status: story.status?.rawValue,
            statusHistory: story.statusHistory.map { AIStatusChange(status: $0.status?.rawValue, date: Self.isoDay($0.changedAt)) },
            resolvedAt: story.resolvedAt.map(Self.isoDay),
            resolution: story.resolution
        )
    }

    /// A script's text for Gemma, with rumor/reported/confirmed passages labeled.
    func aiText(_ script: Script) -> String {
        guard script.richText != nil else { return script.plainText }
        let formatted = ScriptStyle.load(script)
        // The formatted copy carries the marks; only trust it if it matches the plain text.
        guard formatted.string == script.plainText else { return script.plainText }
        return ScriptStyle.withStatusTags(formatted)
    }

    func aiEpisode(_ script: Script, includeScript: Bool = false) -> AIEpisode {
        AIEpisode(
            name: script.name,
            date: Self.isoDay(script.episodeDate),
            script: includeScript ? aiText(script) : nil,
            stories: includeScript ? script.notes.map { AIEpisodeStory(kind: $0.kind.rawValue, title: $0.title, body: $0.body) } : nil
        )
    }

    /// Everything only the app knows, for Ask Gemma.
    var aiAppContext: AIAppContext {
        AIAppContext(
            scripts: scripts.sorted { $0.episodeDate > $1.episodeDate }.map {
                AIScript(name: $0.name, date: Self.isoDay($0.episodeDate), script: aiText($0))
            },
            trackedStories: trackedStories.map(aiStory)
        )
    }

    func ask(_ question: String) async {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAsking else { return }
        let history = chat
        chat.append(ChatMessage(role: "user", content: trimmed))
        isAsking = true
        defer { isAsking = false }
        do {
            let reply = try await service.ask(trimmed, history: history, app: aiAppContext)
            chat.append(ChatMessage(role: "assistant", content: reply.answer, detail: "\(reply.model) · \(String(format: "%.1f", Double(reply.ms) / 1000))s", sources: reply.sources))
        } catch {
            chat.append(ChatMessage(role: "assistant", content: error.localizedDescription, detail: "error"))
        }
    }

    /// Opens the script a Sources passage came from (matched by name and episode date).
    func openScript(named name: String, on date: String) {
        let match = scripts.first { $0.name == name && Self.isoDay($0.episodeDate) == date }
            ?? scripts.first { $0.name == name }
        if let match { open(match.id) }
    }

    func suggestStory(for excerpt: String, in scriptID: Script.ID) async throws -> StorySuggestion? {
        guard let script = script(scriptID) else { return nil }
        return try await service.suggestStory(excerpt: excerpt, episode: aiEpisode(script), stories: trackedStories.map(aiStory))
    }

    /// Stories to brief on: the ones tagged in this episode, else the most recently updated.
    func briefingStories(for scriptID: Script.ID) -> [TrackedStory] {
        let tagged = trackedStories(in: scriptID).filter { !$0.isResolved }
        if !tagged.isEmpty { return tagged }
        return Array(trackedStories.filter { !$0.isResolved }.sorted { $0.lastUpdated > $1.lastUpdated }.prefix(8))
    }

    func briefing(for scriptID: Script.ID) async throws -> [StoryBriefing] {
        guard let script = script(scriptID) else { return [] }
        return try await service.briefing(episode: aiEpisode(script), stories: briefingStories(for: scriptID).map(aiStory))
    }

    func introBullets(for scriptID: Script.ID) async throws -> [String] {
        guard let script = script(scriptID) else { return [] }
        return try await service.introBullets(episode: aiEpisode(script, includeScript: true))
    }

    func aiStatus() async throws -> AIStatus {
        try await service.aiStatus()
    }

    func testAI() async throws -> AIReply {
        try await service.testAI()
    }

    func teams(inLeague league: String) async throws -> [TeamOption] {
        try await service.fetchTeams(league: league)
    }

    /// Loads the standings and matches. `force` (the Sync button) bypasses the service's cache.
    func syncSidebar(force: Bool) async {
        guard sidebarSync != .syncing else { return }
        sidebarSync = .syncing
        let service = service
        async let standingsResult = capture { try await service.fetchStandings(refresh: force) }
        async let matchesResult = capture { try await service.fetchMatches(refresh: force) }
        let (standingsOutcome, matchesOutcome) = await (standingsResult, matchesResult)

        var failures: [String] = []
        switch standingsOutcome {
        case .success(let value): standings = value
        case .failure(let error): failures.append(error.localizedDescription)
        }
        switch matchesOutcome {
        case .success(let value): matches = value
        case .failure(let error): failures.append(error.localizedDescription)
        }
        sidebarSync = failures.isEmpty ? .synced(Date()) : .failed(failures[0])
    }

    /// Shows the saved rankings right away, then fetches every source.
    func syncRankings() async {
        guard rankingsSync != .syncing else { return }
        rankingsSync = .syncing
        if rankings == nil, let saved = try? await service.fetchRankings(season: nil) {
            rankings = saved
        }
        do {
            rankings = try await service.syncRankings()
            rankingsSync = .synced(Date())
        } catch {
            rankingsSync = .failed(error.localizedDescription)
        }
    }

    /// The rankings to graph for `season`: the live copy for the current season, else a saved one.
    func rankings(for season: Int) async -> RankingsSummary? {
        if let rankings, rankings.season == season { return rankings }
        if let cached = pastRankings[season] { return cached }
        let loaded = try? await service.fetchRankings(season: season)
        pastRankings[season] = loaded
        return loaded
    }

    private nonisolated func capture<T: Sendable>(_ operation: @Sendable () async throws -> T) async -> Result<T, Error> {
        do {
            return .success(try await operation())
        } catch {
            return .failure(error)
        }
    }

    /// Keeps the queue current with things shared from the phone. Runs for the app's lifetime.
    func runRefreshLoop(every interval: Duration = .seconds(60)) async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: interval)
        }
    }

    /// Debounced so typing in the editor doesn't write on every keystroke.
    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    func save() {
        saveTask?.cancel()
        let state = PersistedState(projects: projectData, currentProject: currentProjectID)
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            lastError = "Couldn't save: \(error.localizedDescription)"
        }
    }

    private func seedSampleData() {
        let cal = Calendar.current
        scripts = (1...4).reversed().map { n in
            Script(
                name: "Script \(n)",
                episodeDate: cal.date(byAdding: .day, value: -7 * (4 - n), to: Date()) ?? Date()
            )
        }
        trackedStories = [
            TrackedStory(title: "Justen Glad Injury"),
            TrackedStory(title: "Diego Luna Injury"),
            TrackedStory(title: "Zach Booth Injury"),
        ]
    }

    // MARK: - Scripts

    var filteredScripts: [Script] {
        let sorted = scripts.sorted { $0.episodeDate > $1.episodeDate }
        guard !searchText.isEmpty else { return sorted }
        return sorted.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.plainText.localizedCaseInsensitiveContains(searchText)
        }
    }

    func script(_ id: Script.ID) -> Script? {
        scripts.first { $0.id == id }
    }

    /// New scripts start from the show template (sections, intro and outro).
    @discardableResult
    func createScript(name: String, date: Date, notes: [StoryItem] = []) -> Script {
        var script = Script(name: name, episodeDate: date, notes: notes)
        let template = ScriptTemplate.make(for: date, config: config)
        script.plainText = template.string
        script.richText = ScriptStyle.rtfData(template)
        scripts.append(script)
        save()
        return script
    }

    func updateScript(_ script: Script, debounced: Bool = false) {
        guard let i = scripts.firstIndex(where: { $0.id == script.id }) else { return }
        var updated = script
        updated.updatedAt = Date()
        scripts[i] = updated
        debounced ? scheduleSave() : save()
    }

    func deleteScript(_ id: Script.ID) {
        scripts.removeAll { $0.id == id }
        if route == .editor(id) { route = .home }
        save()
    }

    func open(_ id: Script.ID) {
        route = .editor(id)
    }

    // MARK: - Story queue

    var filteredQueue: [StoryItem] {
        guard !searchText.isEmpty else { return storyQueue }
        return storyQueue.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
                || $0.body.localizedCaseInsensitiveContains(searchText)
        }
    }

    func toggleSelection(_ id: UUID) {
        if selectedStoryIDs.contains(id) {
            selectedStoryIDs.remove(id)
        } else {
            selectedStoryIDs.insert(id)
        }
    }

    /// Checks every story in `ids`, or unchecks them all if they're all checked already.
    func toggleSelectAll(_ ids: [UUID]) {
        let all = Set(ids)
        if !all.isEmpty, all.isSubset(of: selectedStoryIDs) {
            selectedStoryIDs.subtract(all)
        } else {
            selectedStoryIDs.formUnion(all)
        }
    }

    func clearSelection() {
        selectedStoryIDs.removeAll()
    }

    /// Selected queue items and news, in on-screen order (queue first).
    private var selectedStories: [StoryItem] {
        storyQueue.filter { selectedStoryIDs.contains($0.id) }
            + news.filter { selectedStoryIDs.contains($0.id) }.map(\.asStoryItem)
    }

    /// Copies the selected stories into a new script, opens it, and marks them used in the service
    /// so they leave the queue and news columns.
    func createScriptFromSelected() async {
        let selected = selectedStories
        guard !selected.isEmpty else { return }
        let script = createScript(
            name: config.show.fullName,
            date: Date(),
            notes: selected
        )
        removeLocally(selected.map(\.id))
        open(script.id)

        do {
            for item in selected { try await service.setStatus(item.id, .used) }
        } catch {
            lastError = "The script was created, but some stories couldn't be marked as used, so they may reappear. \(error.localizedDescription)"
        }
    }

    /// Appends the selected stories to an existing script (skipping ones it already has), opens it,
    /// and marks them used in the service.
    func addSelected(toScript id: Script.ID) async {
        guard var script = script(id) else { return }
        let existing = Set(script.notes.map(\.id))
        let selected = selectedStories
        guard !selected.isEmpty else { return }
        script.notes += selected.filter { !existing.contains($0.id) }
        updateScript(script)
        removeLocally(selected.map(\.id))
        open(id)

        do {
            for item in selected { try await service.setStatus(item.id, .used) }
        } catch {
            lastError = "The stories were added, but some couldn't be marked as used, so they may reappear. \(error.localizedDescription)"
        }
    }

    /// Takes stories out of a script and puts them back in the service's inbox, so queue items
    /// return to the Story Queue and news returns to its news column.
    func returnToQueue(_ ids: Set<UUID>, from scriptID: Script.ID) async {
        guard var script = script(scriptID) else { return }
        let returning = script.notes.filter { ids.contains($0.id) }
        guard !returning.isEmpty else { return }
        script.notes.removeAll { ids.contains($0.id) }
        updateScript(script)

        var failed = 0
        for story in returning {
            do {
                try await service.setStatus(story.id, .inbox)
            } catch {
                failed += 1
            }
        }
        if failed > 0 {
            lastError = "\(failed) of \(returning.count) stories couldn't be returned to the queue in the notes service; they've been removed from the script."
        }
        await refresh()
    }

    /// Hides the selected stories. They're dismissed rather than deleted, so they stay in the
    /// service's history (and news feeds don't re-add them).
    func deleteSelected() async {
        for item in selectedStories {
            do {
                try await service.setStatus(item.id, .dismissed)
                removeLocally([item.id])
            } catch {
                lastError = "Couldn't delete from the notes service: \(error.localizedDescription)"
                break
            }
        }
    }

    private func removeLocally(_ ids: [UUID]) {
        let ids = Set(ids)
        storyQueue.removeAll { ids.contains($0.id) }
        news.removeAll { ids.contains($0.id) }
        selectedStoryIDs.subtract(ids)
        save()
    }

    /// Sends a link or note to the service. Returns false (and sets `lastError`) on failure.
    func addStory(input: String) async -> Bool {
        do {
            let item = try await service.add(input: input)
            storyQueue.removeAll { $0.id == item.id }
            storyQueue.insert(item, at: 0)
            save()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func testConnection() async -> String? {
        do {
            try await service.checkHealth()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - Story tracker

    /// Stories still being followed (search applies).
    var filteredTrackedStories: [TrackedStory] {
        trackedStories.filter { !$0.isResolved && matchesSearch($0) }
    }

    /// Wrapped-up stories, most recently resolved first (search applies).
    var resolvedStories: [TrackedStory] {
        trackedStories.filter { $0.isResolved && matchesSearch($0) }
            .sorted { ($0.resolvedAt ?? .distantPast) > ($1.resolvedAt ?? .distantPast) }
    }

    private func matchesSearch(_ story: TrackedStory) -> Bool {
        searchText.isEmpty || story.title.localizedCaseInsensitiveContains(searchText)
    }

    /// Moves a story to the Resolved list, with an optional note on how it ended.
    func resolveStory(_ id: TrackedStory.ID, resolution: String?) {
        guard let i = trackedStories.firstIndex(where: { $0.id == id }) else { return }
        let note = resolution?.trimmingCharacters(in: .whitespacesAndNewlines)
        trackedStories[i].resolvedAt = Date()
        trackedStories[i].resolution = note?.isEmpty == false ? note : nil
        trackedStories[i].lastUpdated = Date()
        save()
    }

    /// Brings a resolved story back to the active tracker.
    func reopenStory(_ id: TrackedStory.ID) {
        guard let i = trackedStories.firstIndex(where: { $0.id == id }) else { return }
        trackedStories[i].resolvedAt = nil
        trackedStories[i].resolution = nil
        trackedStories[i].lastUpdated = Date()
        save()
    }

    func addTrackedStory(title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        trackedStories.append(TrackedStory(title: trimmed))
        save()
    }

    func updateTrackedStory(_ story: TrackedStory) {
        guard let i = trackedStories.firstIndex(where: { $0.id == story.id }) else { return }
        var updated = story
        // A status picked in the sheet is recorded in the story's history.
        if story.status != trackedStories[i].status {
            updated.status = trackedStories[i].status
            updated.statusHistory = trackedStories[i].statusHistory
            updated.setStatus(story.status)
        }
        updated.lastUpdated = Date()
        trackedStories[i] = updated
        save()
    }

    /// Tags a script passage as part of a tracked story (an existing one, or a new one by title).
    /// Returns the story it was added to.
    /// Sets a tracked story's status from the tracker (nil clears it).
    func setStatus(_ status: StoryStatus?, ofStory id: TrackedStory.ID) {
        guard let i = trackedStories.firstIndex(where: { $0.id == id }) else { return }
        trackedStories[i].setStatus(status)
        trackedStories[i].lastUpdated = Date()
        save()
    }

    @discardableResult
    func tagPassage(_ excerpt: String, in scriptID: Script.ID, story storyID: TrackedStory.ID?, newTitle: String?, note: String?,
                    passageStatus: StoryStatus? = nil, storyStatus: StoryStatus?? = nil) -> TrackedStory? {
        guard let script = script(scriptID) else { return nil }
        let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let mention = StoryMention(
            scriptID: script.id,
            scriptName: script.name,
            episodeDate: script.episodeDate,
            excerpt: excerpt.trimmingCharacters(in: .whitespacesAndNewlines),
            note: trimmedNote?.isEmpty == false ? trimmedNote : nil,
            status: passageStatus
        )

        let index: Int
        if let storyID, let existing = trackedStories.firstIndex(where: { $0.id == storyID }) {
            index = existing
        } else {
            let title = (newTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            trackedStories.append(TrackedStory(title: title))
            index = trackedStories.count - 1
        }
        trackedStories[index].mentions.append(mention)
        // `storyStatus` nil = leave the story's status alone; .some(x) = set it (x may be nil to clear).
        if let storyStatus { trackedStories[index].setStatus(storyStatus) }
        trackedStories[index].latestUpdate = mention.note ?? mention.excerpt
        trackedStories[index].lastUpdated = Date()
        save()
        return trackedStories[index]
    }

    /// Tracked stories mentioned in a script, most recently updated first.
    func trackedStories(in scriptID: Script.ID) -> [TrackedStory] {
        trackedStories
            .filter { $0.mentions.contains { $0.scriptID == scriptID } }
            .sorted { $0.lastUpdated > $1.lastUpdated }
    }

    func deleteTrackedStory(_ id: TrackedStory.ID) {
        trackedStories.removeAll { $0.id == id }
        save()
    }

    // MARK: - News

    func news(in category: NewsCategory) -> [NewsItem] {
        news.filter {
            $0.category == category
                && (searchText.isEmpty
                    || $0.headline.localizedCaseInsensitiveContains(searchText)
                    || $0.source.localizedCaseInsensitiveContains(searchText))
        }
    }
}
