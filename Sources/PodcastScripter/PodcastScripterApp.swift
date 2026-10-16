import AppKit
import SwiftUI

@main
struct PodcastScripterApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var store = AppStore(service: MockNewsService())

    var body: some Scene {
        WindowGroup("Podcast Scripter") {
            ContentView()
                .environment(store)
                .frame(minWidth: 1100, minHeight: 700)
                .preferredColorScheme(.dark)
                .task { await store.refresh() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    store.save()
                }
        }
        .defaultSize(width: 1500, height: 920)
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
        @Bindable var store = store
        VStack(spacing: 0) {
            TopBar()
            switch store.route {
            case .home:
                HomeView()
            case .editor(let id):
                EditorView(projectID: id)
            }
        }
        .background(Theme.window)
        .alert("Something went wrong", isPresented: Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } }
        )) {
            Button("OK") { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
        }
    }
}
