import SwiftUI
import PortmasterCore
import PortmasterMCP

struct StopSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let target: AppModel.StopTarget
    @State private var phase: Phase = .confirm
    @State private var outcomes: [pid_t: StopCoordinator.Outcome] = [:]
    @State private var confirmingForce = false
    enum Phase { case confirm, running, done }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(target.isProject ? "Quit project" : "Stop processes", systemImage: "exclamationmark.triangle").font(.headline).foregroundStyle(.orange)
            StopTargetMemberList(target: target)
            Divider()
            if phase == .running {
                HStack { ProgressView().controlSize(.small); Text("Stopping \(target.name)…") }
            } else if phase == .done {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(target.members) { member in
                            switch outcomes[member.pid]?.status {
                            case .stopped: Label("PID \(member.pid) stopped or already exited", systemImage: "checkmark.circle").foregroundStyle(.teal)
                            case .stillRunning: Label("PID \(member.pid) still running or exit could not be verified", systemImage: "clock.badge.exclamationmark").foregroundStyle(.orange)
                            case .failed(let message): Label(message, systemImage: "xmark.circle").foregroundStyle(Color.coral)
                            case nil: Text("PID \(member.pid): no result recorded").foregroundStyle(.secondary)
                            }
                        }
                    }.font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 170)
            }
            HStack {
                Spacer()
                if phase == .confirm {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button(target.isProject ? "Quit Project" : "Stop Processes", role: .destructive) { run(force: false) }.keyboardShortcut(.defaultAction)
                        .disabled(target.members.isEmpty || model.prefs.fixtureMode)
                } else if phase == .done {
                    if shouldOfferForce { Button("Force Quit…") { confirmingForce = true }.foregroundStyle(Color.coral) }
                    Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }.padding(18).frame(width: 500)
        .confirmationDialog("Force quit the remaining confirmed processes?", isPresented: $confirmingForce, titleVisibility: .visible) {
            Button("Force Quit", role: .destructive) { run(force: true) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Unsaved work may be lost. Only originally listed processes will be targeted, after another identity check.") }
        .interactiveDismissDisabled(phase == .running)
    }
    private var shouldOfferForce: Bool {
        outcomes.values.contains { if case .stopped = $0.status { return false }; return true }
    }
    private func run(force: Bool) {
        guard !model.prefs.fixtureMode else { return }
        phase = .running
        Task { @MainActor in
            let members = force ? target.members.filter {
                if case .stopped? = outcomes[$0.pid]?.status { return false }; return true
            } : target.members
            let results = await model.stopCoordinator.stopConfirmed(members, force: force)
            outcomes.merge(results) { _, new in new }
            phase = .done; model.engine.refreshNow()
        }
    }
}

/// The confirmed membership of a stop, and the two sentences about what stopping it
/// means — shared with `MCPConfirmationWindow` rather than copied.
///
/// A person agreeing to a stop has to see the same list in both places: the list, the
/// ports and the promises about identity are the substance of the confirmation, and a
/// second rendering of them is a second promise about what will be stopped.
///
/// - Parameter asksBeforeQuitting: whether these processes are asked to close before
///   they are quit. True for the sheet and for a graceful stop. False for the MCP
///   window's forced quit, where the client's `force` means they are not — and where
///   saying otherwise would put "processes will be asked to close" directly under a
///   heading that says "without asking it to save first".
struct StopTargetMemberList: View {
    let target: AppModel.StopTarget
    var asksBeforeQuitting = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(target.name) · \(target.members.count) processes")
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(target.members) { member in
                        Text("\(member.name) — PID \(member.pid)\(member.startedAt == nil ? " (identity unavailable; will skip)" : "")")
                            .font(.system(.caption, design: .monospaced))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 150)
            if !target.ports.isEmpty {
                Text("Listening ports: \(Array(Set(target.ports.map(\.port))).sorted().map { ":\($0)" }.joined(separator: ", "))")
            }
            if let project = target.project { Text("Project: \(project)").font(.caption).textSelection(.enabled) }
            Text("Only the processes listed above will be stopped. Portmaster checks their identity again; any new processes require a new confirmation.")
                .font(.caption).foregroundStyle(.secondary)
            // The sentence is `MCPApprovalCopy`'s so it cannot disagree with the one
            // above it about the same processes.
            Text(MCPApprovalCopy.saveWorkNotice(force: !asksBeforeQuitting))
                .font(.caption).foregroundStyle(.secondary)
        }.padding(10).cardBackground(cornerRadius: 8)
    }
}
