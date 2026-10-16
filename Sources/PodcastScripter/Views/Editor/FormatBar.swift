import SwiftUI

/// The formatting toolbar above the script.
struct FormatBar: View {
    var controller: RichTextController

    var body: some View {
        HStack(spacing: 2) {
            Menu {
                ForEach(BlockStyle.allCases) { block in
                    Button {
                        controller.setBlock(block)
                    } label: {
                        if controller.block == block {
                            Label(block.label, systemImage: "checkmark")
                        } else {
                            Text(block.label)
                        }
                    }
                }
            } label: {
                Text(controller.block.label)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 78, alignment: .leading)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .help("Paragraph style (⌥⌘0–4, ⌥⌘' for Quote)")

            divider

            FormatButton(systemName: "bold", help: "Bold (⌘B)", isOn: controller.isBold, action: controller.toggleBold)
            FormatButton(systemName: "italic", help: "Italic (⌘I)", isOn: controller.isItalic, action: controller.toggleItalic)
            FormatButton(systemName: "underline", help: "Underline (⌘U)", isOn: controller.isUnderlined, action: controller.toggleUnderline)
            FormatButton(systemName: "strikethrough", help: "Strikethrough (⇧⌘X)", isOn: controller.isStruckThrough, action: controller.toggleStrikethrough)

            divider

            FormatButton(systemName: "text.quote", help: "Quote (⌥⌘')", isOn: controller.block == .quote) {
                controller.setBlock(controller.block == .quote ? .body : .quote)
            }
            FormatButton(systemName: "decrease.indent", help: "Decrease indent (⌥⌘[)", action: controller.outdent)
            FormatButton(systemName: "increase.indent", help: "Increase indent (⌥⌘])", action: controller.indent)

            divider

            FormatButton(systemName: "link", help: "Link (⌘K)", isOn: controller.linkURL != nil) {
                controller.isEditingLink = true
            }
            FormatButton(systemName: "eraser", help: "Clear formatting", action: controller.clearFormatting)
        }
    }

    private var divider: some View {
        Rectangle().fill(Theme.borderStrong).frame(width: 1, height: 16).padding(.horizontal, 6)
    }
}

private struct FormatButton: View {
    var systemName: String
    var help: String
    var isOn = false
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isOn ? Theme.accent : hovering ? Theme.textPrimary : Theme.textSecondary)
                .frame(width: 28, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isOn ? Theme.accent.opacity(0.15) : hovering ? Color.white.opacity(0.08) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

/// Add, change or remove the link on the selection.
struct LinkSheet: View {
    @Environment(\.dismiss) private var dismiss
    var controller: RichTextController
    @State private var address = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(controller.linkURL == nil ? "Add Link" : "Edit Link")
                .font(.system(size: 15, weight: .semibold))
                .padding([.horizontal, .top], 20)
            Form {
                TextField("Address", text: $address, prompt: Text("https://"))
                if !controller.selectedText.isEmpty {
                    LabeledContent("Text", value: controller.selectedText)
                        .lineLimit(1)
                }
            }
            .formStyle(.grouped)
            HStack {
                if controller.linkURL != nil {
                    Button("Remove Link") {
                        controller.setLink(nil)
                        dismiss()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    controller.setLink(normalizedURL)
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(normalizedURL == nil)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 420)
        .onAppear { address = controller.linkURL?.absoluteString ?? "" }
    }

    /// Accepts "rsl.com/news" as well as full URLs.
    private var normalizedURL: URL? {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        let withScheme = trimmed.contains("://") || trimmed.hasPrefix("mailto:") ? trimmed : "https://\(trimmed)"
        return URL(string: withScheme)
    }
}
