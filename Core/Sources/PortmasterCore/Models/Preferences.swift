// Settings and history models shared across app and core.
import Foundation

/// Which value the menu bar shows.
public enum MenuBarMetric: String, CaseIterable, Sendable, Identifiable, Codable {
    case cpu
    case memoryPressure
    case topProcessCPU
    case temperature
    case memoryUsed, gpu, networkDown, networkUp, diskWrite

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .cpu: "CPU %"
        case .memoryPressure: "Memory pressure"
        case .topProcessCPU: "Top process CPU"
        case .temperature: "Temperature"
        case .memoryUsed: "Memory used"
        case .gpu: "GPU %"
        case .networkDown: "Download"
        case .networkUp: "Upload"
        case .diskWrite: "Disk writes"
        }
    }
}

public enum SamplingCadence: String, CaseIterable, Sendable, Identifiable, Codable {
    case brisk    // 2 s live / 15 s background
    case standard // 3 s live / 30 s background
    case gentle   // 5 s live / 60 s background

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .brisk: "Brisk (2 s)"
        case .standard: "Standard (3 s)"
        case .gentle: "Gentle (5 s)"
        }
    }

    public var liveInterval: TimeInterval {
        switch self {
        case .brisk: 2
        case .standard: 3
        case .gentle: 5
        }
    }

    public var backgroundInterval: TimeInterval {
        switch self {
        case .brisk: 15
        case .standard: 30
        case .gentle: 60
        }
    }
}

public enum HistoryRetention: String, CaseIterable, Sendable, Identifiable, Codable {
    case hours24
    case days3
    case days7
    case days30

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .hours24: "24 hours"
        case .days3: "3 days"
        case .days7: "7 days"
        case .days30: "30 days"
        }
    }

    public var seconds: TimeInterval {
        switch self {
        case .hours24: 24 * 3600
        case .days3: 3 * 86400
        case .days7: 7 * 86400
        case .days30: 30 * 86400
        }
    }
}

/// How long agent sessions and their token usage are kept.
///
/// **Not `HistoryRetention`, and not the same setting.** A sample is a reading and a
/// session is spend: it holds token counts and the model ids they were billed under,
/// and `HistoryRetention`'s floor is 24 hours. A user who wants a day of CPU history
/// would lose agent spend irrecoverably on a schedule chosen for a different purpose,
/// so the two are set and stated separately, and the floor here is 30 days.
///
/// Nil seconds for `.keepForever` rather than a very large number: keeping everything
/// is not a long window, and giving it one would put an expiry on a setting that has
/// none. `AppPreferences.agentSessionRetention` being nil — never chosen, or not
/// readable — keeps everything too, for the same reason.
public enum AgentSessionRetention: String, CaseIterable, Sendable, Identifiable, Codable {
    case days30
    case days90
    case days365
    case keepForever

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .days30: "30 days"
        case .days90: "90 days"
        case .days365: "1 year"
        case .keepForever: "Forever"
        }
    }

    /// Nil when nothing is ever deleted, which is a different thing from "a long time".
    public var seconds: TimeInterval? {
        switch self {
        case .days30: 30 * 86400
        case .days90: 90 * 86400
        case .days365: 365 * 86400
        case .keepForever: nil
        }
    }

    /// The shortest period on offer. Also the value a caller must never fall back to
    /// for a setting it could not read: guessing the floor here would delete spend on
    /// a schedule nobody chose.
    public static let floor: AgentSessionRetention = .days30
}

/// Viewing ranges are independent from retention: choosing 1h must not delete older data.
public enum HistoryRange: String, CaseIterable, Sendable, Identifiable {
    case hour1, hours12, hours24, days7, days30
    public var id: String { rawValue }
    public var label: String {
        switch self { case .hour1: "1 hour"; case .hours12: "12 hours"; case .hours24: "24 hours"; case .days7: "7 days"; case .days30: "30 days" }
    }
    public var seconds: TimeInterval {
        switch self { case .hour1: 3600; case .hours12: 43200; case .hours24: 86400; case .days7: 604800; case .days30: 2592000 }
    }
}

/// User preferences, persisted in the app's standard UserDefaults domain.
public struct AppPreferences: Sendable, Codable {
    public var presentation: PresentationPreferences
    public var menuBarMetric: MenuBarMetric
    public var cadence: SamplingCadence
    public var retention: HistoryRetention
    /// How long agent sessions are kept. **Nil is a value**: never chosen, or not
    /// readable, and it keeps everything rather than falling back to the floor. A
    /// preference that cannot be read must not turn into a deletion schedule.
    public var agentSessionRetention: AgentSessionRetention?
    public var launchAtLogin: Bool
    public var fixtureMode: Bool
    /// Plain-language "acting up" notifications (sustained CPU, memory growth,
    /// disk/network hammering).
    public var alertsEnabled: Bool
    /// New installs see the welcome screen; legacy preferences skip it.
    public var hasCompletedOnboarding: Bool
    /// Show the regular app icon in the Dock (menu-bar-only when false).
    public var showInDock: Bool
    /// Whether a pressured session may hand off to another agent at all — the
    /// spec's kill switch (§5): an off switch that stops the feature without
    /// touching permissions. Default on: the permission mode is the real gate
    /// (handoffs still require `allowSession`), so this is the big red button,
    /// not the lock.
    public var contextHandoffsEnabled: Bool

