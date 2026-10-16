import AppKit

/// Paragraph-level styles available in the script editor.
enum BlockStyle: String, CaseIterable, Identifiable {
    case body
    case heading1
    case heading2
    case heading3
    case heading4
    case quote

    var id: String { rawValue }

    var label: String {
        switch self {
        case .body: "Body"
        case .heading1: "Heading 1"
        case .heading2: "Heading 2"
        case .heading3: "Heading 3"
        case .heading4: "Heading 4"
        case .quote: "Quote"
        }
    }

    var isHeading: Bool {
        switch self {
        case .heading1, .heading2, .heading3, .heading4: true
        case .body, .quote: false
        }
    }

    /// Each style has its own size so the style can be recovered from saved RTF.
    var fontSize: CGFloat {
        switch self {
        case .body, .quote: 16
        case .heading1: 28
        case .heading2: 23
        case .heading3: 19
        case .heading4: 17
        }
    }

    fileprivate var weight: NSFont.Weight {
        switch self {
        case .body, .quote: .regular
        case .heading1, .heading2: .bold
        case .heading3, .heading4: .semibold
        }
    }

    fileprivate var spacingBefore: CGFloat {
        switch self {
        case .heading1: 18
        case .heading2: 14
        case .heading3: 12
        case .heading4: 10
        case .body, .quote: 0
        }
    }

    fileprivate var spacingAfter: CGFloat { isHeading ? 6 : 10 }

    fileprivate var baseIndent: CGFloat { self == .quote ? 24 : 0 }

    var markdownPrefix: String {
        switch self {
        case .body: ""
        case .heading1: "# "
        case .heading2: "## "
        case .heading3: "### "
        case .heading4: "#### "
        case .quote: "> "
        }
    }
}

/// Fonts, colors and conversions for the formatted script.
enum ScriptStyle {
    static let indentStep: CGFloat = 28
    static let textColor = NSColor(srgbRed: 0.929, green: 0.929, blue: 0.937, alpha: 1)
    static let quoteColor = NSColor(srgbRed: 0.631, green: 0.631, blue: 0.667, alpha: 1)
    static let linkColor = NSColor(srgbRed: 0.886, green: 0.408, blue: 0.494, alpha: 1)

    // MARK: Building attributes

    static func font(for block: BlockStyle, bold: Bool = false, italic: Bool = false) -> NSFont {
        // Inline bold only applies to body text; headings are already heavy.
        let weight: NSFont.Weight = bold && block.weight == .regular ? .bold : block.weight
        let font = NSFont.systemFont(ofSize: block.fontSize, weight: weight)
        guard italic || block == .quote else { return font }
        return NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    }

