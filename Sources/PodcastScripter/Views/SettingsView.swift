import SwiftUI

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @AppStorage(ServiceSettings.urlKey) private var serviceURL = ServiceSettings.defaultURL
    @AppStorage(ServiceSettings.tokenKey) private var token = ""
    @State private var testResult: TestResult?
    @State private var testing = false

    private enum TestResult {
        case success
        case failure(String)
    }

    var body: some View {
        Form {
            Section {
                TextField("Address", text: $serviceURL, prompt: Text(ServiceSettings.defaultURL))
                SecureField("Token", text: $token, prompt: Text("NOTES_TOKEN from .env"))
            } header: {
                Text("Notes Service")
            } footer: {
                Text("Use http://localhost:3030 when the service runs on this Mac, or its Tailscale address when it runs on another machine.")
                    .foregroundStyle(.secondary)
            }

            HStack {
                switch testResult {
                case .success:
                    Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.positive)
                case .failure(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.negative)
                case nil:
                    EmptyView()
                }
                Spacer()
                if testing { ProgressView().controlSize(.small) }
                Button("Save & Test") {
                    Task { await test() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func test() async {
        testing = true
        defer { testing = false }
        await store.reconfigureService()
        if let error = await store.testConnection() {
            testResult = .failure(error)
        } else {
            testResult = .success
        }
    }
}
