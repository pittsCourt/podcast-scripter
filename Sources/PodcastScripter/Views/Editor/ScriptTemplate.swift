import AppKit

/// The starting script for a new episode: the show's sections as Heading 2s, with the
/// verbatim intro and outro filled in.
enum ScriptTemplate {
    static let sections = [
        "Intro",
        "Match Report",
        "\(ShowConfig.teamName) News",
        "League News",
        "Power Rankings",
        "Looking Ahead",
        "Outro",
    ]

    /// Exactly three per episode, ranked by importance; a match result is normally #1.
    static let topStoryCount = 3

    static func intro(for date: Date) -> String {
        let day = date.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
        return "Hello, I’m \(ShowConfig.host), and this is your \(ShowConfig.fullShowName). Today is \(day) and our top stories include:"
    }

    static let outro = "Thanks for tuning in! Follow us on X \(ShowConfig.xHandle). Until next time, I’m your host \(ShowConfig.host), and this has been your \(ShowConfig.fullShowName)."

    static func make(for date: Date) -> NSAttributedString {
        let script = NSMutableAttributedString()
        func add(_ text: String, _ block: BlockStyle, indent: Int = 0) {
            script.append(NSAttributedString(string: text + "\n", attributes: ScriptStyle.attributes(for: block, indentLevel: indent)))
        }

        for section in sections {
            add(section, .heading2)
            switch section {
            case "Intro":
                add(intro(for: date), .body)
                for n in 1...topStoryCount { add("• [Bullet \(n)]", .body, indent: 1) }
                add("Let’s kick it off.", .body)
            case "Outro":
                add(outro, .body)
            default:
                add("", .body)
            }
        }
        return script
    }
}
