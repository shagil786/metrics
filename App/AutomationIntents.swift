import AppIntents
import AppKit
import PortmasterCore

enum ReadingKind: String, AppEnum {
    case cpu, memoryPressure, memoryUsed, gpu, temperature, networkDown, networkUp, diskWrite
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Reading")
    static var caseDisplayRepresentations: [ReadingKind: DisplayRepresentation] = [
        .cpu: "CPU", .memoryPressure: "Memory pressure", .memoryUsed: "Memory used", .gpu: "GPU",
        .temperature: "Temperature", .networkDown: "Download", .networkUp: "Upload", .diskWrite: "Disk writes"
    ]
}

private enum AutomationReading {
    @MainActor static func freshModel() async throws -> AppModel {
        let model = AppModel.shared
        model.start(); model.engine.noteUserActivity()
        // Never return a frozen/empty launch snapshot as a current reading.
        for _ in 0..<150 {
            if model.snapshot.at != .distantPast, Date().timeIntervalSince(model.snapshot.at) < 15 { return model }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw NSError(domain: "Portmaster", code: 1, userInfo: [NSLocalizedDescriptionKey: "A current reading is not available. Open Portmaster and try again."])
    }
}

struct GetPortmasterReading: AppIntent {
    static var title: LocalizedStringResource = "Get a Portmaster Reading"
    static var description = IntentDescription("Returns a current local reading with its unit, or reports that it is unavailable. Preview data is labelled.")
    @Parameter(title: "Reading", default: .cpu) var reading: ReadingKind
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let model = try await AutomationReading.freshModel()
        let value = model.statusText(MenuBarMetric(rawValue: reading.rawValue) ?? .cpu)
        return .result(value: (model.prefs.fixtureMode ? "Preview: " : "") + (value == "—" ? "Unavailable" : value))
    }
}
struct GetPortmasterBusiestApp: AppIntent {
    static var title: LocalizedStringResource = "Get Portmaster's Busiest App"
    static var description = IntentDescription("Returns the current app group with the highest observed CPU, plus its CPU value. This is a current reading, not a historical ranking.")
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let model = try await AutomationReading.freshModel()
        let prefix = model.prefs.fixtureMode ? "Preview: " : ""
        guard let app = model.snapshot.rollups.filter({ $0.totalCPU.isFinite && $0.totalCPU > 0 }).max(by: { $0.totalCPU < $1.totalCPU }) else { return .result(value: prefix + "No CPU activity observed") }
        return .result(value: prefix + app.displayName + " · " + model.cpuText(app.totalCPU))
    }
}
struct OpenPortmasterWindow: AppIntent {
    static var title: LocalizedStringResource = "Open Portmaster"
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        AppDelegate.shared?.openMainWindow()
        return .result()
    }
}
struct ShowPortmasterDropdown: AppIntent {
    static var title: LocalizedStringResource = "Show Portmaster Dropdown"
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        guard let controller = AppDelegate.shared?.statusItems else {
            throw NSError(domain: "Portmaster", code: 2, userInfo: [NSLocalizedDescriptionKey: "The menu bar is not ready. Try again after Portmaster opens."])
        }
        controller.show()
        return .result()
    }
}
struct PortmasterShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: GetPortmasterReading(), phrases: ["Get a reading from \(.applicationName)"], shortTitle: "Get Reading", systemImageName: "gauge")
        AppShortcut(intent: GetPortmasterBusiestApp(), phrases: ["Get the busiest app in \(.applicationName)"], shortTitle: "Busiest App", systemImageName: "cpu")
        AppShortcut(intent: OpenPortmasterWindow(), phrases: ["Open \(.applicationName)"], shortTitle: "Open Portmaster", systemImageName: "macwindow")
        AppShortcut(intent: ShowPortmasterDropdown(), phrases: ["Show the \(.applicationName) dropdown"], shortTitle: "Show Dropdown", systemImageName: "menubar.rectangle")
    }
}
