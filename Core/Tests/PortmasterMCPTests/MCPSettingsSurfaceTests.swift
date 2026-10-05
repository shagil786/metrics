// MCPSettingsSurfaceTests: what the MCP settings page says, and the command it copies.
//
// `App/SettingsView.swift` builds the page and has no test target — the app scheme builds
// and nothing runs — so the parts of it that are *decisions* rather than drawing live
// here as two library types: `MCPSettingsCopy` (what each mutation mode is called and
// what it means, what the host's status is, what a connected client row reads, what is
// said when none is) and `MCPInstallCommand` (where the built binary is said to be, and
// the `claude mcp add` line built from it).
//
// Four properties are worth holding still, because each is a way this page can be
// quietly wrong rather than loudly broken:
//
//  1. **A mode is described by its consequence, not its mechanism.** "Off" means "no
//     changes at all", "Allow session" means "no person is asked", "Confirm each" means
//     "Portmaster asks before every change". A person choosing between these is choosing
//     what an AI assistant can do to their machine unattended, and the difference between
//     those three is invisible from the names.
//  2. **The status line is true in all three states.** Listening says where; not running
//     says so; a failure says the reason. A status line that reads the same in all three
//     is the failure mode — a person cannot tell a dead host from a live one.
//  3. **The install command names the binary where it actually is.** Slice 1 shipped a
//     `$PWD/` prefix on top of a path `--show-bin-path` had already made absolute, so the
//     registered command pointed at a file that did not exist. The resolution helper is
//     tested against the real shape of what the toolchain prints, in both directions.
//  4. **The token is never on this page.** It is what makes a connection legitimate, and
//     Settings is a screenshot someone takes to ask for help.
//
// Note what is deliberately absent: the copy says nothing about what `claude mcp add`
// does when it runs. That command has never been executed from here — it writes the
// user's client configuration — so the page states where the binary is and stops.

import Foundation
@testable import PortmasterMCP
import XCTest

final class MCPSettingsSurfaceTests: XCTestCase {

    // MARK: - The mode radio

    /// The three choices are named the way a person thinks about them, and each says
    /// what it means for an AI client rather than how the gate is implemented.
    func testEachModeIsNamedAndSaysWhatItMeans() {
        XCTAssertEqual(MCPSettingsCopy.modeTitle(for: .off), "Off")
        XCTAssertEqual(MCPSettingsCopy.modeTitle(for: .confirmEach), "Confirm each")
        XCTAssertEqual(MCPSettingsCopy.modeTitle(for: .allowSession), "Allow session")

        XCTAssertEqual(
            MCPSettingsCopy.modeConsequence(for: .off),
            "An AI client can read this Mac, and make no changes at all."
        )
        XCTAssertEqual(
            MCPSettingsCopy.modeConsequence(for: .allowSession),
            "An AI client can make changes, and no person is asked before any of them."
        )
        XCTAssertEqual(
            MCPSettingsCopy.modeConsequence(for: .confirmEach),
            "An AI client can make changes, and Portmaster asks before every change."
        )
    }

    /// The consequence is the whole point of the radio, so it is per-mode and never
    /// shared: two modes described by one sentence are one choice wearing two names.
    func testNoTwoModesShareAConsequence() {
        let consequences = MCPMutationMode.allCases.map(MCPSettingsCopy.modeConsequence(for:))
        XCTAssertEqual(
            Set(consequences).count, consequences.count,
            "two modes must not read alike: \(consequences)"
        )
    }

    /// Every case is described, including one added later. A new mode with no sentence
    /// of its own would render as a radio with nothing under it.
    func testEveryModeHasBothATitleAndAConsequence() {
        XCTAssertEqual(MCPMutationMode.allCases.count, 3)
        for mode in MCPMutationMode.allCases {
            XCTAssertFalse(MCPSettingsCopy.modeTitle(for: mode).isEmpty, "\(mode)")
            XCTAssertFalse(MCPSettingsCopy.modeConsequence(for: mode).isEmpty, "\(mode)")
        }
    }

    /// The default is `off`, so that is what the page must open showing — an unset
    /// preference must never be described as a permission.
    func testTheDefaultModeIsTheOneThatChangesNothing() {
        XCTAssertEqual(MCPSettings.defaultMode, .off)
        XCTAssertEqual(
            MCPSettingsCopy.modeConsequence(for: MCPSettings.defaultMode),
            "An AI client can read this Mac, and make no changes at all."
        )
    }

    // MARK: - The status line

