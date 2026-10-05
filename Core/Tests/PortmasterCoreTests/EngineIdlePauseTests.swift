// Idle pause: who is allowed to wake the sampler, and who is only allowed one sample.
//
// The idle pause is a promise to the person using the machine — Portmaster costs
// nothing once they have walked away. Two callers want a reading, and they are not
// alike: a person interacting with the app, which stamps activity and keeps sampling
// for another interval, and a program asking a question, which must get one reading
// without looking like the user came back. `noteUserActivity()` and `resumeOnce()`
// are those two callers, and the difference between them is exactly whether sampling
// can be held awake — so it is tested here rather than left to a comment.
//
// No wall-clock sleeps longer than a few hundred milliseconds, and no dependence on the
// timer interval: every tick in this file is forced with `refreshNow()`, so the test
// says what it means rather than what a cadence happens to allow.

import XCTest
@testable import PortmasterCore

final class EngineIdlePauseTests: XCTestCase {

    /// Shorter than any cadence, so "idle" is a fact within one tick rather than a
    /// five-minute wait — and long enough that the checks below sit well inside it.
    ///
    /// The two waits are deliberately far apart: the engine is made idle by sleeping
    /// *past* this, and then asked whether a tick within it still samples. A stamped
    /// activity buys a whole window; with a window of 50 ms there is no room to ask
    /// "within it" at all, and the test would pass whether or not `resumeOnce()`
    /// stamped anything.
    private let idleWindow: TimeInterval = 0.5
    /// Comfortably inside `idleWindow`, so a tick here can only sample if something
    /// recorded activity.
    private let insideTheWindow: TimeInterval = 0.1

    private func makeEngine() -> SamplingEngine {
        SamplingEngine(
            systemCollector: FixtureSystemCollector(),
            processCollector: FixtureProcessCollector(),
            portCollector: FixturePortCollector(),
            cadence: .brisk,
            nettopCollector: FixtureNettopProvider(),
            assertionCollector: FixtureAssertionProvider(),
            dockerCollector: FixtureDockerProvider(),
            thermalCollector: FixtureThermalProvider(),
            audioCollector: FixtureAudioProvider(),
            bluetoothCollector: FixtureBluetoothProvider()
        )
    }

    /// The one property the ruling is about: after a one-shot resume the engine can
    /// still pause. A resume that stamped activity would leave it sampling for another
    /// full idle window, and every later poll would do the same — so the difference
    /// between "took one sample" and "looks awake" has to be observable, and the only
    /// observable is whether sampling stops again on its own.
    func testAOneShotResumeSamplesOnceAndStillAllowsTheEngineToPause() {
        let engine = makeEngine()
        engine.idlePauseAfter = idleWindow
        addTeardownBlock { engine.stop() }
        engine.start()

        let first = waitForSample(after: engine)
        // `setSurfaceVisible(true)` is what stamps `lastLiveSampleAt` in the app — the
        // window appearing — and the idle guard has nothing to compare against without
        // it. Going straight to `(false)` would be a no-op on a default-constructed
        // engine, and this file would then prove nothing at all.
        engine.setSurfaceVisible(true)
        engine.setSurfaceVisible(false)

        // Go idle, then force a tick: it must take the pause branch.
        Thread.sleep(forTimeInterval: idleWindow + insideTheWindow)
        engine.refreshNow()
        XCTAssertTrue(waitUntil { engine.isPaused }, "an idle engine with no surface must pause")

        // `resumeOnce()` samples through the idle guard…
        engine.resumeOnce()
        let resumed = waitForSample(after: engine, newerThan: first)
        XCTAssertGreaterThan(
            resumed, first,
            "a one-shot resume must produce a reading even while the idle window has elapsed"
        )
        // The flag is display state and the tick corrects it: this resume produced one
        // reading and left the engine exactly as it found it, so it must report itself
        // paused again rather than claiming to sample for another cadence interval.
        XCTAssertTrue(
            waitUntil { engine.isPaused },
            "a one-shot resume must leave the engine reporting that it will not sample again"
        )

        // …and the next idle window must still be able to pause it. This tick lands
        // *inside* the window the resume would have bought, so a stamped
        // `lastLiveSampleAt` samples here and `latest` moves — which is exactly the
        // defect, and the reason this check sits inside the window rather than after
        // it.
        Thread.sleep(forTimeInterval: insideTheWindow)
        let afterResume = engine.latest.at
        engine.refreshNow()
        XCTAssertTrue(waitUntil { engine.isPaused }, "a resume must not hold the engine awake")
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(
            engine.latest.at, afterResume,
            "no reading may arrive from an idle engine: the resume stamped activity"
        )
    }

    /// The contrast that gives the first test meaning: `noteUserActivity()` *does*
    /// stamp, so the same sequence keeps the engine sampling. Without this, "still
    /// pauses" could pass because nothing ever woke the engine at all.
    func testUserActivityStampsAndKeepsSamplingPastTheIdleWindow() {
        let engine = makeEngine()
        engine.idlePauseAfter = idleWindow
        addTeardownBlock { engine.stop() }
        engine.start()

        let first = waitForSample(after: engine)
        engine.setSurfaceVisible(true)
        engine.setSurfaceVisible(false)
        Thread.sleep(forTimeInterval: idleWindow + insideTheWindow)
        engine.noteUserActivity()
        engine.refreshNow()

        let second = waitForSample(after: engine, newerThan: first)
        XCTAssertGreaterThan(
            second, first,
            "real user activity must buy another idle window, which is resumeOnce() does not"
        )
        XCTAssertFalse(engine.isPaused, "an engine with fresh activity is not paused")
    }

    // MARK: - Waiting on an asynchronous engine

    /// The engine publishes on the main queue, and `waitUntil` pumps the run loop —
    /// the same reason `EngineProbeTests` can read `latest` at all.
    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    /// Waits for a reading newer than `after`, returning its timestamp — or the
    /// current one when none arrived, so an assertion on it fails with the value rather
    /// than with a timeout message that says nothing.
    private func waitForSample(
        after engine: SamplingEngine,
        newerThan after: Date = .distantPast,
        timeout: TimeInterval = 3
    ) -> Date {
        var published = engine.latest.at
        _ = waitUntil({
            published = engine.latest.at
            return published > after
        }, timeout: timeout)
        return published
    }
}
