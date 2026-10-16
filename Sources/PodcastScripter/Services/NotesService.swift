import Foundation

/// Where the notes service lives. Edited in Settings (⌘,).
enum ServiceSettings {
    static let urlKey = "notesServiceURL"
    static let tokenKey = "notesServiceToken"
    static let defaultURL = "http://localhost:3030"

    static var baseURL: URL {
        let raw = UserDefaults.standard.string(forKey: urlKey) ?? defaultURL
        return URL(string: raw.trimmingCharacters(in: .whitespaces)) ?? URL(string: defaultURL)!
    }

    static var token: String {
        UserDefaults.standard.string(forKey: tokenKey) ?? ""
    }
}

enum ItemStatus: String, Sendable {
    case inbox
    case used
    case dismissed
}

/// The boundary to the notes service in services/notes (the story inbox and RSS news).
protocol NotesService: Sendable {
    func fetchInbox() async throws -> [StoryItem]
    /// Only news that hasn't been used or dismissed.
    func fetchNews(category: NewsCategory, limit: Int) async throws -> [NewsItem]
    /// A link (X post or article) or note text; the service decides which.
    func add(input: String) async throws -> StoryItem
    /// Works for inbox items and news.
    func setStatus(_ id: UUID, _ status: ItemStatus) async throws
    func delete(_ id: StoryItem.ID) async throws
    /// `refresh` skips the service's 30-minute cache.
    func fetchStandings(refresh: Bool) async throws -> Standings
    func fetchMatches(refresh: Bool) async throws -> Matches
    /// Saved rankings for a season (nil = current), instantly.
    func fetchRankings(season: Int?) async throws -> RankingsSummary
    /// Fetches every ranking source now (slower: it reads articles, Gmail and Opta's data).
    func syncRankings() async throws -> RankingsSummary
    func checkHealth() async throws
    /// Settings shared by every device (show, template, team, sources).
    func fetchConfig() async throws -> AppConfig
    func saveConfig(_ config: AppConfig) async throws -> AppConfig
    func resetConfig() async throws -> AppConfig
    /// Teams in an ESPN league, for the team picker.
    func fetchTeams(league: String) async throws -> [TeamOption]
    // Projects (one show and team each). These ignore the client's current project.
    func listProjects() async throws -> [ProjectInfo]
    func createProject(_ request: NewProjectRequest) async throws -> ProjectInfo
    func updateProject(id: String, name: String?, makeDefault: Bool) async throws -> ProjectInfo
    func deleteProject(id: String) async throws
    func aiStatus() async throws -> AIStatus
    /// Sends a one-line prompt to the configured model.
    func testAI() async throws -> AIReply
    // Gemma features: the app sends its own data (scripts, tracker); the service adds the rest.
    func ask(_ question: String, history: [ChatMessage], app: AIAppContext) async throws -> AskReply
    func suggestStory(excerpt: String, episode: AIEpisode, stories: [AIStory]) async throws -> StorySuggestion
    func briefing(episode: AIEpisode, stories: [AIStory]) async throws -> [StoryBriefing]
    func introBullets(episode: AIEpisode) async throws -> [String]
}

// MARK: - Projects

struct ProjectInfo: Decodable, Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var isDefault: Bool
    var showName: String?
    var team: Team?

    struct Team: Decodable, Equatable, Sendable {
        var name: String
        var shortName: String?
        var espnSport: String?
        var espnLeague: String?
    }
}

struct NewProjectRequest: Encodable, Sendable {
    var name: String
    /// Copy settings (template, sources, competitions) from this project; nil = the defaults.
    var fromProject: String?
    var team: Team
    var show: Show

    struct Team: Encodable, Sendable {
        var name: String
        var shortName: String
        var espnTeamId: String
        var espnLeague: String
        var espnSport: String
    }

    struct Show: Encodable, Sendable {
        var name: String
        var fullName: String
        var host: String
        var xHandle: String
    }
}

