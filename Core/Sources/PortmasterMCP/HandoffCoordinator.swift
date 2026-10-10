import Foundation
import PortmasterCore

/// Everything one completed handoff did, for the caller and for the audit line.
/// The brief's path rather than its text: an audit line cites where to read
/// (spec amendment 6), never a multi-KB document as an argument value.
public struct HandoffOutcome: Sendable, Equatable {
    public let briefPath: String
    /// Physical source lines the brief cites — the audit's `lines=` tail.
    public let citedLines: [Int]
    public let launchedPID: Int32
    public let target: String

    public init(briefPath: String, citedLines: [Int], launchedPID: Int32, target: String) {
        self.briefPath = briefPath
        self.citedLines = citedLines
        self.launchedPID = launchedPID
        self.target = target
    }

    /// `brief=<path> lines=<n,…>` — the whole audit note, bounded at 20 line
    /// numbers plus a count so one line stays one line (AuditLog's own rule for
    /// arguments applies here in spirit: bounded and marked, never silently cut).
    public var auditNote: String {
        let listed = citedLines.prefix(20).map(String.init).joined(separator: ",")
        let more = citedLines.count > 20 ? ",+\(citedLines.count - 20) more" : ""
        return "brief=\(briefPath) lines=\(listed)\(more)"
    }
}

/// Spec §5's sequence, in order, and every refusal along it:
/// kill switch → session → target config → uniquely matched log → extract →
/// budget → **write the brief** (the dry run) → cwd exists → CLI installed →
/// spawn → record under the lock (terminate on refusal). A generation failure
/// cannot produce a launch because the launch is after the brief; an empty or
/// unsourced brief cannot produce a file because the citation check is before
/// the write.
public struct HandoffCoordinator: Sendable {
    private let store: AgentSessionStore
    private let adapter: any TokenSourceAdapter
    private let launcher: any HandoffLaunching
    private let defaults: UserDefaults
    private let handoffDirectory: URL

    public init(
        store: AgentSessionStore,
        adapter: any TokenSourceAdapter = ClaudeCodeLogAdapter(),
        launcher: any HandoffLaunching = SystemHandoffLauncher(),
        defaults: UserDefaults = .standard,
        handoffDirectory: URL? = nil
    ) {
        self.store = store
        self.adapter = adapter
        self.launcher = launcher
        self.defaults = defaults
        self.handoffDirectory = handoffDirectory
            ?? MCPSettings.defaultDirectory.appendingPathComponent("handoffs", isDirectory: true)
    }

