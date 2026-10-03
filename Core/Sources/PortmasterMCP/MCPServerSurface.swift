// MCPServerSurface: everything between the MCP wire and `ToolExecutor` that is
// not wiring.
//
// It lives in the library rather than in `main.swift` so it can be tested
// in-process; the executable only assembles and runs it. The two rules it exists
// to keep true:
//
//  1. **stdout is the JSON-RPC channel.** Anything diagnostic belongs on stderr,
//     and the server itself writes exactly one thing there: whatever
//     `ToolExecutor` decided. A stray newline on stdout is not harmless framing
//     noise — it is a line a client will try to parse.
//  2. **The permission gate is built per call, not per process.**
//     `PermissionGate` takes the mutation mode and the app's liveness as
//     construction-time values, so a gate built once at startup would keep
//     permitting `allowSession` mutations after the user quit Portmaster —
//     contradicting the very reason string it returns when liveness is false.
//     Rebuilding it per call also re-reads the settings file, so a mode change
//     takes effect without restarting the server.
import Foundation
import MCP

// MARK: - Catalog on the wire

/// `ToolExecutor.catalog` in the shape `tools/list` answers with.
public enum MCPCatalog {
    /// One MCP `Tool` per catalog entry, with an input schema derived from the
    /// arguments the catalog already declares. The catalog stays the single
    /// source of truth: a tool cannot be listed without being dispatchable,
    /// because `execute` refuses any name the catalog does not declare.
    public static func tools() -> [Tool] {
        ToolExecutor.catalog.map(tool)
    }

    static func tool(_ definition: ToolDefinition) -> Tool {
        var properties: [String: Value] = [:]
        for argument in definition.arguments {
            properties[argument.name] = .object([
                // Every argument is a string as far as the executor is concerned;
                // a client that sends `10` or `true` has them coerced, not rejected
                // (see `MCPArguments`).
                "type": "string",
                "description": .string(argument.help),
            ])
        }
        var schema: [String: Value] = ["type": "object", "properties": .object(properties)]
        let required = definition.arguments.filter { $0.required }.map { $0.name }
        if !required.isEmpty {
            schema["required"] = .array(required.map { .string($0) })
        }
        let readOnly = definition.effect == .read
        return Tool(
            name: definition.name,
            description: definition.description,
            inputSchema: .object(schema),
            // The catalog's `effect`, never anything a caller sent.
            annotations: .init(
                readOnlyHint: readOnly,
                destructiveHint: readOnly ? nil : true,
                idempotentHint: readOnly ? nil : false
            )
        )
    }
}

// MARK: - Arguments

/// Reduces MCP's arbitrary JSON arguments to the `[String: String]` the tools take.
///
/// Coercing rather than rejecting is deliberate: the tools parse their own values
/// and report their own argument errors ("Invalid metric: …"), and a stricter
/// gate here would only add a second, blunter place for a call to fail. What it
/// will not do is guess: a JSON `null` is the caller's "no value" and becomes an
/// absent key, so the tool reports the missing argument by name.
public enum MCPArguments {
    /// The string map for one call. A nil object and an empty object are the same
    /// answer — "no arguments given" — because that is what the tools expect.
    public static func strings(fromJSON object: [String: Any]?) -> [String: String] {
        guard let object else { return [:] }
        var arguments: [String: String] = [:]
        for (name, value) in object {
            if let text = text(forJSON: value) { arguments[name] = text }
        }
        return arguments
    }

    /// One JSON argument value as the string a tool will read.
    public static func text(forJSON value: Any?) -> String? {
        guard let value else { return nil }
        switch value {
        case is NSNull:
            return nil
        case let text as String:
            return text
        case let number as NSNumber:
            return numberText(number)
        default:
            // A container. Kept as JSON text rather than dropped: no tool reads
            // one, so it will fail on its own argument, which names the tool.
            return jsonText(value)
        }
    }

    private static func numberText(_ number: NSNumber) -> String {
        // `true` must not arrive as "1": `force` is parsed as the string "true",
        // and `1` would silently read as false.
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue ? "true" : "false"
        }
        let double = number.doubleValue
        // Integral values are spelled without a fraction, so `limit: 10` and
        // `limit: 10.0` are the same argument. Beyond 2^53 a double has lost the
        // integer it came from, so those keep their decimal form.
        if double == double.rounded(), abs(double) < 9_007_199_254_740_992 {
            return String(Int64(double))
        }
        return String(double)
    }

    private static func jsonText(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
            let data = try? JSONSerialization.data(withJSONObject: value),
            let text = String(data: data, encoding: .utf8)
        else { return nil }
        return text
    }
}

// MARK: - Per-call context

/// Supplies the executor for one `tools/call`.
///
/// A protocol rather than a stored executor so that "per call" is structural:
/// there is nowhere to cache one.
public protocol MCPCallContext: Sendable {
    /// A ready-to-run executor. Called once per tool call, never once per process.
    func makeExecutor() -> ToolExecutor
}

/// The production context: the real provider, the real audit log, and a gate
/// rebuilt from freshly observed state on every call.
///
/// Slice 1 has no `MCPHost`, so `confirmEach` always denies with its documented
/// message — the app has no way to be asked, and no path here pretends otherwise.
public struct LiveMCPCallContext: MCPCallContext {
    private let provider: @Sendable () -> any DataProvider
    private let loadSettings: @Sendable () -> MCPSettings
    private let appRunning: @Sendable () -> Bool
    private let auditDirectory: URL?
    private let settingsDirectory: URL?

