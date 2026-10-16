import AppKit
import SwiftUI
import WebKit

/// An in-app browser for an article: select a passage and insert it into the script as a quote.
struct ArticleReaderSheet: View {
    @Environment(\.dismiss) private var dismiss
    var story: StoryItem
    var controller: RichTextController
    @State private var page = WebPage()
    @State private var status: Status = .hint

    private enum Status: Equatable {
        case hint
        case inserted(Int)
        case noSelection
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                IconButton(systemName: "chevron.left", help: "Back") { page.webView.goBack() }
                    .disabled(!page.canGoBack)
                VStack(alignment: .leading, spacing: 1) {
                    Text(page.title.isEmpty ? story.title : page.title)
                        .font(.system(size: Zoom.s(13), weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(page.url?.host() ?? story.source ?? "")
                        .font(.system(size: Zoom.s(11)))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                if page.isLoading { ProgressView().controlSize(.small) }
                Spacer()
                IconButton(systemName: "safari", help: "Open in browser") {
                    if let url = page.url ?? story.url { NSWorkspace.shared.open(url) }
                }
                Button("Done") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task { await insertSelection() }
                } label: {
                    Label("Insert as Quote", systemImage: "text.quote")
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 14)
            .frame(height: 52)
            Divider().overlay(Theme.border)

            WebView(webView: page.webView)

            Divider().overlay(Theme.border)
            Text(statusText)
                .font(.system(size: Zoom.s(11.5)))
                .foregroundStyle(status == .noSelection ? Theme.negative : Theme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .frame(height: 30)
        }
        .frame(width: 980, height: 720)
        .background(Theme.surface)
        .onAppear {
            if let url = story.url { page.webView.load(URLRequest(url: url)) }
        }
    }

    private var statusText: String {
        switch status {
        case .hint: "Highlight a passage on the page, then click Insert as Quote. You can insert several before closing."
        case .inserted(let count): "Inserted \(count) \(count == 1 ? "quote" : "quotes") into the script."
        case .noSelection: "Highlight some text on the page first."
        }
    }

    private func insertSelection() async {
        let selected = (try? await page.webView.evaluateJavaScript("window.getSelection().toString()")) as? String ?? ""
        let paragraphs = selected
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !paragraphs.isEmpty else {
            status = .noSelection
            return
        }

        // Prefer the page's own title and final URL (news links arrive as Google News redirects).
        let title = page.title.isEmpty ? story.title : page.title
        let source = story.source ?? page.url?.host()?.replacingOccurrences(of: "www.", with: "")
        let attribution = ["—", source.map { "\($0):" }, "“\(title)”"].compactMap { $0 }.joined(separator: " ")
        controller.insertQuote(paragraphs, attribution: attribution, link: page.url ?? story.url)

        if case .inserted(let count) = status {
            status = .inserted(count + 1)
        } else {
            status = .inserted(1)
        }
    }
}

/// Owns the WKWebView and mirrors its navigation state for SwiftUI.
@MainActor
@Observable
final class WebPage: NSObject, WKNavigationDelegate {
    @ObservationIgnored let webView: WKWebView
    private(set) var title = ""
    private(set) var url: URL?
    private(set) var isLoading = false
    private(set) var canGoBack = false

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
    }

    private func sync() {
        title = webView.title ?? ""
        url = webView.url
        isLoading = webView.isLoading
        canGoBack = webView.canGoBack
    }

    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        MainActor.assumeIsolated { sync() }
    }

    nonisolated func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        MainActor.assumeIsolated { sync() }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { sync() }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { sync() }
    }
}

private struct WebView: NSViewRepresentable {
    var webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
