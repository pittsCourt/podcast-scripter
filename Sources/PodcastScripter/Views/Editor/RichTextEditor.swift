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

    /// Drives the link sheet; set by ⌘K or the link button.
    var isEditingLink = false

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
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = scrollView.documentView as! NSTextView
        textView.isRichText = true
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.importsGraphics = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticLinkDetectionEnabled = true
        textView.isAutomaticDashSubstitutionEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = true
        textView.textContainerInset = NSSize(width: 0, height: 24)
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
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            parent.controller.updateState()
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
            Section {
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
