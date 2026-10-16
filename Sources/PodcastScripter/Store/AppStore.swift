import Foundation
import Observation

enum Route: Hashable {
    case home
    case editor(Project.ID)
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

/// Everything the user creates; written to disk as JSON.
private struct PersistedState: Codable {
    var projects: [Project] = []
    var storyQueue: [StoryItem] = []
    var trackedStories: [TrackedStory] = []
    /// Last settings seen from the notes service.
    var config: AppConfig?

    init(projects: [Project] = [], storyQueue: [StoryItem] = [], trackedStories: [TrackedStory] = [], config: AppConfig? = nil) {
        self.projects = projects
        self.storyQueue = storyQueue
        self.trackedStories = trackedStories
        self.config = config
    }

    // A settings copy from an older version must never stop projects from loading.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projects = try c.decodeIfPresent([Project].self, forKey: .projects) ?? []
        storyQueue = try c.decodeIfPresent([StoryItem].self, forKey: .storyQueue) ?? []
        trackedStories = try c.decodeIfPresent([TrackedStory].self, forKey: .trackedStories) ?? []
        config = try? c.decodeIfPresent(AppConfig.self, forKey: .config)
    }
}

@MainActor
@Observable
final class AppStore {
    /// Show, template, team and source settings (from the notes service; cached for offline use).
    var config: AppConfig = .fallback

