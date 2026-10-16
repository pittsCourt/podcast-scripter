import AppKit
import SwiftUI

/// Formatting commands for the script editor, shared by the format bar and the Format menu.
@MainActor
@Observable
final class RichTextController {
    @ObservationIgnored weak var textView: NSTextView?

    // Reflects the selection, for highlighting format bar buttons.
    private(set) var block: BlockStyle = .body
    private(set) var isBold = false
    private(set) var isItalic = false
    private(set) var isUnderlined = false
    private(set) var isStruckThrough = false
    private(set) var linkURL: URL?
    /// Rumor / reported / confirmed for the selection, if any.
    private(set) var status: StoryStatus?

    /// Drives the link sheet; set by ⌘K or the link button.
    var isEditingLink = false
    /// Drives the "Track as Story" sheet; holds the passage being tagged.
    var taggingExcerpt: String?

    /// Opens the Track as Story sheet for the selected text.
    func beginTagging() {
        let text = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        taggingStatus = status
        taggingExcerpt = text
    }

    /// The highlighted passage's own rumor/reported/confirmed mark, captured with `taggingExcerpt`.
    var taggingStatus: StoryStatus?

    private(set) var hasSelection = false

    // MARK: Paragraph styles

    func setBlock(_ newBlock: BlockStyle) {
        editParagraphs { storage, paragraph in
            let first = storage.attributes(at: paragraph.location, effectiveRange: nil)
            let oldBlock = ScriptStyle.block(from: first)
            let level = ScriptStyle.indentLevel(from: first, block: oldBlock)
            storage.addAttribute(.paragraphStyle, value: ScriptStyle.paragraphStyle(for: newBlock, indentLevel: level), range: paragraph)
            storage.enumerateAttributes(in: paragraph) { attrs, run, _ in
                let traits = ScriptStyle.inlineTraits(attrs, block: oldBlock)
                storage.addAttribute(.font, value: ScriptStyle.font(for: newBlock, bold: traits.bold, italic: traits.italic), range: run)
                storage.addAttribute(.foregroundColor, value: newBlock == .quote ? ScriptStyle.quoteColor : ScriptStyle.textColor, range: run)
            }
        } typing: { attrs in
            let oldBlock = ScriptStyle.block(from: attrs)
            let traits = ScriptStyle.inlineTraits(attrs, block: oldBlock)
            let level = ScriptStyle.indentLevel(from: attrs, block: oldBlock)
            return attrs.merging(ScriptStyle.attributes(for: newBlock, indentLevel: level, bold: traits.bold, italic: traits.italic)) { $1 }
        }
    }

    func indent() { changeIndent(by: 1) }
    func outdent() { changeIndent(by: -1) }

    private func changeIndent(by delta: Int) {
        editParagraphs { storage, paragraph in
            let first = storage.attributes(at: paragraph.location, effectiveRange: nil)
            let block = ScriptStyle.block(from: first)
            let level = max(0, min(8, ScriptStyle.indentLevel(from: first, block: block) + delta))
            storage.addAttribute(.paragraphStyle, value: ScriptStyle.paragraphStyle(for: block, indentLevel: level), range: paragraph)
        } typing: { attrs in
            let block = ScriptStyle.block(from: attrs)
            let level = max(0, min(8, ScriptStyle.indentLevel(from: attrs, block: block) + delta))
            var attrs = attrs
            attrs[.paragraphStyle] = ScriptStyle.paragraphStyle(for: block, indentLevel: level)
            return attrs
        }
    }

    func clearFormatting() {
        editParagraphs { storage, paragraph in
            storage.removeAttribute(.underlineStyle, range: paragraph)
            storage.removeAttribute(.strikethroughStyle, range: paragraph)
            storage.removeAttribute(.link, range: paragraph)
            storage.addAttributes(ScriptStyle.attributes(for: .body), range: paragraph)
        } typing: { _ in
            ScriptStyle.attributes(for: .body)
        }
    }

    // MARK: Story status

