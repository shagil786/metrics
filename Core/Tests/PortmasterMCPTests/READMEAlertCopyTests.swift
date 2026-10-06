import XCTest
@testable import PortmasterMCP
import PortmasterCore

/// The README quotes Portmaster's alert sentences. `AlertCopy` now produces
/// them, so the quote and the code can drift apart — and this branch has spent
/// four review rounds finding stale prose.
///
/// The rule that emerged: prose that quotes code should be asserted by a test,
/// and prose that states arithmetic should be derived in the test. These
/// sentences are the first kind.
final class READMEAlertCopyTests: XCTestCase {

    /// The repository's `README.md`, resolved from `#filePath` four levels up
    /// the same way `READMEClaimsTests` does it — the test bundle's working
    /// directory is not something to rely on.
    private static let readme: String = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // PortmasterMCPTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // Core
            .deletingLastPathComponent()  // repository root
            .appendingPathComponent("README.md")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            // `XCTFail` rather than `preconditionFailure`: a moved file must
            // cost one result, not abort the run and take every other test's
            // with it.
            XCTFail("README.md not found at \(url.path)")
            return ""
        }
        return text
    }()

    func testTheReadmeQuotesTheLiveCpuSentence() {
        let sentence = AlertCopy.sustainedCPU(70, source: .live)
        XCTAssertTrue(
            Self.readme.contains(sentence),
            "The README's CPU example no longer matches `AlertCopy`. Expected to find: \(sentence)"
        )
    }

    func testTheReadmeQuotesTheLiveMemorySentence() {
        let sentence = AlertCopy.memoryGrowth(growth: "1.4 GB", now: "3.3 GB", source: .live)
        XCTAssertTrue(
            Self.readme.contains(sentence),
            "The README's memory example no longer matches `AlertCopy`. Expected: \(sentence)"
        )
    }

    func testTheReadmeQuotesTheLiveDiskSentence() {
        let sentence = AlertCopy.diskHammering("62 MB/s", source: .live)
        XCTAssertTrue(Self.readme.contains(sentence), "Expected: \(sentence)")
    }

    func testTheReadmeQuotesTheLiveNetworkSentence() {
        let sentence = AlertCopy.networkHammering("11 MB/s", source: .live)
        XCTAssertTrue(Self.readme.contains(sentence), "Expected: \(sentence)")
    }

    func testTheReadmeDoesNotQuoteTheOldWording() {
        // The three windowed details were shortened; the old phrasing is what
        // a stale README would still be carrying.
        XCTAssertFalse(
            Self.readme.contains("average over the last 10 minutes"),
            "The README still quotes the pre-`AlertCopy` phrasing, which `AlertCopy` can no longer produce."
        )
    }

    func testEveryQuotedExampleIsOneTheCodeCanProduce() {
        // Guards the other direction: a README sentence that no constant can
        // produce is a sentence nobody can verify.
        let quoted = [
            AlertCopy.sustainedCPU(70, source: .live),
            AlertCopy.memoryGrowth(growth: "1.4 GB", now: "3.3 GB", source: .live),
            AlertCopy.diskHammering("62 MB/s", source: .live),
            AlertCopy.networkHammering("11 MB/s", source: .live),
        ]
        for sentence in quoted {
            XCTAssertTrue(Self.readme.contains(sentence), "README is missing: \(sentence)")
        }
    }
}
