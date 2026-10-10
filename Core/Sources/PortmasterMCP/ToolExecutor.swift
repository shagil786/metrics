// ToolExecutor: the MCP tool surface. Every call goes catalog → argument
// validation → permission gate (mutations only) → provider → JSON.
//
// Two invariants worth stating, because they are the whole security story:
//  1. The read/mutation decision comes from the catalog's `effect`, never from
//     anything a caller sent. A caller cannot ask to be treated as a read.
//  2. A denied mutation returns before the provider is touched, so there is no
//     code path in which a gate denial still performs the action.
import Foundation
import PortmasterCore

// MARK: - Outcome

/// What a tool call returns to the MCP host: text plus whether it failed.
public struct ToolOutcome: Sendable {
    public let text: String
    public let isError: Bool

    public init(text: String, isError: Bool) {
        self.text = text
        self.isError = isError
    }
}

/// A change has nothing to list, so `set_preference` acknowledges what it
/// applied rather than returning a collection that would be empty by
/// construction. The echoed key matters: a caller setting several preferences in
/// sequence needs to know which one this answer is about.
private struct PreferencePayload: Encodable {
    let key: String
    let value: String
}

// MARK: - Catalog

/// Whether a tool observes or changes the machine. The executor asks the
/// catalog — never the caller — before consulting `PermissionGate`.
public enum ToolEffect: String, Sendable {
    case read
    case mutation
}

/// One entry of `tools/list`.
public struct ToolDefinition: Sendable {
    public let name: String
    public let description: String
    public let arguments: [(name: String, required: Bool, help: String)]
    public let effect: ToolEffect
}

// MARK: - Executor

public struct ToolExecutor: Sendable {
    private let provider: DataProvider
    private let gate: PermissionGate
    private let audit: AuditLog
    /// Where `set_preference` writes `mcpMode`. `nil` is the per-user default
    /// (`~/.portmaster`); the parameter exists so a test can write somewhere
    /// disposable instead.
    private let settingsDirectory: URL?
    /// The host's currently-open agent session ids.
    ///
    /// One source, used twice: handed to the provider so it can decide what it
    /// knows, and read here to mark each payload's `isOpen`. Deliberately a single
    /// stored value rather than something each path derives — a second derivation
    /// is how a payload's liveness and the store's would come to disagree, which is
    /// the shape of bug the session-identity work already hit once.
    private let openSessionIDs: @Sendable () async -> Set<UUID>
    /// Where `set_model_price` writes. Optional so the tool can exist where no store
    /// does; `UnavailableModelPriceWriter` then refuses with a reason rather than
    /// accepting a price that would be dropped.
    private let priceWriter: any ModelPriceWriting
    /// Where `report_usage` appends. Optional so the tool can exist in contexts with
    /// no store; `UnavailableSessionRecorder` then refuses with a reason rather than
    /// accepting a report that would be dropped.
    private let sessionRecorder: any SessionRecording
    /// The connection a `report_usage` call is attributed to, or nil when this
    /// executor was built without one. The recorder appends against an existing
    /// session row and never creates one, so an unattributable report is refused
    /// rather than filed under a fresh id — a usage record no session row names is
    /// unreachable through every session-scoped read.
    private let sessionID: UUID?

    public init(
        provider: DataProvider,
        gate: PermissionGate,
        audit: AuditLog,
        settingsDirectory: URL? = nil,
        sessionRecorder: (any SessionRecording)? = nil,
        sessionID: UUID? = nil,
        openSessionIDs: @escaping @Sendable () async -> Set<UUID> = { Set<UUID>() },
        priceWriter: (any ModelPriceWriting)? = nil
    ) {
        self.provider = provider
        self.gate = gate
        self.audit = audit
        self.settingsDirectory = settingsDirectory
        self.sessionRecorder = sessionRecorder ?? UnavailableSessionRecorder()
        self.sessionID = sessionID
        self.openSessionIDs = openSessionIDs
        self.priceWriter = priceWriter ?? UnavailableModelPriceWriter()
    }

