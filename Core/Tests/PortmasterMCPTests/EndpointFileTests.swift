import XCTest
import PortmasterMCP

/// The endpoint file is slice 2's whole security boundary: it is how a CLI finds
/// a running app, and the token inside it is what proves the caller may talk to
/// it. So what matters here is not only the round trip but every way the file can
/// be *unusable* — a stale pid, a truncated write, a shape a future version
/// changes — each of which must read as "no app" rather than as a token to trust.
final class EndpointFileTests: XCTestCase {

    /// Far above macOS's pid ceiling, so this can never name a live process.
    private static let deadPID: pid_t = 999_999

    /// pid 1 is launchd: root-owned, so an unprivileged `kill(1, 0)` answers
    /// EPERM rather than ESRCH. That is the "alive but not ours to signal" case.
    private static let rootOwnedPID: pid_t = 1

    // MARK: - Round trip and shape

    func testWriteThenReadRoundTripsEveryField() throws {
        let directory = try makeTemporaryDirectory(prefix: name)
        let endpoint = EndpointFile(
            socket: directory.appendingPathComponent("mcp.sock"),
            token: try EndpointFileStore.newToken(),
            pid: ProcessInfo.processInfo.processIdentifier
        )

        try EndpointFileStore.write(endpoint, directory: directory)

        XCTAssertEqual(EndpointFileStore.read(directory: directory), endpoint)

        // The bytes on disk are a contract with the CLI that reads them, so they
        // are asserted rather than inferred from the round trip: exactly three
        // plain keys, and the socket as a plain path string. `URL`'s own Codable
        // conformance would have nested it as `{"relative": ...}` instead.
        let data = try Data(contentsOf: EndpointFileStore.defaultURL(directory: directory))
        let object = try jsonObject(String(decoding: data, as: UTF8.self))
        XCTAssertEqual(Set(object.keys), ["socket", "token", "pid"])
        XCTAssertEqual(object["socket"] as? String, endpoint.socket.path)
        XCTAssertEqual(object["token"] as? String, endpoint.token)
        XCTAssertEqual((object["pid"] as? NSNumber)?.int32Value, endpoint.pid)

        // The write builds the endpoint in a sibling temp file and renames it in, so
        // the temp must not survive: a leftover one would sit beside the real
        // endpoint holding an older token, and `read` only ever looks at the name.
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path),
            ["mcp-endpoint.json"],
            "write must leave the endpoint file and nothing else"
        )
    }

    /// The token is a secret, and `EndpointFile` ends up in logs, assertion messages
    /// and error text by reflection alone. Its own description must not be the way it
    /// escapes: the socket path and pid are diagnostics worth keeping, the token is not.
    func testDescriptionRedactsTheTokenButKeepsTheDiagnosableFields() throws {
        let directory = try makeTemporaryDirectory(prefix: name)
        let endpoint = EndpointFile(
            socket: directory.appendingPathComponent("mcp.sock"),
            token: try EndpointFileStore.newToken(),
            pid: 4242
        )

        for rendered in [endpoint.description, endpoint.debugDescription, "\(endpoint)"] {
            XCTAssertFalse(
                rendered.contains(endpoint.token),
                "the token must not survive being printed: \(rendered)"
            )
            XCTAssertTrue(rendered.contains("<redacted>"), "and must say it was withheld: \(rendered)")
            XCTAssertTrue(rendered.contains(endpoint.socket.path), "the socket is not secret: \(rendered)")
            XCTAssertTrue(rendered.contains("4242"), "the pid is not secret: \(rendered)")
        }

        // Interpolating into a message is the path that actually leaks, so check the
        // reflected form a logger would produce, not just the property.
        XCTAssertFalse(
            "endpoint=\(endpoint)".contains(endpoint.token),
            "string interpolation must not carry the token either"
        )
    }

    func testDefaultURLIsExactlyEndpointFileUnderPortmasterDirectory() throws {
        let directory = try makeTemporaryDirectory(prefix: name)
        XCTAssertEqual(
            EndpointFileStore.defaultURL(directory: directory).path,
            directory.appendingPathComponent("mcp-endpoint.json").path
        )
        // Path-only, so this cannot write to the real per-user location.
        XCTAssertEqual(
            EndpointFileStore.defaultURL(directory: nil).path,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".portmaster", isDirectory: true)
                .appendingPathComponent("mcp-endpoint.json").path
        )
    }

    func testFileIsOwnerOnlyAndDirectoryIs0700() throws {
        let root = try makeTemporaryDirectory(prefix: name)
        // A directory that does not exist yet: `write` has to create it, which is
        // the path a first launch takes when `~/.portmaster` was never made.
        let directory = root.appendingPathComponent("portmaster", isDirectory: true)
        let fileURL = EndpointFileStore.defaultURL(directory: directory)
        let socket = directory.appendingPathComponent("mcp.sock")
        let pid = ProcessInfo.processInfo.processIdentifier

        try EndpointFileStore.write(
            EndpointFile(socket: socket, token: try EndpointFileStore.newToken(), pid: pid),
            directory: directory
        )

        XCTAssertEqual(try posixPermissions(of: directory), 0o700, "the directory must be created owner-only")
        XCTAssertEqual(try posixPermissions(of: fileURL), 0o600)

        // Now widen both, the way a hand-made directory or an older version's file
        // would be, and write again: the modes must be repaired rather than
        // adopted, and a rewrite must never leave the token readable.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)

        try EndpointFileStore.write(
            EndpointFile(socket: socket, token: try EndpointFileStore.newToken(), pid: pid),
            directory: directory
        )

        XCTAssertEqual(try posixPermissions(of: directory), 0o700, "a wider directory must be tightened")
        XCTAssertEqual(try posixPermissions(of: fileURL), 0o600, "a wider file must be tightened")
    }

    // MARK: - Every unusable file reads as "no app"

    func testReadReturnsNilWhenFileAbsent() throws {
        let directory = try makeTemporaryDirectory(prefix: name)

        XCTAssertNil(EndpointFileStore.read(directory: directory))

        // And once written and removed, back to absent rather than cached.
        try EndpointFileStore.write(
            EndpointFile(
                socket: directory.appendingPathComponent("mcp.sock"),
                token: try EndpointFileStore.newToken(),
                pid: ProcessInfo.processInfo.processIdentifier
            ),
            directory: directory
        )
        XCTAssertNotNil(EndpointFileStore.read(directory: directory))
        EndpointFileStore.remove(directory: directory)
        XCTAssertNil(EndpointFileStore.read(directory: directory))
    }

    func testReadReturnsNilWhenJSONIsCorrupt() throws {
        let directory = try makeTemporaryDirectory(prefix: name)
        let fileURL = EndpointFileStore.defaultURL(directory: directory)
        let socket = directory.appendingPathComponent("mcp.sock").path
        let alive = ProcessInfo.processInfo.processIdentifier
        // A fixed well-formed token, not a minted one: these cases are about the
        // *other* field being wrong, and a failure message that echoes the file
        // should not carry a real-shaped secret into the test log to say so.
        let token = String(repeating: "a", count: 64)

        // Each of these is a real way the file can be wrong: a half-written
        // update, a version that changed the shape, a hand edit. All of them
        // must read as "no app" — none may throw, and none may yield a token a
        // caller would then present to a socket.
        let cases: [(label: String, text: String)] = [
            ("truncated", "{not json"),
            ("empty file", ""),
            ("not an object", "[]"),
            ("no fields", "{}"),
            ("missing token", #"{"socket":"\#(socket)","pid":\#(alive)}"#),
            ("missing pid", #"{"socket":"\#(socket)","token":"\#(token)"}"#),
            ("socket is not a string", #"{"socket":42,"token":"\#(token)","pid":\#(alive)}"#),
            ("pid is not a number", #"{"socket":"\#(socket)","token":"\#(token)","pid":"1"}"#),
            ("pid past Int32", #"{"socket":"\#(socket)","token":"\#(token)","pid":99999999999}"#),
            ("empty socket", #"{"socket":"","token":"\#(token)","pid":\#(alive)}"#),
            ("empty token", #"{"socket":"\#(socket)","token":"","pid":\#(alive)}"#),
            ("short token", #"{"socket":"\#(socket)","token":"abc123","pid":\#(alive)}"#),
            ("non-hex token", #"{"socket":"\#(socket)","token":"\#(String(repeating: "z", count: 64))","pid":\#(alive)}"#),
            ("pid zero", #"{"socket":"\#(socket)","token":"\#(token)","pid":0}"#),
            ("negative pid", #"{"socket":"\#(socket)","token":"\#(token)","pid":-1}"#),
            // Otherwise entirely valid — a live pid, a well-formed token — and
            // rejected only for its size, which is what stops a file this code did
            // not write from being read in full.
            (
                "too large",
                #"{"socket":"\#(socket)","token":"\#(token)","pid":\#(alive),"pad":"\#(String(repeating: "x", count: 8_192))"}"#
            ),
        ]

        for testCase in cases {
            try Data(testCase.text.utf8).write(to: fileURL)
            XCTAssertNil(
                EndpointFileStore.read(directory: directory),
                "read must be nil for a file that is \(testCase.label): \(testCase.text)"
            )
        }
    }

    func testReadReturnsNilWhenPidIsNoLongerAlive() throws {
        let directory = try makeTemporaryDirectory(prefix: name)
        let socket = directory.appendingPathComponent("mcp.sock")

        try EndpointFileStore.write(
            EndpointFile(socket: socket, token: try EndpointFileStore.newToken(), pid: Self.deadPID),
            directory: directory
        )

        XCTAssertNil(
            EndpointFileStore.read(directory: directory),
            "a file left behind by a dead app must read as no app"
        )

        // The other half of the same check. A process that is alive but not ours
        // to signal answers `kill(pid, 0)` with EPERM, and it *is* alive — calling
        // that dead would send every caller to the on-demand fallback while the
        // app is running, which is the whole thing this file exists to prevent.
        // pid 1 (launchd) is root-owned, so an unprivileged test process gets
        // exactly EPERM here.
        try EndpointFileStore.write(
            EndpointFile(socket: socket, token: try EndpointFileStore.newToken(), pid: Self.rootOwnedPID),
            directory: directory
        )

        XCTAssertEqual(
            EndpointFileStore.read(directory: directory)?.pid,
            Self.rootOwnedPID,
            "a pid that merely cannot be signalled is still a live pid"
        )
    }

    // MARK: - Token

    func testTokenIs64HexCharactersAndTwoCallsDiffer() throws {
        let first = try EndpointFileStore.newToken()
        let second = try EndpointFileStore.newToken()

        XCTAssertEqual(first.count, 64, "32 bytes must be hex-encoded, not truncated or padded")
        XCTAssertTrue(
            first.allSatisfy { $0.isHexDigit && !$0.isUppercase },
            "a token must be lowercase hex, so it can be compared as bytes: \(first)"
        )
        XCTAssertNotEqual(first, second, "a token that repeats is not a token")
    }

    func testTokenMatchesAcceptsOnlyTheExactToken() throws {
        let token = try EndpointFileStore.newToken()

        XCTAssertTrue(EndpointFileStore.tokenMatches(token, expected: token))
        XCTAssertTrue(
            EndpointFileStore.tokenMatches(token, expected: token),
            "matching twice must be stable, not a one-shot"
        )

        let flippedCase = (token.first == "a" ? "A" : "a") + String(token.dropFirst())
        XCTAssertFalse(
            EndpointFileStore.tokenMatches(flippedCase, expected: token),
            "hex case is part of the token: a case-folded compare would widen it"
        )
        XCTAssertFalse(
            EndpointFileStore.tokenMatches(String(token.dropLast()), expected: token),
            "a truncated token is not the token"
        )
        XCTAssertFalse(
            EndpointFileStore.tokenMatches("", expected: token),
            "an empty candidate must never match"
        )
        XCTAssertFalse(
            EndpointFileStore.tokenMatches(token + "0", expected: token),
            "an extended token is not the token"
        )

        // Same length, one byte different: the case a branch-free compare exists
        // for, and the one an early-returning compare gets visibly wrong.
        var oneByteOff = Array(token)
        oneByteOff[30] = oneByteOff[30] == "0" ? "1" : "0"
        XCTAssertFalse(
            EndpointFileStore.tokenMatches(String(oneByteOff), expected: token),
            "a token differing in one byte must be rejected"
        )

        // 64 emoji is 64 *characters* and 256 UTF-8 bytes, which is what pins which
        // of the two the length check counts: a check written against `count` would
        // wave this past a 64-character token and then walk 256 bytes against 64. No
        // emoji byte equals a hex digit, so the strings are rejected on content as
        // well — this assertion is deliberately redundant with that, and states the
        // contract instead of leaving it to be inferred from a rejection.
        let multiByte = String(repeating: "\u{1F600}", count: 64)
        XCTAssertEqual(multiByte.count, 64)
        XCTAssertEqual(multiByte.utf8.count, 256)
        XCTAssertFalse(
            EndpointFileStore.tokenMatches(multiByte, expected: token),
            "the comparison is over UTF-8 bytes, not characters"
        )
    }

    // MARK: - Removal

    func testRemoveDeletesTheFileAndIsSafeToCallTwice() throws {
        let directory = try makeTemporaryDirectory(prefix: name)
        let fileURL = EndpointFileStore.defaultURL(directory: directory)

        try EndpointFileStore.write(
            EndpointFile(
                socket: directory.appendingPathComponent("mcp.sock"),
                token: try EndpointFileStore.newToken(),
                pid: ProcessInfo.processInfo.processIdentifier
            ),
            directory: directory
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        EndpointFileStore.remove(directory: directory)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fileURL.path),
            "the token must not be left on disk after the host stops"
        )
        XCTAssertNil(EndpointFileStore.read(directory: directory))

        // Shutdown paths race: two stops, or a stop for a host that never wrote
        // the file, must not trap.
        EndpointFileStore.remove(directory: directory)
        EndpointFileStore.remove(directory: directory)
    }

    // MARK: - Helpers

    private func posixPermissions(of url: URL) throws -> UInt16 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).uint16Value
    }
}
