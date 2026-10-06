// ConfirmationWindowPlacementTests: the confirmation window never opens under the pointer.
//
// This is a table rather than one case because the arithmetic has several boundaries and
// three of them were wrong at once the first time it was written (in `App/`, where no test
// could reach it). Two properties are asserted for every case:
//
//   1. the returned frame is **never off the screen**; and
//   2. **whenever a frame fits entirely on one side of the pointer**, the pointer is not
//      inside it.
//
// (2) is stated as an implication because it is not true unconditionally: a 488 pt frame
// plus its clearance cannot sit on either side of a pointer in the middle of a 900 pt
// screen, and that case — `ConfirmationWindowPlacement.fallback` — is asserted too rather
// than left implicit. "The guarantee holds except sometimes" is only useful if the
// sometimes is named, and this file names it.

import CoreGraphics
import PortmasterMCP
import XCTest

final class ConfirmationWindowPlacementTests: XCTestCase {

    /// The content size the window is built with, and a frame height consistent with a
    /// titled window — 28 pt of title bar on every macOS this app supports.
    private static let contentWidth: CGFloat = 540
    private static let contentHeight: CGFloat = 460
    private static let frameHeight: CGFloat = contentHeight + 28

    /// Screens worth placing against: a tall desktop, the two laptop sizes the reviewer
    /// named, and a second display whose origin is not (0, 0).
    private static let screens: [(name: String, frame: NSRect)] = [
        ("tall desktop 2560×1440", NSRect(x: 0, y: 0, width: 2560, height: 1440)),
        ("laptop 1440×900", NSRect(x: 0, y: 0, width: 1440, height: 900)),
        ("laptop 1280×800", NSRect(x: 0, y: 0, width: 1280, height: 800)),
        ("second display, minX/minY non-zero",
         NSRect(x: 2560, y: -1200, width: 1920, height: 1080)),
    ]

    /// Whether a frame of `frameHeight` fits entirely on one side of `pointer` here — i.e.
    /// whether the guarantee is claimed at this pointer at all.
    private static func canClear(
        _ pointer: NSPoint, in screen: NSRect, frameHeight: CGFloat
    ) -> Bool {
        let clearance = ConfirmationWindowPlacement.clearance
        return pointer.y - clearance - frameHeight >= screen.minY
            || pointer.y + clearance + frameHeight <= screen.maxY
    }

    /// The frame the returned origin describes.
    private static func frame(
        origin: NSPoint, width: CGFloat = contentWidth, height: CGFloat = frameHeight
    ) -> NSRect {
        NSRect(x: origin.x, y: origin.y, width: width, height: height)
    }

    /// Bounds written out rather than `a.contains(b)`, so which rect overload a bare
    /// `contains` resolves to cannot quietly stop the assertion testing anything.
    private static func onScreen(_ frame: NSRect, _ screen: NSRect) -> Bool {
        frame.minX >= screen.minX && frame.maxX <= screen.maxX
            && frame.minY >= screen.minY && frame.maxY <= screen.maxY
    }

    // MARK: The table

    func testTheFrameIsNeverOffScreenAndNeverCoversAClearablePointer() {
        var cases = 0
        for screen in Self.screens {
            for pointer in Self.pointerPositions(in: screen.frame) {
                cases += 1
                let origin = ConfirmationWindowPlacement.frameOrigin(
                    contentWidth: Self.contentWidth,
                    frameHeight: Self.frameHeight,
                    pointer: pointer,
                    visibleFrame: screen.frame
                )
                let frame = Self.frame(origin: origin)

                XCTAssertTrue(
                    Self.onScreen(frame, screen.frame),
                    "\(screen.name), pointer at \(pointer): the frame \(frame) left the "
                        + "visible area \(screen.frame)"
                )
                if Self.canClear(pointer, in: screen.frame, frameHeight: Self.frameHeight) {
                    XCTAssertFalse(
                        frame.contains(pointer),
                        "\(screen.name), pointer at \(pointer): the frame \(frame) covers "
                            + "the pointer even though a frame fits beside it"
                    )
                }
            }
        }
        XCTAssertGreaterThanOrEqual(cases, 20, "a table this short is not a table")
    }

