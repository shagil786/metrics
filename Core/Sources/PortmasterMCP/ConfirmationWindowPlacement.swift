// ConfirmationWindowPlacement: where the "Confirm AI Request" window may go.
//
// The one rule: **never under the pointer.** Not "the button is disabled until the
// pointer arrives" — never *under*. The window is a destructive consent prompt, and a
// prompt that appears beneath a stationary cursor is one stray click from approving
// itself. That is not hypothetical: three end-to-end runs recorded `outcome: "allowed"`
// for a mutation nobody approved, and the measurement that explained it logged the
// pointer at (457, 53) with the window at (0, 30, 520, 462) — the Approve button's
// centre. Nothing had moved the pointer.
//
// **Everything here is in *frame* space, not content space, and that distinction is the
// whole reason this file exists.** `NSWindow(contentRect:)` positions the content; the
// frame is the content plus the title bar, and the bar sits *above* the given origin. An
// origin chosen so that `origin.y == pointer.y - 24` puts the frame's top edge at
// `pointer.y - 24 + titleBarThickness` — inside the very gap the arithmetic claimed. The
// first version of this function did exactly that, in `App/`, and could not be tested
// because the App target has no test suite; the arithmetic it got wrong was invisible for
// exactly that reason.
//
// Pure, with no AppKit in it, so the placement is a table test rather than a parked
// pointer on somebody's machine. The caller passes the frame height because measuring it
// needs AppKit (`NSWindow.frameRect(forContentRect:styleMask:)`).

import Foundation

/// Where a confirmation window of a given size must be placed.
public enum ConfirmationWindowPlacement {

    /// Gap between the pointer and the nearest edge of the window's **frame**.
    ///
    /// Comfortably more than the Approve button's own inset, so the pointer is nowhere
    /// near the button rather than merely off its centre.
    public static let clearance: CGFloat = 24

    /// The frame origin that keeps `pointer` outside the window.
    ///
    /// Placed **below** the pointer where that fits — in AppKit's y-up space "below" is
    /// the smaller `y`, which is what a person means by appearing under the thing they
    /// were looking at — and **above** it otherwise. Both axes are clamped to
    /// `visibleFrame`, so a pointer near an edge cannot push the question off the screen,
    /// and horizontally the window is centred on the pointer rather than stuck to a
    /// corner, which is also what stops it appearing somewhere the person has to find.
    ///
    /// - Parameters:
    ///   - contentWidth: the content width. A titled window's frame and content share a
    ///     width, so this is the frame's too.
    ///   - frameHeight: `NSWindow.frameRect(forContentRect:styleMask:).height` — the
    ///     content height **plus the title bar**. Passing the content height here is the
    ///     bug this function exists to prevent.
    ///   - visibleFrame: the usable area of the screen the pointer is on.
    /// - Returns: a frame origin, always inside `visibleFrame`. The pointer is outside
    ///   the returned frame **whenever the screen is tall enough to put a frame entirely
    ///   on one side of it** — which is everywhere except the middle band described on
    ///   `fallback`.
    public static func frameOrigin(
        contentWidth: CGFloat,
        frameHeight: CGFloat,
        pointer: NSPoint,
        visibleFrame: NSRect
    ) -> NSPoint {
        let halfWidth = contentWidth / 2
        let x = min(
            max(visibleFrame.minX, pointer.x - halfWidth),
            max(visibleFrame.minX, visibleFrame.maxX - contentWidth)
        )

        // Below the pointer: the frame's top edge is `clearance` under the cursor, so
        // the cursor is outside the frame by construction.
        let below = pointer.y - clearance - frameHeight
        if below >= visibleFrame.minY {
            return NSPoint(x: x, y: below)
        }
        // Above it: the frame's bottom edge is `clearance` over the cursor.
        let above = pointer.y + clearance
        if above + frameHeight <= visibleFrame.maxY {
            return NSPoint(x: x, y: above)
        }
        return fallback(x: x, visibleFrame: visibleFrame, frameHeight: frameHeight)
    }

    /// Neither side fits, so the window has to overlap the pointer's row.
    ///
    /// **Reachable for any pointer in the middle band of the screen**, and the band is
    /// non-empty on every display shorter than `2 * (clearance + frameHeight)` — about
    /// 1072 pt of usable height with this window, which includes 1440×900 and 1280×800
    /// laptops as well as the 970 pt case first claimed. A pointer near the top or
    /// bottom of the screen is always cleared; a pointer near the middle is not, because
    /// a 488 pt frame cannot sit entirely on one side of it.
    ///
    /// (A round-2 version of this comment claimed the fallback was only for displays
    /// under about 970 pt. The table test in
    /// `ConfirmationWindowPlacementTests` showed that wrong — 1440×900 has a 364 pt
    /// middle band — so the precondition is stated as it actually is.)
    ///
    /// The honest consequence: when the pointer is mid-screen, it *can* end up inside the
    /// frame, and the window's `onHover` gate is then the thing standing between a parked
    /// cursor and a consent. The gate is defence in depth everywhere else and load-bearing
    /// here, which is why it was kept.
    ///
    /// Pinned to the top of the visible area, where the title bar is furthest from the
    /// pointer for a cursor in the lower half of the screen.
    static func fallback(x: CGFloat, visibleFrame: NSRect, frameHeight: CGFloat) -> NSPoint {
        NSPoint(x: x, y: max(visibleFrame.minY, visibleFrame.maxY - frameHeight))
    }
}