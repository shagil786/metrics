// HostMCPCallContext: the running app's call surface, with a person in it.
//
// `LocalMCPCallContext` is what a CLI serves when there is no app to talk to: one
// real provider, the real audit log, and a `PermissionGate` rebuilt per call. This
// is the same shape for the app that *is* the host, and the difference is one thing
// slice 1 could not have: a mutation mode of `confirmEach` can now be answered.
//
// Three decisions are worth stating before the code, because each is a place where
// the obvious thing is the wrong thing:
//
//  1. **The gate is still the gate.** `allowSession` and `off` are handed straight
//     to `PermissionGate`, with liveness probed per call, so the host does not get a
//     second and looser copy of the mutation policy just for being the app. Only
//     `confirmEach` is answered here, because only it needs someone who is not this
//     process.
//  2. **A refusal is audited here, in the executor's own vocabulary.** A
//     confirmation that is denied or never answered is refused *before* the executor
//     runs, so the `denied` line is this file's to write. Same outcome names as
//     `ToolExecutor` uses (`denied` / `allowed` / `failed`), because a log a reader
//     has to check per tool is not an audit log.
//  3. **Nothing here hangs and nothing here throws.** Every accepted request ends in
//     exactly one outcome, and each outcome maps to exactly one answer: an approval
//     performs the call, a refusal is `isError` with a reason a model can read, and a
//     timeout is a refusal too — silence is never consent.
//
// The app-side wiring — which provider, which presenter — is `App/MCPHostController.swift`,
// which is untestable in this repo's shape (the app target has no test target). This
// type is the part of that wiring that is a decision rather than glue, so it lives
// here where a test can hold it still.

import Foundation

/// The app-hosted answer to one tool call, with a person in the loop for mutations.
public struct HostMCPCallContext: MCPToolCalling {

    /// What a client is told when nobody answers a confirmation.
    ///
    /// One string, like every other refusal in this module, and it names the silence
    /// rather than the user's inattention: the window may have been behind another
    /// window, or the caller may have asked from a session nobody was watching.
    public static let confirmationTimedOutMessage =
        "No answer to Portmaster's confirmation prompt, so this action was not taken."

    private let provider: any DataProvider
    private let broker: ConfirmationBroker
    /// Opens the confirmation. The caller decides what "cannot ask" means — today
    /// that is answering the request itself, with a reason.
    private let present: @Sendable (MCPApprovalRequest) -> Void
    private let loadSettings: @Sendable () -> MCPSettings
    private let appRunning: @Sendable () -> Bool
    private let auditDirectory: URL?
    private let settingsDirectory: URL?

    /// - Parameters:
    ///   - provider: the app's own data. `LiveDataProvider` in production.
    ///   - broker: where a request waits for its answer.
    ///   - present: shows the question to a person. Handed to `request` as the
    ///     broker's `onQueued` callback, so it runs at the one moment its answer is
    ///     guaranteed to be matched — and without the polling an approximation of
    ///     that moment would need.
    ///   - loadSettings: re-reads the mutation policy per call, so changing the mode
    ///     takes effect without restarting anything.
    ///   - appRunning: probed per call, because `allowSession` is a grant that lasts
    ///     only while Portmaster is running — the same probe the on-demand path uses,
    ///     so the two cannot disagree about what "running" means.
    ///   - auditDirectory: where mutation attempts are recorded.
    ///   - settingsDirectory: where `mcpMode` is written.
    public init(
        provider: any DataProvider,
        broker: ConfirmationBroker,
        present: @escaping @Sendable (MCPApprovalRequest) -> Void,
        loadSettings: @escaping @Sendable () -> MCPSettings = { MCPSettings.load() },
        appRunning: @escaping @Sendable () -> Bool = { AppLiveness.isPortmasterRunning() },
        auditDirectory: URL? = nil,
        settingsDirectory: URL? = nil
    ) {
        self.provider = provider
        self.broker = broker
        self.present = present
        self.loadSettings = loadSettings
        self.appRunning = appRunning
        self.auditDirectory = auditDirectory
        self.settingsDirectory = settingsDirectory
    }

    public func call(name: String, arguments: [String: String]) async -> ToolOutcome {
        // The catalog's `effect`, never the caller's account of what it is asking
        // for. An unknown name has no declared effect, so it is treated as a read
        // and refused by the executor as before.
        guard let tool = ToolExecutor.catalog.first(where: { $0.name == name }),
            tool.effect == .mutation
        else {
            return await run(name: name, arguments: arguments)
        }

        // Normalized by the executor's own code, so the question a person is asked
        // and the line the audit log writes describe the same values the tool will
        // act on.
        let normalized = ToolExecutor.normalizing(arguments, for: tool)
        let settings = loadSettings()
        guard settings.mode == .confirmEach else {
            // `.off` and `.allowSession` are `PermissionGate`'s answers, including
            // its liveness check — one policy, not two.
            return await run(name: name, arguments: normalized, gate: makeGate(for: settings))
        }

        switch await confirm(Self.request(for: tool, arguments: normalized)) {
        case .approved:
            return await run(
                name: name, arguments: normalized, gate: Self.approvedGate
            )
        case .denied(let reason):
            return refusal(name: name, arguments: normalized, reason: reason)
        case .timedOut:
            return refusal(
                name: name, arguments: normalized, reason: Self.confirmationTimedOutMessage
            )
        }
    }