    /// All 18 tools the MCP server exposes. Names wired into dispatch stay in
    /// step with this list, because `execute` refuses anything not declared here.
    public static let catalog: [ToolDefinition] = [
        // Reads
        ToolDefinition(
            name: "get_system_overview",
            description: "Current machine state: CPU, memory, network throughput, "
                + "disk capacity and I/O, battery, GPU, and temperatures.",
            arguments: [],
            effect: .read
        ),
        ToolDefinition(
            name: "get_top_apps",
            description: "Apps ranked by one metric, highest first. Metrics whose "
                + "rate has not been measured yet sort last, never as zero.",
            arguments: [
                (name: "metric", required: true, help: "cpu | memory | network | disk"),
                (name: "limit", required: false, help: "How many apps to return (1-100, default 10)")
            ],
            effect: .read
        ),
        ToolDefinition(
            name: "get_app_detail",
            description: "One app's totals plus a per-process breakdown.",
            arguments: [
                (name: "id", required: true, help: "App id from get_top_apps")
            ],
            effect: .read
        ),
        ToolDefinition(
            name: "get_agent_sessions",
            description: "AI agent sessions that have connected to this machine, newest "
                + "first, with the tokens each one reported and what that cost. A session "
                + "that reported nothing says so rather than reporting zero, and a model "
                + "with no price says so rather than costing nothing. Tokens live in "
                + "usage.segments, one entry per model: add inputTokens, outputTokens, "
                + "cacheReadTokens and reasoningTokens across the entries for the session's "
                + "total, because cost bills all four. A null count is missing, not zero — "
                + "a model whose two readers disagree past the tolerance keeps its entry "
                + "with null counts while cost.reason reads \"conflict\" and its readings sit "
                + "in that entry's alternateTotals, which must not be added to the counts. "
                + "A reported session can therefore hold no countable token at all.",
            arguments: [
                (name: "limit", required: false, help: "How many sessions to return (1-100, default 20)")
            ],
            effect: .read
        ),
        ToolDefinition(
            name: "get_containers",
            description: "Docker containers and whether Docker is installed, "
                + "with the daemon running, or down.",
            arguments: [],
            effect: .read
        ),
        ToolDefinition(
            name: "get_projects",
            description: "Detected repositories with their process counts and "
                + "listening ports.",
            arguments: [],
            effect: .read
        ),
        ToolDefinition(
            name: "get_history_rankings",
            description: "Apps ranked by recorded CPU time over a window. With "
                + "'resource' the response is a different shape: recorded readings "
                + "of that one resource as {at, metric, value} points belonging to no "
                + "app, not per-app rankings.",
            arguments: [
                (name: "range", required: true, help: "1h | 12h | 24h | 7d | 30d"),
                (name: "resource", required: false, help: "HistoryResource raw value")
            ],
            effect: .read
        ),
        ToolDefinition(
            name: "get_temperatures_fans",
            description: "CPU/GPU/hottest sensor temperatures and fan RPMs. "
                + "Reports 'availability': 'available' with the readings, or "
                + "'noSensors' when a completed pass over a readable SMC produced "
                + "no plausible reading. Refuses while no sensor reading has been "
                + "observed, rather than guessing that the machine has no sensors.",
            arguments: [],
            effect: .read
        ),
        ToolDefinition(
            name: "get_active_alerts",
            description: "Freshly evaluated 'this app is acting up' observations.",
            arguments: [],
            effect: .read
        ),
        ToolDefinition(
            name: "get_settings",
            description: "Current preferences, including the MCP mutation mode.",
            arguments: [],
            effect: .read
        ),
        // A declaration, not an observation — but still not a mutation. See
        // `SessionRecorder.swift` for why the click it would otherwise cost is
        // not worth taking.
        ToolDefinition(
            name: "report_usage",
            description: "Report your own token usage for this session. Optional: Portmaster "
                + "can read some agents' usage from their own logs instead, and says so when "
                + "it has no figure rather than reporting zero.",
            arguments: [
                (name: "input", required: true, help: "Input tokens used so far this session"),
                (name: "output", required: true, help: "Output tokens used so far this session"),
                (name: "model", required: true, help: "The model id these counts are for"),
                (name: "cache_read", required: false, help: "Cache-read tokens, if you track them"),
                (name: "reasoning", required: false, help: "Reasoning tokens, if you track them")
            ],
            effect: .read
        ),
        // Mutations — every one of these is default-deny and audit-logged.
        ToolDefinition(
            name: "quit_app",
            description: "Quit an app's processes, verifying each pid's identity "
                + "immediately before signalling.",
            arguments: [
                (name: "id", required: true, help: "App id from get_top_apps"),
                (name: "force", required: false, help: "true | false (default false)")
            ],
            effect: .mutation
        ),
        ToolDefinition(
            name: "stop_container",
            description: "Stop a running Docker container.",
            arguments: [
                (name: "id", required: true, help: "Container id from get_containers")
            ],
            effect: .mutation
        ),
        ToolDefinition(
            name: "stop_project",
            description: "Stop every process belonging to a detected project, "
                + "with membership checks.",
            arguments: [
                (name: "id", required: true, help: "Project id from get_projects")
            ],
            effect: .mutation
        ),
        ToolDefinition(
            name: "get_model_prices",
            description: "The token prices Portmaster has been given, and which models "
                + "it has seen usage for but has no price for. A model with no price is "
                + "reported as missing rather than as costing nothing.",
            arguments: [],
            effect: .read
        ),
        ToolDefinition(
            name: "set_model_price",
            description: "Set the token price for one model, so its sessions stop reading "
                + "as not priced. Prices are yours to set: Portmaster does not fetch them, "
                + "because a price it looked up today would silently disagree with the "
                + "one you meant.",
            arguments: [
                (name: "model", required: true, help: "The model id exactly as usage reports it"),
                (name: "price", required: true, help: "Price per token, in US dollars, e.g. 0.0000015"),
                (name: "component", required: false, help: "input | output | cache_read | reasoning (default input)")
            ],
            effect: .mutation
        ),
        ToolDefinition(
            name: "set_preference",
            description: "Change one allowlisted preference. Allowed keys: "
                + allowedPreferenceKeysDescription() + ". "
                + "Any other key is rejected, not ignored. Two keys are not named "
                + "after what they change: mcpMode sets this MCP server's own mutation "
                + "policy rather than an app preference, and get_settings reports the "
                + "compact preference as 'compactMenuBar', but the key to write is "
                + "'compact'.",
            arguments: [
                (name: "key", required: true, help: "Allowlisted preference key"),
                (name: "value", required: true, help: "New value for that key")
            ],
            effect: .mutation
        ),
        ToolDefinition(
            name: "handoff_context",
            description: "Write this session's context brief and launch a receiving "
                + "agent to continue it in the session's own working directory. A "
                + "session hands off at most once.",
            arguments: [
                (name: "session_id", required: true, help: "Session id from get_agent_sessions"),
                (name: "target", required: true, help: "Receiving agent: claude | codex, or a configured name")
            ],
            effect: .mutation
        )
    ]

