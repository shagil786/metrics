// MCPRoute: which surface the CLI serves a session with.
//
// Slice 1 made the CLI a server. Slice 2 has to make it a *router*: when Portmaster is
// running it holds the authoritative state, the permission gate and the confirmation
// window, and a CLI that ignores all of that is a second, weaker opinion about the same
// machine. So the CLI's first act is to ask whether there is an app to talk to, and only
// then decide who answers.
//
// Four decisions, each of which the obvious alternative gets wrong:
//
//  1. **The route is chosen once, at startup, and never revisited.** Not per call: a
//     per-call decision is how one mutation ends up gated twice — once here, once in
//     the app — or how two reads come back from two snapshots taken a second apart.
//     Once is also what makes "one authority per call" checkable rather than aspirational.
//  2. **Failing to reach an app is not a client-visible error.** Absent endpoint, wrong
//     token, dead pid, refused connect, wedged socket: all of it is "no app", which is
//     slice 1's situation and slice 1's path. One line on stderr, then the on-demand
//     path. An agent asking for a reading must not be told its connection broke because
//     the user has not launched Portmaster.
//  3. **The relay performs no gating and writes no audit line.** It forwards a name and
//     arguments and returns what comes back. A second gate is a second policy, and a
//     second audit line is a second account of what was decided; the app's executor is
//     the only authority for a relayed call.
//  4. **The token is never a route's business.** The route never reads it, prints it or
//     reasons about it; the client presents it once and nothing else on this path can
//     see it. A token in a log line outlives the connection that leaked it.
//
// The relay itself is `SocketMCPClient`, and the on-demand path is slice 1's
// `LocalMCPCallContext`, unchanged.

import Foundation

// MARK: - The route

/// Which surface the CLI serves this session with.
public enum MCPRoute: Sendable {
    /// A running app answered, and every call goes to it.
    case proxy(SocketMCPClient)
    /// No app, or the user asked for slice 1's path anyway.
    case onDemand(LocalMCPCallContext)

    /// The call surface this route serves stdio with. The one thing a caller needs, and
    /// the only way either route can be reached from here — which is what keeps "which
    /// authority" a single value rather than a decision spread over two call sites.
    public var context: any MCPToolCalling {
        switch self {
        case .proxy(let client): client
        case .onDemand(let local): local
        }
    }
}

/// Picks the route, once, at startup.
public enum MCPRouteSelector {

    /// The environment variable that forces the on-demand path even when the app is up.
    ///
    /// The escape hatch for an app that is listening but not answering — the shape of
    /// "wedged" that a user can see: the window is there, the tools hang. Nothing else
    /// can reach past a live socket, because a live socket is the whole definition of
    /// "there is an app", and it is right: the fallback is not for an app that is
    /// working, it is for one that is not.
    public static let onDemandVariable = "PORTMASTER_MCP"

    /// Overrides which directory the endpoint file is read from.
    ///
    /// **Both environment variables are documented here and nowhere else**, because a
    /// second copy of this list is how one of them quietly stops working.
    ///
    /// A test seam, and the reason a spawned `portmaster-mcp` can be pointed at a host a
    /// test started: without it, the child reads the per-user `~/.portmaster`, which on a
    /// developer machine is whichever app they happen to have running — so the whole
    /// spawned-binary suite has to force the on-demand path to be deterministic at all.
    /// With it, the same suite can drive **both** routes against a host it controls.
    ///
    /// Unset is the real per-user directory, so nothing about production changes, and
    /// `select`'s own `endpointDirectory` parameter still wins over it: an explicit
    /// argument is a caller being specific.
    public static let endpointDirectoryVariable = "PORTMASTER_MCP_ENDPOINT_DIR"

    /// What the CLI says when it could not reach an app.
    ///
    /// Said about the socket rather than about Portmaster: every trigger here is
    /// "nothing is answering on the socket", and a line that named a cause would name
    /// the wrong one more often than not.
    public static let unavailableNotice =
        "portmaster-mcp: no Portmaster answering on the socket; this session is doing its own sweep."

