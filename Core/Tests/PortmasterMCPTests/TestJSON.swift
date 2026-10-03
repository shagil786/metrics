import XCTest
import PortmasterMCP

/// Shared scaffolding for the tool-executor tests, so the third and fourth test
/// file do not each grow their own copy of the same three helpers and drift.
extension XCTestCase {

    /// An executor over a stub, plus a fresh audit directory that is removed
    /// when the test ends.
    ///
    /// Cleanup is a teardown block rather than a `defer` in each test: a `defer`
    /// that runs after a test has already failed adds a second, unrelated error
    /// to the failure output, and `defer` in an async test body is easy to place
    /// wrongly. A read-only tool never writes the log, so the directory would
    /// otherwise not exist at all.
    ///
    /// `settingsDirectory` is where `set_preference` writes `mcpMode`; passing
    /// `nil` points it at the real per-user location, which a test must not do.
    func makeExecutor(
        provider: DataProvider,
        mode: MCPMutationMode = .off,
        appRunning: Bool = false,
        directory: URL? = nil,
        settingsDirectory: URL? = nil
    ) throws -> ToolExecutor {
        let url = try directory ?? makeTemporaryDirectory(prefix: name)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return ToolExecutor(
            provider: provider,
            gate: PermissionGate(settings: MCPSettings(mode: mode), appRunning: appRunning),
            audit: AuditLog(directory: url),
            settingsDirectory: settingsDirectory
        )
    }

    /// A created, empty directory, for the tests that need to read the audit log
    /// by path rather than through the executor.
    func makeTemporaryDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    /// A payload as a JSON object. Fails with the text in the message, because
    /// "not a dictionary" without the payload is unreadable.
    func jsonObject(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
            "payload must be a JSON object: \(text)"
        )
    }

    /// A payload as a JSON array of objects.
    func jsonArray(_ text: String) throws -> [[String: Any]] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]],
            "payload must be a JSON array: \(text)"
        )
    }

    /// Parsed audit lines, in write order. Throws when the log is absent, which
    /// is itself the assertion for "nothing was logged".
    func auditEntries(in directory: URL) throws -> [[String: Any]] {
        let logURL = directory.appendingPathComponent("mcp-audit.log")
        let contents = try String(contentsOf: logURL, encoding: .utf8)
        return try contents.split(separator: "\n").map { line in
            try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                "every audit line must be a JSON object: \(line)"
            )
        }
    }
}