    /// Largest number of apps `get_top_apps` will return for one call. Bounds a
    /// single response so a client cannot ask for an unbounded payload.
    public static let maxTopApps = 100

    /// Runs one tool call.
    ///
    /// Failure is data, not a thrown error: every problem comes back as a
    /// `ToolOutcome` with `isError` set, so the MCP host never has to guess.
    ///
    /// Audit vocabulary, one line per mutation attempt: `rejected` (the request was
    /// malformed — a required argument missing or blank — and was refused before the
    /// gate, so no policy was ever consulted), `denied` (the gate refused, so no
    /// provider call happened and the line is written before any provider call),
    /// `allowed` / `failed` (written after the provider call returns). For an attempt
    /// that reached the provider the log therefore answers "did the stop actually
    /// work?" — not merely "was it permitted?". It cannot answer that for a denial or a
    /// rejection, neither of which reached the action.
    public func execute(name: String, arguments: [String: String]) async -> ToolOutcome {
        guard let tool = Self.catalog.first(where: { $0.name == name }) else {
            return ToolOutcome(text: "Unknown tool: \(name)", isError: true)
        }
        // Trim once, here. The value that is validated must be the value that is
        // used and audited — a `" foo "` that passes a trim-based emptiness
        // check and is then looked up untrimmed would make the audit line
        // disagree with what was actually acted on. Absent and blank are the
        // same failure to a caller, so both report a missing argument.
        //
        // Also not private: `HostMCPCallContext` normalizes before it puts a
        // mutation to a person and before it records a refused attempt, and it must
        // be the same normalization — an approval question quoting `" celsius "`
        // and an audit line recording `celsius` would be two answers about one
        // request.
        let normalized = Self.normalizing(arguments, for: tool)
        if let missing = Self.firstMissingRequiredArgument(in: normalized, for: tool) {
            // Recorded rather than returned silently, because this returns *before* the
            // gate and a mutation that returns before the gate used to leave no trace at
            // all — so "an assistant tried to stop a container and nothing happened" had
            // no answer in the log the log exists to give. `rejected` rather than
            // `denied`: nothing was refused by a policy, the request never got far
            // enough for there to be one, and a reader counting refusals should not
            // count this as a decision the user made. Reads are still not logged — a
            // client sends those constantly and they would bury the mutation lines.
            let message = "Missing argument: \(missing)"
            if tool.effect == .mutation {
                audit.record(
                    tool: name, arguments: normalized, outcome: "rejected", reason: message
                )
            }
            return ToolOutcome(text: message, isError: true)
        }

        let isMutation = tool.effect == .mutation
        if isMutation, case .deny(let reason) = gate.decide(isMutation: true) {
            audit.record(tool: name, arguments: normalized, outcome: "denied", reason: reason)
            return ToolOutcome(text: reason, isError: true)
        }

        do {
            let payload = try await dispatch(tool, arguments: normalized)
            let text = try Self.encode(payload)
            if isMutation {
                audit.record(
                    tool: name, arguments: normalized, outcome: "allowed",
                    reason: (payload as? MCPAuditNoting)?.auditNote
                )
            }
            return ToolOutcome(text: text, isError: false)
        } catch {
            let reason = Self.failureText(for: error, tool: name)
            if isMutation {
                audit.record(tool: name, arguments: normalized, outcome: "failed", reason: reason)
            }
            return ToolOutcome(text: reason, isError: true)
        }
    }