    static func paragraphStyle(for block: BlockStyle, indentLevel: Int) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 5
        style.paragraphSpacingBefore = block.spacingBefore
        style.paragraphSpacing = block.spacingAfter
        let indent = block.baseIndent + CGFloat(indentLevel) * indentStep
        style.headIndent = indent
        style.firstLineHeadIndent = indent
        return style
    }

    static func attributes(for block: BlockStyle, indentLevel: Int = 0, bold: Bool = false, italic: Bool = false) -> [NSAttributedString.Key: Any] {
        [
            .font: font(for: block, bold: bold, italic: italic),
            .paragraphStyle: paragraphStyle(for: block, indentLevel: indentLevel),
            .foregroundColor: block == .quote ? quoteColor : textColor,
        ]
    }

    // MARK: Reading attributes

    static func block(from attributes: [NSAttributedString.Key: Any]) -> BlockStyle {
        let size = ((attributes[.font] as? NSFont)?.pointSize ?? 16).rounded()
        if let heading = BlockStyle.allCases.first(where: { $0.isHeading && $0.fontSize == size }) {
            return heading
        }
        if let color = attributes[.foregroundColor] as? NSColor, isClose(color, quoteColor) {
            return .quote
        }
        return .body
    }

    static func indentLevel(from attributes: [NSAttributedString.Key: Any], block: BlockStyle) -> Int {
        let indent = (attributes[.paragraphStyle] as? NSParagraphStyle)?.headIndent ?? 0
        return max(0, Int(((indent - block.baseIndent) / indentStep).rounded()))
    }

    static func isBold(_ font: NSFont?) -> Bool {
        font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false
    }

    static func isItalic(_ font: NSFont?) -> Bool {
        font?.fontDescriptor.symbolicTraits.contains(.italic) ?? false
    }

    /// Inline bold/italic as the user applied it (ignoring what the block style itself adds).
    static func inlineTraits(_ attributes: [NSAttributedString.Key: Any], block: BlockStyle) -> (bold: Bool, italic: Bool) {
        let font = attributes[.font] as? NSFont
        return (
            bold: !block.isHeading && isBold(font),
            italic: block != .quote && isItalic(font)
        )
    }

    private static func isClose(_ a: NSColor, _ b: NSColor) -> Bool {
        guard let a = a.usingColorSpace(.sRGB), let b = b.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < 0.03
            && abs(a.greenComponent - b.greenComponent) < 0.03
            && abs(a.blueComponent - b.blueComponent) < 0.03
    }

    /// Calls `body` with each paragraph's full range (including its newline).
    static func enumerateParagraphs(in string: NSAttributedString, range: NSRange? = nil, _ body: (NSRange) -> Void) {
        let text = string.string as NSString
        let target = range ?? NSRange(location: 0, length: text.length)
        var location = target.location
        repeat {
            let paragraph = text.paragraphRange(for: NSRange(location: location, length: 0))
            body(paragraph)
            location = NSMaxRange(paragraph)
        } while location < NSMaxRange(target) && location < text.length
    }

    // MARK: Loading & saving

    static func load(_ project: Project) -> NSAttributedString {
        if let data = project.richText,
           let stored = NSAttributedString(rtf: data, documentAttributes: nil) {
            let text = NSMutableAttributedString(attributedString: stored)
            normalize(text)
            return text
        }
        return NSAttributedString(string: project.script, attributes: attributes(for: .body))
    }

    static func rtfData(_ text: NSAttributedString) -> Data? {
        text.rtf(from: NSRange(location: 0, length: text.length), documentAttributes: [:])
    }

    /// RTF can swap the system font for another, so fonts and colors are rebuilt from each
    /// paragraph's style, keeping inline bold, italic, underline and links.
    static func normalize(_ text: NSMutableAttributedString) {
        guard text.length > 0 else { return }
        text.beginEditing()
        enumerateParagraphs(in: text) { paragraph in
            let first = text.attributes(at: paragraph.location, effectiveRange: nil)
            let block = block(from: first)
            let level = indentLevel(from: first, block: block)
            text.addAttribute(.paragraphStyle, value: paragraphStyle(for: block, indentLevel: level), range: paragraph)
            text.enumerateAttributes(in: paragraph) { attrs, run, _ in
                let traits = inlineTraits(attrs, block: block)
                text.addAttribute(.font, value: font(for: block, bold: traits.bold, italic: traits.italic), range: run)
                text.addAttribute(.foregroundColor, value: block == .quote ? quoteColor : textColor, range: run)
            }
        }
        text.endEditing()
    }

    // MARK: Export

    /// A copy for other apps: dark-mode colors become print colors and the system font becomes Helvetica Neue.
    static func exportRTF(_ text: NSAttributedString, title: String) -> Data? {
        let output = NSMutableAttributedString(string: "\(title)\n", attributes: attributes(for: .heading1))
        output.append(text)
        output.enumerateAttributes(in: NSRange(location: 0, length: output.length)) { attrs, run, _ in
            let block = block(from: attrs)
            let traits = inlineTraits(attrs, block: block)
            let systemFont = font(for: block, bold: traits.bold, italic: traits.italic)
            var descriptor = NSFontDescriptor(name: "Helvetica Neue", size: block.fontSize)
            descriptor = descriptor.withSymbolicTraits(systemFont.fontDescriptor.symbolicTraits)
            if let font = NSFont(descriptor: descriptor, size: block.fontSize) {
                output.addAttribute(.font, value: font, range: run)
            }
            output.addAttribute(.foregroundColor, value: block == .quote ? NSColor.darkGray : NSColor.black, range: run)
        }
        return rtfData(output)
    }

    static func markdown(_ text: NSAttributedString, title: String) -> String {
        var paragraphs = ["# \(title)"]
        let string = text.string as NSString
        guard text.length > 0 else { return paragraphs[0] + "\n" }

        enumerateParagraphs(in: text) { paragraph in
            var content = paragraph
            // Drop the trailing newline from the paragraph's range.
            while content.length > 0, let scalar = UnicodeScalar(string.character(at: NSMaxRange(content) - 1)),
                  CharacterSet.newlines.contains(scalar) {
                content.length -= 1
            }
            guard content.length > 0 else { return }

            let block = block(from: text.attributes(at: content.location, effectiveRange: nil))
            var line = ""
            text.enumerateAttributes(in: content) { attrs, run, _ in
                line += markdownRun(string.substring(with: run), attrs: attrs, block: block)
            }
            paragraphs.append(block.markdownPrefix + line)
        }
        return paragraphs.joined(separator: "\n\n") + "\n"
    }

    private static func markdownRun(_ raw: String, attrs: [NSAttributedString.Key: Any], block: BlockStyle) -> String {
        let core = raw.trimmingCharacters(in: .whitespaces)
        guard !core.isEmpty else { return raw }
        // Keep surrounding spaces outside the markers: "** bold **" isn't valid Markdown.
        let leading = String(raw.prefix { $0 == " " || $0 == "\t" })
        let trailing = String(raw.reversed().prefix { $0 == " " || $0 == "\t" })

        let traits = inlineTraits(attrs, block: block)
        var text = core
        if (attrs[.strikethroughStyle] as? Int ?? 0) != 0 { text = "~~\(text)~~" }
        if (attrs[.underlineStyle] as? Int ?? 0) != 0 { text = "<u>\(text)</u>" }
        if traits.italic { text = "*\(text)*" }
        if traits.bold { text = "**\(text)**" }
        if let link = linkURL(attrs[.link]) { text = "[\(text)](\(link.absoluteString))" }
        return leading + text + trailing
    }

    static func linkURL(_ value: Any?) -> URL? {
        if let url = value as? URL { return url }
        if let string = value as? String { return URL(string: string) }
        return nil
    }
}
