import XCTest
import PortmasterMCP

/// Exercises the full decision table: reads are always allowed, mutations are
/// default-deny and only `allowSession` can open them up.
final class PermissionGateTests: XCTestCase {

    // MARK: - Reads

    func testReadsAlwaysAllowedInEveryMode() {
        for mode in MCPMutationMode.allCases {
            for appRunning in [true, false] {
                let gate = PermissionGate(settings: MCPSettings(mode: mode), appRunning: appRunning)
                XCTAssertEqual(
                    gate.decide(isMutation: false),
                    .allow,
                    "reads must be allowed in \(mode) (appRunning: \(appRunning))"
                )
            }
        }
    }

    // MARK: - Mutations

    func testOffDeniesMutationsWithExactReason() {
        for appRunning in [true, false] {
            let gate = PermissionGate(settings: MCPSettings(mode: .off), appRunning: appRunning)
            XCTAssertEqual(
                gate.decide(isMutation: true),
                .deny(reason: "MCP mutations are disabled in Portmaster settings."),
                "off must deny mutations even when the app is running"
            )
        }
    }

    func testConfirmEachDeniesEvenWhenAppRunning() {
        let gate = PermissionGate(settings: MCPSettings(mode: .confirmEach), appRunning: true)
        XCTAssertEqual(
            gate.decide(isMutation: true),
            .deny(reason: "Portmaster must be open to approve this action.")
        )
    }

    func testAllowSessionAllowsWhenAppRunning() {
        let gate = PermissionGate(settings: MCPSettings(mode: .allowSession), appRunning: true)
        XCTAssertEqual(gate.decide(isMutation: true), .allow)
    }

    func testAllowSessionDeniesWhenAppClosed() {
        let gate = PermissionGate(settings: MCPSettings(mode: .allowSession), appRunning: false)
        XCTAssertEqual(
            gate.decide(isMutation: true),
            .deny(reason: "Session grants apply only while Portmaster is running.")
        )
    }
}