    /// Pointer positions per screen: the four corners inset by a point, the centre, three
    /// heights, and both fit boundaries from either side.
    private static func pointerPositions(in screen: NSRect) -> [NSPoint] {
        let inset: CGFloat = 1
        let clearance = ConfirmationWindowPlacement.clearance
        let line = screen.minY + frameHeight + clearance
        return [
            NSPoint(x: screen.minX + inset, y: screen.minY + inset),
            NSPoint(x: screen.maxX - inset, y: screen.minY + inset),
            NSPoint(x: screen.minX + inset, y: screen.maxY - inset),
            NSPoint(x: screen.maxX - inset, y: screen.maxY - inset),
            NSPoint(x: screen.midX, y: screen.midY),
            NSPoint(x: screen.midX, y: screen.minY + screen.height * 0.25),
            NSPoint(x: screen.midX, y: screen.minY + screen.height * 0.75),
            // Both sides of the line where the "below" fit test starts and stops working.
            NSPoint(x: screen.midX, y: line - 1),
            NSPoint(x: screen.midX, y: line),
            NSPoint(x: screen.midX, y: line + 1),
            // And the boundary the "above" fit test uses, from the other side.
            NSPoint(x: screen.midX, y: screen.maxY - frameHeight - clearance),
        ]
    }

    // MARK: The boundaries, pinned

    /// The branch switch happens exactly where the fit test says, not near it.
    ///
    /// The first version of this test assumed it happened one point later and was wrong,
    /// which is why both sides of the line are now explicit.
    func testTheBranchSwitchesExactlyAtTheFitBoundary() {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 1440)
        let clearance = ConfirmationWindowPlacement.clearance
        let line = visible.minY + Self.frameHeight + clearance

        let oneUnder = NSPoint(x: 700, y: line - 1)
        let exactlyOn = NSPoint(x: 700, y: line)

        let placedAbove = ConfirmationWindowPlacement.frameOrigin(
            contentWidth: Self.contentWidth, frameHeight: Self.frameHeight,
            pointer: oneUnder, visibleFrame: visible
        )
        let placedBelow = ConfirmationWindowPlacement.frameOrigin(
            contentWidth: Self.contentWidth, frameHeight: Self.frameHeight,
            pointer: exactlyOn, visibleFrame: visible
        )

