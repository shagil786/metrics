import SwiftUI
import Sparkle
import PortmasterCore

@MainActor final class UpdateController: ObservableObject {
    @Published private(set) var status: String
    private(set) var controller: SPUStandardUpdaterController?
    var configured: Bool { controller != nil }
    var canCheck: Bool { controller?.updater.canCheckForUpdates == true }
    init(bundle: Bundle = .main) {
        let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        guard UpdateConfiguration.isValid(feed: feed, publicKey: key) else {
            status = "Updates are not configured for this build."; return
        }
        status = "Signed updates are available from the configured release host."
        let candidate = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        do { try candidate.updater.start(); controller = candidate }
        catch { status = "Updater unavailable: \(error.localizedDescription)" }
    }
    func check() { guard canCheck else { return }; controller?.checkForUpdates(nil) }
    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue; objectWillChange.send() }
    }
}

struct UpdateSettings: View {
    @ObservedObject var updates: UpdateController
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Portmaster updates", systemImage: "arrow.down.app").font(.headline)
            Text(updates.status).foregroundStyle(.secondary)
            Toggle("Check for updates automatically", isOn: Binding(get: { updates.automaticallyChecks }, set: { updates.automaticallyChecks = $0 }))
                .disabled(!updates.configured)
            Button("Check for Updates…") { updates.check() }.disabled(!updates.canCheck)
            Text("Update checks contact the release host. System profiling is disabled; Portmaster never uploads process metrics or history. Installation uses Sparkle's signed-update flow.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20)
    }
}