    /// The caller-facing text for a failed call. A provider that throws a plain
    /// Swift error would otherwise render as `localizedDescription`'s
    /// "The operation couldn't be completed. (Module.Error error 1.)", so
    /// providers are expected to wrap failures in `MCPToolError`.
    private static func failureText(for error: Error, tool: String) -> String {
        switch error {
        case let error as MCPToolError:
            return error.message
        case let error as EncodingError:
            return "Could not encode \(tool) result: \(error)"
        default:
            return error.localizedDescription
        }
    }

    // MARK: Dispatch

    private func dispatch(
        _ tool: ToolDefinition, arguments: [String: String]
    ) async throws -> any Encodable {
        switch tool.name {
        case "get_system_overview":
            return SystemOverviewPayload(try await provider.systemOverview())

        case "get_top_apps":
            let metric = try Self.requireMetric(arguments["metric"])
            let limit = try Self.limit(arguments["limit"])
            let rollups = try await provider.topApps(metric: metric, limit: limit)
            // The provider may pre-filter for cost, but the executor is the one
            // place that decides "the top N by this metric", so it truncates.
            return Self.rank(rollups, by: metric).prefix(limit).map(AppRollupPayload.init)

        case "get_app_detail":
            return AppRollupPayload(try await provider.appDetail(id: Self.id(arguments)))

        case "get_model_prices":
            let prices = try priceWriter.prices()
            return ModelPricesPayload(
                prices: prices.map(ModelPricePayload.init),
                missingPricesFor: try priceWriter.modelsMissingAPrice()
            )

        case "set_model_price":
            // Validated before the writer is touched, so a rejected price cannot
            // half-apply. The component is optional and defaults to input, which is
            // what "the price of gpt-5" means to a caller.
            let modelID = try Self.nonBlank(arguments["model"], field: "model")
            let component = try Self.priceComponent(arguments["component"])
            let price = try Self.price(arguments["price"])
            let note = try priceWriter.setPrice(
                modelID: modelID, component: component, price: price
            )
            return ModelPriceSetPayload(note: note)

        case "get_agent_sessions":
            let sessionsLimit = try Self.sessionLimit(arguments["limit"])
            // Read once and used twice — for the provider's own answer and for each
            // payload's `isOpen`. Two reads would be two moments, and a session
            // closing between them would be priced by one and marked by the other.
            let open = await openSessionIDs()
            let (sessions, storeAvailable, note) = try await provider.agentSessions(
                limit: sessionsLimit, openSessionIDs: open
            )
            return AgentSessionsPayload(
                sessions: sessions.map { AgentSessionPayload($0, isOpen: open.contains($0.id)) },
                storeAvailable: storeAvailable,
                note: note
            )

        case "get_containers":
            return ContainersPayload(try await provider.containers())

        case "get_projects":
            return try await provider.projects()

        case "get_history_rankings":
            // Both arguments are checked before the provider is touched, so an
            // unusable window or resource never reads history.
            let window = try Self.requireWindow(arguments["range"])
            if let resource = try Self.optionalResource(arguments["resource"]) {
                // A resource reading belongs to no app, so it is returned as the
                // recorded point it is. Reusing `AppHistoryTrend` here would
                // invent the app the reading was never attributed to.
                return try await provider.historyResources(window: window, resource: resource)
                    .map(ResourceHistoryPointPayload.init)
            }
            return try await provider.historyRankings(window: window, resource: nil)
                .map(HistoryTrendPayload.init)

        case "get_temperatures_fans":
            return TemperaturesPayload(try await provider.temperaturesFans())

        case "get_active_alerts":
            return AlertsPayload(try await provider.activeAlerts())

        case "get_settings":
            return await provider.settingsSnapshot()

        case "quit_app":
            return try await provider.quitApp(id: Self.id(arguments), force: Self.flag(arguments))

        case "stop_container":
            return try await provider.stopContainer(id: Self.id(arguments))

        case "stop_project":
            return try await provider.stopProject(id: Self.id(arguments))

        case "set_preference":
            // Both arguments are required, and `execute` has already refused a
            // missing or blank one, so neither can be absent here. Unwrapped
            // rather than defaulted to "" on purpose: an empty key reaching the
            // allowlist check would report "Preference '' cannot be changed via
            // MCP", which points at the allowlist instead of at the argument the
            // caller actually got wrong.
            guard let key = arguments["key"], let value = arguments["value"] else {
                throw MCPToolError(
                    message: "Missing argument: \(arguments["key"] == nil ? "key" : "value")"
                )
            }
            return try await setPreference(key: key, value: value)

        case "report_usage":
            // Counts are parsed and range-checked before the recorder is touched, so
            // an invalid report cannot leave a partial record behind.
            let input = try Self.nonNegative(arguments["input"], field: "input")
            let output = try Self.nonNegative(arguments["output"], field: "output")
            let model = try Self.nonBlank(arguments["model"], field: "model")
            let cacheRead = try Self.optionalNonNegative(
                arguments["cache_read"], field: "cache_read"
            )
            let reasoning = try Self.optionalNonNegative(arguments["reasoning"], field: "reasoning")
            // **Where there is to record, then which session.** The order is the
            // point and it used to be the reverse: a CLI with no app answered "cannot
            // tell which session this belongs to", which is true and tells the agent
            // nothing, instead of the one thing that would fix it — start Portmaster.
            // Both refusals are still reachable, in this order.
            try sessionRecorder.requireAvailable()
            let note = try sessionRecorder.record(
                sessionID: try requireSessionID(),
                input: input, output: output,
                cacheRead: cacheRead, reasoning: reasoning, modelID: model
            )
            return AgentUsageRecordedPayload(note: note)

        case "handoff_context":
            let sessionID = try Self.sessionUUID(arguments)
            let target = try Self.nonBlank(arguments["target"], field: "target")
            let outcome = try await provider.handoffContext(sessionID: sessionID, target: target)
            return HandoffContextPayload(outcome)

        // Unreachable while the catalog and this switch stay in step: `execute`
        // refuses any name the catalog does not declare, and every declared name
        // is handled above. Kept so a tool added to the catalog without a
        // dispatch case fails loudly instead of quietly doing nothing.
        default:
            throw MCPToolError(message: "Tool not implemented yet")
        }
    }