    /// Three states, three different sentences. A status line that reads the same
    /// whether the host is bound or not is the whole failure this holds still.
    func testTheStatusLineDistinguishesListeningNotRunningAndFailed() {
        let socket = URL(fileURLWithPath: "/Users/you/.portmaster/mcp.sock")
        XCTAssertEqual(
            MCPSettingsCopy.listening(socket: socket),
            "Listening — an AI client on this Mac can reach Portmaster at \(socket.path)."
        )
        XCTAssertEqual(MCPSettingsCopy.notRunning, "Not running — no AI client can reach Portmaster.")

        let lines = [
            MCPSettingsCopy.listening(socket: socket),
            MCPSettingsCopy.notRunning,
            MCPSettingsCopy.failed(reason: "Address already in use"),
        ]
        XCTAssertEqual(Set(lines).count, lines.count, "the three states must read differently: \(lines)")
    }

    /// A failed bind says why. The reason is passed through rather than replaced with a
    /// generic apology, because "Address already in use" is the difference between
    /// quitting something and chasing a stale socket.
    func testAFailureShowsTheReasonItWasGiven() {
        let line = MCPSettingsCopy.failed(reason: "Address already in use")
        XCTAssertTrue(line.contains("Address already in use"), line)
        XCTAssertTrue(line.contains("Not listening"), line)
    }

    /// A bind that failed without a usable reason must still say something true. An
    /// empty line under a heading that says the host is broken is the worst of both.
    func testAFailureWithNoReasonStillSaysTheHostIsNotListening() {
        XCTAssertEqual(MCPSettingsCopy.failed(reason: ""), MCPSettingsCopy.failed(reason: "   "))
        XCTAssertTrue(
            MCPSettingsCopy.failed(reason: "").contains("Not listening"),
            MCPSettingsCopy.failed(reason: "")
        )
    }

    // MARK: - Connected clients

    /// A row names the process and both times, because "something is connected" without
    /// any of those is the one fact a person cannot act on.
    func testAClientRowNamesThePidAndBothTimes() {
        let connected = Date(timeIntervalSince1970: 1_700_000_000)
        let called = Date(timeIntervalSince1970: 1_700_000_600)
        let row = MCPSettingsCopy.clientRow(pid: 4_321, connectedAt: connected, lastCallAt: called)

        XCTAssertTrue(row.contains("PID 4321"), row)
        XCTAssertTrue(row.contains("Connected"), row)
        XCTAssertTrue(row.contains("Last call"), row)
        XCTAssertTrue(
            row.contains(MCPSettingsCopy.timestampFormatter.string(from: connected)),
            "the connected-at time itself must be in the row: \(row)"
        )
        XCTAssertTrue(
            row.contains(MCPSettingsCopy.timestampFormatter.string(from: called)),
            "the last-call time itself must be in the row: \(row)"
        )
    }

    /// A client that has not called a tool is a real and different state from one that
    /// has — `initialize` and `tools/list` do not count — so the row says so rather
    /// than showing a blank where a time would be.
    func testAClientThatHasNotCalledAnythingSaysSo() {
        let row = MCPSettingsCopy.clientRow(
            pid: 42, connectedAt: Date(timeIntervalSince1970: 1_700_000_000), lastCallAt: nil
        )
        XCTAssertTrue(row.contains("has not called a tool yet"), row)
        XCTAssertFalse(row.contains("Last call"), "there is no time to show: \(row)")
    }

    /// `LOCAL_PEERPID` can simply fail, and the client is still worth listing. "PID 0"
    /// would name a process that does not exist; the row says it is not known instead.
    func testAClientWithNoKnowablePidIsNotReportedAsPidZero() {
        let row = MCPSettingsCopy.clientRow(
            pid: 0, connectedAt: Date(timeIntervalSince1970: 1_700_000_000), lastCallAt: nil
        )
        XCTAssertFalse(row.contains("PID 0"), row)
        XCTAssertTrue(row.contains("process not known"), row)
    }

    /// The empty state says what it means and what to do about it. An empty list with no
    /// line under it is indistinguishable from a page that failed to load.
    func testTheEmptyStateSaysNothingIsConnected() {
        XCTAssertFalse(MCPSettingsCopy.noClients.isEmpty)
        let text = MCPSettingsCopy.noClients
        XCTAssertTrue(text.contains("No AI client"), text)
        XCTAssertTrue(
            text.lowercased().contains("installed") || text.lowercased().contains("copy"),
            "the empty state must say what would put one there: \(text)"
        )
    }

