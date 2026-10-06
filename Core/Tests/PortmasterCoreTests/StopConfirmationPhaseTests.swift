import XCTest
@testable import PortmasterCore

/// The stop sheet's phase decisions, tested without a window.
///
/// The force-first entry exists because a quiet dev server — detached, no
/// terminal attached — often ignores SIGTERM outright. These pin the rules
/// that make asking the real question first safe: the confirmation is still
/// shown, and a force attempt can never re-signal something already stopped.
final class StopConfirmationPhaseTests: XCTestCase {

    private func member(_ pid: pid_t) -> ConfirmedProcess {
        ConfirmedProcess(pid: pid, name: "node \(pid)", startedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private func outcome(
        _ status: StopCoordinator.Outcome.Status,
        pid: pid_t
    ) -> StopCoordinator.Outcome {
        StopCoordinator.Outcome(status: status, pid: pid)
    }

    // MARK: - Opening

    func testForceFirstStillOpensAtConfirm() {
        // The whole point of the feature is that it does *not* skip the
        // confirmation. If this ever returns `.running`, a force request
        // signals without a person answering.
        XCTAssertEqual(StopConfirmationPhase.opening(forceFirst: true), .confirm)
        XCTAssertEqual(StopConfirmationPhase.opening(forceFirst: false), .confirm)
    }

    func testForceFirstChangesWhichQuestionConfirmAsks() {
        XCTAssertTrue(StopConfirmationPhase.asksForceFirst(forceFirst: true))
        XCTAssertFalse(StopConfirmationPhase.asksForceFirst(forceFirst: false))
    }

    // MARK: - Offering a force quit

    func testForceIsOfferedWhileAnythingSurvived() {
        let outcomes: [pid_t: StopCoordinator.Outcome] = [
            100: outcome(.stopped, pid: 100),
            200: outcome(.stillRunning, pid: 200),
        ]
        XCTAssertTrue(
            StopConfirmationPhase.offersForceQuit(after: outcomes),
            "A member reported still running is exactly what a force quit is for."
        )
    }

    func testForceIsNotOfferedWhenAFailedMemberRemains() {
        let outcomes: [pid_t: StopCoordinator.Outcome] = [
            100: outcome(.failed(message: "identity unavailable"), pid: 100),
        ]
        XCTAssertTrue(
            StopConfirmationPhase.offersForceQuit(after: outcomes),
            "An identity failure leaves the process untouched, so a force attempt is still meaningful."
        )
    }

    func testForceIsNotOfferedWhenEverythingStopped() {
        let outcomes: [pid_t: StopCoordinator.Outcome] = [
            100: outcome(.stopped, pid: 100),
            200: outcome(.stopped, pid: 200),
        ]
        XCTAssertFalse(
            StopConfirmationPhase.offersForceQuit(after: outcomes),
            "Offering to force-quit nothing would put a button on screen that cannot do what its label says."
        )
    }

    func testForceIsNotOfferedBeforeAnythingHasRun() {
        XCTAssertFalse(StopConfirmationPhase.offersForceQuit(after: [:]))
    }

    // MARK: - Which members a force quit targets

    func testForceTargetsOnlyMembersWithoutAConfirmedStop() {
        let members = [member(100), member(200), member(300)]
        let outcomes: [pid_t: StopCoordinator.Outcome] = [
            100: outcome(.stopped, pid: 100),
            200: outcome(.stillRunning, pid: 200),
        ]
        XCTAssertEqual(
            StopConfirmationPhase.forceQuitCandidates(members, after: outcomes).map(\.pid),
            [200, 300],
            "300 has no outcome yet, so it is untouched and still eligible."
        )
    }

    func testForceNeverResignalsAConfirmedStop() {
        let members = [member(100)]
        let outcomes: [pid_t: StopCoordinator.Outcome] = [
            100: outcome(.stopped, pid: 100),
        ]
        XCTAssertTrue(
            StopConfirmationPhase.forceQuitCandidates(members, after: outcomes).isEmpty,
            "Re-sending SIGKILL at a PID already reported stopped is at best wasted and at worst a recycled PID."
        )
    }

    func testForceTargetsEveryMemberWhenNothingHasRun() {
        let members = [member(100), member(200)]
        XCTAssertEqual(
            StopConfirmationPhase.forceQuitCandidates(members, after: [:]).map(\.pid),
            [100, 200]
        )
    }

    func testForcePreservesTheOriginalOrderOfConfirmedMembers() {
        // The frozen list is what the person agreed to. Reordering it would
        // mean the second rendering of the list differs from the first.
        let members = [member(300), member(100), member(200)]
        let outcomes: [pid_t: StopCoordinator.Outcome] = [
            100: outcome(.stopped, pid: 100),
        ]
        XCTAssertEqual(
            StopConfirmationPhase.forceQuitCandidates(members, after: outcomes).map(\.pid),
            [300, 200]
        )
    }
}
