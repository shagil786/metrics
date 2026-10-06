// MCPSettingsTab: Settings' page for the MCP host.
//
// What a person needs in one place: what an AI assistant may do here, whether Portmaster
// is listening, where the record of what happened is, how to register the CLI with a
// client, and who is connected right now.
//
// Its own file because it is its own screen — the repo's convention is one screen per file
// — and its own view because it observes `MCPHostController` directly. The other Settings
// pages read `AppModel` from the environment; the host is the app delegate's, `@MainActor`
// and owned for the life of the process rather than injected.
//
// **Every string below comes from `MCPSettingsCopy`.** That is not tidiness: the app target
// has no test target, so a literal written here is a sentence nothing can check, and
// `MCPSettingsChromeTests` reads this file and fails on any string literal that is not one
// of the copy module's — which is what makes "the token is never on this page" a claim
// about the whole page rather than about the parts somebody remembered to route through
// the library. What is left in here is drawing and the four actions that are genuinely
// the app's: copying to the pasteboard, asking Finder to reveal the log, writing the
// chosen mode, and resolving where the CLI binary is.

import AppKit
import PortmasterMCP
import SwiftUI

struct MCPSettingsTab: View {
    @ObservedObject var host: MCPHostController
    /// Set by the copy button and cleared after a moment, so the confirmation is a fact
    /// about this click rather than a permanent claim that something was copied.
    @State private var copied = false
    /// Cancels the pending clear, so a second click restarts the countdown instead of
    /// leaving two tasks racing to write the same `@State`.
    @State private var copyReset: Task<Void, Never>?

    /// The `claude mcp add` line for the binary on this machine, or `nil` when it cannot
    /// be found.
    ///
    /// **The app bundle is searched first.** The copy inside `Contents/Resources` travels
    /// with the app, so it is there for the person the app was shipped to. The checkout
    /// candidates behind it come from `#filePath` — the path the *compiler* saw — which
    /// exists only on the machine that built the app; searching only those is why an
    /// earlier version of this page told every real user the binary had not been built.
    /// The checkout stays in the list so a developer build still finds what it just
    /// compiled.
    ///
    /// Resolved once for the life of the process rather than per appearance: it is a
    /// filesystem question, and asking it on every redraw would stat several paths per
    /// frame for a value that cannot change while Settings is open. The cost is that an app
    /// launched before a checkout build ran keeps showing the notice until relaunched —
    /// a stale label rather than a wrong command.
    private static let installCommand: String? = {
        let candidates = MCPInstallCommand.binaryCandidates(
            bundleResourcesPath: MCPInstallCommand.bundleResourcesPath(for: Bundle.main.bundleURL),
            checkoutPackagePath: MCPInstallCommand.compiledPackagePath
        )
        return MCPInstallCommand.locateBinary(
            in: candidates, isExecutableFile: { FileManager.default.isExecutableFile(atPath: $0) }
        ).flatMap { path -> String? in
            path.isEmpty ? nil : MCPInstallCommand.command(binaryPath: path)
        }
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            policy
            Divider()
            status
            Divider()
            auditLog
            Divider()
            install
            Divider()
            clients
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    // MARK: The policy

    private var policy: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(MCPSettingsCopy.Chrome.policyHeading).font(.headline)
            Picker(MCPSettingsCopy.Chrome.modePickerLabel, selection: Binding(
                get: { host.mode },
                set: { host.setMode($0) }
            )) {
                ForEach(MCPMutationMode.allCases, id: \.self) { mode in
                    Text(MCPSettingsCopy.modeTitle(for: mode)).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
            .accessibilityHint(MCPSettingsCopy.Chrome.modeHint)
            Text(MCPSettingsCopy.modeConsequence(for: host.mode))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            // Counted from the catalog rather than naming tools, so a new read tool moves
            // the number instead of making this sentence a lie.
            Text(MCPSettingsCopy.readsAvailableInEveryMode)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // Shown only when a write failed. `setMode` leaves the published mode alone
            // when the save fails, so the radio has already snapped back — without this
            // line, a person whose choice was fine reads the snap-back as a refusal.
            if let failure = host.modeSaveFailure {
                Text(MCPSettingsCopy.modeSaveFailed(mode: failure))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: The status

    private var status: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(MCPSettingsCopy.Chrome.statusHeading).font(.headline)
            Text(statusText)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusText: String {
        switch host.status {
        case .listening(let socket): return MCPSettingsCopy.listening(socket: socket)
        case .notRunning: return MCPSettingsCopy.notRunning
        case .failed(let reason): return MCPSettingsCopy.failed(reason: reason)
        }
    }

    // MARK: The audit log

    private var auditLog: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(MCPSettingsCopy.Chrome.auditLogHeading).font(.headline)
            Text(MCPSettingsCopy.auditLogCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(MCPSettingsCopy.auditLogPath(host.auditLogURL))
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Button(MCPSettingsCopy.Chrome.revealButton) { revealAuditLog() }
        }
    }

    // MARK: Installing the CLI

    /// **The button is always rendered**, and disabled when there is no command to copy.
    ///
    /// Hiding it entirely is what made the earlier version incoherent: the empty-state line
    /// told people to copy the install command, and the only copy affordance lived inside
    /// the branch that exists precisely when the binary is missing. A disabled button the
    /// line can honestly refer to is better than a control that is not there.
    private var install: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(MCPSettingsCopy.Chrome.installHeading).font(.headline)
            if let command = Self.installCommand {
                Text(command)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // No path to offer rather than a path that does not exist: a clipboard
                // holding `claude mcp add` pointed at an unbuilt binary is a command that
                // fails for the person who trusted it.
                Text(MCPSettingsCopy.binaryNotBuiltNotice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button(MCPSettingsCopy.Chrome.copyButton) {
                    if let command = Self.installCommand { copy(command) }
                }
                .disabled(Self.installCommand == nil)
                if copied {
                    Label(MCPSettingsCopy.Chrome.copiedLabel, systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.teal)
                }
            }
            Text(MCPSettingsCopy.installCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Asks Finder to show the audit log, or the directory holding it when the log has
    /// never been written.
    ///
    /// The alternative — always revealing the file — is a button that appears to do
    /// nothing on a machine where no mutation has been attempted, which is most machines
    /// when somebody first opens this page.
    private func revealAuditLog() {
        let url = host.auditLogURL
        NSWorkspace.shared.activateFileViewerSelecting([
            MCPSettingsCopy.revealTarget(
                logURL: url, fileExists: FileManager.default.fileExists(atPath: url.path)
            )
        ])
    }

    /// Puts the command on the pasteboard, and says so for a moment.
    ///
    /// The clear is a `Task.sleep` rather than a `Timer`: a `Timer` on the main run loop
    /// has to be cancelled by hand, and this one was outliving the view — firing into
    /// `@State` nobody reads any more. A cancelled task cannot do that, and a second press
    /// cancels the first so the countdown restarts rather than two tasks racing.
    private func copy(_ command: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        copied = true
        copyReset?.cancel()
        copyReset = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }

    // MARK: Who is connected

    private var clients: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(MCPSettingsCopy.Chrome.clientsHeading).font(.headline)
            if host.clients.isEmpty {
                // Branch-aware: the instruction has to match the controls this build
                // actually rendered.
                Text(MCPSettingsCopy.noClients(installCommandAvailable: Self.installCommand != nil))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(host.clients) { client in
                    Text(MCPSettingsCopy.clientRow(
                        pid: client.pid,
                        connectedAt: client.connectedAt,
                        lastCallAt: client.lastCallAt
                    ))
                    .font(.callout)
                }
            }
        }
    }
}
