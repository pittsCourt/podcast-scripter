import Foundation
import Observation

enum Route: Hashable {
    case home
    case editor(Project.ID)
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
}

@MainActor
@Observable
final class AppStore {
    // Persisted. `storyQueue` mirrors the notes service inbox and is cached for offline use.
    var projects: [Project] = []
    var storyQueue: [StoryItem] = []
    var trackedStories: [TrackedStory] = []

    // Fetched from the notes service; not persisted
    var rankings: [RankingGroup] = MockRankings.groups
    var news: [NewsItem] = []
    var connection: ConnectionState = .connecting

    // UI state
    var route: Route = .home
    var searchText = ""
    var selectedQueueIDs: Set<StoryItem.ID> = []
    var lastError: String?

    private var service: NotesService
    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    init(service: NotesService? = nil, fileURL: URL = AppStore.defaultFileURL) {
        self.service = service ?? NotesServiceClient(baseURL: ServiceSettings.baseURL, token: ServiceSettings.token)
        self.fileURL = fileURL
        load()
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
        } catch {
            lastError = "Couldn't read saved data: \(error.localizedDescription)"
        }
    }

    /// Pulls the inbox and news. Failures only change `connection`; the cached queue stays.
    func refresh() async {
        do {
            async let inbox = service.fetchInbox()
            async let teamNews = service.fetchNews(category: .team, limit: 15)
            async let leagueNews = service.fetchNews(category: .league, limit: 15)
            let (items, team, league) = try await (inbox, teamNews, leagueNews)

            if items != storyQueue {
                storyQueue = items
                selectedQueueIDs.formIntersection(items.map(\.id))
                save()
            }
            news = team + league
            connection = .online(lastSync: Date())
        } catch {
            connection = .offline(reason: error.localizedDescription)
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
            trackedStories: trackedStories
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

    @discardableResult
    func createProject(name: String, date: Date, notes: [StoryItem] = []) -> Project {
        let project = Project(name: name, episodeDate: date, notes: notes)
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

    func toggleSelection(_ id: StoryItem.ID) {
        if selectedQueueIDs.contains(id) {
            selectedQueueIDs.remove(id)
        } else {
            selectedQueueIDs.insert(id)
        }
    }

    /// Copies the selected queue items into a new project, opens it, and marks them used in the service.
    func createProjectFromSelected() async {
        let selected = storyQueue.filter { selectedQueueIDs.contains($0.id) }
        guard !selected.isEmpty else { return }
        let project = createProject(
            name: "\(ShowConfig.teamName) \(ShowConfig.showName)",
            date: Date(),
            notes: selected
        )
        storyQueue.removeAll { selectedQueueIDs.contains($0.id) }
        selectedQueueIDs.removeAll()
        save()
        open(project.id)

        do {
            for item in selected { try await service.markUsed(item.id) }
        } catch {
            lastError = "The project was created, but some stories couldn't be marked as used, so they may reappear in the queue. \(error.localizedDescription)"
        }
    }

    func deleteSelected() async {
        for id in selectedQueueIDs {
            do {
                try await service.delete(id)
                storyQueue.removeAll { $0.id == id }
                selectedQueueIDs.remove(id)
            } catch {
                lastError = "Couldn't delete from the notes service: \(error.localizedDescription)"
                break
            }
        }
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

    func deleteTrackedStory(_ id: TrackedStory.ID) {
        trackedStories.removeAll { $0.id == id }
        save()
    }

    // MARK: - News

    func news(in category: NewsCategory) -> [NewsItem] {
        news.filter { $0.category == category }
    }
}
