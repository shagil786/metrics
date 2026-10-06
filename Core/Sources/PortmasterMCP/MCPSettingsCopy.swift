// MCPSettingsCopy: what the MCP settings page says.
//
// `App/SettingsView.swift` builds the page and the app target has no test target — the
// app scheme builds and nothing runs — so the words live here, beside `MCPApprovalCopy`,
// for the same reason and with the same discipline: one implementation of each sentence,
// and tests that hold it still.
//
// Four properties this file is responsible for, each a way the page can be quietly wrong:
//
//  1. **A mode is described by its consequence.** "Off", "Confirm each" and "Allow
//     session" are three words with no visible difference between them, and they decide
//     what an AI assistant may do to someone's Mac with nobody watching. So each name is
//     followed by what it means: no changes at all, Portmaster asks before every change,
//     no person is asked.
//  2. **The status line is true in each of its three states.** Listening says where, not
//     running says so, a failed bind says the reason it gave. A line that reads the same
//     in all three is the failure — a person cannot tell a dead host from a live one.
//  3. **A client row is actionable.** Pid and both times, or a plain statement that one
//     of them is not known. `LOCAL_PEERPID` can fail, so "PID 0" must never be printed.
//  4. **Nothing here says the token.** Settings is the screen someone screenshots when
//     something is wrong — and that is a claim about *every* string the page shows, so the
//     headings and button labels live here too (`Chrome`), and `MCPSettingsChromeTests`
//     reads the view file to fail on any literal that is not one of these.
//
// Two more, added on review of the first version:
//
//  5. **The page must not claim anything that can go stale.** The read-tools sentence
//     enumerated six tool names and was already wrong about a ten-tool catalog — three
//     tools unnamed, and memory/network/disk being *arguments* to `get_top_apps` rather
//     than reads of their own. It now counts `ToolExecutor.catalog`, so a new read tool
//     moves the number instead of making the sentence a lie.
//  6. **A control that did not do what it looks like must say so.** `setMode` leaves the
//     published mode alone when the write fails — right for the value, useless for the
//     person, whose radio has just snapped back with no explanation. `modeSaveFailed` says
//     which mode did not stick and why.
//
// What is deliberately absent: any claim that `claude mcp add` has been run. It writes the
// user's client configuration and has never been executed from here, so the page says
// where the binary is and stops.

import Foundation

/// Every word the MCP settings page shows.
public enum MCPSettingsCopy {

    // MARK: - The mutation mode

    /// What a mode is called on the radio.
    ///
    /// Short, because the sentence that matters is the one underneath: these three names
    /// are not self-explaining, which is why `modeConsequence` exists rather than this
    /// string being the whole of the choice.
    public static func modeTitle(for mode: MCPMutationMode) -> String {
        switch mode {
        case .off: return "Off"
        case .confirmEach: return "Confirm each"
        case .allowSession: return "Allow session"
        }
    }

    /// What the chosen mode means for an AI client, in one sentence.
    ///
    /// Consequences, not mechanics: "no changes at all", "Portmaster asks before every
    /// change", "no person is asked". A person choosing between these is choosing what may
    /// happen to their machine unattended, and how the gate is implemented is not what
    /// they are choosing between.
    public static func modeConsequence(for mode: MCPMutationMode) -> String {
        switch mode {
        case .off:
            return "An AI client can read this Mac, and make no changes at all."
        case .confirmEach:
            return "An AI client can make changes, and Portmaster asks before every change."
        case .allowSession:
            return "An AI client can make changes, and no person is asked before any of them."
        }
    }

    /// Reads are not gated by any of the three modes, and the page says so.
    ///
    /// **Counts the catalog rather than naming tools in the sentence.** The earlier
    /// version listed "CPU, memory, apps, containers, projects, history" and was already
    /// wrong: the catalog has ten read tools, three of them unnamed in that list, and
    /// memory/network/disk are *arguments* to `get_top_apps` rather than reads of their
    /// own. A sentence that enumerates tools goes stale the moment one is added and nobody
    /// notices, and this one is the string a person is most likely to hold against
    /// `tools/list` while debugging. A count derived from `ToolExecutor.catalog` cannot go
    /// stale — a new read tool moves the number rather than making the sentence a lie.
    public static var readsAvailableInEveryMode: String {
        let reads = ToolExecutor.catalog.filter { $0.effect == .read }.count
        return "\(reads) read tools answer immediately in every mode, whatever this setting says."
    }