    public func handoff(sessionID: UUID, target targetKey: String) throws -> HandoffOutcome {
        // 1. The kill switch, read per call the way this repo reads settings
        // per call. Off means the feature is off for every path — the tool's
        // gate and the UI's mirror both funnel through here.
        guard AppPreferences.load(from: defaults).contextHandoffsEnabled else {
            throw MCPToolError(message: "Context handoffs are disabled in Portmaster settings.")
        }

        // 2. The session, and the once-only check as of now (authoritative
        // re-check happens again in `recordHandoff`, under the lock).
        let sessions = try store.sessions()
        guard let source = sessions.first(where: { $0.id == sessionID }) else {
            throw MCPToolError(message: "No session \(sessionID.uuidString) is recorded.")
        }
        guard source.handoffTargetPID == nil else {
            throw MCPToolError(message: "This session has already handed off; a thread hands off once.")
        }

        // 3. The target, from configuration.
        let targets = HandoffTargets.load()
        guard let target = targets[targetKey] else {
            let known = targets.keys.sorted().joined(separator: ", ")
            throw MCPToolError(
                message: "Unknown handoff target '\(targetKey)'. Known targets: \(known)."
            )
        }

        // 4. The log — the same matcher the poller uses, scoped to this one
        // session, so "uniquely attributable" means exactly what usage
        // attribution means.
        let candidates = adapter.logCandidates(
            newerThan: source.connectedAt.addingTimeInterval(-AgentLogMatcher.defaultOverlap)
        )
        let matches = AgentLogMatcher.match(
            candidates,
            for: [(id: source.id, connectedAt: source.connectedAt)],
            overlap: AgentLogMatcher.defaultOverlap,
            now: Date()
        )
        guard case .unique(let log) = matches[source.id] else {
            // A log that exists but carries no timestamps is *unsourced*, not
            // ambiguous: there is a file on disk and nothing citable in it, and
            // §5's refusal for that fact is "nothing to hand off" rather than
            // the attribution refusal, which would tell a reader the problem
            // is ambiguity when the problem is an absence of content.
            if !candidates.isEmpty, candidates.allSatisfy({ $0.interval == nil }) {
                throw MCPToolError(
                    message: "This session's conversation log carries no timestamps, "
                        + "so there is nothing to hand off."
                )
            }
            throw MCPToolError(
                message: "This session's conversation log is not uniquely attributable, "
                    + "so no brief can be cited from it."
            )
        }

        // 5. Extract and budget. A read failure and an uncitable log are
        // different facts and say different things.
        let brief: HandoffBrief
        do {
            brief = try HandoffBriefExtractor.extract(from: log.url)
        } catch {
            throw MCPToolError(
                message: "Could not read \(log.url.path): \(error.localizedDescription)"
            )
        }
        var draft = brief
        draft.sessionID = sessionID
        let budgeted = draft.budgeted()
        guard !budgeted.citedLines.isEmpty else {
            throw MCPToolError(
                message: "No cited content was found in \(log.url.path), "
                    + "so there is nothing to hand off."
            )
        }

        // 6. THE DRY RUN: the brief exists on disk before anything spawns
        // (spec §5, amendment 6).
        let briefPath = try writeBrief(budgeted)

        // 7. Working directory: recorded from the log, never guessed
        // (amendment 7). Missing means refused — with the brief offered.
        guard let cwd = budgeted.workingDirectory, isDirectory(cwd) else {
            throw MCPToolError(
                message: "The log records no usable working directory, so the agent "
                    + "cannot be started there. The brief was saved at \(briefPath.path) "
                    + "for manual use."
            )
        }

        // 8. The CLI must exist (§6).
        guard let executable = launcher.resolve(target.executable, path: nil) else {
            throw MCPToolError(
                message: "\(target.executable) is not installed (not found on PATH). "
                    + "The brief was saved at \(briefPath.path) for manual use."
            )
        }

        // 9. Spawn. The brief, verbatim, on stdin.
        let pid: Int32
        do {
            pid = try launcher.launch(
                executable: executable, arguments: target.arguments,
                workingDirectory: cwd, stdinText: budgeted.renderedMarkdown()
            )
        } catch {
            let reason = (error as? MCPToolError)?.message ?? error.localizedDescription
            throw MCPToolError(
                message: "\(target.executable) could not be started: \(reason). "
                    + "The brief was saved at \(briefPath.path) for manual use."
            )
        }
        // A launcher that reports a non-positive pid after a successful launch has
        // not really started anything we can find again; recording it would hand
        // the store a pid that no process on the machine will ever match — the
        // unlinkable-handoff hole this guard closes. Nothing real to terminate
        // either, so no `launcher.terminate` on this path.
        guard pid > 0 else {
            throw MCPToolError(
                message: "\(target.executable) reported no usable process id "
                    + "(\(pid)), so nothing was recorded. The brief was saved at "
                    + "\(briefPath.path) for manual use."
            )
        }

        // 10. Record under the lock. If a second handoff won the race, the
        // process we just spawned is ours to undo — the spawn was contingent
        // on this write, and a refusal must leave nothing running.
        guard try store.recordHandoff(
            sourceID: sessionID, targetPID: pid, targetName: targetKey
        ) else {
            launcher.terminate(pid: pid)
            throw MCPToolError(
                message: "This session has already handed off; the new agent was stopped."
            )
        }
        try store.flush()

        return HandoffOutcome(
            briefPath: briefPath.path,
            citedLines: budgeted.citedLines,
            launchedPID: pid,
            target: targetKey
        )
    }

    private func writeBrief(_ brief: HandoffBrief) throws -> URL {
        try FileManager.default.createDirectory(
            at: handoffDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let url = handoffDirectory.appendingPathComponent(
            "\(brief.sessionID?.uuidString ?? UUID().uuidString).md"
        )
        try brief.renderedMarkdown().write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path
        )
        return url
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            && isDir.boolValue
    }
}
