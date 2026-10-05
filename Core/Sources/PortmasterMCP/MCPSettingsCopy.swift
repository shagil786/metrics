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
//     something is wrong.
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

    /// How a client's two timestamps are written. Shared so a test can hold the format
    /// still and so a row cannot be built from two different ideas of what "connected at"
    /// looks like.
    public static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()

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
        let connected = timestampFormatter.string(from: connectedAt)
        guard let lastCallAt else {
            return "\(who) · Connected \(connected) · has not called a tool yet"
        }
        let called = timestampFormatter.string(from: lastCallAt)
        return "\(who) · Connected \(connected) · Last call \(called)"
    }

    /// Shown when nothing is connected.
    ///
    /// Says what an empty list means and what would put a client in it, because an empty
    /// table with no line under it is indistinguishable from a page that failed to load.
    public static let noClients =
        "No AI client is connected. Copy the install command below and the one you add will show up here."

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

    /// Shown when no built `portmaster-mcp` was found anywhere Portmaster knows to look.
    ///
    /// Says how to build it rather than offering a command that points at a file which is
    /// not there.
    public static let binaryNotBuiltNotice =
        "The portmaster-mcp binary was not found. Build it with:\n"
        + MCPInstallCommand.buildCommand

    /// What the install button claims.
    ///
    /// Two facts and no others: where the binary is, and that this page does not run
    /// anything for the person. `claude mcp add` has never been executed from here — it
    /// edits the user's client configuration — so nothing here may imply it was tried.
    public static let installCaption =
        "Paste this into your AI client's terminal to register the built binary. "
        + "Portmaster does not run it for you, and the command has not been run from here."
}
