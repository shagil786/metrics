import XCTest
@testable import PortmasterCore

final class PresentationTests: XCTestCase {
    func testOldPreferencesKeepSelectedStatusMetric() throws {
        let preferences = try JSONDecoder().decode(AppPreferences.self, from: Data(#"{"menuBarMetric":"temperature","showInDock":true}"#.utf8))
        XCTAssertEqual(preferences.presentation.effectiveStatusItems.map(\.metric), [.temperature])
        XCTAssertTrue(preferences.showInDock)
        XCTAssertEqual(preferences.presentation.cpuScale, .perCore)
        XCTAssertEqual(preferences.presentation.temperatureUnit, .celsius)
        XCTAssertFalse(preferences.presentation.windowShortcut.enabled)
    }
    func testEmptyLegacyPreferencesGetSafeDefaults() throws {
        let preferences = try JSONDecoder().decode(AppPreferences.self, from: Data("{}".utf8))
        XCTAssertEqual(preferences.presentation.effectiveStatusItems.map(\.metric), [.cpu])
        XCTAssertFalse(preferences.fixtureMode)
    }
    func testPartialPresentationKeepsExistingPreferencesAndAddsDefaults() throws {
        let preferences = try JSONDecoder().decode(AppPreferences.self, from: Data(#"{"showInDock":true,"presentation":{"networkUnit":"bits","statusItems":[]}}"#.utf8))
        XCTAssertTrue(preferences.showInDock)
        XCTAssertEqual(preferences.presentation.networkUnit, .bits)
        XCTAssertEqual(preferences.presentation.statusItems.map(\.metric), [.cpu])
        XCTAssertEqual(preferences.presentation.panelTiles, LayoutOrder())
        XCTAssertFalse(preferences.presentation.windowShortcut.enabled)
    }
    func testPresentationRoundTripKeepsIndependentLayoutsAndUnits() throws {
        var preferences = AppPreferences()
        preferences.presentation.networkUnit = .bits
        preferences.presentation.temperatureUnit = .fahrenheit
        preferences.presentation.cpuScale = .perMac
        preferences.presentation.windowTabs = LayoutOrder(order: ["audio", "cpu"], hidden: ["gpu"])
        preferences.presentation.panelTabs = LayoutOrder(order: ["sensors", "overview"])
        preferences.presentation.panelTiles = LayoutOrder(order: ["disk", "cpu"])
        preferences.presentation.sections["cpu"] = LayoutOrder(order: ["apps", "hero", "stats"], hidden: ["stats"])
        preferences.presentation.statusItems = [StatusReadout(metric: .networkUp, style: .both, icon: true, caption: true)]
        let copy = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(copy.presentation.windowTabs, preferences.presentation.windowTabs)
        XCTAssertEqual(copy.presentation.panelTabs, preferences.presentation.panelTabs)
        XCTAssertEqual(copy.presentation.panelTiles, preferences.presentation.panelTiles)
        XCTAssertEqual(copy.presentation.sections["cpu"]?.visible(["hero", "stats", "apps"]), ["apps", "hero"])
        XCTAssertEqual(copy.presentation.statusItems, preferences.presentation.statusItems)
        XCTAssertEqual(copy.presentation.networkUnit, .bits)
        XCTAssertEqual(copy.presentation.temperatureUnit, .fahrenheit)
        XCTAssertEqual(copy.presentation.cpuScale, .perMac)
    }
    func testOrderDropsObsoleteItemsAndDuplicatesButIncludesNewTabs() {
        let layout = LayoutOrder(order: ["removed", "b", "b", "a"], hidden: ["a"])
        XCTAssertEqual(layout.resolved(["a", "b", "new"]), ["b", "a", "new"])
        XCTAssertEqual(layout.visible(["a", "b", "new"]), ["b", "new"])
    }
    func testAllHiddenStillLeavesAnEntryPoint() {
        let layout = LayoutOrder(order: ["b", "a"], hidden: ["a", "b"])
        XCTAssertEqual(layout.visible(["a", "b"]), ["b"])
        XCTAssertEqual(layout.visible(["a", "b"], keepOne: false), [])
    }
    func testStatusReadoutsDeduplicateAndAlwaysHaveFallback() {
        let options = PresentationPreferences(statusItems: [StatusReadout(metric: .cpu, style: .graph), StatusReadout(metric: .cpu), StatusReadout(metric: .networkDown)])
        XCTAssertEqual(options.effectiveStatusItems.map(\.metric), [.cpu, .networkDown])
        XCTAssertEqual(options.effectiveStatusItems.first?.style, .graph)
        XCTAssertEqual(PresentationPreferences(statusItems: []).effectiveStatusItems.map(\.metric), [.cpu])
    }
    func testTemperatureConversionsAndUnknowns() {
        XCTAssertEqual(DisplayUnits.temperature(0, unit: .fahrenheit), "32°F")
        XCTAssertEqual(DisplayUnits.temperature(40, unit: .fahrenheit), "104°F")
        XCTAssertEqual(DisplayUnits.temperature(-40, unit: .celsius, decimals: 1), "-40.0°C")
        XCTAssertEqual(DisplayUnits.temperature(nil, unit: .fahrenheit), "—")
        XCTAssertEqual(DisplayUnits.temperature(.nan, unit: .celsius), "—")
    }
    func testCPUScaleUsesActualCoreCountWithoutChangingInput() {
        let reading = 250.0
        XCTAssertEqual(DisplayUnits.processCPU(reading, scale: .perMac, cores: 10), 25)
        XCTAssertEqual(DisplayUnits.processCPU(reading, scale: .perCore, cores: 10), 250)
        XCTAssertNil(DisplayUnits.processCPU(reading, scale: .perMac, cores: 0))
        XCTAssertNil(DisplayUnits.processCPU(.infinity, scale: .perCore, cores: 10))
        XCTAssertNil(DisplayUnits.processCPU(nil, scale: .perCore, cores: 10))
        XCTAssertEqual(reading, 250)
    }
    func testNetworkUnitsDistinguishBitsFromBytes() {
        let bits = DisplayUnits.networkParts(1_000_000, unit: .bits)
        XCTAssertEqual(bits.value, "8.0"); XCTAssertEqual(bits.unit, "Mbit/s")
        let bytes = DisplayUnits.networkParts(1_048_576, unit: .bytes)
        XCTAssertEqual(bytes.unit, "MB/s")
        XCTAssertEqual(DisplayUnits.networkParts(.nan, unit: .bits).value, "—")
        XCTAssertEqual(DisplayUnits.networkParts(-1, unit: .bytes).value, "—")
        XCTAssertEqual(DisplayUnits.networkParts(0, unit: .bits).value, "0")
    }
    func testGlobalShortcutsRequireModifierAndKnownKey() {
        XCTAssertTrue(KeyboardShortcutPreference().valid)
        XCTAssertTrue(KeyboardShortcutPreference(key: "P").valid)
        XCTAssertEqual(KeyboardShortcutPreference(key: "P").label, "⌥⌘P")
        XCTAssertFalse(KeyboardShortcutPreference(key: "P", command: false, option: false).valid)
        XCTAssertFalse(KeyboardShortcutPreference(key: "Escape").valid)
    }
}
