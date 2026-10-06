// PreferencesStore: the app's preferences blob, read and written one field at a
// time.
//
// Two properties matter here. Sibling fields survive a write, because the blob is
// decoded, one field is mutated, and the rest is re-encoded untouched. And the
// read-modify-write is serialized, because two MCP calls setting two different
// preferences would otherwise each read the same blob and the second write would
// erase the first one's field.
import Foundation
import PortmasterCore

/// Reads and writes the app's preferences blob.
///
/// `UserDefaults` is not `Sendable`, so this box owns the one instance and the
/// lock serializes the read-modify-write. That lock is not incidental: two MCP
/// calls setting two different preferences concurrently would otherwise each
/// read the same blob and the second write would erase the first one's field.
///
/// **The type is public and only `apply` and `validate` are public methods**, because
/// the app writes its preferences through its own `AppModel.prefs` rather than through
/// this store: it holds the decoded blob in memory and saves it on every change, so a
/// write behind its back would be overwritten by the next thing the user does. What
/// the app needs from here is the *mapping* — which value means which field, and the
/// refusals for values that mean nothing — and that must be the same mapping the
/// on-demand path validates against. A second switch in the app is how one key gets
/// accepted by one provider and refused by the other.
public final class PreferencesStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func load() -> AppPreferences {
        AppPreferences.load(from: defaults)
    }

    /// Changes exactly one allowlisted field and writes the whole blob back.
    /// Sibling fields are preserved by construction: the blob is decoded, one
    /// field is mutated, and the rest is re-encoded untouched.
    func setAllowlisted(key: String, value: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var preferences = try read()
        try Self.apply(key: key, value: value, to: &preferences)
        try write(preferences)
    }

    private func read() throws -> AppPreferences {
        guard let data = defaults.data(forKey: AppPreferences.defaultsKey) else {
            // No blob yet: the app has never saved preferences, so the defaults
            // are the current state and there is nothing to preserve.
            return AppPreferences()
        }
        do {
            return try JSONDecoder().decode(AppPreferences.self, from: data)
        } catch {
            // Refuse rather than overwrite: a blob this build cannot read may
            // still be one it can preserve field by field, and replacing it with
            // defaults would silently discard the user's preferences.
            throw MCPToolError(
                message: "Could not read Portmaster preferences: \(error.localizedDescription)"
            )
        }
    }

    private func write(_ preferences: AppPreferences) throws {
        do {
            defaults.set(try JSONEncoder().encode(preferences), forKey: AppPreferences.defaultsKey)
        } catch {
            throw MCPToolError(
                message: "Could not save Portmaster preferences: \(error.localizedDescription)"
            )
        }
    }

    /// Whether one allowlisted key/value pair can be applied at all.
    ///
    /// A check, not a write, and shaped as one so a caller that only needs the
    /// answer says so: `LiveDataProvider` hands preference writes on to the app,
    /// which is the thing that writes, and asking this question must not require
    /// it to know what a preferences blob is.
    ///
    /// The throwaway `AppPreferences` is the cost of having one definition of the
    /// allowed values rather than two — a second switch over the same five keys
    /// would be free to drift from `apply`, which is exactly what this file's
    /// refusals exist to prevent. The refusals below are `apply`'s own, so there is
    /// one answer to "can this be applied" in the module.
    public static func validate(key: String, value: String) throws {
        // `mcpMode` is this MCP server's own mutation policy. It is not a field of
        // `AppPreferences` — `MCPSettings` owns it, beside the audit log, precisely so
        // the server can read and write it whether or not the UI is running — and
        // `ToolExecutor.setPreference` performs the write after this check.
        //
        // So it is validated here rather than through `apply`, and the split is the
        // whole point: `validate` answers "can this request be carried out?", which
        // covers every key the executor's allowlist advertises, while `apply` answers
        // "can this be written into the app's preferences blob?", which `mcpMode`
        // cannot be. `validate` used to be `apply` against a throwaway blob and nothing
        // else, so the two questions were one question — and the confirmation window
        // validates through here before it will put a change to a person, which meant
        // every `mcpMode` change was refused by the window with a sentence that
        // refused `mcpMode` while listing `mcpMode` as allowed.
        if key == "mcpMode" {
            guard Self.matching(MCPMutationMode.self, value) != nil else {
                throw MCPToolError(
                    message: "Invalid mcpMode: \(value). Allowed: "
                        + MCPMutationMode.allCases.map(\.rawValue).joined(separator: ", ")
                        + "."
                )
            }
            return
        }
        var scratch = AppPreferences()
        try apply(key: key, value: value, to: &scratch)
    }

    /// Applies one allowlisted value.
    ///
    /// **How values are read, in one place:** a value is trimmed of surrounding
    /// whitespace and then matched case-insensitively against the enum's raw
    /// values (`compact` against `true`/`false`). So `Fahrenheit`, `fahrenheit`
    /// and `" fahrenheit "` are the same request, and `"kelvin"` is still
    /// rejected. Anything looser would be guessing at the caller's intent;
    /// anything stricter would make a client that echoes a label back fail for
    /// no reason a user can see.
    public static func apply(key: String, value: String, to preferences: inout AppPreferences) throws {
        func invalid() -> MCPToolError {
            MCPToolError(message: "Invalid value '\(value)' for '\(key)'.")
        }
        switch key {
        case "compact":
            switch Self.normalized(value) {
            case "true": preferences.presentation.compact = true
            case "false": preferences.presentation.compact = false
            default: throw invalid()
            }
        case "cpuScale":
            guard let scale = Self.matching(CPUScale.self, value) else { throw invalid() }
            preferences.presentation.cpuScale = scale
        case "networkUnit":
            guard let unit = Self.matching(NetworkUnit.self, value) else { throw invalid() }
            preferences.presentation.networkUnit = unit
        case "temperatureSource":
            guard let source = Self.matching(TemperatureSource.self, value) else { throw invalid() }
            preferences.presentation.temperatureSource = source
        case "temperatureUnit":
            guard let unit = Self.matching(TemperatureUnit.self, value) else { throw invalid() }
            preferences.presentation.temperatureUnit = unit
        default:
            // Two kinds of key land here and they mean different things. A key nobody
            // may write at all is the allowlist refusal, quoting the executor's list so
            // a rejection can never name a key the executor would have let through, or
            // hide one it would have refused. `mcpMode` is the other: the executor
            // *does* let it through, because it is the MCP server's own policy rather
            // than a field of this blob, so refusing it here is what stops the on-demand
            // provider writing the server's mode into the app's preferences. Its own
            // validity is checked by `validate`, which is the question the confirmation
            // window asks; this one is "can this blob hold it?", and the answer is no.
            throw MCPToolError(
                message: "Preference '\(key)' cannot be changed via MCP. Allowed: "
                    + ToolExecutor.allowedPreferenceKeysDescription() + "."
            )
        }
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The case whose raw value matches, ignoring surrounding whitespace and case.
    /// Falls back to a scan because the enums' initializers are exact-match.
    private static func matching<Value: RawRepresentable & CaseIterable>(
        _ type: Value.Type, _ raw: String
    ) -> Value? where Value.RawValue == String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = Value(rawValue: trimmed) { return exact }
        return Value.allCases.first {
            $0.rawValue.caseInsensitiveCompare(trimmed) == .orderedSame
        }
    }
}
