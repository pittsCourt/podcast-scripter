import Foundation
import Observation

enum Route: Hashable {
    case home
    case editor(Project.ID)
}

/// Everything the user creates; written to disk as JSON.
private struct PersistedState: Codable {
    var projects: [Project] = []
    var storyQueue: [StoryItem] = []
    var trackedStories: [TrackedStory] = []
    var instructionFiles: [InstructionFile] = []
}

@MainActor
@Observable
final class AppStore {
    // Persisted
    var projects: [Project] = []
    var storyQueue: [StoryItem] = []
    var trackedStories: [TrackedStory] = []
    var instructionFiles: [InstructionFile] = []

    // Fetched from the service each launch
    var rankings: [RankingGroup] = []
    var news: [NewsItem] = []

    // UI state
    var route: Route = .home
    var searchText = ""
    var selectedQueueIDs: Set<StoryItem.ID> = []
    var lastError: String?

    private let service: NewsService
    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    init(service: NewsService, fileURL: URL = AppStore.defaultFileURL) {
        self.service = service
        self.fileURL = fileURL
        load()
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

    private var isFirstLaunch = false

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            isFirstLaunch = true
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
            instructionFiles = state.instructionFiles
        } catch {
            lastError = "Couldn't read saved data: \(error.localizedDescription)"
        }
    }

    func refresh() async {
        do {
            async let rankings = service.fetchRankings()
            async let news = service.fetchNews()
            self.rankings = try await rankings
            self.news = try await news
            if isFirstLaunch {
                storyQueue = try await service.fetchGeneratedStories()
                isFirstLaunch = false
                save()
            }
        } catch {
            lastError = "Couldn't reach the news service: \(error.localizedDescription)"
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
            instructionFiles: instructionFiles
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

    /// Moves the selected queue items into a new project and opens it.
    func createProjectFromSelected() {
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
    }

    func deleteSelected() {
        storyQueue.removeAll { selectedQueueIDs.contains($0.id) }
        selectedQueueIDs.removeAll()
        save()
    }

    func addStory(_ item: StoryItem) {
        storyQueue.insert(item, at: 0)
        save()
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

    // MARK: - Instruction files

    func importInstructionFile(from url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            instructionFiles.append(InstructionFile(name: url.lastPathComponent, content: content))
            save()
        } catch {
            lastError = "Couldn't import \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func deleteInstructionFile(_ id: InstructionFile.ID) {
        instructionFiles.removeAll { $0.id == id }
        save()
    }

    // MARK: - News

    func news(in category: NewsCategory) -> [NewsItem] {
        news.filter { $0.category == category }
    }
}
