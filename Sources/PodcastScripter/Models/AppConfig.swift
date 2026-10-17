import Foundation

/// Show, script template, team and data-source settings. Owned by Newsdesk
/// (`/api/config`, defaults in services/newsdesk/config.default.json) and edited in Settings.
/// The app keeps the last copy it saw so it works offline.
struct AppConfig: Codable, Equatable, Sendable {
    var show: Show
    var template: Template
    var team: Team
    var competitions: [Competition]
    var news: News
    var rankings: Rankings
    /// Gemma provider. Optional so settings saved before AI existed still load; use `aiSettings`.
    var ai: AI?

    var aiSettings: AI {
        get { ai ?? .fallback }
        set { ai = newValue }
    }

    struct AI: Codable, Equatable, Sendable {
        /// "gemini" (Gemini API, the default) or "ollama" (a local model).
        var provider: String
        var gemini: Gemini
        var ollama: Ollama
        /// Most characters of app data sent with a question (keeps requests within API limits).
        var contextChars: Int?

        struct Gemini: Codable, Equatable, Sendable {
            var model: String
        }

        struct Ollama: Codable, Equatable, Sendable {
            var url: String
            var model: String
        }

        static let fallback = AI(
            provider: "gemini",
            gemini: .init(model: "gemma-4-26b-a4b-it"),
            ollama: .init(url: "http://host.docker.internal:11434", model: "gemma4:12b"),
            contextChars: nil
        )
    }

    struct Show: Codable, Equatable, Sendable {
        /// Short name, e.g. "Riot Report".
        var name: String
        /// e.g. "RSL Riot Report", used as {show} in the template.
        var fullName: String
        var host: String
        var xHandle: String
    }

    struct Template: Codable, Equatable, Sendable {
        var sections: [Section]

        struct Section: Codable, Equatable, Sendable, Identifiable {
            var id = UUID()
            var title: String
            /// Starting text. Lines beginning with "• " are indented as bullets.
            var body: String

            private enum CodingKeys: String, CodingKey { case title, body }
        }
    }

    struct Team: Codable, Equatable, Sendable {
        /// Full name as the ranking sources write it, e.g. "Real Salt Lake".
        var name: String
        /// Abbreviation, e.g. "RSL" (highlights the club in tables, names news sections).
        var shortName: String
        /// Other names sources use, e.g. ["RSL"].
        var aliases: [String]
        var espnSport: String
        var espnLeague: String
        var espnTeamId: String
    }

    struct Competition: Codable, Equatable, Sendable, Identifiable {
        var id = UUID()
        var name: String
        var espnLeague: String
        var enabled: Bool

        private enum CodingKeys: String, CodingKey { case name, espnLeague, enabled }
    }

    struct News: Codable, Equatable, Sendable {
        /// Google News search for the team column.
        var teamQuery: String
        var leagueQuery: String
    }

    struct Rankings: Codable, Equatable, Sendable {
        /// e.g. "Tue 16:00"; empty turns the weekly sync off.
        var schedule: String
        var timeZone: String
        var sources: Sources

        struct Sources: Codable, Equatable, Sendable {
            var mls: Toggle
            var espn: ESPN
            var tfz: TFZ
            var concacaf: Toggle
            var opta: Toggle
        }

        struct Toggle: Codable, Equatable, Sendable {
            var enabled: Bool
        }

        struct ESPN: Codable, Equatable, Sendable {
            var enabled: Bool
            /// Headline prefix of the ESPN column, e.g. "MLS Power Rankings".
            var query: String
        }

        struct TFZ: Codable, Equatable, Sendable {
            var enabled: Bool
            var sender: String
            var forwardedFrom: [String]
        }
    }

    /// The competition the team's league games are filed under (e.g. "MLS").
    var homeCompetitionName: String {
        competitions.first { $0.espnLeague == team.espnLeague }?.name ?? team.espnLeague.uppercased()
    }

    /// Used until Newsdesk is reached. Keep in sync with services/newsdesk/config.default.json
    /// (a test checks this).
    static let fallback = AppConfig(
        show: Show(name: "Riot Report", fullName: "RSL Riot Report", host: "Court", xHandle: "@rslriotreport"),
        template: Template(sections: [
            .init(title: "Intro", body: "Hello, I’m {host}, and this is your {show}. Today is {date} and our top stories include:\n• [Bullet 1]\n• [Bullet 2]\n• [Bullet 3]\nLet’s kick it off."),
            .init(title: "Match Report", body: ""),
            .init(title: "{team} News", body: ""),
            .init(title: "League News", body: ""),
            .init(title: "Power Rankings", body: ""),
            .init(title: "Looking Ahead", body: ""),
            .init(title: "Outro", body: "Thanks for tuning in! Follow us on X {handle}. Until next time, I’m your host {host}, and this has been your {show}."),
        ]),
        team: Team(name: "Real Salt Lake", shortName: "RSL", aliases: ["RSL"], espnSport: "soccer", espnLeague: "usa.1", espnTeamId: "4771"),
        competitions: [
            .init(name: "MLS", espnLeague: "usa.1", enabled: true),
            .init(name: "Leagues Cup", espnLeague: "concacaf.leagues.cup", enabled: true),
            .init(name: "U.S. Open Cup", espnLeague: "usa.open", enabled: true),
            .init(name: "Concacaf Champions Cup", espnLeague: "concacaf.champions", enabled: true),
        ],
        news: News(teamQuery: "\"Real Salt Lake\"", leagueQuery: "\"Major League Soccer\" OR MLS soccer"),
        rankings: Rankings(
            schedule: "Tue 16:00",
            timeZone: "UTC",
            sources: .init(
                mls: .init(enabled: true),
                espn: .init(enabled: true, query: "MLS Power Rankings"),
                tfz: .init(enabled: true, sender: "tacticsfreezone@ghost.io", forwardedFrom: []),
                concacaf: .init(enabled: true),
                opta: .init(enabled: true)
            )
        ),
        ai: .fallback
    )
}

/// A team from ESPN, for the Settings team picker.
struct TeamOption: Decodable, Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var shortName: String?
    var abbreviation: String?
}