        // "Below the pointer" is a *smaller* y in AppKit's y-up space.
        XCTAssertEqual(
            placedBelow.y, exactlyOn.y - clearance - Self.frameHeight, accuracy: 0.001,
            "the frame's top edge must be `clearance` under the cursor"
        )
        XCTAssertEqual(
            placedAbove.y, oneUnder.y + clearance, accuracy: 0.001,
            "and when it does not fit below, the frame's bottom edge is `clearance` over it"
        )
        XCTAssertGreaterThan(placedAbove.y, placedBelow.y, "the two branches must disagree")
    }

    /// The **frame** height is used, not the content height.
    ///
    /// This is the regression the whole file exists for. `NSWindow(contentRect:)` positions
    /// the content and the title bar goes *above* the given origin, so an origin chosen to
    /// clear the pointer by `clearance` on a content-sized height lands the frame's top
    /// edge inside the gap. One point of assertion here is worth more than the round-2
    /// four-run measurement, which could not have detected it.
    func testTheTitleBarIsCountedInTheGap() {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 1440)
        let clearance = ConfirmationWindowPlacement.clearance
        // Low enough that the frame must go above the pointer, which is where the
        // content-vs-frame confusion showed.
        let pointer = NSPoint(
            x: 700,
            y: visible.minY + Self.frameHeight + clearance - 5
        )

        let origin = ConfirmationWindowPlacement.frameOrigin(
            contentWidth: Self.contentWidth, frameHeight: Self.frameHeight,
            pointer: pointer, visibleFrame: visible
        )
        let frame = Self.frame(origin: origin)

        XCTAssertFalse(
            frame.contains(pointer),
            "a frame height that omitted the title bar would contain the pointer here"
        )
        XCTAssertEqual(frame.minY, pointer.y + clearance, accuracy: 0.001)
    }

    // MARK: Where the guarantee stops holding

    /// The round-2 comment claimed the fallback was reachable only below about 970 pt of
    /// visible height. The table shows otherwise and this pins it: on a 1440×900 screen —
    /// taller than that claim — a pointer in the middle band cannot be cleared, because
    /// twice (488 + 24) does not fit in 900.
    func testTheMiddleBandIsWhereTheGuaranteeStopsHolding() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let clearance = ConfirmationWindowPlacement.clearance
        // The band is where a frame fits on *neither* side: above `clearedLow` a frame
        // fits underneath the cursor, below `clearedHigh` it fits on top, and between
        // them neither is possible.
        let clearedLow = screen.maxY - Self.frameHeight - clearance
        let clearedHigh = screen.minY + Self.frameHeight + clearance

        XCTAssertTrue(
            Self.canClear(
                NSPoint(x: 700, y: clearedLow - 1), in: screen, frameHeight: Self.frameHeight
            ),
            "a pointer just under the band can be cleared, or the band is not where this says"
        )
        XCTAssertTrue(
            Self.canClear(
                NSPoint(x: 700, y: clearedHigh + 1), in: screen, frameHeight: Self.frameHeight
            ),
            "and so can one just over it"
        )
        XCTAssertFalse(
            Self.canClear(
                NSPoint(x: 700, y: screen.midY), in: screen, frameHeight: Self.frameHeight
            ),
            "a mid-screen pointer on a 900pt screen cannot be cleared"
        )
        XCTAssertGreaterThan(
            clearedHigh, clearedLow,
            "precondition: the band on this screen is "
                + "\(Int(clearedHigh - clearedLow))pt tall"
        )
    }

    /// The documented exception, asserted rather than assumed: the frame stays on the
    /// screen, and the pointer *is* inside it — which is why the window's hover gate is
    /// load-bearing on a short display and defence in depth on a tall one.
    func testTheFallbackStaysOnScreenAndIsTheOneCaseThatOverlaps() {
        let short = NSRect(x: 0, y: 0, width: 1280, height: 800)
        let pointer = NSPoint(x: 640, y: short.midY)
        let origin = ConfirmationWindowPlacement.frameOrigin(
            contentWidth: Self.contentWidth, frameHeight: Self.frameHeight,
            pointer: pointer, visibleFrame: short
        )
        let frame = Self.frame(origin: origin)

        XCTAssertFalse(
            Self.canClear(pointer, in: short, frameHeight: Self.frameHeight),
            "precondition: an \(Int(Self.frameHeight))pt frame cannot sit entirely on "
                + "either side of a pointer at the middle of an 800pt screen"
        )
        XCTAssertTrue(
            Self.onScreen(frame, short), "the fallback must still stay on the screen"
        )
        XCTAssertEqual(
            origin.y, short.maxY - Self.frameHeight, accuracy: 0.001,
            "the fallback is the top of the visible area, where the title bar is furthest "
                + "from a cursor low on the screen"
        )
    }

    // MARK: Horizontal

    /// Centred on the pointer and clamped to its own screen — including a display whose
    /// origin is not (0, 0), where clamping against a hardcoded zero would put the window
    /// on the neighbouring display or off both.
    func testTheWindowIsCentredOnThePointerAndClampedToItsOwnScreen() {
        let second = NSRect(x: 2560, y: -1200, width: 1920, height: 1080)
        for pointer in [
            NSPoint(x: second.minX + 1, y: second.midY),
            NSPoint(x: second.maxX - 1, y: second.midY),
            NSPoint(x: second.midX, y: second.midY),
        ] {
            let origin = ConfirmationWindowPlacement.frameOrigin(
                contentWidth: Self.contentWidth, frameHeight: Self.frameHeight,
                pointer: pointer, visibleFrame: second
            )
            XCTAssertTrue(
                Self.onScreen(Self.frame(origin: origin), second),
                "pointer at \(pointer) put the frame off its own display \(second)"
            )
        }

        // Centred, when there is room: x is the pointer's, less half the width.
        let roomy = NSRect(x: 0, y: 0, width: 2560, height: 1440)
        let origin = ConfirmationWindowPlacement.frameOrigin(
            contentWidth: Self.contentWidth, frameHeight: Self.frameHeight,
            pointer: NSPoint(x: 1280, y: 1000), visibleFrame: roomy
        )
        XCTAssertEqual(origin.x, 1280 - Self.contentWidth / 2, accuracy: 0.001)
    }
}