    /// The walk up to the package root, tested with an injected probe rather than a real
    /// checkout. A page that cannot find the package root must find nothing — the failure
    /// to look must never look like a path that was found.
    func testThePackageRootIsTheNearestAncestorThatIsAPackage() {
        let root = MCPInstallCommand.packageRoot(
            containingSourceFileAt: "/src/portmaster/Core/Sources/PortmasterMCP/MCPInstallCommand.swift",
            isPackage: { $0 == "/src/portmaster/Core" }
        )
        XCTAssertEqual(root, "/src/portmaster/Core")
    }

    func testNoPackageRootIsFoundWhenNothingAboveIsAPackage() {
        let noneIsAPackage: (String) -> Bool = { _ in false }
        let found = MCPInstallCommand.packageRoot(
            containingSourceFileAt: "/tmp/a/b/c/File.swift", isPackage: noneIsAPackage
        )
        XCTAssertEqual(found, "")
        let allArePackages: (String) -> Bool = { _ in true }
        XCTAssertEqual(
            MCPInstallCommand.packageRoot(containingSourceFileAt: "", isPackage: allArePackages),
            "",
            "no path at all is not a package root, however willing the probe is"
        )
    }

    /// A package found several levels up, and a nearer non-package directory that must be
    /// passed through rather than accepted.
    func testTheWalkSkipsDirectoriesThatAreNotPackages() {
        var visited: [String] = []
        _ = MCPInstallCommand.packageRoot(
            containingSourceFileAt: "/a/b/Package/Sources/PortmasterMCP/File.swift",
            isPackage: { directory in
                visited.append(directory)
                return directory == "/a/b"
            }
        )
        XCTAssertEqual(
            visited,
            [
                "/a/b/Package/Sources/PortmasterMCP",
                "/a/b/Package/Sources",
                "/a/b/Package",
                "/a/b",
            ]
        )
    }

