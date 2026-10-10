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

    /// What a client is told when it stopped waiting before anybody answered.
    ///
    /// Its own sentence rather than `confirmationTimedOutMessage`, because they are
    /// different facts: one is a person who was asked and said nothing, the other is
    /// a caller that is no longer there to hear an answer. An audit log that
    /// reported the second as the first would send a reader looking for a person who
    /// was never asked.
    public static let abandonedReason =
        "The AI client stopped waiting for an answer, so this action was not taken."

    private let provider: any DataProvider
    private let broker: ConfirmationBroker
    /// Opens the confirmation. The caller decides what "cannot ask" means — today
    /// that is answering the request itself, with a reason.
    private let present: @Sendable (MCPApprovalRequest) -> Void
    private let loadSettings: @Sendable () -> MCPSettings
    private let appRunning: @Sendable () -> Bool
    private let auditDirectory: URL?
    private let settingsDirectory: URL?
    /// Where `report_usage` appends. Shared, unlike the session id beside it: the
    /// store is one object with its own lock, opened once by `AppModel`, and every
    /// connection's records go into it. `nil` refuses the tool with a reason.
    ///
    /// **The session id is not here, and could not be.** This context is constructed
    /// once (`MCPHostController.makeContext`) and handed to every connection the
    /// socket host will serve, so a session stored on it would stamp all of them with
    /// one id — valid UUIDs, existing rows, successful reads, all of them naming the
    /// wrong connection. The id arrives per call instead; see `MCPConnectionSession`.
    private let sessionRecorder: any SessionRecording
    /// The host's currently-open agent session ids, so `get_agent_sessions` can say
    /// which rows are live.
    ///
    /// A closure rather than a stored set, for the same reason the recorder takes an
    /// id per call: this context is shared across every connection, so anything it
    /// held would be shared too. Reading the host's live set at call time keeps the
    /// answer current, and a stale set would mark a just-closed session open — an
    /// absence of evidence read as evidence.
    private let liveSessionIDs: @Sendable () async -> Set<UUID>
    /// Where `set_model_price` writes. A store like the recorder's: one for the
    /// app's life, and nil here means the tool refuses rather than dropping a price.
    private let priceWriter: any ModelPriceWriting

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
    ///   - sessionRecorder: where `report_usage` appends. `nil` refuses the tool with
    ///     a reason rather than accepting a report that would be dropped.
    public init(
        provider: any DataProvider,
        broker: ConfirmationBroker,
        present: @escaping @Sendable (MCPApprovalRequest) -> Void,
        loadSettings: @escaping @Sendable () -> MCPSettings = { MCPSettings.load() },
        appRunning: @escaping @Sendable () -> Bool = { AppLiveness.isPortmasterRunning() },
        auditDirectory: URL? = nil,
        settingsDirectory: URL? = nil,
        sessionRecorder: (any SessionRecording)? = nil,
        liveSessionIDs: @escaping @Sendable () async -> Set<UUID> = { Set<UUID>() },
        priceWriter: (any ModelPriceWriting)? = nil
    ) {
        self.provider = provider
        self.broker = broker
        self.present = present
        self.loadSettings = loadSettings
        self.appRunning = appRunning
        self.auditDirectory = auditDirectory
        self.settingsDirectory = settingsDirectory
        self.sessionRecorder = sessionRecorder ?? UnavailableSessionRecorder()
        self.liveSessionIDs = liveSessionIDs
        self.priceWriter = priceWriter ?? UnavailableModelPriceWriter()
    }

    /// The two-argument entry point, for a call that arrived with no connection behind
    /// it.
    ///
    /// It forwards `session: nil` rather than holding an id, which is why a context
    /// used this way refuses `report_usage`: there is genuinely no connection to
    /// attribute it to, and the refusal says so.
    public func call(name: String, arguments: [String: String]) async -> ToolOutcome {
        await call(name: name, arguments: arguments, session: nil)
    }

    /// Answers one call that arrived on `session`.
    ///
    /// The session travels through here as data and reaches exactly one place — the
    /// `ToolExecutor` built for this call — so a connection's reports are stamped with
    /// that connection's id and no other.
    public func call(
        name: String, arguments: [String: String], session: MCPConnectionSession?
    ) async -> ToolOutcome {
        // The catalog's `effect`, never the caller's account of what it is asking
        // for. An unknown name has no declared effect, so it is treated as a read
        // and refused by the executor as before.
        guard let tool = ToolExecutor.catalog.first(where: { $0.name == name }),
            tool.effect == .mutation
        else {
            return await run(name: name, arguments: arguments, session: session)
        }

        // Normalized by the executor's own code, so the question a person is asked
        // and the line the audit log writes describe the same values the tool will
        // act on.
        let normalized = ToolExecutor.normalizing(arguments, for: tool)

        // **At most one line from here, and at least one whenever the caller goes
        // away.** A `CheckedContinuation` resumes whatever the awaiting task has since
        // decided to do, so a cancelled caller is woken anyway; without the handler
        // below, cancellation was the one branch in the whole feature that left no
        // record of an attempt somebody made.
        //
        // "At most", not "exactly": `OneAttemptAudit` covers every line written *through
        // this context* — the refusals and the cancellation. A cancellation that lands
        // between the `.approved` branch's `Task.isCancelled` check and the dispatch
        // below can still produce a second line from `ToolExecutor`'s own `allowed`,
        // because the executor has no idea this context exists. Closing that would mean
        // threading the one-shot into `ToolExecutor` and every construction site; flagged
        // rather than done, because the race is narrow and the fix is not.
        let audit = OneAttemptAudit(directory: auditDirectory)

        // **Checked here, before a person is asked anything.** The same check the
        // executor runs, and deliberately so: without it, a mutation missing a required
        // argument reaches the window, where `Self.request` builds its question from
        // whatever is there — a `stop_container` with no `id` becomes "Stop container ?",
        // and `resolve` refuses it for a reason that has nothing to do with the problem.
        // The person is asked to authorise a malformed request, answers no, and the
        // attempt is audited `denied` — which says *they refused it*. Ruling R3 exists so
        // a buggy client is not counted among the user's refusals, and under the one mode
        // that asks a person it was being counted exactly there.
        //
        // `rejected`, the executor's own word for this, and the executor's own reason, so
        // the two modes cannot report the same request two different ways.
        if let missing = ToolExecutor.firstMissingRequiredArgument(in: normalized, for: tool) {
            return refusal(
                name: name, arguments: normalized,
                reason: "Missing argument: \(missing)", audit: audit, outcome: "rejected"
            )
        }

        let settings = loadSettings()
        guard settings.mode == .confirmEach else {
            // `.off` and `.allowSession` are `PermissionGate`'s answers, including
            // its liveness check — one policy, not two.
            return await run(
                name: name, arguments: normalized,
                gate: makeGate(for: settings), session: session
            )
        }

        let request = Self.request(for: tool, arguments: normalized)

        return await withTaskCancellationHandler {
            switch await confirm(request) {
            case .approved:
                // **The approval is not enough on its own.** A person said yes to a
                // change on behalf of a caller; if that caller has gone, there is
                // nobody to carry the change out for, and performing it would be a
                // mutation with no recipient — reported to the log as `allowed`, for
                // a client that never heard back. Silence is never consent, and a
                // consent with nobody to give it to is not consent.
                if Task.isCancelled {
                    return abandoned(name: name, arguments: normalized, audit: audit)
                }
                return await run(
                    name: name, arguments: normalized,
                    gate: Self.approvedGate, session: session
                )
            case .denied(let reason):
                return refusal(
                    name: name, arguments: normalized, reason: reason, audit: audit
                )
            case .timedOut:
                return refusal(
                    name: name, arguments: normalized,
                    reason: Self.confirmationTimedOutMessage, audit: audit
                )
            }
        } onCancel: {
            // Runs synchronously on whichever thread cancelled, because that is the
            // only moment guaranteed to arrive: the awaiting task may never run again,
            // so a line written from inside it would be a line that might not exist.
            audit.record(
                tool: name, arguments: normalized,
                outcome: "denied", reason: Self.abandonedReason
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
        case "set_model_price":
            kind = .setModelPrice
            // "Set X?" rather than "Change X to Y?" — the figure is long and the
            // detail sentence below carries it, so the one-line summary stays the
            // question and not the arithmetic.
            summary = "Set the price of \(arguments["model"] ?? "")?"
        case "handoff_context":
            kind = .handoffContext
            summary = "Hand off this session to \(arguments["target"] ?? "the target agent")?"
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
        gate: PermissionGate? = nil,
        session: MCPConnectionSession?
    ) async -> ToolOutcome {
        await executor(gate, session: session).execute(name: name, arguments: arguments)
    }

    /// The executor for one call, carrying the id of the connection that made it.
    ///
    /// Built per call, and that is what makes the session binding per call too: there
    /// is nowhere to cache an executor, so there is nowhere for a stale connection's
    /// id to survive between two calls. The recorder is the opposite — one store for
    /// the app's life — and it takes the id per record, which is why it never holds
    /// one: an id in the recorder would be shared by every connection exactly as
    /// surely as one on this context.
    private func executor(
        _ gate: PermissionGate? = nil, session: MCPConnectionSession?
    ) -> ToolExecutor {
        ToolExecutor(
            provider: provider,
            gate: gate ?? makeGate(for: loadSettings()),
            audit: AuditLog(directory: auditDirectory),
            settingsDirectory: settingsDirectory,
            sessionRecorder: sessionRecorder,
            sessionID: session?.id,
            openSessionIDs: { await liveSessionIDs() },
            priceWriter: priceWriter
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
    private func refusal(
        name: String, arguments: [String: String], reason: String, audit: OneAttemptAudit,
        outcome: String = "denied"
    ) -> ToolOutcome {
        audit.record(tool: name, arguments: arguments, outcome: outcome, reason: reason)
        return ToolOutcome(text: reason, isError: true)
    }

    /// The caller stopped waiting, so the attempt ends without happening.
    ///
    /// `denied` rather than a fourth word: nothing was permitted either, and the log's
    /// job here is to say that an attempt was made and refused, which `denied` already
    /// means. The `reason` is what distinguishes this from a person saying no.
    private func abandoned(
        name: String, arguments: [String: String], audit: OneAttemptAudit
    ) -> ToolOutcome {
        audit.record(
            tool: name, arguments: arguments,
            outcome: "denied", reason: Self.abandonedReason
        )
        return ToolOutcome(text: Self.abandonedReason, isError: true)
    }
}

/// Writes at most one audit line for one mutation attempt.
///
/// The cancellation handler and the refusal path can both fire for the same attempt —
/// a cancelled caller is resumed anyway, so both run — and two lines for one attempt
/// would make the log a *worse* account of what happened than the single refusal it is
/// recording. First writer wins; whoever loses is told so, which is why this returns
/// whether it wrote rather than returning nothing.
///
/// `@unchecked Sendable` with a lock, because the whole point is that one of the two
/// callers is a cancellation handler and the other is a task on an arbitrary executor:
/// there is no queue to serialise them, so the exclusion has to be explicit.
private final class OneAttemptAudit: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded = false
    private let audit: AuditLog

    init(directory: URL?) {
        audit = AuditLog(directory: directory)
    }

    /// Records the attempt unless something already has. Returns whether this call was
    /// the one that wrote.
    @discardableResult
    func record(
        tool: String, arguments: [String: String], outcome: String, reason: String?
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !recorded else { return false }
        recorded = true
        audit.record(tool: tool, arguments: arguments, outcome: outcome, reason: reason)
        return true
    }
}
