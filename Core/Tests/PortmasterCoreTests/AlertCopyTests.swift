import XCTest
@testable import PortmasterCore

/// Every sentence Portmaster says about an app acting up.
///
/// These exist because six call sites once wrote the same four sentences by
/// hand, and a threshold change could leave one module describing a window the
/// other no longer used. The assertions below are mostly about that coupling:
/// change a constant and the wording has to follow, or the test goes red.
final class AlertCopyTests: XCTestCase {

    // MARK: - Window wording

    func testTenMinutesReadsAsTenMinutes() {
        XCTAssertEqual(AlertCopy.spanDescription(600), "10 minutes")
    }

    func testOneHourReadsAsOneHour() {
        XCTAssertEqual(AlertCopy.spanDescription(3600), "1 hour")
    }

    func testWindowsArePluralisedOnlyWhenTheyShouldBe() {
        XCTAssertEqual(AlertCopy.spanDescription(60), "1 minute")
        XCTAssertEqual(AlertCopy.spanDescription(120), "2 minutes")
        XCTAssertEqual(AlertCopy.spanDescription(7200), "2 hours")
        XCTAssertEqual(AlertCopy.spanDescription(1), "1 second")
        XCTAssertEqual(AlertCopy.spanDescription(30), "30 seconds")
    }

    func testASubMinuteWindowDoesNotReadAsZeroMinutes() {
        // "0 minutes" is not a sentence anyone can read, and a threshold tight
        // enough to produce one would make the alert meaningless rather than
        // precise.
        XCTAssertEqual(AlertCopy.spanDescription(0.4), "0 seconds")
        XCTAssertFalse(AlertCopy.spanDescription(0.4).contains("0 minutes"))
    }

    func testAWindowThatDoesNotDivideEvenlyStaysInItsOwnUnit() {
        // Rounding 90 minutes to "1 hour" would describe a window that is not
        // the one the threshold used. The sentence has to name the real span.
        XCTAssertEqual(AlertCopy.spanDescription(5400), "90 minutes")
        XCTAssertEqual(AlertCopy.spanDescription(90), "90 seconds")
        XCTAssertEqual(
            AlertCopy.spanDescription(3660), "61 minutes",
            "61 minutes does not divide into hours, so it must not read as one."
        )
    }

    func testEveryWindowConstantReadsAsSomethingAReaderCanRead() {
        for interval in [AlertEngine.cpuWindow, AlertEngine.memGrowthWindow, AlertEngine.hammerWindow] {
            let text = AlertCopy.spanDescription(interval)
            XCTAssertFalse(text.isEmpty)
            XCTAssertFalse(text.hasPrefix("0 "), "\(interval)s reads as \(text)")
        }
    }

    // MARK: - The sentences track the constants

    func testTheCpuSentenceUsesTheCpuWindow() {
        let detail = AlertCopy.sustainedCPU(70, source: .live)
        XCTAssertTrue(
            detail.contains(AlertCopy.spanDescription(AlertEngine.cpuWindow)),
            "The sentence must describe the window the threshold actually used. Got: \(detail)"
        )
        XCTAssertEqual(detail, "70% on average for 10 minutes.")
    }

    func testTheMemorySentenceUsesTheMemoryWindow() {
        let detail = AlertCopy.memoryGrowth(growth: "1.4 GB", now: "3.3 GB", source: .live)
        XCTAssertTrue(detail.contains(AlertCopy.spanDescription(AlertEngine.memGrowthWindow)))
        XCTAssertEqual(detail, "Up 1.4 GB in the last 1 hour, now 3.3 GB.")
    }

    func testTheDiskAndNetworkSentencesUseTheHammerWindow() {
        let disk = AlertCopy.diskHammering("62 MB/s", source: .live)
        let network = AlertCopy.networkHammering("11 MB/s", source: .live)
        let window = AlertCopy.spanDescription(AlertEngine.hammerWindow)
        XCTAssertTrue(disk.contains(window))
        XCTAssertTrue(network.contains(window))
    }

    func testTheMemorySentenceReadsAsABaselineNotADurationOfGrowth() {
        // "for an hour" would claim growth sustained across the whole hour,
        // which the measurement does not establish — it compares against a
        // baseline taken at that point.
        let detail = AlertCopy.memoryGrowth(growth: "1.4 GB", now: "3.3 GB", source: .live)
        XCTAssertTrue(
            detail.contains("in the last"),
            "The window is a baseline age. Got: \(detail)"
        )
    }

    // MARK: - Source qualifier

