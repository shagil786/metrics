// AppPreferencesHandoffTests: the kill switch for context handoffs.
//
// The switch is the feature's big red button (spec §5): it stops every handoff
// path without touching permissions, and it must default to on because the
// permission mode is the real gate. A switch that shipped off would leave the
// feature looking broken to every user who never touched settings.

import XCTest
import Foundation
@testable import PortmasterCore

final class AppPreferencesHandoffTests: XCTestCase {

    func testHandoffsAreOnWhenTheKeyWasNeverWritten() throws {
        let defaults = UserDefaults(suiteName: "prefs-\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaults.dictionaryRepresentation().keys.first ?? "") }
        let decoded = AppPreferences.load(from: defaults)
        XCTAssertTrue(decoded.contextHandoffsEnabled,
                      "the kill switch exists to be turned off, so its default is on")
    }

    func testTheKillSwitchSurvivesARoundTrip() throws {
        let defaults = UserDefaults(suiteName: "prefs-\(UUID().uuidString)")!
        var prefs = AppPreferences()
        prefs.contextHandoffsEnabled = false
        prefs.save(to: defaults)
        XCTAssertFalse(AppPreferences.load(from: defaults).contextHandoffsEnabled)
    }

    func testAnUnknownNewerValueDoesNotResetTheOtherPreferences() throws {
        // A blob written by a future build where the key is a string: the
        // decode must survive the way every other preference does.
        let defaults = UserDefaults(suiteName: "prefs-\(UUID().uuidString)")!
        var prefs = AppPreferences()
        prefs.alertsEnabled = false
        prefs.save(to: defaults)
        var data = try XCTUnwrap(defaults.data(forKey: AppPreferences.defaultsKey))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["contextHandoffsEnabled"] = "on"  // wrong type for this build
        data = try JSONSerialization.data(withJSONObject: json)
        defaults.set(data, forKey: AppPreferences.defaultsKey)
        let decoded = AppPreferences.load(from: defaults)
        XCTAssertFalse(decoded.alertsEnabled, "the rest of the blob still decodes")
        XCTAssertTrue(decoded.contextHandoffsEnabled,
                      "an unreadable value reads as absent, and absent means the switch stays on")
    }
}
