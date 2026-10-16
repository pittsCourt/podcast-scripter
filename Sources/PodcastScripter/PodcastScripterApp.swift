import AppKit
import SwiftUI

@main
struct PodcastScripterApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var store = AppStore()

    var body: some Scene {
        WindowGroup(ShowConfig.showName) {
            ContentView()
                .environment(store)
                .frame(minWidth: 1100, minHeight: 680)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .task { await store.runRefreshLoop() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    Task { await store.refresh() }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    store.save()
                }
        }
        .defaultSize(width: 1440, height: 900)
        .windowToolbarStyle(.unified(showsTitle: true))

        Settings {
            SettingsView()
                .environment(store)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (`swift run`) so the app gets a Dock icon and keyboard focus.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

struct ContentView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Group {
            switch store.route {
            case .home:
                HomeView()
            case .editor(let id):
                EditorView(projectID: id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbar {
            if case .editor = store.route {
                ToolbarItem(placement: .navigation) {
                    Button {
                        store.route = .home
                    } label: {
                        Label("Projects", systemImage: "chevron.left")
                    }
                    .help("Back to projects (⌘[)")
                    .keyboardShortcut("[", modifiers: .command)
                }
            }
            ToolbarItem(placement: .principal) {
                RankingsBanner()
            }
            ToolbarItem(placement: .primaryAction) {
                UserMenu()
            }
        }
        .toolbarBackground(Theme.background, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .alert("Something went wrong", isPresented: Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } }
        )) {
            Button("OK") { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
        }
    }

    private var title: String {
        if case .editor(let id) = store.route, let project = store.project(id) {
            return project.name
        }
        return ShowConfig.showName
    }

    private var subtitle: String {
        if case .editor(let id) = store.route, let project = store.project(id) {
            return project.episodeDate.formatted(date: .long, time: .omitted)
        }
        return ""
    }
}

private struct UserMenu: View {
    var body: some View {
        Menu {
            Text("Local user")
            Divider()
            Button("Reveal Data in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([AppStore.defaultFileURL])
            }
        } label: {
            Image(systemName: "person.crop.circle")
        }
        .help("Account")
    }
}