    /// The gate for a mutation a person has just approved.
    ///
    /// `.allowSession` is what the broker's approval already *is* — a grant that lasts
    /// this session — and liveness is `true` because this context only runs inside
    /// Portmaster, so the host is by definition running. It is the same gate, on its
    /// allowing branch, rather than a second policy: any other mode would re-decide a
    /// call the user has already answered.
    static let approvedGate = PermissionGate(
        settings: MCPSettings(mode: .allowSession), appRunning: true
    )

    // MARK: - The confirmation

    /// Puts `request` to a person and waits for the broker's answer.
    ///
    /// The order is the whole subtlety, and it is now the broker's to guarantee:
    /// `ConfirmationBroker.decide` matches by id and *ignores* an answer for an id it
    /// does not hold — right for a stale answer, exactly wrong for one that arrives
    /// first. Handing `present` to `request` as its `onQueued` callback makes "the
    /// broker owns it" and "a person is being asked" the same step, so an approval
    /// given the instant the window appears is matched rather than dropped, and no
    /// confirmation pays a polling interval before its window opens.
    private func confirm(_ request: MCPApprovalRequest) async -> ApprovalOutcome {
        let present = self.present
        return await broker.request(request) { present(request) }
    }

    /// The question a person is shown, in their terms.
    ///
    /// Built from the arguments the executor normalized, and deliberately claiming no
    /// more than they say: the exact member list behind an app id lives in the app's
    /// snapshot, and the confirmation window is where that would be shown. A prompt
    /// that guessed at membership would be showing a person a list the stop may not
    /// act on.
    ///
    /// The detail line comes from `MCPApprovalCopy` with no targets, because that is the
    /// same function the window calls *with* them: one set of words for a change, whether
    /// it is being asked or shown, so the two cannot drift into describing different
    /// actions. The arguments ride along because the window needs them to resolve the
    /// membership this approval will cover — `force` and the id are not recoverable from
    /// the sentence.
    static func request(
        for tool: ToolDefinition, arguments: [String: String]
    ) -> MCPApprovalRequest {
        let id = arguments["id"] ?? ""
        let kind: MCPApprovalRequest.Kind
        let summary: String
        switch tool.name {
        case "quit_app":
            kind = .quitApp
            summary = "Quit \(id)?"
        case "stop_container":
            kind = .stopContainer
            summary = "Stop container \(id)?"
        case "stop_project":
            kind = .stopProject
            summary = "Stop project \(id)?"
        case "set_preference":
            kind = .setPreference
            summary = "Change \(arguments["key"] ?? "") to \(arguments["value"] ?? "")?"
        default:
            // Unreachable for any declared mutation; a mutation added to the catalog
            // without a case here is asked about generically rather than silently,
            // because a prompt with no name in it is not one a person can answer. The
            // kind is the one whose copy needs no target list, so the window can still
            // show it without inventing targets it does not have.
            return MCPApprovalRequest(
                kind: .setPreference,
                summary: "Run \(tool.name)?",
                detail: "An AI client asked Portmaster to run \(tool.name).",
                arguments: arguments
            )
        }
        return MCPApprovalRequest(
            kind: kind,
            summary: summary,
            detail: MCPApprovalCopy.detail(for: kind, arguments: arguments, targets: []),
            arguments: arguments
        )
    }

    // MARK: - Running, refusing, recording

    /// The executor for one call.
    ///
    /// The provider is shared (it is the app's, and it owns the sampler); the gate is
    /// this call's. `settingsDirectory` is passed through so `mcpMode` — which the
    /// executor owns end to end, and which is therefore never a provider's business —
    /// lands in the same file the app reads its mode from.
    private func run(
        name: String,
        arguments: [String: String],
        gate: PermissionGate? = nil
    ) async -> ToolOutcome {
        await executor(gate).execute(name: name, arguments: arguments)
    }

    private func executor(_ gate: PermissionGate? = nil) -> ToolExecutor {
        ToolExecutor(
            provider: provider,
            gate: gate ?? makeGate(for: loadSettings()),
            audit: AuditLog(directory: auditDirectory),
            settingsDirectory: settingsDirectory
        )
    }

    private func makeGate(for settings: MCPSettings) -> PermissionGate {
        PermissionGate(settings: settings, appRunning: appRunning())
    }

    /// A refusal that reaches the caller as data and the audit log as a denial.
    ///
    /// `denied` is the executor's own outcome name for "the gate refused, so nothing
    /// happened", and here it is also what a person refusing, or failing to answer,
    /// means: nothing happened. The reason travels in both places, because the caller
    /// needs it and the log is where anyone looking at this an hour later will look.
    private func refusal(name: String, arguments: [String: String], reason: String) -> ToolOutcome {
        AuditLog(directory: auditDirectory)
            .record(tool: name, arguments: arguments, outcome: "denied", reason: reason)
        return ToolOutcome(text: reason, isError: true)
    }
}