    /// The preference keys MCP may change.
    ///
    /// An allowlist rather than a denylist, because the surface being protected is
    /// the app's whole preferences blob: a denylist only stays exhaustive while
    /// nobody adds a preference, and this file does not own that list.
    ///
    /// This is the one definition of the list. The catalog description, the
    /// rejection message here, and `PreferencesStore`'s rejection message are all
    /// built from it rather than written out, so a key cannot be accepted at one
    /// layer and reported as refused — or advertised as allowed — at another.
    public static let allowedPreferenceKeys: Set<String> = [
        "temperatureUnit", "networkUnit", "cpuScale", "temperatureSource",
        "compact", "mcpMode",
    ]

    /// The allowlist as one sentence, sorted so the text is stable. The single
    /// place a rejection names the keys, wherever that rejection is raised.
    public static func allowedPreferenceKeysDescription() -> String {
        allowedPreferenceKeys.sorted().joined(separator: ", ")
    }

    /// Applies one allowlisted preference.
    ///
    /// `mcpMode` is the exception: it is the MCP server's own mutation policy, kept
    /// in `MCPSettings` beside the audit log rather than in the app's preferences
    /// blob, because the server has to be able to read and write it whether or not
    /// the UI is running. Everything else goes to the provider, which owns the
    /// meaning of each value and rejects the ones it cannot apply.
    private func setPreference(
        key: String, value: String
    ) async throws -> PreferencePayload {
        guard Self.allowedPreferenceKeys.contains(key) else {
            // Naming the rejected key and the allowlist back: a caller that guessed
            // a key learns what it may try instead, and a caller that did not learn
            // which of its keys was the problem.
            throw MCPToolError(
                message: "Preference '\(key)' cannot be changed via MCP. Allowed: "
                    + Self.allowedPreferenceKeysDescription() + "."
            )
        }

        if key == "mcpMode" {
            guard let mode = MCPMutationMode(rawValue: value) else {
                throw MCPToolError(
                    message: "Invalid mcpMode: \(value). Allowed: "
                        + MCPMutationMode.allCases.map(\.rawValue).joined(separator: ", ") + "."
                )
            }
            var settings = MCPSettings.load(directory: settingsDirectory)
            settings.mode = mode
            do {
                try settings.save(directory: settingsDirectory)
            } catch {
                // Wrapped so the failure reads as a preference that did not change
                // rather than as a Cocoa error code.
                throw MCPToolError(
                    message: "Could not save MCP settings: \(error.localizedDescription)"
                )
            }
            return PreferencePayload(key: key, value: mode.rawValue)
        }

        try await provider.setPreference(key: key, value: value)
        return PreferencePayload(key: key, value: value)
    }

