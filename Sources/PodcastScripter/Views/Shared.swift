import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Floating assistant button. Placeholder until the Claude integration is built.
struct ClaudeButton: View {
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            Text("Claude")
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.text)
                .frame(width: 60, height: 60)
                .background(Circle().fill(Color(white: 0.35)))
                .overlay(Circle().stroke(Theme.border, lineWidth: 2))
                .shadow(radius: 4)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showing, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Claude assistant").font(.headline)
                Text("Coming soon: draft segments, tighten copy, and pull in story notes using your instruction files.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()
            .frame(width: 280)
        }
    }
}

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
