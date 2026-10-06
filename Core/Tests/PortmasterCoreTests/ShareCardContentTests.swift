import XCTest
@testable import PortmasterCore

/// The share card's content decisions, tested without a renderer.
///
/// The card is a picture people post, so the failures that matter here are the
/// ones that make it *wrong* rather than ugly: a confident-looking card of no
/// data, a stale reading presented as current, or figures that disagree with
/// the dashboard they were copied from.
final class ShareCardContentTests: XCTestCase {

    private func rollup(
        _ name: String,
        memory: UInt64,
        processes: Int = 1
    ) -> AppRollup {
        var rollup = AppRollup(id: "/apps/\(name)", displayName: name, isAppBundle: true)
        rollup.processes = (0..<processes).map { index in
            ProcessRow(
                pid: pid_t(1000 + index),
                name: "\(name) Helper \(index)",
                parentPid: 1,
                memoryBytes: memory / UInt64(processes)
            )
        }
        return rollup
    }

    private func snapshot(
        at: Date = Date(),
        used: UInt64 = 0,
        total: UInt64 = 0,
        cpu: Double = 0,
        rollups: [AppRollup] = []
    ) -> ObservationSnapshot {
        ObservationSnapshot(
            at: at,
            system: SystemSample(
                at: at,
                cpu: SystemCPU(
                    totalPercent: cpu, userPercent: cpu * 0.7, systemPercent: cpu * 0.3,
                    idlePercent: 100 - cpu, corePercents: [], coreCount: 12
                ),
                memory: SystemMemory(
                    totalBytes: total, usedBytes: used, pressureLevel: .normal,
                    pressureRatio: total > 0 ? Double(used) / Double(total) : 0,
                    swapBytes: nil, freeBytes: nil, appBytes: nil,
                    wiredBytes: nil, compressedBytes: nil
                )
            ),
            processes: [], ports: [], services: [], rollups: rollups
        )
    }

    // MARK: - Refusing a card with no reading

    func testAnUnsampledSnapshotHasNoReading() {
        let content = ShareCardContent.make(
            snapshot: .empty, machineName: "Mac", subtitle: "M2 Max"
        )
        XCTAssertFalse(
            content.hasReading,
            "`distantPast` is the engine's nothing-sampled-yet sentinel. A card rendered from it is a confident picture of no data."
        )
    }

    func testASampledSnapshotHasAReading() {
        let content = ShareCardContent.make(
            snapshot: snapshot(at: Date()), machineName: "Mac", subtitle: "M2 Max"
        )
        XCTAssertTrue(content.hasReading)
    }

    func testTheUnsampledSentinelIsOnlyDistantPast() {
        // A real timestamp from 1970 is still a reading. The sentinel is the
        // one value that means "nothing has been sampled", not "old".
        let content = ShareCardContent.make(
            snapshot: snapshot(at: Date(timeIntervalSince1970: 0)),
            machineName: "Mac", subtitle: "M2 Max"
        )
        XCTAssertTrue(content.hasReading, "An old reading is still a reading; only `distantPast` is the sentinel.")
    }

    // MARK: - The timestamp is the claim's scope

    func testTheTimestampNamesTheTimeNotJustTheDate() {
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        let text = ShareCardContent.make(
            snapshot: snapshot(at: at), machineName: "Mac", subtitle: "M2 Max"
        ).timestampText
        XCTAssertTrue(
            text.contains("at"),
            "A card showing only a date lets someone post a two-week-old reading as current. Got: \(text)"
        )
    }

    // MARK: - Missing readings print as unknown, not zero

    func testUnreadMemoryIsNilRatherThanZero() {
        let content = ShareCardContent.make(
            snapshot: snapshot(used: 0, total: 0), machineName: "Mac", subtitle: "M2 Max"
        )
        XCTAssertNil(
            content.memoryUsed,
            "Zero bytes of memory used is a different claim from never having read memory."
        )
        XCTAssertNil(content.memoryTotal)
    }

    func testReadMemoryIsFormattedByTheAppsOwnFormatter() {
        let content = ShareCardContent.make(
            snapshot: snapshot(used: 8_589_934_592, total: 68_719_476_736),
            machineName: "Mac", subtitle: "M2 Max"
        )
        XCTAssertEqual(content.memoryUsed, "8.0 GB")
        XCTAssertEqual(
            content.memoryTotal, "64.0 GB",
            "The card must use `Fmt.bytes` so it cannot disagree with the dashboard about the same figure."
        )
    }

    func testACpuReadingThatExistsIsFormattedAndOneThatDoesNotIsDash() {
        let known = ShareCardContent.make(
            snapshot: snapshot(cpu: 27.4), machineName: "Mac", subtitle: "M2 Max"
        )
        XCTAssertEqual(known.cpu, "27.4%")

        // `SystemCPU.unknown` reports `totalPercent: 0` rather than nil, so a
        // card that read the percentage directly would print "0.0%" for a
        // machine it knows nothing about. A zero core count is what actually
        // distinguishes "idle" from "never sampled".
        let unknown = ShareCardContent.make(
            snapshot: .empty, machineName: "Mac", subtitle: "M2 Max"
        )
        XCTAssertEqual(
            unknown.cpu, "—",
            "Zero percent and never-sampled are different claims; the card must not print one as the other."
        )
    }