// MARK: - Gemma payloads

struct ChatMessage: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    /// "user" or "assistant".
    var role: String
    var content: String
    /// For assistant replies: model and seconds, e.g. "gemma-4-26b-a4b-it · 3.2s".
    var detail: String?
    /// For assistant replies: exactly what Gemma was given. Not sent back with later questions.
    var sources: AskSources?

    private enum CodingKeys: String, CodingKey { case role, content }
}

/// What only the app has: every episode's script and the Story Tracker.
struct AIAppContext: Encodable, Sendable {
    var scripts: [AIScript]
    var trackedStories: [AIStory]
}

struct AIScript: Encodable, Sendable {
    var name: String
    var date: String
    var script: String
}

struct AIEpisode: Encodable, Sendable {
    var name: String
    var date: String
    var script: String?
    var stories: [AIEpisodeStory]?
}

struct AIEpisodeStory: Encodable, Sendable {
    var kind: String
    var title: String
    var body: String
}

struct AIStory: Encodable, Sendable {
    var id: String
    var title: String
    var latestUpdate: String
    var mentions: [AIMention]
    /// "rumor", "reported", "confirmed", or nil.
    var status: String?
    /// e.g. [{"status": "rumor", "date": "2026-10-03"}, {"status": "confirmed", "date": "2026-10-12"}]
    var statusHistory: [AIStatusChange]
    /// YYYY-MM-DD when the story was resolved, and how it ended.
    var resolvedAt: String?
    var resolution: String?
}

struct AIStatusChange: Encodable, Sendable {
    var status: String?
    var date: String
}

struct AIMention: Encodable, Sendable {
    var episode: String
    var date: String
    var excerpt: String
    var note: String?
    var status: String?
}

struct AskReply: Decodable, Sendable {
    var answer: String
    var model: String
    var ms: Int
    var sources: AskSources?
}

/// What the notes service gave Gemma for one question.
struct AskSources: Codable, Equatable, Sendable {
    /// Script passages, labeled with their episode.
    var excerpts: [Excerpt]
    /// Scripts available to pick from.
    var episodes: Int
    var stories: [Story]
    /// True if the Story Tracker was too long and got cut short.
    var storiesShortened: Bool
    /// Other app data sections, e.g. "Results · 33 matches".
    var data: [Section]

    struct Excerpt: Codable, Equatable, Sendable, Hashable {
        var episode: String
        /// YYYY-MM-DD
        var date: String
        var text: String
    }

    struct Story: Codable, Equatable, Sendable, Hashable {
        var title: String
        var mentions: Int
        var status: String?
    }

    struct Section: Codable, Equatable, Sendable, Hashable {
        var label: String
        var detail: String
    }

    var count: Int { excerpts.count + stories.count + data.count }
}

struct StorySuggestion: Decodable, Equatable, Sendable {
    var storyId: String?
    var newTitle: String?
    var update: String
    var contradiction: String?
}

struct StoryBriefing: Decodable, Equatable, Sendable, Identifiable {
    var storyId: String
    var summary: String
    var whatsNew: String?
    var id: String { storyId }
}

struct AIStatus: Decodable, Equatable, Sendable {
    var provider: String
    var model: String
    var ready: Bool
    var problem: String?
}

struct AIReply: Decodable, Equatable, Sendable {
    var text: String
    var provider: String
    var model: String
    var ms: Int
}

// MARK: - HTTP client

enum NotesServiceError: LocalizedError {
    case unreachable(String)
    case unauthorized
    case server(String)

    var errorDescription: String? {
        switch self {
        case .unreachable(let host): "Can't reach the notes service at \(host). Is it running?"
        case .unauthorized: "The notes service rejected the token. Check it in Settings (⌘,)."
        case .server(let message): message
        }
    }
}

struct NotesServiceClient: NotesService {
    var baseURL: URL
    var token: String
    /// Sent as X-Project so the service acts on this project; empty = the service's default.
    var projectID = ""