    /// Marks the selection as rumor, reported or confirmed (nil clears it). Shown as an emoji in
    /// the margin and a faint tint behind the text.
    func setStatus(_ newStatus: StoryStatus?) {
        guard let textView, let storage = textView.textStorage else { return }
        var range = textView.selectedRange()
        // With just a cursor, act on the marked passage it's in.
        if range.length == 0 {
            guard let match = ScriptStyle.statusRanges(in: storage).first(where: { NSLocationInRange(range.location, $0.range) || NSMaxRange($0.range) == range.location }) else { return }
            range = match.range
        }
        guard textView.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        if let newStatus {
            storage.addAttribute(.backgroundColor, value: newStatus.tint, range: range)
        } else {
            storage.removeAttribute(.backgroundColor, range: range)
        }
        storage.endEditing()
        textView.didChangeText()
        textView.needsDisplay = true
        updateState()
    }

    // MARK: Inline styles

    func toggleBold() { toggleTrait(bold: true) }
    func toggleItalic() { toggleTrait(bold: false) }

    private func toggleTrait(bold: Bool) {
        let isOn = bold ? isBold : isItalic
        editSelection { storage, range in
            storage.enumerateAttributes(in: range) { attrs, run, _ in
                let block = ScriptStyle.block(from: attrs)
                var traits = ScriptStyle.inlineTraits(attrs, block: block)
                if bold { traits.bold = !isOn } else { traits.italic = !isOn }
                storage.addAttribute(.font, value: ScriptStyle.font(for: block, bold: traits.bold, italic: traits.italic), range: run)
            }
        } typing: { attrs in
            let block = ScriptStyle.block(from: attrs)
            var traits = ScriptStyle.inlineTraits(attrs, block: block)
            if bold { traits.bold = !isOn } else { traits.italic = !isOn }
            var attrs = attrs
            attrs[.font] = ScriptStyle.font(for: block, bold: traits.bold, italic: traits.italic)
            return attrs
        }
    }

    func toggleUnderline() { toggleLine(.underlineStyle, isOn: isUnderlined) }
    func toggleStrikethrough() { toggleLine(.strikethroughStyle, isOn: isStruckThrough) }

    private func toggleLine(_ key: NSAttributedString.Key, isOn: Bool) {
        editSelection { storage, range in
            if isOn {
                storage.removeAttribute(key, range: range)
            } else {
                storage.addAttribute(key, value: NSUnderlineStyle.single.rawValue, range: range)
            }
        } typing: { attrs in
            var attrs = attrs
            attrs[key] = isOn ? nil : NSUnderlineStyle.single.rawValue
            return attrs
        }
    }

    // MARK: Links

    /// The selected text, shown in the link sheet.
    var selectedText: String {
        guard let textView else { return "" }
        return (textView.string as NSString).substring(with: textView.selectedRange())
    }

    func setLink(_ url: URL?) {
        guard let textView, let storage = textView.textStorage else { return }
        var range = textView.selectedRange()

        // With no selection, act on the link under the cursor, or insert the URL as its own text.
        if range.length == 0 {
            if storage.length > 0, range.location > 0,
               storage.attribute(.link, at: range.location - 1, longestEffectiveRange: &range,
                                 in: NSRange(location: 0, length: storage.length)) != nil {
                // `range` now covers the existing link.
            } else if let url {
                let attrs = textView.typingAttributes.merging([.link: url]) { $1 }
                let inserted = NSAttributedString(string: url.absoluteString, attributes: attrs)
                let insertAt = textView.selectedRange()
                guard textView.shouldChangeText(in: insertAt, replacementString: inserted.string) else { return }
                storage.replaceCharacters(in: insertAt, with: inserted)
                textView.didChangeText()
                textView.setSelectedRange(NSRange(location: insertAt.location + inserted.length, length: 0))
                textView.typingAttributes[.link] = nil
                updateState()
                return
            } else {
                return
            }
        }

        guard textView.shouldChangeText(in: range, replacementString: nil) else { return }
        if let url {
            storage.addAttribute(.link, value: url, range: range)
        } else {
            storage.removeAttribute(.link, range: range)
        }
        textView.didChangeText()
        updateState()
    }

    // MARK: Inserting stories

    /// Inserts `paragraphs` as a quote at the cursor, followed by a linked credit line.
    func insertQuote(_ paragraphs: [String], attribution: String, link: URL?) {
        let quote = NSMutableAttributedString()
        for paragraph in paragraphs {
            quote.append(NSAttributedString(string: paragraph + "\n", attributes: ScriptStyle.attributes(for: .quote)))
        }
        let creditAttrs = ScriptStyle.attributes(for: .quote)
        let credit = NSMutableAttributedString(string: attribution, attributes: creditAttrs)
        if let link {
            credit.addAttribute(.link, value: link, range: NSRange(location: 0, length: credit.length))
        }
        quote.append(credit)
        quote.append(NSAttributedString(string: "\n", attributes: creditAttrs))
        insertParagraphs(quote)
    }

