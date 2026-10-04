// MCPRoute: which surface the CLI serves a session with.
//
// Slice 1 made the CLI a server. Slice 2 has to make it a *router*: when Portmaster is
// running it holds the authoritative state, the permission gate and the confirmation
// window, and a CLI that ignores all of that is a second, weaker opinion about the same
// machine. So the CLI's first act is to ask whether there is an app to talk to, and only
// then decide who answers.
//
// The route was extracted out of `SocketMCPClient`, which owns the relay itself; the
// decision and the thing it decides between are different questions, and this file now
// holds the first beside `MCPRouteSelector` alone.

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

    /// The one line a fallback writes. On stderr, and never on stdout — stdout is the
    /// JSON-RPC channel, and a client reading a diagnostic there will try to parse it.
    public static let fallbackNotice =
        "portmaster-mcp: no Portmaster on the socket; answering from an on-demand sweep."

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
    ///     can force the fallback without the test runner's environment deciding it.
    ///   - endpointDirectory: where the endpoint file is. `nil` is the per-user
    ///     `~/.portmaster`; a test must never pass `nil`, because that is the one place
    ///     the token would be real.
    public static func select(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        endpointDirectory: URL? = nil
    ) async -> MCPRoute {
        if isForcedOnDemand(environment) {
            notice()
            return .onDemand(LocalMCPCallContext())
        }
        // `nil` here is every way of not reaching an app at once: no endpoint file, a
        // stale one, a socket nothing is listening on, a refused token. They are one
        // answer to the only question a caller has, so they are collapsed before they
        // are returned.
        if let client = SocketMCPClient(endpointDirectory: endpointDirectory),
            await client.open()
        {
            return .proxy(client)
        }
        notice()
        return .onDemand(LocalMCPCallContext())
    }

    /// Whether the environment asks for the on-demand path, whatever case it is in —
    /// an agent or a shell script should not have to remember which spelling works.
    static func isForcedOnDemand(_ environment: [String: String]) -> Bool {
        guard let value = environment[onDemandVariable] else { return false }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "on-demand"
    }

    /// The one line a fallback writes, to stderr — never to stdout, which is the
    /// JSON-RPC channel, where a client would try to parse it.
    ///
    /// No token anywhere near this, and nothing about *why* the probe failed: a reason
    /// would be a description of the endpoint file, and the endpoint file is where the
    /// token is.
    private static func notice() {
        FileHandle.standardError.write(Data((fallbackNotice + "\n").utf8))
    }
}

