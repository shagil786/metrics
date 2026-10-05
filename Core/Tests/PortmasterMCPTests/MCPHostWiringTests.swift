// MCPHostWiringTests: the wiring decisions the app makes, in the library.
//
// `App/MCPHostController.swift` has no test target — the app scheme builds and
// nothing runs — so the parts of it that are decisions rather than glue are
// library types with tests here: `HostMCPCallContext`, which is what turns the
// mutation mode and a person's answer into an action or a refusal, and the
// `MCPToolError` the app's snapshot closure must throw when its sampler has
// published nothing.
//
// Nothing here touches a window, a socket or the machine. The provider is the
// shared `StubProvider`, the settings file and the audit log are in a temp
// directory, and the "person" is a closure — which is the whole of what the
// controller injects.
import Foundation
import PortmasterCore
@testable import PortmasterMCP
import XCTest

final class MCPHostWiringTests: XCTestCase {

    // MARK: - A confirmed mutation

    /// The outcome that matters most and is the easiest to get wrong: a person
    /// said yes, so the action is performed and the audit log says it was
    /// allowed. Three things have to be true at once — the confirmation was
    /// asked, the approval reached the executor rather than being refused a
    /// second time by the gate, and the mutation actually happened.
    func testAnApprovedMutationIsPerformedAndAuditedAllowed() async throws {
        let provider = StubProvider()
        provider.stopReport = StopReport(results: ["4321": "stopped"])
        let directory = try makeTemporaryDirectory(prefix: "pmwiring")
        let broker = ConfirmationBroker(timeout: 5)
        let presented = RecordingPresenter()
        let context = makeContext(
            provider: provider, broker: broker, directory: directory,
            mode: .confirmEach, present: { request in
                presented.record(request)
                Task { await broker.decide(id: request.id, outcome: .approved) }
            }
        )

        let outcome = await context.call(
            name: "quit_app", arguments: ["id": "app:Chrome", "force": "true"]
        )

        XCTAssertFalse(outcome.isError, outcome.text)
        XCTAssertEqual(provider.quitAppCallCount, 1, "an approved mutation must be performed")
        XCTAssertEqual(provider.lastQuitAppID, "app:Chrome")
        XCTAssertEqual(provider.lastQuitAppForce, true)
        XCTAssertEqual(presented.requests.count, 1, "a confirmed mutation is asked about exactly once")
        let request = try XCTUnwrap(presented.requests.first)
        XCTAssertEqual(request.kind, .quitApp)
        XCTAssertEqual(
            request.summary, "Quit app:Chrome?",
            "the summary is what a person reads, so it is pinned"
        )
        XCTAssertTrue(
            request.detail.contains("app:Chrome"),
            "the detail must name what is being acted on: \(request.detail)"
        )
        XCTAssertEqual(
            try auditOutcomes(directory), ["allowed"],
            "the only audit line for an approved mutation is the one the executor wrote"
        )
    }

    // MARK: - A refused confirmation

    /// A person said no: no provider call at all, a refusal the model can read,
    /// and one `denied` line saying why. That line is written by the *host*,
    /// because the refusal happens before the executor sees the call — so the
    /// audit vocabulary has to be checked here rather than assumed.
    func testADeniedConfirmationIsRefusedAndAuditedDenied() async throws {
        let provider = StubProvider()
        let directory = try makeTemporaryDirectory(prefix: "pmwiring")
        let broker = ConfirmationBroker(timeout: 5)
        let context = makeContext(
            provider: provider, broker: broker, directory: directory,
            mode: .confirmEach, present: { request in
                Task {
                    await broker.decide(
                        id: request.id, outcome: .denied(reason: "Not this time.")
                    )
                }
            }
        )

        let outcome = await context.call(name: "stop_project", arguments: ["id": "/src/api"])

        XCTAssertTrue(outcome.isError)
        XCTAssertEqual(outcome.text, "Not this time.", "the reason reaches the caller verbatim")
        XCTAssertEqual(provider.stopProjectCallCount, 0, "a refusal must not perform the action")
        let entry = try XCTUnwrap(try auditEntries(directory).first)
        XCTAssertEqual(entry["outcome"] as? String, "denied")
        XCTAssertEqual(entry["reason"] as? String, "Not this time.")
        XCTAssertEqual(entry["tool"] as? String, "stop_project")
    }