    // MARK: Argument parsing

    /// `arguments` with every declared value trimmed.
    ///
    /// Absent and blank are the same failure to a caller, so both report a missing
    /// argument — but only for a *required* one, since an absent optional is not a
    /// failure at all and must stay absent rather than become `""`.
    static func normalizing(
        _ arguments: [String: String], for tool: ToolDefinition
    ) -> [String: String] {
        var normalized = arguments
        for argument in tool.arguments {
            guard let value = normalized[argument.name] else { continue }
            normalized[argument.name] = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return normalized
    }

    /// The first required argument `arguments` is missing or has left blank, or
    /// `nil` when every required one is there.
    ///
    /// Checked after `normalizing` so a blank value is recognised as blank rather
    /// than as a string of whitespace the tool would go on to parse.
    static func firstMissingRequiredArgument(
        in arguments: [String: String], for tool: ToolDefinition
    ) -> String? {
        for argument in tool.arguments where argument.required {
            guard let value = arguments[argument.name], !value.isEmpty else {
                return argument.name
            }
        }
        return nil
    }

    private static func id(_ arguments: [String: String]) -> String {
        arguments["id"] ?? ""
    }

    private static func flag(_ arguments: [String: String]) -> Bool {
        arguments["force"].map { $0.lowercased() == "true" } ?? false
    }

    private static func requireMetric(_ raw: String?) throws -> AppMetric {
        guard let raw, let metric = AppMetric(rawValue: raw) else {
            throw MCPToolError(message: "Invalid metric: \(raw ?? "")")
        }
        return metric
    }

    private static func requireWindow(_ raw: String?) throws -> HistoryWindow {
        guard let raw, let window = HistoryWindow(rawValue: raw) else {
            throw MCPToolError(message: "Invalid range: \(raw ?? "")")
        }
        return window
    }

    /// Absent means "no resource": the caller wants app trends. A value that is
    /// present but unknown is rejected rather than quietly dropped, because
    /// silently answering with app trends would look like the resource was
    /// honoured.
    private static func optionalResource(_ raw: String?) throws -> HistoryResource? {
        guard let raw else { return nil }
        guard let resource = HistoryResource(rawValue: raw) else {
            throw MCPToolError(message: "Invalid resource: \(raw)")
        }
        return resource
    }

    private static func limit(_ raw: String?) throws -> Int {
        guard let raw else { return 10 }
        guard let parsed = Int(raw) else {
            throw MCPToolError(message: invalidLimit(raw))
        }
        return try validatedLimit(parsed)
    }

    /// The `1...maxTopApps` range, refused rather than clamped.
    ///
    /// Widen past the argument parser because a provider can be handed a limit
    /// directly, and a client reaches whichever provider is installed: a limit one
    /// path refuses must not be quietly clamped into a different answer on the
    /// other. Clamping would answer a question nobody asked — a limit of 0 or 101
    /// would silently become the largest legal one.
    static func validatedLimit(_ limit: Int) throws -> Int {
        guard limit > 0, limit <= maxTopApps else {
            throw MCPToolError(message: invalidLimit(String(limit)))
        }
        return limit
    }

    /// One refusal for both the unparsable and the out-of-range limit, so the
    /// range is stated the same way however it was missed.
    private static func invalidLimit(_ raw: String) -> String {
        "Invalid limit: \(raw) (must be 1...\(maxTopApps))"
    }

    /// A price per token. Refused rather than coerced on anything non-numeric, and
    /// negatives are refused rather than clamped — a negative price is a caller bug,
    /// and clamping would file a plausible figure for it. Zero is accepted: a free
    /// model is a real answer, unlike a missing price.
    static func price(_ raw: String?) throws -> Decimal {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw MCPToolError(message: "price is required.")
        }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard ModelPriceEntry.isDecimalNumber(trimmed) else {
            throw MCPToolError(message: "price must be a decimal number, such as 0.0000015.")
        }
        guard let value = Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX")) else {
            throw MCPToolError(message: "price must be a decimal number, such as 0.0000015.")
        }
        guard value >= 0 else {
            throw MCPToolError(message: "price must not be negative.")
        }
        return value
    }

    static func priceComponent(_ raw: String?) throws -> PriceComponent {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
            return PriceComponent.named
        }
        // Underscores and case are both forgiven, because they are spelling and a
        // caller is not wrong about which component they meant. `cache_read` and
        // `cacheRead` are the same request written twice.
        let normalized = raw.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "_", with: "")
            .lowercased()
        switch normalized {
        case "input": return .input
        case "output": return .output
        case "cacheread": return .cacheRead
        case "reasoning": return .reasoning
        default:
            throw MCPToolError(message: "component must be input, output, cache_read or reasoning.")
        }
    }

    /// How many sessions to return. Bounded because the list is unbounded in
    /// principle — nothing deletes a session but the user's own retention setting.
    static func sessionLimit(_ raw: String?) throws -> Int {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return 20 }
        guard let value = Int(raw.trimmingCharacters(in: .whitespaces)) else {
            throw MCPToolError(message: "limit must be a whole number.")
        }
        guard (1...100).contains(value) else {
            throw MCPToolError(message: "limit must be between 1 and 100.")
        }
        return value
    }

    /// A token count. Negative is refused rather than clamped: a negative count is a
    /// caller bug, and clamping would record a plausible number for a broken report.
    static func nonNegative(_ raw: String?, field: String) throws -> Int {
        guard let raw, let value = Int(raw.trimmingCharacters(in: .whitespaces)) else {
            throw MCPToolError(message: "\(field) must be a whole number.")
        }
        guard value >= 0 else {
            throw MCPToolError(message: "\(field) must not be negative.")
        }
        return value
    }

    /// Absent and blank are both "not supplied", which is a distinct answer from
    /// zero — a component nobody tracks is not a component that cost nothing.
    static func optionalNonNegative(_ raw: String?, field: String) throws -> Int? {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return try nonNegative(raw, field: field)
    }

    /// A required string that must carry something.
    ///
    /// `execute` already refuses a missing or blank required argument before
    /// dispatch, and `model` is required — so through the tool this never throws.
    /// Kept anyway for the same reason `set_preference` re-unwraps its own
    /// arguments: dispatch validates what it was handed instead of trusting a
    /// caller to have done it, so a second caller reaching `report_usage` cannot
    /// record a usage row priced against an empty model id.
    static func nonBlank(_ raw: String?, field: String) throws -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !trimmed.isEmpty else {
            throw MCPToolError(message: "\(field) is required.")
        }
        return trimmed
    }

    /// The session a report is filed under, or a refusal saying why there is none.
    ///
    /// Its own failure rather than a `nil` passed down: the recorder appends against
    /// an existing session and never creates one, so a missing attribution cannot be
    /// papered over with a fresh id — that record would be invisible to every
    /// session-scoped read, and the session would read `notReported` with no way to
    /// tell a lost report from one never made.
    private func requireSessionID() throws -> UUID {
        guard let sessionID else {
            throw MCPToolError(
                message: "Portmaster cannot tell which session this report belongs to, "
                    + "so it was not recorded."
            )
        }
        return sessionID
    }

    /// The `session_id` argument as a UUID.
    ///
    /// Its own helper rather than `requireSessionID`: that one reads the connection's
    /// own binding (`report_usage` records against the caller's session), while a
    /// handoff names its session explicitly — any recorded session may be handed off,
    /// not only the one the call arrived on.
    private static func sessionUUID(_ arguments: [String: String]) throws -> UUID {
        let raw = try nonBlank(arguments["session_id"], field: "session_id")
        guard let id = UUID(uuidString: raw) else {
            throw MCPToolError(message: "Invalid session_id: not an id Portmaster recorded.")
        }
        return id
    }

    // MARK: Ranking

    /// Orders rollups by the requested metric, highest first. A nil total means
    /// "not measured yet" and sorts last — reading it as zero would rank an
    /// unmeasured app above a slow one, which reads as a fact about the app.
    ///
    /// Not private: `LiveDataProvider` ranks with this same function, so a
    /// `get_top_apps` call cannot be ordered one way through the app and another
    /// way without it. Applying it twice is applying it once — the comparator is
    /// a total order on the metric — so the executor's own re-ranking below is
    /// unchanged.
    static func rank(_ rollups: [AppRollup], by metric: AppMetric) -> [AppRollup] {
        let total: (AppRollup) -> Double?
        switch metric {
        case .cpu: total = { $0.totalCPU }
        case .memory: total = { Double($0.totalMemory) }
        case .network: total = { $0.totalNetInBytesPerSec }
        case .disk: total = { $0.totalDiskWriteBytesPerSec }
        }
        return rollups.sorted { lhs, rhs in
            switch (total(lhs), total(rhs)) {
            case let (left?, right?):
                return left == right ? lhs.displayName < rhs.displayName : left > right
            case (nil, nil):
                return lhs.displayName < rhs.displayName
            case (nil, _?):
                return false
            case (_?, nil):
                return true
            }
        }
    }

    // MARK: Encoding

    /// Sorted keys and unescaped slashes keep payloads byte-stable, so tests and
    /// humans diffing two calls for the same snapshot see the same text.
    private static func encode(_ payload: any Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw MCPToolError(message: "Result was not valid UTF-8.")
        }
        return text
    }
}

/// The `reason` a successful call carries, for payloads that have one.
///
/// The executor's vocabulary stays four words (`allowed`/`denied`/`failed`/`rejected`);
/// this is the note that rides the `allowed` line, so the log records not only that a
/// handoff ran but where its brief went (ruling 10). Payloads without the conformance
/// audit with no reason, exactly as before.
private protocol MCPAuditNoting {
    var auditNote: String { get }
}

extension HandoffContextPayload: MCPAuditNoting {
    var auditNote: String { outcome.auditNote }
}