    // Persisted. `storyQueue` mirrors the notes service inbox and is cached for offline use.
    var projects: [Project] = []
    var storyQueue: [StoryItem] = []
    var trackedStories: [TrackedStory] = []

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
                UserDefaults.standard.set(id.uuidString, forKey: Self.lastProjectKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.lastProjectKey)
            }
        }
    }
    private static let lastProjectKey = "lastOpenProject"
    var searchText = ""
    /// Selected story-queue items and news stories (their IDs never collide).
    var selectedStoryIDs: Set<UUID> = []
    var lastError: String?

    private var service: NotesService
    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    init(service: NotesService? = nil, fileURL: URL = AppStore.defaultFileURL) {
        self.service = service ?? NotesServiceClient(baseURL: ServiceSettings.baseURL, token: ServiceSettings.token)
        self.fileURL = fileURL
        load()
        if let saved = UserDefaults.standard.string(forKey: Self.lastProjectKey),
           let id = UUID(uuidString: saved), project(id) != nil {
            route = .editor(id)
        }
    }

    /// Call after the service URL or token changes in Settings.
    func reconfigureService() async {
        service = NotesServiceClient(baseURL: ServiceSettings.baseURL, token: ServiceSettings.token)
        connection = .connecting
        await refresh()
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
            projects = state.projects
            storyQueue = state.storyQueue
            trackedStories = state.trackedStories
            if let saved = state.config { config = saved }
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
                AIMention(episode: $0.projectName, date: Self.isoDay($0.episodeDate), excerpt: $0.excerpt, note: $0.note)
            }
        )
    }

    func aiEpisode(_ project: Project, includeScript: Bool = false) -> AIEpisode {
        AIEpisode(
            name: project.name,
            date: Self.isoDay(project.episodeDate),
            script: includeScript ? project.script : nil,
            stories: includeScript ? project.notes.map { AIEpisodeStory(kind: $0.kind.rawValue, title: $0.title, body: $0.body) } : nil
        )
    }

    /// Everything only the app knows, for Ask Gemma.
    var aiAppContext: AIAppContext {
        AIAppContext(
            projects: projects.sorted { $0.episodeDate > $1.episodeDate }.map {
                AIProject(name: $0.name, date: Self.isoDay($0.episodeDate), script: $0.script)
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
            chat.append(ChatMessage(role: "assistant", content: reply.answer, detail: "\(reply.model) · \(String(format: "%.1f", Double(reply.ms) / 1000))s"))
        } catch {
            chat.append(ChatMessage(role: "assistant", content: error.localizedDescription, detail: "error"))
        }
    }

    func suggestStory(for excerpt: String, in projectID: Project.ID) async throws -> StorySuggestion? {
        guard let project = project(projectID) else { return nil }
        return try await service.suggestStory(excerpt: excerpt, episode: aiEpisode(project), stories: trackedStories.map(aiStory))
    }

    /// Stories to brief on: the ones tagged in this episode, else the most recently updated.
    func briefingStories(for projectID: Project.ID) -> [TrackedStory] {
        let tagged = trackedStories(in: projectID)
        if !tagged.isEmpty { return tagged }
        return Array(trackedStories.sorted { $0.lastUpdated > $1.lastUpdated }.prefix(8))
    }

    func briefing(for projectID: Project.ID) async throws -> [StoryBriefing] {
        guard let project = project(projectID) else { return [] }
        return try await service.briefing(episode: aiEpisode(project), stories: briefingStories(for: projectID).map(aiStory))
    }

    func introBullets(for projectID: Project.ID) async throws -> [String] {
        guard let project = project(projectID) else { return [] }
        return try await service.introBullets(episode: aiEpisode(project, includeScript: true))
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
        let state = PersistedState(
            projects: projects,
            storyQueue: storyQueue,
            trackedStories: trackedStories,
            config: config
        )
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
        projects = (1...4).reversed().map { n in
            Project(
                name: "Project \(n)",
                episodeDate: cal.date(byAdding: .day, value: -7 * (4 - n), to: Date()) ?? Date()
            )
        }
        trackedStories = [
            TrackedStory(title: "Justen Glad Injury"),
            TrackedStory(title: "Diego Luna Injury"),
            TrackedStory(title: "Zach Booth Injury"),
        ]
    }

    // MARK: - Projects

    var filteredProjects: [Project] {
        let sorted = projects.sorted { $0.episodeDate > $1.episodeDate }
        guard !searchText.isEmpty else { return sorted }
        return sorted.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.script.localizedCaseInsensitiveContains(searchText)
        }
    }

    func project(_ id: Project.ID) -> Project? {
        projects.first { $0.id == id }
    }

    /// New projects start from the show template (sections, intro and outro).
    @discardableResult
    func createProject(name: String, date: Date, notes: [StoryItem] = []) -> Project {
        var project = Project(name: name, episodeDate: date, notes: notes)
        let script = ScriptTemplate.make(for: date, config: config)
        project.script = script.string
        project.richText = ScriptStyle.rtfData(script)
        projects.append(project)
        save()
        return project
    }

    func updateProject(_ project: Project, debounced: Bool = false) {
        guard let i = projects.firstIndex(where: { $0.id == project.id }) else { return }
        var updated = project
        updated.updatedAt = Date()
        projects[i] = updated
        debounced ? scheduleSave() : save()
    }

    func deleteProject(_ id: Project.ID) {
        projects.removeAll { $0.id == id }
        if route == .editor(id) { route = .home }
        save()
    }

    func open(_ id: Project.ID) {
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

    func clearSelection() {
        selectedStoryIDs.removeAll()
    }

    /// Selected queue items and news, in on-screen order (queue first).
    private var selectedStories: [StoryItem] {
        storyQueue.filter { selectedStoryIDs.contains($0.id) }
            + news.filter { selectedStoryIDs.contains($0.id) }.map(\.asStoryItem)
    }

    /// Copies the selected stories into a new project, opens it, and marks them used in the service
    /// so they leave the queue and news columns.
    func createProjectFromSelected() async {
        let selected = selectedStories
        guard !selected.isEmpty else { return }
        let project = createProject(
            name: config.show.fullName,
            date: Date(),
            notes: selected
        )
        removeLocally(selected.map(\.id))
        open(project.id)

        do {
            for item in selected { try await service.setStatus(item.id, .used) }
        } catch {
            lastError = "The project was created, but some stories couldn't be marked as used, so they may reappear. \(error.localizedDescription)"
        }
    }

    /// Appends the selected stories to an existing project (skipping ones it already has), opens it,
    /// and marks them used in the service.
    func addSelected(toProject id: Project.ID) async {
        guard var project = project(id) else { return }
        let existing = Set(project.notes.map(\.id))
        let selected = selectedStories
        guard !selected.isEmpty else { return }
        project.notes += selected.filter { !existing.contains($0.id) }
        updateProject(project)
        removeLocally(selected.map(\.id))
        open(id)

        do {
            for item in selected { try await service.setStatus(item.id, .used) }
        } catch {
            lastError = "The stories were added, but some couldn't be marked as used, so they may reappear. \(error.localizedDescription)"
        }
    }

    /// Takes stories out of a project and puts them back in the service's inbox, so queue items
    /// return to the Story Queue and news returns to its news column.
    func returnToQueue(_ ids: Set<UUID>, from projectID: Project.ID) async {
        guard var project = project(projectID) else { return }
        let returning = project.notes.filter { ids.contains($0.id) }
        guard !returning.isEmpty else { return }
        project.notes.removeAll { ids.contains($0.id) }
        updateProject(project)

        var failed = 0
        for story in returning {
            do {
                try await service.setStatus(story.id, .inbox)
            } catch {
                failed += 1
            }
        }
        if failed > 0 {
            lastError = "\(failed) of \(returning.count) stories couldn't be returned to the queue in the notes service; they've been removed from the project."
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

    var filteredTrackedStories: [TrackedStory] {
        guard !searchText.isEmpty else { return trackedStories }
        return trackedStories.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
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
        updated.lastUpdated = Date()
        trackedStories[i] = updated
        save()
    }

    /// Tags a script passage as part of a tracked story (an existing one, or a new one by title).
    /// Returns the story it was added to.
    @discardableResult
    func tagPassage(_ excerpt: String, in projectID: Project.ID, story storyID: TrackedStory.ID?, newTitle: String?, note: String?) -> TrackedStory? {
        guard let project = project(projectID) else { return nil }
        let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let mention = StoryMention(
            projectID: project.id,
            projectName: project.name,
            episodeDate: project.episodeDate,
            excerpt: excerpt.trimmingCharacters(in: .whitespacesAndNewlines),
            note: trimmedNote?.isEmpty == false ? trimmedNote : nil
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
        trackedStories[index].latestUpdate = mention.note ?? mention.excerpt
        trackedStories[index].lastUpdated = Date()
        save()
        return trackedStories[index]
    }

    /// Tracked stories mentioned in a project, most recently updated first.
    func trackedStories(in projectID: Project.ID) -> [TrackedStory] {
        trackedStories
            .filter { $0.mentions.contains { $0.projectID == projectID } }
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