    /// - Parameters:
    ///   - provider: builds the data provider. Defaults to a live
    ///     `OnDemandProvider` over the same `settingsDirectory`; a test passes a
    ///     stub so a call cannot touch the machine.
    ///   - loadSettings: re-reads the mutation policy. Called per call, so
    ///     changing the mode on disk takes effect without a restart.
    ///   - appRunning: probed per call, because the app can be launched or quit
    ///     while this server stays up and both answers matter.
    ///   - auditDirectory: where mutation attempts are recorded.
    ///   - settingsDirectory: where `mcpMode` is written.
    public init(
        provider: (@Sendable () -> any DataProvider)? = nil,
        loadSettings: @escaping @Sendable () -> MCPSettings = { MCPSettings.load() },
        appRunning: @escaping @Sendable () -> Bool = { AppLiveness.isPortmasterRunning() },
        auditDirectory: URL? = nil,
        settingsDirectory: URL? = nil
    ) {
        self.provider = provider ?? { OnDemandProvider(settingsDirectory: settingsDirectory) }
        self.loadSettings = loadSettings
        self.appRunning = appRunning
        self.auditDirectory = auditDirectory
        self.settingsDirectory = settingsDirectory
    }

    public func makeExecutor() -> ToolExecutor {
        ToolExecutor(
            provider: provider(),
            // Both inputs are observed here rather than cached above: this is the
            // whole reason the gate is constructed per call.
            gate: PermissionGate(settings: loadSettings(), appRunning: appRunning()),
            audit: AuditLog(directory: auditDirectory),
            settingsDirectory: settingsDirectory
        )
    }
}

// MARK: - Dispatch

/// One tool call, from the wire's view.
public enum MCPDispatch {
    /// Runs one call and reports it the way MCP expects: a failed call comes back
    /// as data with `isError` set, never as a JSON-RPC error, because a transport
    /// error tells the caller the connection broke rather than that the tool
    /// refused.
    public static func call(
        name: String,
        arguments: [String: String],
        context: any MCPCallContext
    ) async -> ToolOutcome {
        await context.makeExecutor().execute(name: name, arguments: arguments)
    }
}

// MARK: - Server wiring

/// Registers the tool surface on an MCP `Server`.
public enum MCPServerSurface {
    /// Adds `tools/list` and `tools/call` to `server`, and returns the tracker
    /// that knows which calls are outstanding.
    ///
    /// The tracker is returned rather than hidden because the caller has to wait
    /// on it before shutting down — see `MCPStdioRunner`.
    @discardableResult
    public static func configure(_ server: Server, context: any MCPCallContext) async
        -> CallTracker
    {
        let tracker = CallTracker()
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: MCPCatalog.tools())
        }

        await server.withMethodHandler(CallTool.self) { parameters in
            // Tracked, because this is the work a shutdown has to wait for.
            let outcome = await tracker.track {
                await MCPDispatch.call(
                    name: parameters.name,
                    arguments: MCPArguments.strings(fromJSON: jsonObject(parameters.arguments)),
                    context: context
                )
            }
            return .init(
                content: [.text(text: outcome.text, annotations: nil, _meta: nil)],
                isError: outcome.isError
            )
        }
        return tracker
    }

    /// The SDK's decoded arguments as plain JSON.
    ///
    /// `Value` is `Codable` and encodes as plain JSON, so going through
    /// `JSONSerialization` gives the coercion exactly what the client sent, with
    /// no second set of rules for what a `Value` case means.
    private static func jsonObject(_ arguments: [String: Value]?) -> [String: Any]? {
        guard let arguments else { return nil }
        guard let data = try? JSONEncoder().encode(arguments),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            // Unreachable for a `Value` map, and harmless where it is not: an
            // empty argument map is what the tools read as "nothing supplied",
            // and they will name the argument they are missing.
            return nil
        }
        return object
    }
}

// MARK: - Outstanding work

/// Which tool calls are between the wire and a result right now.
///
/// This exists because the SDK's receive loop ends the moment its input does, and
/// it does not wait for the handler tasks it spawned on the way there. Without a
/// count, a server that exits on EOF discards replies it was already computing —
/// which is exactly what happens to `echo '{…}' | portmaster-mcp`, the first
/// thing anyone tries by hand.
///
/// The count is taken at the tool handler rather than at the transport because
/// the handler is the last place this server still owns: reaching past it into
/// the SDK's message loop would make shutdown depend on SDK internals.
public actor CallTracker {
    private var inFlight = 0

    public init() {}

    /// Calls started and not yet finished. Observable so a caller — and a test —
    /// can tell "waiting" from "never started".
    public var inFlightCount: Int { inFlight }

    /// Runs `body` as a tracked call. The count falls even if `body` throws, so a
    /// failure cannot leave the drain waiting on work that is already over.
    public func track<T>(_ body: () async throws -> T) async rethrows -> T {
        inFlight += 1
        do {
            let value = try await body()
            inFlight -= 1
            return value
        } catch {
            inFlight -= 1
            throw error
        }
    }

    /// Waits until no call has been in flight for `quiet`, or until `timeout` has
    /// passed — whichever comes first.
    ///
    /// Always returns, and never sooner than `quiet`, so a handler that hangs
    /// costs the timeout and nothing more: the server cannot be kept alive by
    /// work it is waiting to finish.
    public func waitUntilIdle(quiet: TimeInterval, timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(max(quiet, timeout))
        var idleSince = Date()
        while Date() < deadline {
            if inFlight == 0 {
                if Date().timeIntervalSince(idleSince) >= quiet { return }
            } else {
                // Something is running; the quiet period starts over from here.
                idleSince = Date()
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}