    init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
    }

    func fetchInbox() async throws -> [StoryItem] {
        let items: [ServiceItem] = try await send("api/items")
        return items.compactMap(\.storyItem)
    }

    func fetchNews(category: NewsCategory, limit: Int) async throws -> [NewsItem] {
        let items: [ServiceItem] = try await send("api/news", query: [
            URLQueryItem(name: "category", value: category.rawValue),
            URLQueryItem(name: "limit", value: String(limit)),
        ])
        return items.compactMap { $0.newsItem(category: category) }
    }

    func add(input: String) async throws -> StoryItem {
        let item: ServiceItem = try await send("api/items", method: "POST", body: ["input": input])
        guard let story = item.storyItem else { throw NotesServiceError.server("Unexpected response from the notes service.") }
        return story
    }

    func setStatus(_ id: UUID, _ status: ItemStatus) async throws {
        let _: ServiceItem = try await send("api/items/\(id.uuidString.lowercased())", method: "PATCH", body: ["status": status.rawValue])
    }

    func delete(_ id: StoryItem.ID) async throws {
        try await sendEmpty("api/items/\(id.uuidString.lowercased())", method: "DELETE")
    }

    func fetchStandings(refresh: Bool) async throws -> Standings {
        try await send("api/standings", query: refresh ? [URLQueryItem(name: "refresh", value: "1")] : [])
    }

    func fetchMatches(refresh: Bool) async throws -> Matches {
        try await send("api/matches", query: refresh ? [URLQueryItem(name: "refresh", value: "1")] : [])
    }

    func fetchRankings(season: Int?) async throws -> RankingsSummary {
        try await send("api/rankings", query: season.map { [URLQueryItem(name: "season", value: String($0))] } ?? [])
    }

    func syncRankings() async throws -> RankingsSummary {
        try await send("api/rankings/sync", method: "POST", timeout: 180)
    }

    func fetchConfig() async throws -> AppConfig {
        try await send("api/config")
    }

    func saveConfig(_ config: AppConfig) async throws -> AppConfig {
        try await send("api/config", method: "PUT", json: config)
    }

    func resetConfig() async throws -> AppConfig {
        try await send("api/config/reset", method: "POST")
    }

    func fetchTeams(league: String) async throws -> [TeamOption] {
        try await send("api/espn/teams", query: [URLQueryItem(name: "league", value: league)])
    }

    func listProjects() async throws -> [ProjectInfo] {
        try await send("api/projects")
    }

    func createProject(_ request: NewProjectRequest) async throws -> ProjectInfo {
        try await send("api/projects", method: "POST", json: request, timeout: 60)
    }

    private struct ProjectPatch: Encodable { var name: String?; var makeDefault: Bool }

    func updateProject(id: String, name: String?, makeDefault: Bool) async throws -> ProjectInfo {
        try await send("api/projects/\(id)", method: "PATCH", json: ProjectPatch(name: name, makeDefault: makeDefault))
    }

    func deleteProject(id: String) async throws {
        try await sendEmpty("api/projects/\(id)", method: "DELETE")
    }

    func aiStatus() async throws -> AIStatus {
        try await send("api/ai/status")
    }

    func testAI() async throws -> AIReply {
        try await send("api/ai/test", method: "POST", timeout: 200)
    }

    private struct AskBody: Encodable { var question: String; var history: [ChatMessage]; var app: AIAppContext }
    private struct SuggestBody: Encodable { var excerpt: String; var episode: AIEpisode; var stories: [AIStory] }
    private struct BriefingBody: Encodable { var episode: AIEpisode; var stories: [AIStory] }
    private struct BriefingReply: Decodable { var briefings: [StoryBriefing] }
    private struct BulletsBody: Encodable { var episode: AIEpisode }
    private struct BulletsReply: Decodable { var bullets: [String] }

    func ask(_ question: String, history: [ChatMessage], app: AIAppContext) async throws -> AskReply {
        try await send("api/ai/ask", method: "POST", json: AskBody(question: question, history: history, app: app), timeout: 200)
    }

    func suggestStory(excerpt: String, episode: AIEpisode, stories: [AIStory]) async throws -> StorySuggestion {
        try await send("api/ai/suggest-story", method: "POST", json: SuggestBody(excerpt: excerpt, episode: episode, stories: stories), timeout: 200)
    }

    func briefing(episode: AIEpisode, stories: [AIStory]) async throws -> [StoryBriefing] {
        let reply: BriefingReply = try await send("api/ai/briefing", method: "POST", json: BriefingBody(episode: episode, stories: stories), timeout: 200)
        return reply.briefings
    }

    func introBullets(episode: AIEpisode) async throws -> [String] {
        let reply: BulletsReply = try await send("api/ai/intro-bullets", method: "POST", json: BulletsBody(episode: episode), timeout: 200)
        return reply.bullets
    }

    func checkHealth() async throws {
        // Hits an authed endpoint so a bad token shows up here too.
        let _: [ServiceItem] = try await send("api/items", query: [URLQueryItem(name: "status", value: "used")])
    }

    // MARK: Plumbing

    private func send<T: Decodable>(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: [String: String]? = nil, timeout: TimeInterval = 20) async throws -> T {
        let encoded = try body.map { try JSONEncoder().encode($0) }
        let data = try await perform(path, method: method, query: query, body: encoded, timeout: timeout)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw NotesServiceError.server("Unexpected response from the notes service.")
        }
    }

    private func sendEmpty(_ path: String, method: String) async throws {
        _ = try await perform(path, method: method, query: [], body: nil, timeout: 20)
    }

    private func send<T: Decodable, Body: Encodable>(_ path: String, method: String, json: Body, timeout: TimeInterval = 20) async throws -> T {
        let data = try await perform(path, method: method, query: [], body: JSONEncoder().encode(json), timeout: timeout)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw NotesServiceError.server("Unexpected response from the notes service.")
        }
    }

    private func perform(_ path: String, method: String, query: [URLQueryItem], body: Data?, timeout: TimeInterval) async throws -> Data {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }

        var request = URLRequest(url: components.url!, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if !projectID.isEmpty {
            request.setValue(projectID, forHTTPHeaderField: "X-Project")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw NotesServiceError.unreachable(baseURL.host() ?? baseURL.absoluteString)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw NotesServiceError.unauthorized }
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw NotesServiceError.server(message ?? "The notes service returned HTTP \(status).")
        }
        return data
    }
}

/// Wire format shared by /api/items and /api/news (camelCase JSON, ISO 8601 dates).
private struct ServiceItem: Decodable {
    var id: String
    var kind: String
    var title: String
    var body: String
    var url: String?
    var source: String?
    var publishedAt: String?
    var createdAt: String

    var storyItem: StoryItem? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        let storyKind: StoryKind = switch kind {
        case "x_post": .xPost
        case "article": .article
        default: .storyNote
        }
        return StoryItem(
            id: uuid,
            kind: storyKind,
            title: title,
            body: body,
            source: source,
            url: url.flatMap(URL.init(string:)),
            createdAt: ISO8601.parse(createdAt) ?? Date()
        )
    }

    func newsItem(category: NewsCategory) -> NewsItem? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return NewsItem(
            id: uuid,
            category: category,
            headline: title,
            summary: body,
            source: source ?? "",
            publishedAt: publishedAt.flatMap(ISO8601.parse) ?? ISO8601.parse(createdAt) ?? Date(),
            url: url.flatMap(URL.init(string:))
        )
    }
}

/// JavaScript's toISOString() includes milliseconds, which JSONDecoder's .iso8601 rejects.
enum ISO8601 {
    static func parse(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}