    func testALiveObservationCarriesNoProvenanceQualifier() {
        let detail = AlertCopy.sustainedCPU(70, source: .live)
        XCTAssertFalse(
            detail.contains("From recorded history"),
            "A live reading is not reconstructed; saying so would be a false admission."
        )
        XCTAssertFalse(detail.contains(".."), "No dangling punctuation when the qualifier is empty.")
    }

    func testAHistoryObservationSaysItCameFromHistory() {
        let detail = AlertCopy.sustainedCPU(70, source: .history)
        XCTAssertTrue(
            detail.hasSuffix("From recorded history."),
            "An MCP client must be able to tell an approximation from a reading. Got: \(detail)"
        )
    }

    func testEverySentenceCarriesTheSourceQualifier() {
        let sentences = [
            AlertCopy.sustainedCPU(70, source: .history),
            AlertCopy.memoryGrowth(growth: "1.4 GB", now: "3.3 GB", source: .history),
            AlertCopy.diskHammering("62 MB/s", source: .history),
            AlertCopy.networkHammering("11 MB/s", source: .history),
        ]
        for sentence in sentences {
            XCTAssertTrue(
                sentence.hasSuffix("From recorded history."),
                "Missing qualifier on: \(sentence)"
            )
        }
    }

    func testLiveAndHistoryDifferOnlyByTheQualifier() {
        let live = AlertCopy.sustainedCPU(70, source: .live)
        let history = AlertCopy.sustainedCPU(70, source: .history)
        XCTAssertEqual(
            history, live + " From recorded history.",
            "The two sources must not drift into separately-worded sentences."
        )
    }

    // MARK: - Headlines carry the app and the trend

    func testEveryHeadlineNamesTheApp() {
        for kind in [ActingUpAlert.Kind.sustainedCPU, .memoryGrowth, .diskHammering, .networkHammering] {
            XCTAssertTrue(
                AlertCopy.headline(kind, appName: "Chrome").contains("Chrome"),
                "\(kind) headline does not name the app."
            )
        }
    }

    func testHeadlinesAreDistinctPerKind() {
        var seen = Set<String>()
        for kind in [ActingUpAlert.Kind.sustainedCPU, .memoryGrowth, .diskHammering, .networkHammering] {
            let text = AlertCopy.headline(kind, appName: "App")
            XCTAssertTrue(seen.insert(text).inserted, "Two kinds share a headline: \(text)")
        }
    }

    // MARK: - Headline and detail cannot be mismatched

    func testObservationPairsEachHeadlineWithItsOwnDetail() {
        let cpu = AlertCopy.observation(.sustainedCPU, appName: "Chrome", percent: 70, source: .live)
        XCTAssertEqual(cpu.headline, "Chrome is keeping the CPU busy")
        XCTAssertTrue(cpu.detail.contains("%"), "A CPU observation's detail should carry a percentage.")

        let memory = AlertCopy.observation(
            .memoryGrowth, appName: "Slack", growth: "1.4 GB", now: "3.3 GB", source: .live
        )
        XCTAssertEqual(memory.headline, "Slack keeps using more memory")
        XCTAssertTrue(memory.detail.contains("Up"), "Got: \(memory.detail)")
    }

    func testObservationDefaultsToADashRatherThanAnEmptySentence() {
        // A caller that forgets a figure should get an honest dash rather than
        // "0% on average for 10 minutes" or "Up  in the last 1 hour".
        let disk = AlertCopy.observation(.diskHammering, appName: "Backup", source: .live)
        XCTAssertTrue(
            disk.detail.hasPrefix("— "),
            "A missing figure must read as missing. Got: \(disk.detail)"
        )
        XCTAssertFalse(disk.detail.contains("Up  "), "Double space from an empty figure: \(disk.detail)")
    }

    func testObservationCarriesTheSourceQualifier() {
        let history = AlertCopy.observation(.diskHammering, appName: "Backup", rate: "62 MB/s", source: .history)
        XCTAssertTrue(history.detail.hasSuffix("From recorded history."))
    }

    // MARK: - No stranded punctuation

    func testNoSentenceEndsWithTwoPeriods() {
        let sentences = [
            AlertCopy.sustainedCPU(70, source: .live),
            AlertCopy.memoryGrowth(growth: "1.4 GB", now: "3.3 GB", source: .live),
            AlertCopy.diskHammering("62 MB/s", source: .live),
            AlertCopy.networkHammering("11 MB/s", source: .live),
        ]
        for sentence in sentences {
            XCTAssertFalse(sentence.contains(".."), "Stranded punctuation: \(sentence)")
            XCTAssertTrue(sentence.hasSuffix("."), "Missing full stop: \(sentence)")
        }
    }
}
