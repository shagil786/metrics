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
    /// The preference keys MCP may change, and what each one accepts. Enum
    /// fields take their raw values only; `compact` is the one boolean.
    static let allowedKeys = ["compact", "cpuScale", "networkUnit", "temperatureSource", "temperatureUnit"]

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

    static func apply(key: String, value: String, to preferences: inout AppPreferences) throws {
        func invalid() -> MCPToolError {
            MCPToolError(message: "Invalid value '\(value)' for '\(key)'.")
        }
        switch key {
        case "compact":
            // Only the two literals the catalog documents. "yes" or "1" would be
            // a guess about the caller's intent.
            switch value.lowercased() {
            case "true": preferences.presentation.compact = true
            case "false": preferences.presentation.compact = false
            default: throw invalid()
            }
        case "cpuScale":
            guard let scale = CPUScale(rawValue: value) else { throw invalid() }
            preferences.presentation.cpuScale = scale
        case "networkUnit":
            guard let unit = NetworkUnit(rawValue: value) else { throw invalid() }
            preferences.presentation.networkUnit = unit
        case "temperatureSource":
            guard let source = TemperatureSource(rawValue: value) else { throw invalid() }
            preferences.presentation.temperatureSource = source
        case "temperatureUnit":
            guard let unit = TemperatureUnit(rawValue: value) else { throw invalid() }
            preferences.presentation.temperatureUnit = unit
        default:
            throw MCPToolError(
                message: "Preference '\(key)' cannot be changed via MCP. Allowed: "
                    + allowedKeys.joined(separator: ", ") + "."
            )
        }
    }
}
