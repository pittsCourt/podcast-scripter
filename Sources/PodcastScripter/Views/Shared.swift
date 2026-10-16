import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum ScriptExporter {
    private static let markdown = UTType(filenameExtension: "md", conformingTo: .plainText) ?? .plainText

    /// Shows a save panel with a format picker: RTF (Word, Pages, Google Docs), Markdown, or plain text.
    static func export(_ script: Script) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.rtf, markdown, .plainText]
        if #available(macOS 15, *) {
            panel.showsContentTypes = true
        }
        panel.nameFieldStringValue = script.displayTitle
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let text = ScriptStyle.load(script)
        let data: Data?
        switch url.pathExtension.lowercased() {
        case "rtf":
            data = ScriptStyle.exportRTF(text, title: script.displayTitle)
        case "md", "markdown":
            data = ScriptStyle.markdown(text, title: script.displayTitle).data(using: .utf8)
        default:
            data = "\(script.displayTitle)\n\n\(script.plainText)\n".data(using: .utf8)
        }

        do {
            guard let data else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: url, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