    /// This build's own package root, used by the page. Asserted to be a real package so
    /// a relocation cannot leave the page pointing at nothing without a red test.
    func testThisBuildKnowsItsOwnPackageRoot() {
        let root = MCPInstallCommand.compiledPackagePath
        XCTAssertFalse(
            root.isEmpty,
            "the running tests must be able to find the package they were compiled from"
        )
        XCTAssertTrue(root.hasPrefix("/"), root)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: root).appendingPathComponent("Package.swift").path
            ),
            "\(root) has no Package.swift"
        )
        // …and the bin directories it implies are the ones under it.
        for directory in MCPInstallCommand.binDirectories(packagePath: root) {
            XCTAssertTrue(directory.hasPrefix(root + "/.build"), directory)
        }
    }

    // MARK: - The audit log

    /// Only mutations are recorded, so that is what the page says. A person reading a
    /// log with no reads in it should not conclude the reads were missed.
    func testTheAuditLogCaptionSaysWhatIsRecorded() {
        let caption = MCPSettingsCopy.auditLogCaption
        XCTAssertTrue(caption.contains("mutation"), caption)
        XCTAssertTrue(caption.contains("not"), caption)
    }

    /// The path is shown as-is rather than abbreviated: a person is going to open it.
    func testTheAuditLogPathIsShownWhole() {
        let url = URL(fileURLWithPath: "/Users/you/.portmaster/mcp-audit.log")
        XCTAssertEqual(MCPSettingsCopy.auditLogPath(url), url.path)
    }

    /// The log is only written by a mutation attempt, so on a machine where nothing has
    /// changed it does not exist — and revealing a missing file selects nothing at all.
    /// The directory is then the nearest thing Finder can show that means something.
    func testRevealingAnAbsentLogShowsItsDirectoryInstead() {
        let url = URL(fileURLWithPath: "/Users/you/.portmaster/mcp-audit.log")
        XCTAssertEqual(
            MCPSettingsCopy.revealTarget(logURL: url, fileExists: false).path,
            "/Users/you/.portmaster"
        )
        XCTAssertEqual(
            MCPSettingsCopy.revealTarget(logURL: url, fileExists: true),
            url,
            "a log that exists is revealed itself, not its directory"
        )
    }

    // MARK: - The install command

    /// The slice-1 lesson, stated as the failure it was: `--show-bin-path` prints an
    /// absolute path on this toolchain, so prefixing it produced a command pointing at a
    /// file that does not exist. The exact string the toolchain prints is used here.
    func testAnAbsoluteBinDirectoryIsNotPrefixedASecondTime() {
        let printed = "/Users/you/portmaster/Core/.build/out/Products/Release"
        let path = MCPInstallCommand.binaryPath(in: printed, relativeTo: "/somewhere/else")

        XCTAssertEqual(path, printed + "/" + MCPStdioRunner.serverName)
        XCTAssertFalse(path.contains("$PWD"), "the slice-1 bug: \(path)")
        XCTAssertFalse(path.contains("//"), "a doubled separator: \(path)")
        XCTAssertTrue(path.hasPrefix(printed), "the directory must be kept verbatim: \(path)")
    }

    /// A relative directory still has to be made absolute: `claude mcp add` stores the
    /// string, and the client spawns the binary with its own working directory, not the
    /// one the command was pasted in.
    func testARelativeBinDirectoryIsMadeAbsoluteAgainstABase() {
        let path = MCPInstallCommand.binaryPath(
            in: "Core/.build/out/Products/Release", relativeTo: "/Users/you/portmaster"
        )
        XCTAssertEqual(
            path,
            "/Users/you/portmaster/Core/.build/out/Products/Release/" + MCPStdioRunner.serverName
        )
        XCTAssertTrue(path.hasPrefix("/"), "a stored path must be absolute: \(path)")
    }

    /// The boundaries of a real path: a trailing slash from a shell and an empty
    /// directory are both ways the join produces a wrong path rather than no path.
    func testTrailingSeparatorsAndAnEmptyDirectoryAreHandled() {
        let name = MCPStdioRunner.serverName
        XCTAssertEqual(
            MCPInstallCommand.binaryPath(in: "/opt/products/release/", relativeTo: "/nowhere"),
            "/opt/products/release/" + name
        )
        XCTAssertEqual(
            MCPInstallCommand.binaryPath(in: "  ", relativeTo: "/opt/products"),
            "/opt/products/" + name,
            "an empty directory means the base itself"
        )
        XCTAssertEqual(
            MCPInstallCommand.binaryPath(
                in: "Core/.build/release", relativeTo: "/Users/you/portmaster/"
            ),
            "/Users/you/portmaster/Core/.build/release/" + name,
            "a trailing separator on the base must not double up either"
        )
    }

    /// With no base to resolve against there is nothing to prepend, and inventing a
    /// leading separator would be a path to the root.
    func testARelativeDirectoryWithNoBaseIsLeftAlone() {
        let path = MCPInstallCommand.binaryPath(in: "Core/.build/release", relativeTo: "")
        XCTAssertEqual(path, "Core/.build/release/" + MCPStdioRunner.serverName)
    }

    /// The command is the one the README documents, built from the resolved path.
    func testTheInstallCommandNamesTheClientAndTheResolvedBinary() {
        let binary = "/Users/you/portmaster/Core/.build/out/Products/Release/" + MCPStdioRunner.serverName
        XCTAssertEqual(
            MCPInstallCommand.command(binaryPath: binary),
            "claude mcp add portmaster -- " + binary
        )
    }

    /// The two halves together, which is what the button actually copies — and the check
    /// that the name of the binary has one source, so the app and the product cannot
    /// disagree about what the executable is called.
    func testTheCommandBuiltFromABinDirectoryIsTheDocumentedLine() {
        let printed = "/Users/you/portmaster/Core/.build/out/Products/Release"
        XCTAssertEqual(
            MCPInstallCommand.command(
                binaryPath: MCPInstallCommand.binaryPath(in: printed, relativeTo: "/elsewhere")
            ),
            "claude mcp add portmaster -- " + printed + "/" + MCPStdioRunner.serverName
        )
    }

    /// A path with a space has to survive a paste into a shell. Unquoted, the client
    /// would be handed two arguments and store a path that is not there.
    func testAPathWithSpacesIsQuotedForTheShell() {
        let binary = "/Users/a b/Products/Release/" + MCPStdioRunner.serverName
        let command = MCPInstallCommand.command(binaryPath: binary)
        XCTAssertEqual(
            command,
            "claude mcp add portmaster -- '" + binary + "'",
            "the whole path is one quoted argument, so the space does not split it"
        )
    }

    /// An already-quoted or already-safe path is left alone: quoting everything would
    /// make the common case harder to read and, worse, would quote a path a person is
    /// meant to recognise.
    func testASimplePathIsNotQuoted() {
        let command = MCPInstallCommand.command(binaryPath: "/opt/bin/" + MCPStdioRunner.serverName)
        XCTAssertFalse(command.contains("'"), command)
    }

    /// The binary is found where it is, and nowhere else. A candidate list that did not
    /// care about existence would put a path in the clipboard that leads nowhere.
    func testTheBinaryIsFoundOnlyWhereItExists() throws {
        let exists = "/opt/products/release/" + MCPStdioRunner.serverName
        let missing = "/opt/products/debug/" + MCPStdioRunner.serverName
        let found = try XCTUnwrap(
            MCPInstallCommand.locateBinary(
                in: [missing, exists], isExecutableFile: { $0 == exists }
            )
        )
        XCTAssertEqual(found, exists)
        XCTAssertNil(
            MCPInstallCommand.locateBinary(in: [missing], isExecutableFile: { _ in false }),
            "no candidate exists, so there is no path to offer"
        )
        XCTAssertNil(MCPInstallCommand.locateBinary(in: [], isExecutableFile: { _ in true }))
    }

    /// The standard SwiftPM layout, release first: the README and the audit both concern
    /// the release build, and a debug binary found first would be a different program.
    func testTheBinDirectoriesAreTheSwiftPMLayoutReleaseFirst() {
        let directories = MCPInstallCommand.binDirectories(packagePath: "/src/portmaster/Core")
        XCTAssertEqual(
            directories,
            [
                "/src/portmaster/Core/.build/out/Products/Release",
                "/src/portmaster/Core/.build/release",
                "/src/portmaster/Core/.build/out/Products/Debug",
                "/src/portmaster/Core/.build/debug",
            ]
        )
        XCTAssertTrue(directories[0].contains("Release"), directories[0])
    }

    /// Nothing is duplicated and nothing is prefixed twice, for a trailing separator on
    /// the package path as much as for an absolute bin path.
    func testTheBinDirectoriesHaveNoDoubledSeparators() {
        for path in MCPInstallCommand.binDirectories(packagePath: "/src/Core/") {
            XCTAssertFalse(path.contains("//"), path)
            XCTAssertFalse(path.hasSuffix("/"), path)
            XCTAssertTrue(path.hasPrefix("/src/Core/.build"), path)
        }
        XCTAssertEqual(MCPInstallCommand.binDirectories(packagePath: "  "), [])
    }

    /// When nothing has been built, the page says what to build. It does not paste a
    /// command pointing at a file that is not there.
    func testTheMissingBinaryNoticeSaysHowToBuildIt() {
        let notice = MCPSettingsCopy.binaryNotBuiltNotice
        XCTAssertTrue(notice.contains("swift build"), notice)
        XCTAssertTrue(notice.contains(MCPInstallCommand.buildCommand), notice)
    }

    /// What is claimed about the command: where the binary is, and that this page does
    /// not run the command. It has never been executed from here — it writes the user's
    /// client configuration — so nothing may say it was tried.
    func testTheInstallCaptionDoesNotClaimTheCommandWasRun() {
        let caption = MCPSettingsCopy.installCaption
        XCTAssertFalse(caption.lowercased().contains("tested"), caption)
        XCTAssertFalse(caption.lowercased().contains("verified"), caption)
        XCTAssertTrue(caption.lowercased().contains("does not run"), caption)
    }

    // MARK: - The token

    /// The token is what makes a connection legitimate and it is never shown, logged or
    /// copied here. Settings is the screen a person screenshots when something is wrong.
    func testNoSettingsCopyMentionsTheToken() {
        let strings = [
            MCPSettingsCopy.modeConsequence(for: .off),
            MCPSettingsCopy.modeConsequence(for: .allowSession),
            MCPSettingsCopy.modeConsequence(for: .confirmEach),
            MCPSettingsCopy.modeTitle(for: .off),
            MCPSettingsCopy.modeTitle(for: .confirmEach),
            MCPSettingsCopy.modeTitle(for: .allowSession),
            MCPSettingsCopy.notRunning,
            MCPSettingsCopy.failed(reason: "Address already in use"),
            MCPSettingsCopy.noClients,
            MCPSettingsCopy.auditLogCaption,
            MCPSettingsCopy.binaryNotBuiltNotice,
            MCPSettingsCopy.installCaption,
            MCPSettingsCopy.clientRow(
                pid: 7, connectedAt: Date(timeIntervalSince1970: 1_700_000_000), lastCallAt: nil
            ),
            MCPInstallCommand.buildCommand,
            MCPInstallCommand.command(binaryPath: "/opt/" + MCPStdioRunner.serverName),
        ]
        for string in strings {
            XCTAssertFalse(
                string.lowercased().contains("token"), "the token must not be on this page: \(string)"
            )
        }
    }
}