    public init(
        menuBarMetric: MenuBarMetric = .cpu,
        cadence: SamplingCadence = .standard,
        retention: HistoryRetention = .hours24,
        agentSessionRetention: AgentSessionRetention? = nil,
        launchAtLogin: Bool = false,
        fixtureMode: Bool = false,
        alertsEnabled: Bool = true,
        showInDock: Bool = false,
        hasCompletedOnboarding: Bool = false,
        contextHandoffsEnabled: Bool = true
    ) {
        self.presentation = PresentationPreferences(statusItems: [StatusReadout(metric: menuBarMetric)])
        self.menuBarMetric = menuBarMetric
        self.cadence = cadence
        self.retention = retention
        self.agentSessionRetention = agentSessionRetention
        self.launchAtLogin = launchAtLogin
        self.fixtureMode = fixtureMode
        self.alertsEnabled = alertsEnabled
        self.showInDock = showInDock
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.contextHandoffsEnabled = contextHandoffsEnabled
    }

    enum CodingKeys: String, CodingKey {
        case menuBarMetric, cadence, retention, agentSessionRetention, launchAtLogin, fixtureMode, alertsEnabled, showInDock, presentation, hasCompletedOnboarding, contextHandoffsEnabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // decodeIfPresent everywhere: preferences saved by an older build
        // must never crash a newer one.
        menuBarMetric = try c.decodeIfPresent(MenuBarMetric.self, forKey: .menuBarMetric) ?? .cpu
        presentation = try c.decodeIfPresent(PresentationPreferences.self, forKey: .presentation)
            ?? PresentationPreferences(statusItems: [StatusReadout(metric: menuBarMetric)])
        presentation.statusItems = presentation.effectiveStatusItems
        cadence = try c.decodeIfPresent(SamplingCadence.self, forKey: .cadence) ?? .standard
        retention = try c.decodeIfPresent(HistoryRetention.self, forKey: .retention) ?? .hours24
        // No `?? .floor`: a build that never wrote this key keeps every session rather
        // than deleting spend for 30 days because a preference was unreadable.
        //
        // `try?` as well as `decodeIfPresent`, and that is not belt-and-braces:
        // `decodeIfPresent` **throws** for a present-but-invalid value, so a raw value
        // this build does not know would fail the decode of every other preference in
        // the blob and reset the lot — including this one, to the floor, by a longer
        // route than the one being guarded against. Unreadable here means absent, and
        // absent keeps everything.
        agentSessionRetention = (try? c.decodeIfPresent(
            AgentSessionRetention.self, forKey: .agentSessionRetention
        )) ?? nil
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        fixtureMode = try c.decodeIfPresent(Bool.self, forKey: .fixtureMode) ?? false
        alertsEnabled = try c.decodeIfPresent(Bool.self, forKey: .alertsEnabled) ?? true
        hasCompletedOnboarding = try c.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? true
        showInDock = try c.decodeIfPresent(Bool.self, forKey: .showInDock) ?? false
        // `try?` for the same reason as `agentSessionRetention` above: a build
        // that wrote a non-Bool here must not fail the decode of the whole blob
        // (and reset every other preference) — an unreadable switch reads as
        // absent, and absent means on.
        contextHandoffsEnabled = (try? c.decodeIfPresent(
            Bool.self, forKey: .contextHandoffsEnabled
        )) ?? true
    }

    // MARK: UserDefaults bridging

    public static let defaultsKey = "PortmasterPreferences"

    public static func load(from defaults: UserDefaults = .standard) -> AppPreferences {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(AppPreferences.self, from: data)
        else { return AppPreferences() }
        return decoded
    }

    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

// MARK: - History rows persisted with SwiftData

import SwiftData

@Model
public final class CPUSample {
    public var at: Date
    public var totalPercent: Double
    public var userPercent: Double
    public var systemPercent: Double

    public init(at: Date, totalPercent: Double, userPercent: Double, systemPercent: Double) {
        self.at = at
        self.totalPercent = totalPercent
        self.userPercent = userPercent
        self.systemPercent = systemPercent
    }
}

@Model
public final class MemSample {
    public var at: Date
    public var usedBytes: Int64
    public var totalBytes: Int64
    /// 0...1, may exceed 1 briefly under heavy swap.
    public var pressureRatio: Double
    public var swapBytes: Int64

    public init(at: Date, usedBytes: Int64, totalBytes: Int64, pressureRatio: Double, swapBytes: Int64) {
        self.at = at
        self.usedBytes = usedBytes
        self.totalBytes = totalBytes
        self.pressureRatio = pressureRatio
        self.swapBytes = swapBytes
    }
}

/// Per-pid point-in-time metrics, enabling per-app/project history.
@Model
public final class ProcessPoint {
    public var at: Date
    public var pid: Int32
    public var name: String
    public var cpuPercent: Double
    public var memoryBytes: Int64
    /// Project ID when attributed, else nil.
    public var projectID: String?
    public var isService: Bool

    public init(
        at: Date, pid: Int32, name: String, cpuPercent: Double,
        memoryBytes: Int64, projectID: String?, isService: Bool
    ) {
        self.at = at
        self.pid = pid
        self.name = name
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.projectID = projectID
        self.isService = isService
    }
}

/// Port binding events for the Projects & Ports timeline.
@Model
public final class PortEvent {
    public var at: Date
    public var port: Int
    public var pid: Int32
    public var processName: String
    public var projectID: String?
    public var kind: String // "bound" | "released"

    public init(
        at: Date, port: Int, pid: Int32, processName: String,
        projectID: String?, kind: String
    ) {
        self.at = at
        self.port = port
        self.pid = pid
        self.processName = processName
        self.projectID = projectID
        self.kind = kind
    }
}