    func testARealMachineThatIsIdleStillPrintsZeroPercent() {
        // The other half of the previous test: a genuine 0% on a machine whose
        // core count is known is a real reading, not an unknown one.
        let idle = ShareCardContent.make(
            snapshot: snapshot(cpu: 0), machineName: "Mac", subtitle: "M2 Max"
        )
        XCTAssertEqual(idle.cpu, "0.0%")
    }

    // MARK: - Choosing the apps

    func testAppsAreOrderedByMemoryDescending() {
        let entries = ShareCardContent.topApps(from: [
            rollup("Small", memory: 1_000_000_000),
            rollup("Huge", memory: 20_000_000_000),
            rollup("Medium", memory: 5_000_000_000),
        ])
        XCTAssertEqual(entries.map(\.name), ["Huge", "Medium", "Small"])
    }

    func testTiesAreBrokenByNameSoTwoExportsMatch() {
        let entries = ShareCardContent.topApps(from: [
            rollup("Zebra", memory: 4_000_000_000),
            rollup("Alpha", memory: 4_000_000_000),
        ])
        XCTAssertEqual(
            entries.map(\.name), ["Alpha", "Zebra"],
            "Equal byte counts would otherwise swap between exports and make two identical cards look like different machines."
        )
    }

    func testNoMoreThanFiveAppsAppear() {
        let rollups = (0..<12).map { rollup("App \($0)", memory: UInt64(12 - $0) * 1_000_000_000) }
        let entries = ShareCardContent.topApps(from: rollups)
        XCTAssertEqual(entries.count, ShareCardContent.appRowLimit)
        XCTAssertEqual(
            entries.count, 5,
            "Ten rows at this height would each be unreadably small, which is the failure mode of a card that tries to show everything."
        )
    }

    func testEveryAppAppearsWhenFewerThanTheLimitExist() {
        let entries = ShareCardContent.topApps(from: [rollup("Only", memory: 1_000_000_000)])
        XCTAssertEqual(entries.map(\.name), ["Only"])
    }

    func testNoAppsIsAnEmptyListNotACrash() {
        XCTAssertTrue(ShareCardContent.topApps(from: []).isEmpty)
    }

    func testTheMemoryCaptionIsOneSentenceWithNoDoubledWords() {
        let known = ShareCardContent.make(
            snapshot: snapshot(used: 52_428_923_392, total: 68_719_476_736),
            machineName: "Mac", subtitle: "M2 Max"
        )
        XCTAssertEqual(known.memoryCaption, "of 64.0 GB in memory")
        XCTAssertFalse(
            known.memoryCaption.contains("in memory in memory"),
            "The caption's grammar lives in the content type precisely so the view cannot append it twice."
        )
    }

    func testTheMemoryCaptionSaysSoWhenMemoryWasNeverRead() {
        let unknown = ShareCardContent.make(
            snapshot: snapshot(used: 0, total: 0), machineName: "Mac", subtitle: "M2 Max"
        )
        XCTAssertEqual(
            unknown.memoryCaption, "memory not read yet",
            "A missing total must read as an observation, not as a total of nothing."
        )
    }

    func testEachEntryCarriesItsFormattedMemoryAndProcessCount() {
        let entries = ShareCardContent.topApps(from: [
            rollup("Chrome", memory: 8_589_934_592, processes: 8),
        ])
        XCTAssertEqual(entries.first?.memory, "8.0 GB")
        XCTAssertEqual(
            entries.first?.processCount, 8,
            "The process count is what makes '96 processes' honest — it is why one row stands for many."
        )
    }

    // MARK: - The card's fixed size

    func testTheCardIsTheSocialPreviewSize() {
        XCTAssertEqual(ShareCardContent.pixelWidth, 1200)
        XCTAssertEqual(ShareCardContent.pixelHeight, 630)
    }

    func testTheCardRendersAtDoubleScale() {
        XCTAssertEqual(
            ShareCardContent.renderScale, 2,
            "A 1× PNG is soft on a Retina display and when a platform upscales it."
        )
    }

    // MARK: - End to end through `make`

    func testMakeCarriesTheMachineNameAndSubtitleThrough() {
        let content = ShareCardContent.make(
            snapshot: snapshot(rollups: [rollup("Safari", memory: 2_000_000_000)]),
            machineName: "Ada's MacBook Pro",
            subtitle: "M2 Max · 12 cores"
        )
        XCTAssertEqual(content.machineName, "Ada's MacBook Pro")
        XCTAssertEqual(content.subtitle, "M2 Max · 12 cores")
        XCTAssertEqual(content.apps.map(\.name), ["Safari"])
    }
}
