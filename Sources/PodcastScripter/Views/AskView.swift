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
                                    .font(.system(size: Zoom.s(11.5)))
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
                    .font(.system(size: Zoom.s(13)))
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
                        .font(.system(size: Zoom.s(11)))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding([.horizontal, .bottom], 10)
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Ask Gemma", systemImage: "sparkles")
                .font(.system(size: Zoom.s(13), weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Gemma can see your scripts, Story Tracker, queue, news, the table, matches and power rankings.")
                .font(.system(size: Zoom.s(12)))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(suggestions, id: \.self) { suggestion in
                Button {
                    question = suggestion
                    send()
                } label: {
                    Text(suggestion)
                        .font(.system(size: Zoom.s(12)))
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
                .font(.system(size: Zoom.s(12.5)))
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
                    .font(.system(size: Zoom.s(10)))
                    .foregroundStyle(Theme.textTertiary)
            }
            if let sources = message.sources {
                SourcesView(sources: sources)
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

/// Everything Gemma was given for an answer, so any claim can be checked. Passages open their script.
private struct SourcesView: View {
    @Environment(AppStore.self) private var store
    var sources: AskSources
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                Label(summary, systemImage: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: Zoom.s(10.5), weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("What Gemma was given to answer this")

            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    group("Script passages") {
                        if sources.excerpts.isEmpty {
                            note(sources.episodes == 0 ? "No scripts yet." : "No passages matched this question, out of \(sources.episodes) scripts.")
                        }
                        ForEach(sources.excerpts, id: \.self) { excerpt in
                            Button {
                                store.openScript(named: excerpt.episode, on: excerpt.date)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(excerpt.episode) · \(shortDate(excerpt.date))")
                                        .font(.system(size: Zoom.s(10.5), weight: .semibold))
                                        .foregroundStyle(Theme.accent)
                                    Text("“\(excerpt.text)”")
                                        .font(.system(size: Zoom.s(11)))
                                        .foregroundStyle(Theme.textSecondary)
                                        .multilineTextAlignment(.leading)
                                        .lineLimit(4)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Open \(excerpt.episode)")
                        }
                    }
                    group("Story Tracker") {
                        if sources.stories.isEmpty { note("No tracked stories.") }
                        ForEach(sources.stories, id: \.self) { story in
                            line(story.title, "\(story.mentions) \(story.mentions == 1 ? "mention" : "mentions")")
                        }
                        if sources.storiesShortened { note("Shortened to fit the size limit in Settings → AI.") }
                    }
                    group("Other app data") {
                        ForEach(sources.data, id: \.self) { section in line(section.label, section.detail) }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border))
            }
        }
    }

    private var summary: String {
        let passages = sources.excerpts.count
        return "Sources: \(passages) script \(passages == 1 ? "passage" : "passages"), \(sources.stories.count) tracked \(sources.stories.count == 1 ? "story" : "stories"), \(sources.data.count) data sections"
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            GroupLabel(text: title)
            content()
        }
    }

    private func line(_ label: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 6)
            Text(detail).foregroundStyle(Theme.textTertiary)
        }
        .font(.system(size: Zoom.s(11)))
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: Zoom.s(11)))
            .foregroundStyle(Theme.textTertiary)
    }

    private func shortDate(_ iso: String) -> String {
        ISO8601.parse("\(iso)T12:00:00Z")?.formatted(.dateTime.month(.abbreviated).day().year()) ?? iso
    }
}