    /// Silence is a refusal. A confirmation nobody answers must end at the
    /// broker's own budget — never as a performed action, and never as a hang —
    /// and it is audited as the denial it is.
    func testAConfirmationNobodyAnswersIsRefusedAtItsBudgetAndAuditedDenied() async throws {
        let provider = StubProvider()
        let directory = try makeTemporaryDirectory(prefix: "pmwiring")
        // A short budget rather than the production 60 seconds, so the test
        // cannot pass by sleeping through the real one.
        let broker = ConfirmationBroker(timeout: 0.2)
        let context = makeContext(
            provider: provider, broker: broker, directory: directory,
            mode: .confirmEach, present: { _ in }  // a window that never opens
        )

        let outcome = await context.call(
            name: "stop_container", arguments: ["id": "abc123"]
        )

        XCTAssertTrue(outcome.isError)
        XCTAssertEqual(outcome.text, HostMCPCallContext.confirmationTimedOutMessage)
        XCTAssertEqual(provider.stopContainerCallCount, 0)
        XCTAssertEqual(try auditOutcomes(directory), ["denied"])
    }

    /// The request a person is shown has to name the exact thing being acted on.
    /// One summary per kind, built from the arguments the executor validated — a
    /// prompt that says "approve?" about an unidentified request is a prompt
    /// nobody can answer honestly.
    func testEveryMutationKindAsksWithItsOwnWords() async throws {
        let broker = ConfirmationBroker(timeout: 5)
        let presented = RecordingPresenter()
        let directory = try makeTemporaryDirectory(prefix: "pmwiring")
        let context = makeContext(
            provider: StubProvider(), broker: broker, directory: directory,
            mode: .confirmEach, present: { request in
                presented.record(request)
                Task { await broker.decide(id: request.id, outcome: .approved) }
            }
        )

        let calls: [(String, [String: String])] = [
            ("quit_app", ["id": "app:Chrome"]),
            ("stop_container", ["id": "web"]),
            ("stop_project", ["id": "/src/api"]),
            ("set_preference", ["key": "temperatureUnit", "value": "celsius"]),
        ]
        for (name, arguments) in calls {
            _ = await context.call(name: name, arguments: arguments)
        }

        XCTAssertEqual(
            presented.requests.map(\.kind),
            [.quitApp, .stopContainer, .stopProject, .setPreference],
            "each mutation is asked about as its own kind of change"
        )
        XCTAssertEqual(
            presented.requests.map(\.summary),
            [
                "Quit app:Chrome?",
                "Stop container web?",
                "Stop project /src/api?",
                "Change temperatureUnit to celsius?",
            ]
        )
        let preference = try XCTUnwrap(presented.requests.last)
        XCTAssertTrue(
            preference.detail.contains("temperatureUnit"),
            "a preference change must name the key: \(preference.detail)"
        )
        XCTAssertTrue(
            preference.detail.contains("celsius"),
            "a preference change must name the value: \(preference.detail)"
        )
    }

    /// A read is never a question. Only the catalog's `effect` decides that, and
    /// a caller cannot talk its way around it by asking to be treated otherwise.
    func testReadsAreNeverPutToAPerson() async throws {
        let broker = ConfirmationBroker(timeout: 5)
        let presented = RecordingPresenter()
        let directory = try makeTemporaryDirectory(prefix: "pmwiring")
        let context = makeContext(
            provider: StubProvider(), broker: broker, directory: directory,
            mode: .confirmEach, present: { request in
                presented.record(request)
                Task { await broker.decide(id: request.id, outcome: .approved) }
            }
        )

        let outcome = await context.call(name: "get_system_overview", arguments: [:])

        XCTAssertFalse(outcome.isError, outcome.text)
        XCTAssertTrue(presented.requests.isEmpty, "a read needs nobody's permission")
        let remaining = await broker.queuedCount
        XCTAssertEqual(remaining, 0, "and must leave nothing waiting on a person")
    }

    // MARK: - Liveness

    /// `allowSession` is a grant that lasts while Portmaster is running, and it
    /// is the same `PermissionGate` that enforces it — the host does not get its
    /// own looser rule for being the app.
    func testSessionGrantsStillFollowLiveness() async throws {
        let provider = StubProvider()
        let directory = try makeTemporaryDirectory(prefix: "pmwiring")
        let context = makeContext(
            provider: provider, broker: ConfirmationBroker(timeout: 5), directory: directory,
            mode: .allowSession, appRunning: { false }
        )

        let outcome = await context.call(name: "quit_app", arguments: ["id": "app:Chrome"])

        XCTAssertTrue(outcome.isError)
        XCTAssertEqual(outcome.text, "Session grants apply only while Portmaster is running.")
        XCTAssertEqual(provider.quitAppCallCount, 0)
        XCTAssertEqual(try auditOutcomes(directory), ["denied"])
    }

