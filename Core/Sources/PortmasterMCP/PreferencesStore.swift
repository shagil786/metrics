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
final class PreferencesStore: @unchecked Sendable {
    /// Every preference key MCP may change, as `ToolExecutor`'s catalog lists
    /// them — the message below quotes this, so a client that guessed a key
    /// learns what it may try instead. `mcpMode` is in the list because the
    /// provider accepts it, but it is written to `MCPSettings` and never reaches
    /// the blob writer below.
    static let mcpAllowedKeys = [
        "compact", "cpuScale", "mcpMode", "networkUnit", "temperatureSource", "temperatureUnit",
    ]

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

    /// Applies one allowlisted value.
    ///
    /// **How values are read, in one place:** a value is trimmed of surrounding
    /// whitespace and then matched case-insensitively against the enum's raw
    /// values (`compact` against `true`/`false`). So `Fahrenheit`, `fahrenheit`
    /// and `" fahrenheit "` are the same request, and `"kelvin"` is still
    /// rejected. Anything looser would be guessing at the caller's intent;
    /// anything stricter would make a client that echoes a label back fail for
    /// no reason a user can see.
    static func apply(key: String, value: String, to preferences: inout AppPreferences) throws {
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
            throw MCPToolError(
                message: "Preference '\(key)' cannot be changed via MCP. Allowed: "
                    + mcpAllowedKeys.joined(separator: ", ") + "."
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
