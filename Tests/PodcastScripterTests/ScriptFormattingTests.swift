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

        var project = Project(name: "Test", episodeDate: Date())
        project.script = textView.string
        project.richText = ScriptStyle.rtfData(textView.attributedString())

        let reloaded = ScriptStyle.load(project)
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
        var project = Project(name: "Old", episodeDate: Date())
        project.script = "Written before formatting"
        let loaded = ScriptStyle.load(project)
        #expect(loaded.string == project.script)
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
}

@MainActor
struct AddToProjectTests {
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
        let project = store.createProject(name: "Episode", date: Date(), notes: [post])

        store.selectedStoryIDs = [post.id, headline.id]
        await store.addSelected(toProject: project.id)

        let updated = try #require(store.project(project.id))
        #expect(updated.notes.map(\.id) == [post.id, headline.id]) // the post isn't duplicated
        #expect(updated.notes.last?.kind == .news)
        #expect(service.statuses == [post.id: .used, headline.id: .used])
        #expect(store.storyQueue.isEmpty && store.news.isEmpty && store.selectedStoryIDs.isEmpty)
        #expect(store.route == .editor(project.id))
    }
}

@MainActor
struct ScriptTemplateTests {
    @Test func newProjectsStartWithShowSections() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("scripter-test-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = AppStore(service: FakeNotesService(), fileURL: file)
        let date = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 16)))
        let project = store.createProject(name: "Episode", date: date)

        let script = ScriptStyle.load(project)
        var headings: [String] = []
        ScriptStyle.enumerateParagraphs(in: script) { range in
            let text = (script.string as NSString).substring(with: range).trimmingCharacters(in: .newlines)
            if ScriptStyle.block(from: script.attributes(at: range.location, effectiveRange: nil)) == .heading2 {
                headings.append(text)
            }
        }
        #expect(headings == ["Intro", "Match Report", "RSL News", "League News", "Power Rankings", "Looking Ahead", "Outro"])
        #expect(project.script.contains("Hello, I’m Court, and this is your RSL Riot Report. Today is Friday, October 16, 2026 and our top stories include:"))
        #expect(project.script.contains("• [Bullet 3]\nLet’s kick it off."))
        #expect(project.script.hasSuffix("Until next time, I’m your host Court, and this has been your RSL Riot Report.\n"))
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