    /// Replaces the template's "[Bullet 1]"–"[Bullet 3]" placeholders with `bullets`, keeping their
    /// formatting. If the placeholders are gone, inserts the bullets at the cursor instead.
    func fillBullets(_ bullets: [String]) {
        guard let textView, let storage = textView.textStorage else { return }
        var replaced = 0
        for (index, bullet) in bullets.enumerated() {
            let range = (storage.string as NSString).range(of: "[Bullet \(index + 1)]")
            guard range.location != NSNotFound, textView.shouldChangeText(in: range, replacementString: bullet) else { continue }
            storage.replaceCharacters(in: range, with: bullet)
            textView.didChangeText()
            replaced += 1
        }
        if replaced == 0 {
            insertParagraphs(NSAttributedString(
                string: bullets.map { "• \($0)\n" }.joined(),
                attributes: ScriptStyle.attributes(for: .body, indentLevel: 1)
            ))
        }
        updateState()
    }

    /// Inserts `text` as body paragraphs at the cursor.
    func insertBody(_ text: String) {
        insertParagraphs(NSAttributedString(string: text + "\n", attributes: ScriptStyle.attributes(for: .body)))
    }

    /// Inserts whole paragraphs (each ending in a newline) at the start of the cursor's paragraph,
    /// or after it if the cursor is mid-paragraph, so existing text is never split.
    private func insertParagraphs(_ paragraphs: NSAttributedString) {
        guard let textView, let storage = textView.textStorage else { return }
        let text = storage.string as NSString
        var location = min(NSMaxRange(textView.selectedRange()), text.length)
        let toInsert = NSMutableAttributedString(attributedString: paragraphs)

        let atParagraphStart = location == 0 || text.character(at: location - 1) == 0x0A
        if !atParagraphStart {
            let paragraph = text.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(paragraph)
            if location == text.length, text.character(at: location - 1) != 0x0A {
                // Last paragraph without a newline: end it, keeping its own style.
                let attrs = storage.attributes(at: location - 1, effectiveRange: nil)
                toInsert.insert(NSAttributedString(string: "\n", attributes: attrs), at: 0)
            }
        }

        let range = NSRange(location: location, length: 0)
        guard textView.shouldChangeText(in: range, replacementString: toInsert.string) else { return }
        storage.replaceCharacters(in: range, with: toInsert)
        textView.didChangeText()

        let end = location + toInsert.length
        textView.setSelectedRange(NSRange(location: end, length: 0))
        textView.typingAttributes = ScriptStyle.attributes(for: .body)
        textView.scrollRangeToVisible(NSRange(location: end, length: 0))
        textView.window?.makeFirstResponder(textView)
        updateState()
    }

    // MARK: State

    func updateState() {
        guard let textView, let storage = textView.textStorage else { return }
        let range = textView.selectedRange()
        hasSelection = range.length > 0
        let attrs: [NSAttributedString.Key: Any]
        if range.length > 0 {
            attrs = storage.attributes(at: range.location, effectiveRange: nil)
        } else {
            attrs = textView.typingAttributes
        }
        block = ScriptStyle.block(from: attrs)
        let traits = ScriptStyle.inlineTraits(attrs, block: block)
        isBold = traits.bold
        isItalic = traits.italic
        isUnderlined = (attrs[.underlineStyle] as? Int ?? 0) != 0
        status = ScriptStyle.status(from: range.length > 0 || storage.length == 0
            ? attrs
            : storage.attributes(at: max(0, min(range.location, storage.length) - 1), effectiveRange: nil))
        isStruckThrough = (attrs[.strikethroughStyle] as? Int ?? 0) != 0

        var link = ScriptStyle.linkURL(attrs[.link])
        if link == nil, range.length == 0, range.location > 0, range.location <= storage.length {
            link = ScriptStyle.linkURL(storage.attribute(.link, at: range.location - 1, effectiveRange: nil))
        }
        linkURL = link
    }

    // MARK: Editing plumbing (undo-aware)

