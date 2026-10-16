import Foundation

/// Show-level settings. Will move to user settings later.
enum ShowConfig {
    static let showName = "Riot Report"
    static let teamName = "RSL"
    static let fullShowName = "RSL Riot Report"
    static let host = "Court"
    static let xHandle = "@rslriotreport"
}

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

    func checkHealth() async throws {
        // Hits an authed endpoint so a bad token shows up here too.
        let _: [ServiceItem] = try await send("api/items", query: [URLQueryItem(name: "status", value: "used")])
    }

    // MARK: Plumbing

    private func send<T: Decodable>(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: [String: String]? = nil, timeout: TimeInterval = 20) async throws -> T {
        let data = try await perform(path, method: method, query: query, body: body, timeout: timeout)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw NotesServiceError.server("Unexpected response from the notes service.")
        }
    }

    private func sendEmpty(_ path: String, method: String) async throws {
        _ = try await perform(path, method: method, query: [], body: nil, timeout: 20)
    }

    private func perform(_ path: String, method: String, query: [URLQueryItem], body: [String: String]?, timeout: TimeInterval) async throws -> Data {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }

        var request = URLRequest(url: components.url!, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
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
