import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum ScriptExporter {
    /// Shows a save panel and writes the script as plain text.
    static func export(_ project: Project) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(project.displayTitle).txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let text = "\(project.displayTitle)\n\n\(project.script)\n"
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