    // MARK: - The mutation mode is the server's own

    /// The mode is read per call, so changing it takes effect without restarting
    /// anything — and it is read from the *server's* settings file, which is the
    /// only place it lives. A host built over `.confirmEach` and then handed a
    /// file saying `.off` must stop asking people, which is only true if the file
    /// is re-read rather than captured.
    func testTheMutationModeIsRereadFromTheServersOwnFileOnEveryCall() async throws {
        let directory = try makeTemporaryDirectory(prefix: "pmwiring")
        try MCPSettings(mode: .confirmEach).save(directory: directory)
        let broker = ConfirmationBroker(timeout: 5)
        let presented = RecordingPresenter()
        let provider = StubProvider()
        let context = makeContext(
            provider: provider, broker: broker, directory: directory,
            mode: nil,  // read the file, as the host does
            present: { request in
                presented.record(request)
                Task { await broker.decide(id: request.id, outcome: .approved) }
            }
        )

        let confirmed = await context.call(name: "quit_app", arguments: ["id": "app:Chrome"])
        XCTAssertFalse(confirmed.isError, confirmed.text)
        XCTAssertEqual(presented.requests.count, 1, ".confirmEach asks")

        // The user's other surface changes the mode.
        try MCPSettings(mode: .off).save(directory: directory)
        let nowOff = await context.call(name: "quit_app", arguments: ["id": "app:Chrome"])
        XCTAssertTrue(nowOff.isError)
        XCTAssertEqual(nowOff.text, "MCP mutations are disabled in Portmaster settings.")
        XCTAssertEqual(presented.requests.count, 1, ".off asks nobody")
        XCTAssertEqual(provider.quitAppCallCount, 1, "and performs nothing")
    }

    /// `mcpMode` never reaches the provider: the executor owns that key end to
    /// end, because it is the MCP server's policy rather than an app preference.
    /// The round trip is asserted in both directions — the tool call writes the
    /// file the host reads, and `get_settings` reports what is in that file and
    /// not what the app's preferences would say.
    func testTheMutationModeRoundTripsThroughTheFileTheHostWrites() async throws {
        let directory = try makeTemporaryDirectory(prefix: "pmwiring")
        try MCPSettings(mode: .allowSession).save(directory: directory)
        let app = RecordedAppSurface()
        let context = makeContext(
            provider: liveProvider(app, mode: { MCPSettings.load(directory: directory).mode }),
            broker: ConfirmationBroker(timeout: 5),
            directory: directory,
            mode: nil,
            present: { _ in XCTFail(".allowSession must not put anything to a person") }
        )

        let before = await context.call(name: "get_settings", arguments: [:])
        XCTAssertFalse(before.isError, before.text)
        XCTAssertEqual(
            try reportedMutationMode(before.text), "allowSession",
            "get_settings must report the server's own mode"
        )

        let mutation = await context.call(name: "quit_app", arguments: ["id": "app:Chrome"])
        XCTAssertFalse(mutation.isError, mutation.text)
        XCTAssertEqual(app.stops, ["app:Chrome"], "the app performed the granted stop")

        let applied = await context.call(
            name: "set_preference", arguments: ["key": "mcpMode", "value": "confirmEach"]
        )
        XCTAssertFalse(applied.isError, applied.text)
        XCTAssertEqual(
            MCPSettings.load(directory: directory).mode, .confirmEach,
            "the tool call must write the file the host reads on its next call"
        )
        XCTAssertEqual(
            app.preferenceWrites, [],
            "mcpMode is the server's own policy, so it must never reach the app's preferences"
        )

        let after = await context.call(name: "get_settings", arguments: [:])
        XCTAssertEqual(try reportedMutationMode(after.text), "confirmEach")
    }

    // MARK: - The refusal the app's own snapshot closure owes a cold sampler

    /// The app's snapshot closure throws this, and `LiveDataProvider` passes
    /// whatever it throws straight through — so the wording is a contract
    /// between two providers rather than a convention. Pinned here, because
    /// nothing else compares them.
    func testTheSamplerNotReadyRefusalIsTheOnDemandPathsOwnWording() async throws {
        XCTAssertEqual(
            MCPToolError.samplerNotReady.message, OnDemandProvider.notReadyMessage,
            "the app's cold-sampler refusal must be the on-demand path's sentence"
        )
        let provider = LiveDataProvider(
            snapshot: { throw MCPToolError.samplerNotReady },
            alerts: { AlertsSnapshot(source: .live, alerts: []) },
            history: { UnavailableHistoryReading(message: "no history") },
            settings: { Self.settingsReporting(mode: .off) },
            applyPreference: { _, _ in },
            stopApp: { _, _ in StopReport(results: [:]) },
            stopContainerNamed: { _ in StopReport(results: [:]) },
            stopProject: { _ in StopReport(results: [:]) }
        )
        do {
            _ = try await provider.systemOverview()
            XCTFail("a sampler that has published nothing must refuse")
        } catch let error as MCPToolError {
            XCTAssertEqual(
                error.message, SnapshotAcquisition.notReadyMessage,
                "the refusal a client reads must be the sentence both providers use"
            )
        }
    }