    /// Applies `change` to every paragraph touched by the selection.
    private func editParagraphs(_ change: (NSTextStorage, NSRange) -> Void,
                                typing: ([NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any]) {
        guard let textView, let storage = textView.textStorage else { return }
        let selection = textView.selectedRange()
        let paragraphs = (storage.string as NSString).paragraphRange(for: selection)

        if paragraphs.length > 0, textView.shouldChangeText(in: paragraphs, replacementString: nil) {
            storage.beginEditing()
            ScriptStyle.enumerateParagraphs(in: storage, range: paragraphs) { change(storage, $0) }
            storage.endEditing()
            textView.didChangeText()
        }
        textView.typingAttributes = typing(textView.typingAttributes)
        updateState()
    }

    /// Applies `change` to the selection, or to what's typed next when nothing is selected.
    private func editSelection(_ change: (NSTextStorage, NSRange) -> Void,
                               typing: ([NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any]) {
        guard let textView, let storage = textView.textStorage else { return }
        let range = textView.selectedRange()
        if range.length > 0 {
            guard textView.shouldChangeText(in: range, replacementString: nil) else { return }
            storage.beginEditing()
            change(storage, range)
            storage.endEditing()
            textView.didChangeText()
        } else {
            textView.typingAttributes = typing(textView.typingAttributes)
        }
        updateState()
    }
}

/// NSTextView-backed formatted text editor. Loads `initialText` once per `documentID`.
struct RichTextEditor: NSViewRepresentable {
    var documentID: UUID
    var initialText: () -> NSAttributedString
    var controller: RichTextController
    var onChange: (NSAttributedString) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // Built by hand (TextKit 1) so the margin can be drawn from the layout manager.
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        context.coordinator.storage = storage

        let textView = ScriptTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 600), textContainer: container)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        // App zoom (⌘+ / ⌘−) magnifies the page; the saved font sizes stay the same.
        scrollView.allowsMagnification = true
        scrollView.magnification = Zoom.factor

