import Foundation

/// Show-level settings. Will move to user settings later.
enum ShowConfig {
    static let showName = "Riot Report"
    static let teamName = "RSL"
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

/// The boundary to the notes service in services/notes (the story inbox and RSS news).
protocol NotesService: Sendable {
    func fetchInbox() async throws -> [StoryItem]
    func fetchNews(category: NewsCategory, limit: Int) async throws -> [NewsItem]
    /// A link (X post or article) or note text; the service decides which.
    func add(input: String) async throws -> StoryItem
    func markUsed(_ id: StoryItem.ID) async throws
    func delete(_ id: StoryItem.ID) async throws
    func checkHealth() async throws
}

/// Power rankings have no backend yet.
enum MockRankings {
    static let groups = [
        RankingGroup(title: "League", entries: [
            RankingEntry(source: "MLS", rank: 7, change: 2),
            RankingEntry(source: "ESPN", rank: 10, change: -2),
            RankingEntry(source: "TacticsFreeZone", rank: 28, change: -5),
        ]),
        RankingGroup(title: "Region", entries: [
            RankingEntry(source: "Concacaf", rank: 43, change: -7),
        ]),
        RankingGroup(title: "World", entries: [
            RankingEntry(source: "Opta", rank: 449, change: -2),
        ]),
    ]
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

    func markUsed(_ id: StoryItem.ID) async throws {
        let _: ServiceItem = try await send("api/items/\(id.uuidString.lowercased())", method: "PATCH", body: ["status": "used"])
    }

    func delete(_ id: StoryItem.ID) async throws {
        try await sendEmpty("api/items/\(id.uuidString.lowercased())", method: "DELETE")
    }

    func checkHealth() async throws {
        // Hits an authed endpoint so a bad token shows up here too.
        let _: [ServiceItem] = try await send("api/items", query: [URLQueryItem(name: "status", value: "used")])
    }

    // MARK: Plumbing

    private func send<T: Decodable>(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: [String: String]? = nil) async throws -> T {
        let data = try await perform(path, method: method, query: query, body: body)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw NotesServiceError.server("Unexpected response from the notes service.")
        }
    }

    private func sendEmpty(_ path: String, method: String) async throws {
        _ = try await perform(path, method: method, query: [], body: nil)
    }

    private func perform(_ path: String, method: String, query: [URLQueryItem], body: [String: String]?) async throws -> Data {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }

        var request = URLRequest(url: components.url!, timeoutInterval: 20)
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
