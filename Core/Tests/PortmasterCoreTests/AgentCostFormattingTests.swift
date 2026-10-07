// Formatting for the Agent Sessions card.
//
// Both formatters exist because a fixed rendering is wrong at one end or the other:
// token counts span four orders of magnitude, and costs span a cent to a hundred
// dollars. These are the parts of a UI nobody can look at on the machine this was
// written on, so they are pinned here instead.
import XCTest
@testable import PortmasterCore

final class AgentCostFormattingTests: XCTestCase {

    // MARK: - Money

    /// A real cost is never rounded to nothing. A session that spent a fraction of a
    /// cent and displayed `$0.00` would say it was free.
    func testASubCentCostIsNotShownAsZero() {
        XCTAssertNotEqual(Fmt.usd(Decimal(string: "0.0004")!), "$0.00")
        XCTAssertEqual(Fmt.usd(Decimal(string: "0.0004")!), "$0.0004")
    }

    func testZeroIsZero() {
        XCTAssertEqual(Fmt.usd(Decimal(0)), "$0.00")
    }

    /// Above a dollar, two places — which is what an invoice shows. More would be
    /// noise the user cannot act on.
    func testLargerAmountsUseTwoPlaces() {
        XCTAssertEqual(Fmt.usd(Decimal(string: "2.5")!), "$2.50")
        XCTAssertEqual(Fmt.usd(Decimal(string: "1234.5")!), "$1,234.50")
    }

    func testThousandsAreGrouped() {
        XCTAssertEqual(Fmt.usd(Decimal(string: "1234")!), "$1,234.00")
    }

    /// Sums must stay exact, and this is why sub-dollar figures are not formatted to
    /// a fixed scale: `0.0000075` rounded to six places is `0.000008`, a different
    /// number from the one computed. A display that quietly changes a cost is the
    /// failure this project keeps refusing.
    func testSummedCostsStayExact() {
        let a = Decimal(string: "0.0000015")!
        let b = Decimal(string: "0.000006")!
        XCTAssertEqual(Fmt.usd(a + b), "$0.0000075")
    }

    // MARK: - Tokens

    func testSmallCountsAreExact() {
        XCTAssertEqual(Fmt.tokens(0), "0")
        XCTAssertEqual(Fmt.tokens(999), "999")
    }

    func testThousandsAndMillions() {
        XCTAssertEqual(Fmt.tokens(1_000), "1K")
        XCTAssertEqual(Fmt.tokens(1_500), "1.5K")
        XCTAssertEqual(Fmt.tokens(1_000_000), "1M")
        XCTAssertEqual(Fmt.tokens(2_400_000), "2.4M")
    }

    /// `12.0K` is noise; `12K` is what a provider's own page shows, and comparing
    /// against that is the point of reading a token count.
    func testWholeUnitsDropTheDecimal() {
        XCTAssertEqual(Fmt.tokens(12_000), "12K")
        XCTAssertFalse(Fmt.tokens(12_000).contains("."))
    }

    /// The boundary itself: 999 is three digits, 1000 is one. An off-by-one here
    /// would print `1000` beside `1K` in the same column.
    func testTheThousandsBoundaryIsCorrect() {
        XCTAssertEqual(Fmt.tokens(999), "999")
        XCTAssertEqual(Fmt.tokens(1_000), "1K")
    }
}