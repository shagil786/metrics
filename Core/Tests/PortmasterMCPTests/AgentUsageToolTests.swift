// report_usage: an agent declaring a fact about itself.
//
// Deliberately outside the permission gate. It is not an action on the machine —
// it cannot quit a process or change a setting — so requiring confirmation for it
// would train users to click through prompts that carry no risk, which makes the
// prompts that do matter easier to dismiss.
import XCTest
import Foundation
import PortmasterCore
@testable import PortmasterMCP

final class AgentUsageToolTests: XCTestCase {

    /// In-memory recorder so the tool's validation is tested without a store.
    final class SpyRecorder: SessionRecording, @unchecked Sendable {
        typealias Call = (
            modelID: String, input: Int, output: Int, provenance: TokenProvenance
        )
        private let lock = NSLock()
        private var recorded: [Call] = []

        var calls: [Call] {
            lock.lock(); defer { lock.unlock() }
            return recorded
        }

        func record(
            sessionID: UUID?, clientName: String?, clientVersion: String?,
            input: Int, output: Int, cacheRead: Int?, reasoning: Int?, modelID: String
        ) throws -> String {
            lock.lock()
            recorded.append((modelID, input, output, .selfReported))
            lock.unlock()
            return "recorded"
        }
    }

    private func executor(_ recorder: SpyRecorder) throws -> ToolExecutor {
        let directory = try makeTemporaryDirectory(prefix: name)
        return ToolExecutor(
            provider: StubProvider(),
            gate: PermissionGate(settings: MCPSettings(mode: .off), appRunning: false),
            audit: AuditLog(directory: directory),
            settingsDirectory: directory,
            sessionRecorder: recorder
        )
    }

    // MARK: - Catalog

    func testToolIsInTheCatalog() {
        XCTAssertTrue(ToolExecutor.catalog.contains { $0.name == "report_usage" })
    }

    func testToolIsNotAMutation() {
        guard let tool = ToolExecutor.catalog.first(where: { $0.name == "report_usage" }) else {
            return XCTFail("report_usage missing from catalog")
        }
        XCTAssertEqual(tool.effect, .read, "self-report must not require confirmation")
    }

    func testToolDeclaresItsArguments() {
        guard let tool = ToolExecutor.catalog.first(where: { $0.name == "report_usage" }) else {
            return XCTFail("report_usage missing from catalog")
        }
        let names = Set(tool.arguments.map(\.name))
        for required in ["input", "output", "model"] {
            XCTAssertTrue(names.contains(required), "\(required) must be declared")
        }
    }

    // MARK: - Behaviour

    func testValidReportReachesTheRecorder() async throws {
        let spy = SpyRecorder()
        let outcome = await try executor(spy).execute(
            name: "report_usage",
            arguments: ["input": "1000", "output": "250", "model": "m1"]
        )
        XCTAssertFalse(outcome.isError, outcome.text)
        XCTAssertFalse(outcome.text.isEmpty)
        XCTAssertEqual(spy.calls.count, 1)
        XCTAssertEqual(spy.calls.first?.modelID, "m1")
        XCTAssertEqual(spy.calls.first?.input, 1000)
    }

    func testNegativeInputIsRejected() async throws {
        let spy = SpyRecorder()
        let outcome = await try executor(spy).execute(
            name: "report_usage",
            arguments: ["input": "-1", "output": "250", "model": "m1"]
        )
        XCTAssertTrue(outcome.isError)
        XCTAssertEqual(spy.calls.count, 0, "nothing may be recorded from an invalid report")
    }

    func testNonNumericInputIsRejected() async throws {
        let spy = SpyRecorder()
        let outcome = await try executor(spy).execute(
            name: "report_usage",
            arguments: ["input": "lots", "output": "250", "model": "m1"]
        )
        XCTAssertTrue(outcome.isError)
        XCTAssertEqual(spy.calls.count, 0)
    }

    func testMissingModelIsRejected() async throws {
        let spy = SpyRecorder()
        let outcome = await try executor(spy).execute(
            name: "report_usage", arguments: ["input": "10", "output": "5"]
        )
        XCTAssertTrue(outcome.isError)
        XCTAssertEqual(spy.calls.count, 0, "a report without a model cannot be priced")
    }

    func testEmptyModelIsRejected() async throws {
        let spy = SpyRecorder()
        let outcome = await try executor(spy).execute(
            name: "report_usage",
            arguments: ["input": "10", "output": "5", "model": "  "]
        )
        XCTAssertTrue(outcome.isError)
        XCTAssertEqual(spy.calls.count, 0)
    }
}
