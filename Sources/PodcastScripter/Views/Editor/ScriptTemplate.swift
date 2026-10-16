import AppKit

/// Builds a new episode's starting script from the template in Settings: each section becomes a
/// Heading 2 followed by its starting text, with placeholders filled in.
enum ScriptTemplate {
    /// Placeholders available in section titles and text.
    static let placeholders: [(token: String, meaning: String)] = [
        ("{date}", "Episode date, e.g. Friday, October 16, 2026"),
        ("{host}", "Host name"),
        ("{show}", "Full show name"),
        ("{handle}", "X handle"),
        ("{team}", "Team short name"),
    ]

    static func fill(_ text: String, date: Date, config: AppConfig) -> String {
        text
            .replacingOccurrences(of: "{date}", with: date.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))
            .replacingOccurrences(of: "{host}", with: config.show.host)
            .replacingOccurrences(of: "{show}", with: config.show.fullName)
            .replacingOccurrences(of: "{handle}", with: config.show.xHandle)
            .replacingOccurrences(of: "{team}", with: config.team.shortName)
    }

    static func make(for date: Date, config: AppConfig) -> NSAttributedString {
        let script = NSMutableAttributedString()
        func add(_ text: String, _ block: BlockStyle, indent: Int = 0) {
            script.append(NSAttributedString(string: text + "\n", attributes: ScriptStyle.attributes(for: block, indentLevel: indent)))
        }

        for section in config.template.sections {
            add(fill(section.title, date: date, config: config), .heading2)
            let body = fill(section.body, date: date, config: config)
            if body.isEmpty {
                add("", .body) // an empty line to start writing in
                continue
            }
            for line in body.components(separatedBy: "\n") {
                // "• " lines are bullets, indented one level.
                add(line, .body, indent: line.hasPrefix("• ") ? 1 : 0)
            }
        }
        return script
    }
}