    /// Said when a chosen mode could not be written.
    ///
    /// `MCPHostController.setMode` leaves the published mode alone when the save fails,
    /// which is the right thing for the *value* — reporting a mode the file does not have
    /// would be a lie the next tool call would contradict — and useless on its own for the
    /// *person*: a radio that snaps back with no explanation reads as Portmaster having
    /// refused the choice, when the choice was fine and the disk was not. So the failure is
    /// named here, next to the radio, with the mode it failed to save.
    ///
    /// Names the mode by its own title so the line and the radio cannot disagree, and never
    /// says the change was allowed or applied: it was not.
    public static func modeSaveFailed(mode: MCPMutationMode) -> String {
        "“\(modeTitle(for: mode))” was not saved, so it is not in effect. "
        + "Portmaster could not write its MCP settings file; try again, or check that "
        + "\(MCPSettings.fileURL(directory: nil).deletingLastPathComponent().path) is writable."
    }

    // MARK: - Whether the host is listening

    /// A host that is bound, and where a client reaches it.
    public static func listening(socket: URL) -> String {
        "Listening — an AI client on this Mac can reach Portmaster at \(socket.path)."
    }

    /// A host that is not bound. Says the consequence too, because "not running" is only
    /// interesting to a person who was expecting a client to work.
    public static let notRunning =
        "Not running — no AI client can reach Portmaster."

