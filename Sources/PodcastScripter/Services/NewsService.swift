import Foundation

/// Show-level settings. Will move to user settings later.
enum ShowConfig {
    static let showName = "Riot Report"
    static let teamName = "RSL"
}

/// The boundary to the (future) notes/news backend. Swap `MockNewsService` for a real
/// implementation once that service exists; nothing else in the app should need to change.
protocol NewsService: Sendable {
    func fetchRankings() async throws -> [RankingGroup]
    func fetchNews() async throws -> [NewsItem]
    /// Auto-generated story-queue items (X posts, articles, notes).
    func fetchGeneratedStories() async throws -> [StoryItem]
}

struct MockNewsService: NewsService {
    func fetchRankings() async throws -> [RankingGroup] {
        [
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

    func fetchNews() async throws -> [NewsItem] {
        let now = Date()
        return [
            NewsItem(category: .team, headline: "RSL News 1", summary: "Placeholder team headline from the news service.", source: "Mock", publishedAt: now.addingTimeInterval(-3600)),
            NewsItem(category: .team, headline: "RSL News 2", summary: "Placeholder team headline from the news service.", source: "Mock", publishedAt: now.addingTimeInterval(-7200)),
            NewsItem(category: .team, headline: "RSL News 3", summary: "Placeholder team headline from the news service.", source: "Mock", publishedAt: now.addingTimeInterval(-10800)),
            NewsItem(category: .league, headline: "League News 1", summary: "Placeholder league headline from the news service.", source: "Mock", publishedAt: now.addingTimeInterval(-5400)),
            NewsItem(category: .league, headline: "League News 2", summary: "Placeholder league headline from the news service.", source: "Mock", publishedAt: now.addingTimeInterval(-9000)),
        ]
    }

    func fetchGeneratedStories() async throws -> [StoryItem] {
        [
            StoryItem(kind: .xPost, title: "X post", body: "Auto-generated summary of a trending post.", source: "x.com"),
            StoryItem(kind: .storyNote, title: "Story/Note", body: "Auto-generated note from recent coverage."),
            StoryItem(kind: .article, title: "Article", body: "Auto-generated article digest.", source: "Mock"),
        ]
    }
}
