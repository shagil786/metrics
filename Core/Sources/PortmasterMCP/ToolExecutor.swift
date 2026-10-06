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

    public init(
        provider: DataProvider,
        gate: PermissionGate,
        audit: AuditLog,
        settingsDirectory: URL? = nil
    ) {
        self.provider = provider
        self.gate = gate
        self.audit = audit
        self.settingsDirectory = settingsDirectory
    }

    /// All 13 tools the MCP server exposes. Names wired into dispatch stay in
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
                    tool: name, arguments: normalized, outcome: "allowed", reason: nil
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