    /// A bind that failed, and the reason it gave.
    ///
    /// The reason is shown rather than replaced with a generic apology: "Address already
    /// in use" is the difference between quitting something and chasing a stale socket.
    /// A failure with nothing usable to say still says the host is not listening, because
    /// an empty line under a heading is the worst of both.
    public static func failed(reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Not listening — Portmaster could not start its MCP host, and gave no reason."
        }
        return "Not listening — Portmaster could not start its MCP host: \(trimmed)"
    }

    // MARK: - Connected clients

    /// How a client's two timestamps are written.
    ///
    /// A function building a formatter per call rather than one shared `static let`,
    /// because `DateFormatter` is not thread-safe and a shared instance published from
    /// this module would be reachable from every thread that can see it — safe today only
    /// because the page happens to be main-actor, which is not a property of the type. A
    /// per-call formatter costs a row's worth of allocation and cannot be reached from off
    /// the main actor at all.
    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }

    /// One connected client, as a single line.
    ///
    /// `lastCallAt` is `nil` for a client that connected and asked nothing —
    /// `initialize` and `tools/list` do not count — which is a genuinely different state
    /// from one that has called, so it is said rather than left blank.
    ///
    /// A pid of 0 is the kernel declining to say (`LOCAL_PEERPID` can simply fail), not a
    /// process numbered zero; the row says the process is not known.
    public static func clientRow(pid: pid_t, connectedAt: Date, lastCallAt: Date?) -> String {
        let who = pid > 0 ? "PID \(pid)" : "process not known"
        let connected = timestamp(connectedAt)
        guard let lastCallAt else {
            return "\(who) · Connected \(connected) · has not called a tool yet"
        }
        let called = timestamp(lastCallAt)
        return "\(who) · Connected \(connected) · Last call \(called)"
    }

    /// Shown when nothing is connected.
    ///
    /// **Branch-aware, because the page's controls are.** A line that says "copy the
    /// install command" is only true where the copy button works; on a build where the
    /// binary could not be found, the only person who reads this line is the person with
    /// no working button, and telling them to press it is the one instruction on the page
    /// that cannot be followed. So each branch says what is actually true of that build,
    /// and both say the empty table is empty rather than merely blank.
    ///
    /// Said as a function rather than two constants because the two are the same sentence
    /// with one clause changed — two independent literals would drift.
    public static func noClients(installCommandAvailable: Bool) -> String {
        guard installCommandAvailable else {
            return "No AI client is connected. Portmaster cannot find its CLI binary on "
                + "this build, so there is no install command here to use yet."
        }
        return "No AI client is connected. Copy the install command below and the one you "
            + "add will show up here."
    }

    // MARK: - The audit log

    /// Says what the log contains. Reads are deliberately not recorded, so a person
    /// reading a log full of mutations should not conclude the reads were missed.
    public static let auditLogCaption =
        "One line per mutation attempt, with what was asked and what was decided. "
        + "Reads are not recorded, so this log is short on a quiet day."

    /// The log's path, whole. A person is going to open it, so it is shown as it is
    /// rather than abbreviated into something that does not paste.
    public static func auditLogPath(_ url: URL) -> String { url.path }

    /// What **Reveal in Finder** should select.
    ///
    /// The file when it is there, and the directory holding it when it is not. The log is
    /// written only by a mutation attempt, so on a machine where nothing has been changed
    /// — the usual state for someone who has just found this page — the file does not
    /// exist, and a reveal aimed at a missing file selects nothing at all: Finder is given
    /// a path with no file and quietly opens a window the person cannot match to the
    /// button they pressed. Showing the directory is the nearest true thing.
    public static func revealTarget(logURL: URL, fileExists: Bool) -> URL {
        fileExists ? logURL : logURL.deletingLastPathComponent()
    }

    // MARK: - Installing the CLI

    /// Shown when no built `portmaster-mcp` was found anywhere Portmaster knows to look —
    /// inside the app bundle or in a checkout.
    ///
    /// Says how to build it rather than offering a command that points at a file which is
    /// not there. On a shipped build this should never appear, because the binary travels
    /// inside the bundle; it is the honest answer for a developer build made before
    /// `swift build` has run.
    public static let binaryNotBuiltNotice =
        "Portmaster could not find its CLI binary, so there is no install command to copy. "
        + "Build it with:\n" + MCPInstallCommand.buildCommand

    /// What the install button claims.
    ///
    /// Two facts and no others: where the binary is, and that this page does not run
    /// anything for the person. `claude mcp add` has never been executed from here — it
    /// edits the user's client configuration — so nothing here may imply it was tried.
    public static let installCaption =
        "Paste this into your AI client's terminal to register the built binary. "
        + "Portmaster does not run it for you, and the command has not been run from here."

    // MARK: - The words the page's own layout needs

    /// The headings, buttons and labels the page renders.
    ///
    /// They live here for the same reason as the sentences: the app target has no test
    /// target, so a literal written in `App/` is a string nothing can inspect — and "the
    /// token is never on this page" is a claim about *every* string the page shows, which
    /// a test that only walks the copy module cannot make. `MCPSettingsChromeTests` reads
    /// `App/MCPSettingsTab.swift` and fails on any string literal that is not one of these,
    /// so the two halves cannot drift apart.
    public enum Chrome {
        public static let policyHeading = "What an AI assistant may do here"
        public static let modePickerLabel = "Mutation mode"
        public static let modeHint = "How much an AI client connected to Portmaster may change"
        public static let statusHeading = "Is Portmaster listening"
        public static let auditLogHeading = "Audit log"
        public static let installHeading = "Use Portmaster from an AI assistant"
        public static let clientsHeading = "Connected AI clients"
        public static let revealButton = "Reveal in Finder"
        public static let copyButton = "Copy install command"
        public static let copiedLabel = "Copied"
        /// Shown when there is no app delegate to read the host from — a state that means
        /// "this build has no MCP host", not one the person caused.
        public static let noHostAvailable = "Portmaster's MCP host is not available in this build."
    }

    /// Every string the MCP settings page renders, in one list.
    ///
    /// The inventory the token test walks, and the list `MCPSettingsChromeTests` checks the
    /// view against. A string added to either side and not the other is a red test, which is
    /// the only way this property survives a person adding a heading.
    public static var everyString: [String] {
        var strings: [String] = []
        strings += MCPMutationMode.allCases.map(modeTitle(for:))
        strings += MCPMutationMode.allCases.map(modeConsequence(for:))
        strings += [Chrome.policyHeading, Chrome.modePickerLabel, Chrome.modeHint]
        strings += [listening(socket: URL(fileURLWithPath: "/tmp/mcp.sock")), notRunning]
        strings += [failed(reason: "example reason"), failed(reason: "")]
        strings += [
            Chrome.statusHeading,
            Chrome.auditLogHeading,
            auditLogCaption,
            auditLogPath(URL(fileURLWithPath: "/tmp/mcp-audit.log")),
            Chrome.revealButton,
            Chrome.installHeading,
            Chrome.copyButton,
            Chrome.copiedLabel,
            binaryNotBuiltNotice,
            installCaption,
            noClients(installCommandAvailable: true),
            noClients(installCommandAvailable: false),
            Chrome.clientsHeading,
            readsAvailableInEveryMode,
        ]
        strings += MCPMutationMode.allCases.map(modeSaveFailed(mode:))
        strings += [
            clientRow(pid: 7, connectedAt: Date(timeIntervalSince1970: 0), lastCallAt: nil),
            clientRow(
                pid: 7,
                connectedAt: Date(timeIntervalSince1970: 0),
                lastCallAt: Date(timeIntervalSince1970: 600)
            ),
        ]
        strings += [
            MCPInstallCommand.buildCommand,
            MCPInstallCommand.command(
                binaryPath: "/Applications/Portmaster.app/Contents/Resources/"
                    + MCPStdioRunner.serverName
            ),
            Chrome.noHostAvailable,
        ]
        return strings
    }
}
