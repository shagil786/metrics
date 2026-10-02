// AppBreakdown: semantic groups inside one app's process tree — the
// "what's inside Chrome" view. Browsers expose their anatomy through
// process naming conventions (Renderer/GPU/Plugin helpers, WebKit
// content processes); everything else falls back to Main/Helpers/Other.
// Pure categorization over an AppRollup, no UI, fully testable.
import Foundation

public struct AppBreakdownGroup: Identifiable, Hashable, Sendable {
    /// Stable category key, e.g. "tabs" — the UI keys icons/footnotes off it.
    public let id: String
    /// Display label, e.g. "Tabs".
    public let label: String
    public let processes: [ProcessRow]
    public let memoryBytes: UInt64
    public let cpuPercent: Double
    public var count: Int { processes.count }

    public init(id: String, label: String, processes: [ProcessRow]) {
        self.id = id
        self.label = label
        self.processes = processes
        self.memoryBytes = processes.reduce(0) { $0 + ($1.memoryBytes ?? 0) }
        self.cpuPercent = processes.reduce(0) { $0 + ($1.cpuPercent ?? 0) }
    }

    /// Average per-process footprint for the "N processes · X each" line.
    public var averageMemoryBytes: UInt64 {
        count == 0 ? 0 : memoryBytes / UInt64(count)
    }
}

public enum AppBreakdown {
    /// Chromium-family helper tags and WebKit service names, used to give
    /// browsers their real anatomy (Tabs / GPU / Extensions / Browser).
    static let browserNames: Set<String> = [
        "google chrome", "chrome", "chromium", "microsoft edge", "edge",
        "brave browser", "brave", "vivaldi", "opera", "arc", "safari",
    ]

    public static func build(for rollup: AppRollup) -> [AppBreakdownGroup] {
        let appLower = rollup.displayName.lowercased()
        let isBrowser = browserNames.contains(appLower)

        var buckets: [Category: [ProcessRow]] = [:]
        for row in rollup.processes {
            let category = categorize(
                name: row.displayName.lowercased(),
                appName: appLower,
                isBrowser: isBrowser
            )
            buckets[category, default: []].append(row)
        }

        let groups = Category.ordered.compactMap { category -> AppBreakdownGroup? in
            guard let rows = buckets[category], !rows.isEmpty else { return nil }
            return AppBreakdownGroup(
                id: category.id, label: category.label(isBrowser: isBrowser), processes: rows
            )
        }
        // The headline group should lead: biggest memory first, matching the
        // reference layout ("Tabs use 82% of its memory" when tabs dominate).
        return groups.sorted { $0.memoryBytes > $1.memoryBytes }
    }

    enum Category: CaseIterable {
        case tabs, gpu, extensions, network, browser, engine, main, other

        /// Display order before memory sorting (never shown verbatim).
        static let ordered: [Category] = [
            .tabs, .gpu, .extensions, .network, .browser, .engine, .main, .other,
        ]

        var id: String {
            switch self {
            case .tabs: "tabs"
            case .gpu: "gpu"
            case .extensions: "extensions"
            case .network: "network"
            case .browser: "browser"
            case .engine: "engine"
            case .main: "main"
            case .other: "other"
            }
        }

        func label(isBrowser: Bool) -> String {
            switch self {
            case .tabs: isBrowser ? "Tabs" : "Renderer Processes"
            case .gpu: "GPU"
            case .extensions: isBrowser ? "Extensions" : "Plug-ins"
            case .network: "Network"
            case .browser: "Browser"
            case .engine: "Engine (Linux VM)"
            case .main: isBrowser ? "Browser" : "Main Process"
            case .other: "Other Processes"
            }
        }
    }

    /// Categorize one member process. Chromium helpers are tagged with
    /// "(Renderer)"/"(GPU)"/"(Plugin)"/"(Utility)"; Safari's WebKit support
    /// processes are com.apple.WebKit.*; Docker's engine hides behind
    /// com.docker.backend. Everything else: main vs. helpers vs. other.
    static func categorize(name: String, appName: String, isBrowser: Bool) -> Category {
        if name.contains("(renderer)") || name.contains("webcontent") {
            return .tabs
        }
        if name.contains("(gpu)") || name.contains("webkit.gpu") {
            return .gpu
        }
        if name.contains("(plugin)") || name.contains("(extension)") {
            return .extensions
        }
        if name.contains("webkit.networking") {
            return .network
        }
        if name.contains("com.docker.backend") || name.contains("docker.backend") {
            return .engine
        }
        if isBrowser && (name == appName || name == "firefox") {
            return .browser
        }
        if !isBrowser && name == appName {
            return .main
        }
        return .other
    }
}
