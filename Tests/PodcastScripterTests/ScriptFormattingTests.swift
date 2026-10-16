import AppKit
import Testing
@testable import PodcastScripter

@MainActor
struct ScriptFormattingTests {
    /// A text view holding `text` as body paragraphs, wired to a controller.
    private func makeEditor(_ text: String) -> (NSTextView, RichTextController) {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        textView.isRichText = true
        textView.allowsUndo = true
        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: ScriptStyle.attributes(for: .body)))
        let controller = RichTextController()
        controller.textView = textView
        return (textView, controller)
    }

    private func range(of substring: String, in textView: NSTextView) -> NSRange {
        (textView.string as NSString).range(of: substring)
    }

    private func attrs(at substring: String, in textView: NSTextView) -> [NSAttributedString.Key: Any] {
        textView.textStorage!.attributes(at: range(of: substring, in: textView).location, effectiveRange: nil)
    }

    @Test func paragraphStylesApplyToWholeParagraph() {
        let (textView, controller) = makeEditor("Match preview\nBody text here\nA quoted line")
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        controller.setBlock(.heading2)
        textView.setSelectedRange(range(of: "quoted", in: textView))
        controller.setBlock(.quote)

        #expect(ScriptStyle.block(from: attrs(at: "preview", in: textView)) == .heading2)
        #expect(ScriptStyle.block(from: attrs(at: "Body", in: textView)) == .body)
        #expect(ScriptStyle.block(from: attrs(at: "A quoted", in: textView)) == .quote)
        #expect(controller.block == .quote)
    }

    @Test func inlineStylesToggle() {
        let (textView, controller) = makeEditor("Glad is back in training")
        textView.setSelectedRange(range(of: "Glad", in: textView))
        controller.updateState()
        controller.toggleBold()
        controller.toggleItalic()
        controller.toggleUnderline()

        let glad = attrs(at: "Glad", in: textView)
        #expect(ScriptStyle.isBold(glad[.font] as? NSFont))
        #expect(ScriptStyle.isItalic(glad[.font] as? NSFont))
        #expect((glad[.underlineStyle] as? Int) == NSUnderlineStyle.single.rawValue)
        #expect(!ScriptStyle.isBold(attrs(at: "training", in: textView)[.font] as? NSFont))

        controller.toggleBold()
        #expect(!ScriptStyle.isBold(attrs(at: "Glad", in: textView)[.font] as? NSFont))
    }

    @Test func indentAndLink() {
        let (textView, controller) = makeEditor("Segment one\nSegment two")
        textView.setSelectedRange(range(of: "two", in: textView))
        controller.indent()
        controller.indent()
        controller.outdent()
        textView.setSelectedRange(range(of: "one", in: textView))
        controller.setLink(URL(string: "https://rsl.com")!)

        let two = attrs(at: "two", in: textView)
        #expect(ScriptStyle.indentLevel(from: two, block: .body) == 1)
        #expect(ScriptStyle.indentLevel(from: attrs(at: "one", in: textView), block: .body) == 0)
        #expect(ScriptStyle.linkURL(attrs(at: "one", in: textView)[.link]) == URL(string: "https://rsl.com"))

        textView.setSelectedRange(range(of: "one", in: textView))
        controller.setLink(nil)
        #expect(attrs(at: "one", in: textView)[.link] == nil)
    }

    @Test func formattingSurvivesSaveAndReload() {
        let (textView, controller) = makeEditor("Cold open\nThe Booth brothers are both fit\nQuote here")
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        controller.setBlock(.heading1)
        textView.setSelectedRange(range(of: "Booth", in: textView))
        controller.toggleBold()
        textView.setSelectedRange(range(of: "fit", in: textView))
        controller.toggleItalic()
        textView.setSelectedRange(range(of: "Quote", in: textView))
        controller.setBlock(.quote)
        controller.indent()

        var script = Script(name: "Test", episodeDate: Date())
        script.plainText = textView.string
        script.richText = ScriptStyle.rtfData(textView.attributedString())

        let reloaded = ScriptStyle.load(script)
        let at = { (s: String) in reloaded.attributes(at: (reloaded.string as NSString).range(of: s).location, effectiveRange: nil) }
        #expect(reloaded.string == textView.string)
        #expect(ScriptStyle.block(from: at("Cold")) == .heading1)
        #expect(ScriptStyle.inlineTraits(at("Booth"), block: .body).bold)
        #expect(ScriptStyle.inlineTraits(at("fit"), block: .body).italic)
        #expect(!ScriptStyle.inlineTraits(at("brothers"), block: .body).bold)
        #expect(ScriptStyle.block(from: at("Quote")) == .quote)
        #expect(ScriptStyle.indentLevel(from: at("Quote"), block: .quote) == 1)
    }

    @Test func plainScriptsLoadAsBody() {
        var script = Script(name: "Old", episodeDate: Date())
        script.plainText = "Written before formatting"
        let loaded = ScriptStyle.load(script)
        #expect(loaded.string == script.plainText)
        #expect(ScriptStyle.block(from: loaded.attributes(at: 0, effectiveRange: nil)) == .body)
    }

    @Test func markdownExport() {
        let (textView, controller) = makeEditor("Injuries\nGlad is back and Luna is close\nRead the report\nFrom the coach")
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        controller.setBlock(.heading2)
        textView.setSelectedRange(range(of: "Glad is back", in: textView))
        controller.toggleBold()
        textView.setSelectedRange(range(of: "Luna", in: textView))
        controller.toggleItalic()
        textView.setSelectedRange(range(of: "report", in: textView))
        controller.setLink(URL(string: "https://rsl.com/news")!)
        textView.setSelectedRange(range(of: "From the coach", in: textView))
        controller.setBlock(.quote)

        let markdown = ScriptStyle.markdown(textView.attributedString(), title: "RSL Riot Report")
        #expect(markdown == """
        # RSL Riot Report

        ## Injuries

        **Glad is back** and *Luna* is close

        Read the [report](https://rsl.com/news)

        > From the coach

        """)
    }

    @Test func rtfExportUsesPrintColors() throws {
        let (textView, _) = makeEditor("Some script text")
        let data = try #require(ScriptStyle.exportRTF(textView.attributedString(), title: "Episode"))
        let exported = try #require(NSAttributedString(rtf: data, documentAttributes: nil))
        #expect(exported.string.hasPrefix("Episode\nSome script text"))
        let color = try #require((exported.attribute(.foregroundColor, at: 10, effectiveRange: nil) as? NSColor)?.usingColorSpace(.sRGB))
        #expect(color.redComponent < 0.1)
    }

    @Test func quoteInsertsAfterCurrentParagraphWithLinkedCredit() {
        let (textView, controller) = makeEditor("Intro line\nNext segment")
        textView.setSelectedRange(NSRange(location: 3, length: 0)) // mid "Intro"
        let url = URL(string: "https://x.com/realsaltlake/status/1")!
        controller.insertQuote(["Glad is back", "Booth too"], attribution: "— Real Salt Lake (@realsaltlake) on X", link: url)

        #expect(textView.string == "Intro line\nGlad is back\nBooth too\n— Real Salt Lake (@realsaltlake) on X\nNext segment")
        #expect(ScriptStyle.block(from: attrs(at: "Intro", in: textView)) == .body)
        #expect(ScriptStyle.block(from: attrs(at: "Glad", in: textView)) == .quote)
        #expect(ScriptStyle.block(from: attrs(at: "Booth", in: textView)) == .quote)
        #expect(ScriptStyle.linkURL(attrs(at: "Real Salt", in: textView)[.link]) == url)
        #expect(ScriptStyle.block(from: attrs(at: "Next", in: textView)) == .body)
        #expect(attrs(at: "Glad", in: textView)[.link] == nil)
    }

    @Test func quoteAtEndOfDocumentKeepsLastParagraphStyle() {
        let (textView, controller) = makeEditor("Closing thoughts")
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        controller.setBlock(.heading3)
        textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
        controller.insertQuote(["A quote"], attribution: "— Source", link: nil)

        #expect(textView.string == "Closing thoughts\nA quote\n— Source\n")
        #expect(ScriptStyle.block(from: attrs(at: "Closing", in: textView)) == .heading3)
        #expect(ScriptStyle.block(from: attrs(at: "A quote", in: textView)) == .quote)
        #expect(controller.block == .body) // typing continues as body text
    }

    @Test func noteInsertsAsBodyAtParagraphStart() {
        let (textView, controller) = makeEditor("First\nSecond")
        textView.setSelectedRange(range(of: "Second", in: textView))
        textView.setSelectedRange(NSRange(location: range(of: "Second", in: textView).location, length: 0))
        controller.insertBody("Ask about the back line")
        #expect(textView.string == "First\nAsk about the back line\nSecond")
    }
}

/// Records status changes instead of calling the notes service.
private final class FakeNotesService: NotesService, @unchecked Sendable {
    var statuses: [UUID: ItemStatus] = [:]
    var inbox: [StoryItem] = []
    var newsItems: [NewsItem] = []

    func fetchInbox() async throws -> [StoryItem] { inbox }
    func fetchNews(category: NewsCategory, limit: Int) async throws -> [NewsItem] { newsItems.filter { $0.category == category } }
    func add(input: String) async throws -> StoryItem { StoryItem(kind: .storyNote, title: input, body: "") }
    func setStatus(_ id: UUID, _ status: ItemStatus) async throws { statuses[id] = status }
    func delete(_ id: StoryItem.ID) async throws {}
    func fetchStandings(refresh: Bool) async throws -> Standings { throw CancellationError() }
    func fetchMatches(refresh: Bool) async throws -> Matches { throw CancellationError() }
    func fetchRankings(season: Int?) async throws -> RankingsSummary { throw CancellationError() }
    func syncRankings() async throws -> RankingsSummary { throw CancellationError() }
    func checkHealth() async throws {}
    func fetchConfig() async throws -> AppConfig { .fallback }
    func saveConfig(_ config: AppConfig) async throws -> AppConfig { config }
    func resetConfig() async throws -> AppConfig { .fallback }
    func fetchTeams(league: String) async throws -> [TeamOption] { [] }
    var projects: [ProjectInfo] = [ProjectInfo(id: "rsl", name: "RSL Riot Report", isDefault: true)]
    func listProjects() async throws -> [ProjectInfo] { projects }
    func createProject(_ request: NewProjectRequest) async throws -> ProjectInfo {
        let created = ProjectInfo(id: request.name.lowercased().replacingOccurrences(of: " ", with: "-"), name: request.name, isDefault: false)
        projects.append(created)
        return created
    }
    func updateProject(id: String, name: String?, makeDefault: Bool) async throws -> ProjectInfo {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { throw CancellationError() }
        if let name { projects[i].name = name }
        return projects[i]
    }
    func deleteProject(id: String) async throws { projects.removeAll { $0.id == id } }
    func aiStatus() async throws -> AIStatus { AIStatus(provider: "gemini", model: "test", ready: true, problem: nil) }
    func testAI() async throws -> AIReply { AIReply(text: "ok", provider: "gemini", model: "test", ms: 1) }
    var lastAskContext: AIAppContext?
    var lastAskHistory: [ChatMessage] = []
    func ask(_ question: String, history: [ChatMessage], app: AIAppContext) async throws -> AskReply {
        lastAskContext = app
        lastAskHistory = history
        return AskReply(answer: "You said he was day to day.", model: "test", ms: 1200, sources: AskSources(
            excerpts: [.init(episode: "Episode 28", date: "2026-09-29", text: "Diego Luna is day to day.")],
            episodes: 1, stories: [.init(title: "Luna Knock", mentions: 1)], storiesShortened: false,
            data: [.init(label: "Results", detail: "33 matches")]
        ))
    }
    func suggestStory(excerpt: String, episode: AIEpisode, stories: [AIStory]) async throws -> StorySuggestion {
        StorySuggestion(storyId: stories.first?.id, newTitle: nil, update: "Back in training", contradiction: nil)
    }
    func briefing(episode: AIEpisode, stories: [AIStory]) async throws -> [StoryBriefing] { [] }
    func introBullets(episode: AIEpisode) async throws -> [String] { ["One", "Two", "Three"] }
}

@MainActor
struct AddToScriptTests {
    @Test func addsSelectedStoriesOnceAndMarksThemUsed() async throws {
        let service = FakeNotesService()
        let post = StoryItem(kind: .xPost, title: "RSL (@realsaltlake)", body: "Lineup is out")
        let headline = NewsItem(category: .team, headline: "Preview: RSL at SKC", summary: "", source: "KSL", publishedAt: Date())
        service.inbox = [post]
        service.newsItems = [headline]

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("scripter-test-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = AppStore(service: service, fileURL: file)
        await store.refresh()
        let script = store.createScript(name: "Episode", date: Date(), notes: [post])

        store.selectedStoryIDs = [post.id, headline.id]
        await store.addSelected(toScript: script.id)

        let updated = try #require(store.script(script.id))
        #expect(updated.notes.map(\.id) == [post.id, headline.id]) // the post isn't duplicated
        #expect(updated.notes.last?.kind == .news)
        #expect(service.statuses == [post.id: .used, headline.id: .used])
        #expect(store.storyQueue.isEmpty && store.news.isEmpty && store.selectedStoryIDs.isEmpty)
        #expect(store.route == .editor(script.id))
    }
}

@MainActor
struct ReturnToQueueTests {
    @Test func removesFromScriptAndRestoresInbox() async throws {
        let service = FakeNotesService()
        let post = StoryItem(kind: .xPost, title: "RSL (@realsaltlake)", body: "Lineup")
        let note = StoryItem(kind: .storyNote, title: "Ask about the back line", body: "")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("scripter-test-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = AppStore(service: service, fileURL: file)
        let script = store.createScript(name: "Episode", date: Date(), notes: [post, note])

        service.inbox = [post] // what the service lists once the post is back in the inbox
        await store.returnToQueue([post.id], from: script.id)

        let updated = try #require(store.script(script.id))
        #expect(updated.notes.map(\.id) == [note.id])
        #expect(service.statuses == [post.id: .inbox])
        #expect(store.storyQueue.map(\.id) == [post.id])
    }
}

@MainActor
struct ScriptTemplateTests {
    @Test func newScriptsStartWithShowSections() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("scripter-test-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = AppStore(service: FakeNotesService(), fileURL: file)
        let date = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 16)))
        let script = store.createScript(name: "Episode", date: date)

        let formatted = ScriptStyle.load(script)
        var headings: [String] = []
        ScriptStyle.enumerateParagraphs(in: formatted) { range in
            let text = (formatted.string as NSString).substring(with: range).trimmingCharacters(in: .newlines)
            if ScriptStyle.block(from: formatted.attributes(at: range.location, effectiveRange: nil)) == .heading2 {
                headings.append(text)
            }
        }
        #expect(headings == ["Intro", "Match Report", "RSL News", "League News", "Power Rankings", "Looking Ahead", "Outro"])
        #expect(script.plainText.contains("Hello, I’m Court, and this is your RSL Riot Report. Today is Friday, October 16, 2026 and our top stories include:"))
        #expect(script.plainText.contains("• [Bullet 3]\nLet’s kick it off."))
        #expect(script.plainText.hasSuffix("Until next time, I’m your host Court, and this has been your RSL Riot Report.\n"))
    }

    @Test func deleteKeepsHistory() async {
        let service = FakeNotesService()
        let post = StoryItem(kind: .xPost, title: "RSL", body: "")
        service.inbox = [post]
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("scripter-test-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = AppStore(service: service, fileURL: file)
        await store.refresh()
        store.selectedStoryIDs = [post.id]
        await store.deleteSelected()
        #expect(service.statuses == [post.id: .dismissed])
        #expect(store.storyQueue.isEmpty)
    }
}

struct MatchesDecodingTests {
    /// A real /api/matches response saved from the notes service.
    @Test func decodesServiceResponse() throws {
        let url = try #require(Bundle.module.url(forResource: "matches-sample", withExtension: "json"))
        let matches = try JSONDecoder().decode(Matches.self, from: Data(contentsOf: url))
        #expect(matches.team.abbreviation == "RSL")
        #expect(!matches.results.isEmpty && !matches.upcoming.isEmpty)
        #expect(matches.results.allSatisfy { $0.result != nil && $0.goalsFor != nil })
        #expect(matches.upcoming.allSatisfy { $0.result == nil })
        // ESPN times have no seconds ("2026-10-18T00:30Z"); they must still parse.
        #expect(matches.upcoming.allSatisfy { $0.kickoff != nil })
        let dates = matches.results.compactMap(\.kickoff)
        #expect(dates == dates.sorted(by: >)) // newest result first
        // Non-MLS competitions (2026: Leagues Cup), with stages and the Tigres shootout.
        #expect(matches.competitions?.contains("Leagues Cup") == true)
        let cup = matches.results.filter { $0.competition == "Leagues Cup" }
        #expect(cup.count == 4)
        #expect(cup.allSatisfy { $0.stage != nil })
        #expect(cup.contains { $0.result == "D" && $0.shootout == "L" })
    }
}

struct RankingsDecodingTests {
    /// A real /api/rankings response saved from the notes service.
    @Test func decodesServiceResponse() throws {
        let url = try #require(Bundle.module.url(forResource: "rankings-sample", withExtension: "json"))
        let summary = try JSONDecoder().decode(RankingsSummary.self, from: Data(contentsOf: url))
        #expect(summary.sources.map(\.id) == ["mls", "espn", "tfz", "concacaf", "opta"])

        let mls = try #require(summary.sources.first { $0.id == "mls" })
        #expect(mls.scale == 30)
        #expect(mls.history.count > 10)
        #expect(mls.history.allSatisfy { $0.day != nil && (1...30).contains($0.rank) })
        #expect(mls.history.map(\.date) == mls.history.map(\.date).sorted())

        let espn = try #require(summary.sources.first { $0.id == "espn" })
        #expect(espn.change == (espn.previousRank ?? 0) - (espn.latest?.rank ?? 0))

        #expect(summary.season == 2026 && summary.seasons.contains(2026))
        let tfz = try #require(summary.sources.first { $0.id == "tfz" })
        #expect(tfz.history.count >= 20) // direct and forwarded emails
        #expect(tfz.history.first?.label == "Matchday 1")
    }

    @Test func ordinals() {
        #expect([1, 2, 3, 11, 22, 483].map(\.ordinal) == ["1st", "2nd", "3rd", "11th", "22nd", "483rd"])
    }
}

struct AppConfigTests {
    /// The app's built-in fallback must match the service's default settings file.
    @Test func fallbackMatchesServiceDefaults() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("services/notes/config.default.json")
        let defaults = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: file))
        // Section and competition IDs are generated locally, so compare their content.
        #expect(defaults.template.sections.map { [$0.title, $0.body] } == AppConfig.fallback.template.sections.map { [$0.title, $0.body] })
        #expect(defaults.competitions.map { [$0.name, $0.espnLeague] } == AppConfig.fallback.competitions.map { [$0.name, $0.espnLeague] })
        #expect(defaults.show == AppConfig.fallback.show)
        #expect(defaults.team == AppConfig.fallback.team)
        #expect(defaults.news == AppConfig.fallback.news)
        #expect(defaults.rankings == AppConfig.fallback.rankings)
        #expect(defaults.aiSettings == AppConfig.fallback.aiSettings)
    }

    @MainActor
    @Test func templateUsesSettings() throws {
        var config = AppConfig.fallback
        config.show = .init(name: "Sound Off", fullName: "Sounders Sound Off", host: "Alex", xHandle: "@soundoff")
        config.team.shortName = "SEA"
        config.template.sections = [
            .init(title: "Open", body: "Welcome to {show} with {host} on {date}.\n• [Top story]"),
            .init(title: "{team} Notes", body: ""),
        ]
        let date = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 16)))
        let script = ScriptTemplate.make(for: date, config: config)
        #expect(script.string == "Open\nWelcome to Sounders Sound Off with Alex on Friday, October 16, 2026.\n• [Top story]\nSEA Notes\n\n")
        let bullet = (script.string as NSString).range(of: "• [Top story]")
        #expect(ScriptStyle.indentLevel(from: script.attributes(at: bullet.location, effectiveRange: nil), block: .body) == 1)
    }
}

@MainActor
struct StoryTaggingTests {
    @Test func tagsToNewAndExistingStories() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("scripter-test-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = AppStore(service: FakeNotesService(), fileURL: file)
        let script = store.createScript(name: "Episode 30", date: Date())
        let before = store.trackedStories.count

        let created = try #require(store.tagPassage("Glad jogged at training", in: script.id, story: nil, newTitle: "Glad Return", note: nil))
        #expect(store.trackedStories.count == before + 1)
        #expect(created.latestUpdate == "Glad jogged at training")

        store.tagPassage("Full training Thursday", in: script.id, story: created.id, newTitle: nil, note: "Likely back vs SKC")
        let story = try #require(store.trackedStories.first { $0.id == created.id })
        #expect(story.mentions.map(\.excerpt) == ["Glad jogged at training", "Full training Thursday"])
        #expect(story.latestUpdate == "Likely back vs SKC")
        #expect(store.trackedStories(in: script.id).first?.id == created.id)
    }

    /// Stories saved before mentions existed must still load.
    @Test func decodesStoriesWithoutMentions() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","title":"Zach Booth Injury","latestUpdate":"","lastUpdated":"2026-10-01T00:00:00Z"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let story = try decoder.decode(TrackedStory.self, from: Data(json.utf8))
        #expect(story.title == "Zach Booth Injury" && story.mentions.isEmpty)
    }
}

@MainActor
struct GemmaFeatureTests {
    @Test func askSendsScriptsAndTrackerAndKeepsHistory() async throws {
        let service = FakeNotesService()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("scripter-test-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = AppStore(service: service, fileURL: file)
        var script = store.createScript(name: "Episode 28", date: Date())
        script.plainText = "Diego Luna is day to day."
        store.updateScript(script)
        store.tagPassage("Diego Luna is day to day.", in: script.id, story: nil, newTitle: "Luna Knock", note: nil)

        await store.ask("What did we say about Luna?")
        await store.ask("And since then?")

        #expect(store.chat.map(\.role) == ["user", "assistant", "user", "assistant"])
        #expect(store.chat[1].detail == "test · 1.2s")
        #expect(store.chat[1].sources?.excerpts.first?.episode == "Episode 28")
        // History sent with the follow-up carries only role and content, not the sources.
        let encoded = try JSONEncoder().encode(service.lastAskHistory)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("excerpts"))
        let sent = try #require(service.lastAskContext)
        #expect(sent.scripts.contains { $0.script.contains("Diego Luna") })
        #expect(sent.trackedStories.contains { $0.title == "Luna Knock" && $0.mentions.count == 1 })
    }

    @Test func bulletsFillTemplatePlaceholders() {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        textView.isRichText = true
        textView.allowsUndo = true
        textView.textStorage?.setAttributedString(ScriptTemplate.make(for: Date(), config: .fallback))
        let controller = RichTextController()
        controller.textView = textView
        controller.fillBullets(["RSL draw San Jose 1-1", "Luna back for SKC", "Booth return nears"])
        #expect(textView.string.contains("• RSL draw San Jose 1-1\n• Luna back for SKC\n• Booth return nears\nLet’s kick it off."))
        #expect(!textView.string.contains("[Bullet"))
    }
}

@MainActor
struct ProjectTests {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("scripter-test-\(UUID()).json")
    }

    /// A data file from before projects (scripts saved under "projects") becomes one project.
    @Test func legacyFileBecomesOneProjectAndLinks() async throws {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let legacy = #"""
        {"projects":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Episode 1","episodeDate":"2026-10-13T00:00:00Z","script":"Hello","notes":[],"createdAt":"2026-10-13T00:00:00Z","updatedAt":"2026-10-13T00:00:00Z"}],
         "storyQueue":[],"trackedStories":[{"id":"7F9619FF-8B86-D011-B42D-00C04FC964FF","title":"Glad Injury","latestUpdate":"","lastUpdated":"2026-10-01T00:00:00Z"}]}
        """#
        try Data(legacy.utf8).write(to: file)

        let service = FakeNotesService()
        let store = AppStore(service: service, fileURL: file)
        #expect(store.projectData.count == 1)
        #expect(store.scripts.map(\.name) == ["Episode 1"])
        #expect(store.scripts.first?.plainText == "Hello")
        #expect(store.trackedStories.map(\.title) == ["Glad Injury"])

        await store.refreshProjects()
        #expect(store.currentProjectID == "rsl")
        #expect(store.currentProjectName == "RSL Riot Report")

        // Saved in the new format, and still loads.
        let reopened = AppStore(service: service, fileURL: file)
        #expect(reopened.currentProjectID == "rsl")
        #expect(reopened.scripts.map(\.name) == ["Episode 1"])
    }

    @Test func projectsKeepTheirOwnScriptsAndStories() async throws {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let store = AppStore(service: FakeNotesService(), fileURL: file)
        await store.refreshProjects()
        let rslScript = store.createScript(name: "RSL Episode", date: Date())
        store.addTrackedStory(title: "RSL Story")
        store.chat = [ChatMessage(role: "user", content: "hi")]

        try await store.createProject(NewProjectRequest(
            name: "Sound Off",
            fromProject: "rsl",
            team: .init(name: "Seattle Sounders FC", shortName: "SEA", espnTeamId: "9726", espnLeague: "usa.1", espnSport: "soccer"),
            show: .init(name: "Sound Off", fullName: "Sound Off", host: "Alex", xHandle: "")
        ))
        #expect(store.currentProjectID == "sound-off")
        #expect(store.scripts.isEmpty)
        #expect(!store.trackedStories.contains { $0.title == "RSL Story" })
        #expect(store.chat.isEmpty) // nothing carries over
        store.createScript(name: "Seattle Episode", date: Date())

        await store.switchProject(to: "rsl")
        #expect(store.scripts.map(\.id).contains(rslScript.id))
        #expect(!store.scripts.contains { $0.name == "Seattle Episode" })

        await store.switchProject(to: "sound-off")
        try await store.deleteCurrentProject()
        #expect(store.currentProjectID == "rsl")
        #expect(store.projectData.map(\.id) == ["rsl"])
        #expect(store.scripts.contains { $0.id == rslScript.id })
    }
}