    // MARK: - Helpers

    /// The host context over a provider and a disposable directory.
    ///
    /// `mode` is a value-or-nil rather than a closure so a test can change the
    /// file underneath a context that is already built — which is the whole of
    /// the per-call claim. `nil` means "read it from `directory`", which is what
    /// the app does.
    private func makeContext(
        provider: any DataProvider,
        broker: ConfirmationBroker,
        directory: URL,
        mode: MCPMutationMode?,
        appRunning: @escaping @Sendable () -> Bool = { true },
        present: @escaping @Sendable (MCPApprovalRequest) -> Void = { _ in }
    ) -> HostMCPCallContext {
        HostMCPCallContext(
            provider: provider,
            broker: broker,
            present: present,
            loadSettings: {
                MCPSettings(mode: mode ?? MCPSettings.load(directory: directory).mode)
            },
            appRunning: appRunning,
            auditDirectory: directory,
            settingsDirectory: directory
        )
    }

    /// A `LiveDataProvider` shaped the way `MCPHostController` builds it: the
    /// app's preferences for everything, and `MCPSettings` for the mutation mode.
    private func liveProvider(
        _ app: RecordedAppSurface,
        mode: @escaping @Sendable () -> MCPMutationMode
    ) -> LiveDataProvider {
        LiveDataProvider(
            snapshot: { throw MCPToolError.samplerNotReady },
            alerts: { AlertsSnapshot(source: .live, alerts: []) },
            history: { UnavailableHistoryReading(message: "no history") },
            settings: { Self.settingsReporting(mode: mode()) },
            applyPreference: { key, value in app.record(key: key, value: value) },
            stopApp: { id, _ in app.record(stop: id) },
            stopContainerNamed: { id in app.record(stop: id) },
            stopProject: { id in app.record(stop: id) }
        )
    }

    /// One settings payload, with the mutation mode named by the caller so a test
    /// can show which value came from where.
    private static func settingsReporting(mode: MCPMutationMode) -> SettingsSnapshot {
        SettingsSnapshot(
            temperatureUnit: "celsius", networkUnit: "bytes", cpuScale: "perCore",
            temperatureSource: "smc", compactMenuBar: false,
            mutationMode: mode.rawValue, alertsEnabled: false, retention: "days7"
        )
    }

    /// The `mutationMode` a `get_settings` payload reported.
    private func reportedMutationMode(_ text: String) throws -> String {
        let object = try jsonObject(text)
        return try XCTUnwrap(object["mutationMode"] as? String)
    }

    /// Every audit line written in `directory`, oldest first.
    private func auditEntries(_ directory: URL) throws -> [[String: Any]] {
        let url = directory.appendingPathComponent("mcp-audit.log")
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return try contents.split(separator: "\n").map { line in
            try jsonObject(String(line))
        }
    }

    /// Just the outcomes, so an assertion can be about the sequence of decisions
    /// rather than about the shape of the log.
    private func auditOutcomes(_ directory: URL) throws -> [String] {
        try auditEntries(directory).compactMap { $0["outcome"] as? String }
    }
}

/// What a person was asked, in order. The stand-in for the confirmation window:
/// it records the request and answers it, which is all `HostMCPCallContext`
/// requires of a presenter.
private final class RecordingPresenter: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [MCPApprovalRequest] = []

    func record(_ request: MCPApprovalRequest) {
        lock.withLock { recorded.append(request) }
    }

    var requests: [MCPApprovalRequest] { lock.withLock { recorded } }
}

/// What the app was asked to do, instead of the app: the mutations that reached
/// it, so a test can assert the difference between "refused" and "performed".
private final class RecordedAppSurface: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped: [String] = []
    private var preferences: [String] = []

    var stops: [String] { lock.withLock { stopped } }
    var preferenceWrites: [String] { lock.withLock { preferences } }

    func record(stop id: String) -> StopReport {
        lock.withLock { stopped.append(id) }
        return StopReport(results: [:])
    }

    func record(key: String, value: String) {
        lock.withLock { preferences.append("\(key)=\(value)") }
    }
}