    /// What the CLI says when the user forced the on-demand path.
    ///
    /// **Not** `unavailableNotice`, and the difference is the whole point of the
    /// variable. When this is printed, an app may well be listening and perfectly
    /// healthy — that is the usual reason anyone sets it — and telling the user "no
    /// Portmaster answering on the socket" would be the one untrue thing the process
    /// says, pointing them away from the wedged app they were trying to route around.
    ///
    /// It does **not** claim Portmaster is up, because this branch never probes: it runs
    /// before any socket work, which is the point of consulting the variable first. On a
    /// machine with nothing running, "even though Portmaster may be up" is still true,
    /// and the alternative — a probe just to justify the wording — would reintroduce the
    /// wait the escape hatch exists to avoid. The user set the variable; they know why.
    public static let forcedNotice =
        "portmaster-mcp: \(onDemandVariable)=on-demand, so this session is doing its own sweep even though Portmaster may be up."

    /// `.proxy` when a live, authenticated host answers; `.onDemand` when
    /// `PORTMASTER_MCP=on-demand` is set, the endpoint is unavailable, or the
    /// connection fails. One stderr line on fallback, no client-visible error.
    ///
    /// The environment variable is consulted **before** any socket work, not after: an
    /// escape hatch that first probes the thing it is meant to avoid is no escape hatch
    /// for a wedged app.
    ///
    /// - Parameters:
    ///   - environment: read once, defaulted to the process's own. A parameter so a test
    ///     can force the fallback without the test runner's environment deciding it, and
    ///     can name an endpoint directory via `endpointDirectoryVariable`.
    ///   - endpointDirectory: where the endpoint file is. `nil` falls back to the
    ///     environment's `endpointDirectoryVariable`, and then to the per-user
    ///     `~/.portmaster`; a test must never leave it at that last one, because that is
    ///     the only place the token would be real.
    public static func select(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        endpointDirectory: URL? = nil
    ) async -> MCPRoute {
        if isForcedOnDemand(environment) {
            notice(forcedNotice)
            return .onDemand(LocalMCPCallContext())
        }
        // `nil` here is every way of not reaching an app at once: no endpoint file, a
        // stale one, a socket nothing is listening on, a refused token. They are one
        // answer to the only question a caller has, so they are collapsed before they
        // are returned.
        let directory = endpointDirectory ?? endpointDirectoryFromEnvironment(environment)
        if let client = SocketMCPClient(endpointDirectory: directory),
            await client.open()
        {
            return .proxy(client)
        }
        notice(unavailableNotice)
        return .onDemand(LocalMCPCallContext())
    }

    /// Whether the environment asks for the on-demand path, whatever case it is in —
    /// an agent or a shell script should not have to remember which spelling works.
    static func isForcedOnDemand(_ environment: [String: String]) -> Bool {
        guard let value = environment[onDemandVariable] else { return false }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "on-demand"
    }

    /// The endpoint directory `environment` names, or `nil` for the per-user default.
    ///
    /// Empty and whitespace-only are treated as unset rather than as a path, because
    /// `URL(fileURLWithPath: "")` does not fail: it resolves to the current working
    /// directory, which names a real place that holds no endpoint file — a silent
    /// "the app is not available" that reads like a correct answer to the wrong
    /// question.
    static func endpointDirectoryFromEnvironment(_ environment: [String: String]) -> URL? {
        guard let raw = environment[endpointDirectoryVariable] else { return nil }
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// One line, to stderr — never to stdout, which is the JSON-RPC channel, where a
    /// client would try to parse it.
    ///
    /// No token anywhere near this, and nothing about *why* a probe failed: a reason
    /// would be a description of the endpoint file, and the endpoint file is where the
    /// token is.
    private static func notice(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