        textView.isRichText = true
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.importsGraphics = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticLinkDetectionEnabled = true
        textView.isAutomaticDashSubstitutionEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = true
        // The left inset is the margin for 🔴 🟡 🟢 status marks.
        textView.textContainerInset = NSSize(width: ScriptTextView.margin, height: 24)
        textView.insertionPointColor = ScriptStyle.linkColor
        textView.linkTextAttributes = [
            .foregroundColor: ScriptStyle.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        textView.delegate = context.coordinator

        context.coordinator.load(into: textView)
        controller.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        controller.textView = textView
        if context.coordinator.loadedID != documentID {
            context.coordinator.load(into: textView)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditor
        var loadedID: UUID?
        /// The text view doesn't own its storage when the TextKit stack is built by hand.
        var storage: NSTextStorage?
        private var returnedFromHeading = false

        init(_ parent: RichTextEditor) {
            self.parent = parent
        }

        func load(into textView: NSTextView) {
            loadedID = parent.documentID
            textView.textStorage?.setAttributedString(parent.initialText())
            textView.typingAttributes = ScriptStyle.attributes(for: .body)
            if let storage = textView.textStorage, storage.length > 0 {
                textView.typingAttributes = storage.attributes(at: storage.length - 1, effectiveRange: nil)
            }
            textView.undoManager?.removeAllActions()
            parent.controller.updateState()
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            // Pressing Return at the end of a heading starts a body paragraph, like Pages and Docs.
            returnedFromHeading = replacementString == "\n" && ScriptStyle.block(from: textView.typingAttributes).isHeading
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            if returnedFromHeading {
                returnedFromHeading = false
                textView.typingAttributes = ScriptStyle.attributes(for: .body)
            }
            parent.onChange(textView.attributedString())
            parent.controller.updateState()
            textView.needsDisplay = true // margin marks follow the text
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            parent.controller.updateState()
        }

        /// Adds "Track as Story…" and the status marks to the right-click menu when text is selected.
        func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
            guard view.selectedRange().length > 0 else { return menu }
            var index = 0
            func add(_ title: String, _ action: Selector, tag: Int = 0) {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                item.tag = tag
                menu.insertItem(item, at: index)
                index += 1
            }
            add("Track as Story…", #selector(trackStory))
            for (offset, status) in StoryStatus.allCases.enumerated() {
                add("\(status.emoji)  Mark as \(status.label)", #selector(markStatus(_:)), tag: offset + 1)
            }
            if ScriptStyle.status(from: view.textStorage?.attributes(at: view.selectedRange().location, effectiveRange: nil) ?? [:]) != nil {
                add("Clear Status", #selector(markStatus(_:)), tag: 0)
            }
            menu.insertItem(.separator(), at: index)
            return menu
        }

        @objc private func trackStory() {
            parent.controller.beginTagging()
        }

        @objc private func markStatus(_ sender: NSMenuItem) {
            parent.controller.setStatus(sender.tag == 0 ? nil : StoryStatus.allCases[sender.tag - 1])
        }
    }
}

// MARK: - Format menu wiring

struct RichTextControllerKey: FocusedValueKey {
    typealias Value = RichTextController
}

extension FocusedValues {
    var richTextController: RichTextController? {
        get { self[RichTextControllerKey.self] }
        set { self[RichTextControllerKey.self] = newValue }
    }
}

/// The menu bar's Format menu; enabled while a script is open.
struct FormatCommands: Commands {
    @FocusedValue(\.richTextController) private var controller

    var body: some Commands {
        CommandMenu("Format") {
            Section {
                ForEach(BlockStyle.allCases) { block in
                    Button(block.label) { controller?.setBlock(block) }
                        .keyboardShortcut(Self.shortcut(for: block), modifiers: [.command, .option])
                }
            }
            Section {
                Button("Bold") { controller?.toggleBold() }
                    .keyboardShortcut("b")
                Button("Italic") { controller?.toggleItalic() }
                    .keyboardShortcut("i")
                Button("Underline") { controller?.toggleUnderline() }
                    .keyboardShortcut("u")
                Button("Strikethrough") { controller?.toggleStrikethrough() }
                    .keyboardShortcut("x", modifiers: [.command, .shift])
            }
            Section {
                Button("Increase Indent") { controller?.indent() }
                    .keyboardShortcut("]", modifiers: [.command, .option])
                Button("Decrease Indent") { controller?.outdent() }
                    .keyboardShortcut("[", modifiers: [.command, .option])
            }
            Menu("Mark As") {
                ForEach(Array(StoryStatus.allCases.enumerated()), id: \.element) { offset, status in
                    Button("\(status.emoji)  \(status.label)") { controller?.setStatus(status) }
                        .keyboardShortcut(KeyEquivalent(Character("\(offset + 1)")), modifiers: [.control, .option])
                }
                Divider()
                Button("Clear Status") { controller?.setStatus(nil) }
                    .keyboardShortcut("0", modifiers: [.control, .option])
            }
            Section {
                Button("Track as Story…") { controller?.beginTagging() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Button("Add Link…") { controller?.isEditingLink = true }
                    .keyboardShortcut("k")
                Button("Clear Formatting") { controller?.clearFormatting() }
            }
        }
    }

    private static func shortcut(for block: BlockStyle) -> KeyEquivalent {
        switch block {
        case .body: "0"
        case .heading1: "1"
        case .heading2: "2"
        case .heading3: "3"
        case .heading4: "4"
        case .quote: "'"
        }
    }
}

/// The script's text view: draws each marked passage's 🔴 🟡 🟢 in the left margin, beside the
/// passage's first line.
final class ScriptTextView: NSTextView {
    static let margin: CGFloat = 28

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let storage = textStorage, storage.length > 0, let layoutManager else { return }
        let origin = textContainerOrigin
        var lastLineY: CGFloat = -.greatestFiniteMagnitude
        var offset: CGFloat = 0

        for (range, status) in ScriptStyle.statusRanges(in: storage) {
            let glyph = layoutManager.glyphIndexForCharacter(at: range.location)
            guard glyph < layoutManager.numberOfGlyphs else { continue }
            let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let lineY = line.minY + origin.y
            // Two marks starting on the same line sit side by side.
            offset = abs(lineY - lastLineY) < 1 ? offset + 16 : 0
            lastLineY = lineY

            let font = (storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont) ?? .systemFont(ofSize: 16)
            let emoji = NSAttributedString(string: status.emoji, attributes: [.font: NSFont.systemFont(ofSize: 12)])
            let size = emoji.size()
            let textHeight = layoutManager.defaultLineHeight(for: font)
            let point = NSPoint(x: 6 + offset, y: lineY + max(0, (textHeight - size.height) / 2))
            guard NSRect(origin: point, size: size).intersects(dirtyRect) else { continue }
            emoji.draw(at: point)
        }
    }
}
