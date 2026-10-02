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
    public var launchAtLogin: Bool
    public var fixtureMode: Bool
    /// Plain-language "acting up" notifications (sustained CPU, memory growth,
    /// disk/network hammering).
    public var alertsEnabled: Bool
    /// New installs see the welcome screen; legacy preferences skip it.
    public var hasCompletedOnboarding: Bool
    /// Show the regular app icon in the Dock (menu-bar-only when false).
    public var showInDock: Bool

    public init(
        menuBarMetric: MenuBarMetric = .cpu,
        cadence: SamplingCadence = .standard,
        retention: HistoryRetention = .hours24,
        launchAtLogin: Bool = false,
        fixtureMode: Bool = false,
        alertsEnabled: Bool = true,
        showInDock: Bool = false,
        hasCompletedOnboarding: Bool = false
    ) {
        self.presentation = PresentationPreferences(statusItems: [StatusReadout(metric: menuBarMetric)])
        self.menuBarMetric = menuBarMetric
        self.cadence = cadence
        self.retention = retention
        self.launchAtLogin = launchAtLogin
        self.fixtureMode = fixtureMode
        self.alertsEnabled = alertsEnabled
        self.showInDock = showInDock
        self.hasCompletedOnboarding = hasCompletedOnboarding
    }

    enum CodingKeys: String, CodingKey {
        case menuBarMetric, cadence, retention, launchAtLogin, fixtureMode, alertsEnabled, showInDock, presentation, hasCompletedOnboarding
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
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        fixtureMode = try c.decodeIfPresent(Bool.self, forKey: .fixtureMode) ?? false
        alertsEnabled = try c.decodeIfPresent(Bool.self, forKey: .alertsEnabled) ?? true
        hasCompletedOnboarding = try c.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? true
        showInDock = try c.decodeIfPresent(Bool.self, forKey: .showInDock) ?? false
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
