// ConfirmationWindowPlacement: where the "Confirm AI Request" window may go.
//
// The one rule: **never under the pointer, wherever the screen is tall enough to put
// the window entirely on one side of it.** Not "the button is disabled until the pointer
// arrives" — never *under*. The window is a destructive consent prompt, and a prompt that
// appears beneath a stationary cursor is one stray click from approving itself.
//
// That is not hypothetical: three end-to-end runs recorded `outcome: "allowed"` for a
// mutation nobody approved, and the measurement that explained it logged the pointer at
// (457, 53) with the window at (0, 30, 520, 462) — the Approve button's centre. Nothing
// had moved the pointer.
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
        return fallback(
            x: x, pointer: pointer, visibleFrame: visibleFrame, frameHeight: frameHeight
        )
    }

    /// Neither side fits, so the window has to overlap the pointer's row.
    ///
    /// **Reachable for any pointer in the middle band of the screen.** A frame clears the
    /// pointer when it fits below it (`pointer.y - clearance - frameHeight >= minY`) or
    /// above it (`pointer.y + clearance + frameHeight <= maxY`), so the band where neither
    /// holds spans `2 * (clearance + frameHeight)` of the screen and every display shorter
    /// than that has one. A pointer near the top or bottom of the screen is always
    /// cleared; a pointer near the middle is not, because the frame cannot sit entirely on
    /// one side of it.
    ///
    /// (Round 2 of this comment claimed the fallback was only for displays under about
    /// 970 pt; round 3 quoted 1072 and a 364 pt band, which were wrong *and mutually
    /// inconsistent* with the formula above them. `ConfirmationWindowPlacementTests` now
    /// asserts the figures — but it asserts them for **a 460 pt content view with a 28 pt
    /// title bar**, which is the frame height the test assumes. Production measures
    /// whatever AppKit reports for the window it actually has, so treat those numbers as
    /// worked examples of the formula, not as this app's constants.)
    ///
    /// The honest consequence: when the pointer is mid-screen, it *can* end up inside the
    /// frame, and the window's `onHover` gate is then the thing standing between a parked
    /// cursor and a consent. The gate is defence in depth everywhere else and load-bearing
    /// here, which is why it was kept.
    ///
    /// Placed in whichever half the pointer is **not** in, so a mid-band cursor lands near
    /// the window's *header* rather than its footer — the footer is where Approve and Deny
    /// live, and the one thing worth avoiding is the cursor coming to rest on the
    /// destructive button when the geometry has already had to give up.
    ///
    /// An improvement, not a fix: the pointer is inside the frame either way, which is
    /// what `fallback`'s own doc says, and the `onHover` gate is what prevents the click.
    /// What changes is which end of the window the cursor ends up near.
    ///
    /// **The result is clamped back into `visibleFrame`** — round 4 returned the two
    /// placements raw and round 3 clamped. Restored, because the degenerate case it covers
    /// is a window taller than the screen, and then something has to be cut. Clamping to
    /// `minY` pins the window's **origin** to the bottom of the screen, so the part that
    /// leaves is the **title bar** at the top — and the footer, which holds Deny, Approve
    /// and the countdown, stays on screen. (Round 5 had this backwards and said the
    /// opposite; the failing assertion in `ConfirmationWindowPlacementTests` now names the
    /// title bar, because that is the string a red test prints.) Unreachable on any real display
    /// — a 488 pt window on a sub-488 pt visible frame does not exist — but the cheap way
    /// to lose the wrong end of a window is to not clamp at all.
    static func fallback(
        x: CGFloat, pointer: NSPoint, visibleFrame: NSRect, frameHeight: CGFloat
    ) -> NSPoint {
        let low = visibleFrame.minY + frameHeight / 2
        let chosen = pointer.y < low ? visibleFrame.maxY - frameHeight : visibleFrame.minY
        return NSPoint(
            x: x,
            y: max(visibleFrame.minY, min(chosen, visibleFrame.maxY - frameHeight))
        )
    }
}
