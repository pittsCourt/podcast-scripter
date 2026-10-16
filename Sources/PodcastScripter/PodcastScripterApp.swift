import AppKit
import SwiftUI

@main
struct PodcastScripterApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var store = AppStore()

    var body: some Scene {
        WindowGroup("Podcast Scripter") {
            ContentView()
                .environment(store)
                .frame(minWidth: 1240, minHeight: 680)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .task {
                    // The sidebar syncs once on open; the queue keeps checking for phone shares.
                    await store.loadConfig()
                    async let sidebar: Void = store.syncSidebar(force: false)
                    async let rankings: Void = store.syncRankings()
                    async let queue: Void = store.runRefreshLoop()
                    _ = await (sidebar, rankings, queue)
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    Task { await store.refresh() }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    store.save()
                }
        }
        .defaultSize(width: 1500, height: 920)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { FormatCommands() }

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
    @AppStorage("showInfoSidebar") private var showSidebar = true

    var body: some View {
        HStack(spacing: 0) {
            Group {
                switch store.route {
                case .home:
                    HomeView()
                case .editor(let id):
                    EditorView(projectID: id)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showSidebar {
                InfoSidebar()
                    .frame(width: 340)
                    .padding([.vertical, .trailing], 12)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
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
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showSidebar.toggle() }
                } label: {
                    Label(showSidebar ? "Hide Sidebar" : "Show Sidebar", systemImage: "sidebar.right")
                }
                .help("\(showSidebar ? "Hide" : "Show") the MLS table and matches (⌃⌘S)")
                .keyboardShortcut("s", modifiers: [.command, .control])
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
        return store.config.show.name
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
            // Opens the Settings window (also ⌘, and the app menu).
            SettingsLink {
                Label("Project Settings…", systemImage: "gearshape")
            }
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
