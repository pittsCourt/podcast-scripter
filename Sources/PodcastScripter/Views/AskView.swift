import SwiftUI

/// Ask Gemma: questions about anything in the app (scripts, tracker, queue, news, table,
/// matches, rankings). Shown as a tab in the right sidebar.
struct AskView: View {
    @Environment(AppStore.self) private var store
    @State private var question = ""
    @FocusState private var focused: Bool

    private var suggestions: [String] {
        let team = store.config.team.shortName
        return [
            "What have we said about \(store.trackedStories.first?.title ?? "injuries") so far?",
            "How has \(team) done since the Leagues Cup?",
            "Summarize \(team)'s power rankings this season.",
            "What's in the queue that we haven't covered?",
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if store.chat.isEmpty {
                            intro
                        }
                        ForEach(store.chat) { message in
                            MessageBubble(message: message).id(message.id)
                        }
                        if store.isAsking {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Gemma is reading your show…")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            .id("thinking")
                        }
                    }
                    .padding(12)
                }
                .onChange(of: store.chat.count) {
                    withAnimation { proxy.scrollTo(store.chat.last?.id, anchor: .bottom) }
                }
                .onChange(of: store.isAsking) {
                    if store.isAsking { withAnimation { proxy.scrollTo("thinking", anchor: .bottom) } }
                }
            }

            Divider().overlay(Theme.border)
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask about your show…", text: $question, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...5)
                    .focused($focused)
                    .onSubmit(send)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                IconButton(systemName: "arrow.up.circle.fill", help: "Ask (Return)", action: send)
                    .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || store.isAsking)
            }
            .padding(10)

            if !store.chat.isEmpty {
                HStack {
                    Spacer()
                    Button("Clear conversation") { store.chat.removeAll() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding([.horizontal, .bottom], 10)
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Ask Gemma", systemImage: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Gemma can see your scripts, Story Tracker, queue, news, the table, matches and power rankings.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(suggestions, id: \.self) { suggestion in
                Button {
                    question = suggestion
                    send()
                } label: {
                    Text(suggestion)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func send() {
        let text = question
        question = ""
        Task { await store.ask(text) }
    }
}

private struct MessageBubble: View {
    var message: ChatMessage

    private var isUser: Bool { message.role == "user" }
    private var isError: Bool { message.detail == "error" }

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 3) {
            Text(markdown)
                .font(.system(size: 12.5))
                .foregroundStyle(isError ? Theme.negative : Theme.textPrimary)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isUser ? Theme.accent.opacity(0.18) : Theme.raised)
                )
            if let detail = message.detail, !isError {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    /// Gemma often answers in Markdown (bold, lists); render the inline parts.
    private var markdown: AttributedString {
        (try? AttributedString(markdown: message.content, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(message.content)
    }
}
