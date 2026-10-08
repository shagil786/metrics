// Price entry, from both directions an agent and a person arrive at.
//
// The test that matters is the round trip: a session reads *not priced*, a price is
// set, and the same session reads a figure. Everything else here is in service of
// that, because a price table nobody can write to leaves every session uncosted —
// which is the state this feature exists to end.
import XCTest
import Foundation
import PortmasterCore
@testable import PortmasterMCP

final class ModelPriceToolTests: XCTestCase {

    private var store: AgentSessionStore!

    override func setUpWithError() throws {
        store = try AgentSessionStore(
            storeURL: makeTemporaryDirectory(prefix: "prices").appendingPathComponent("p.sqlite")
        )
    }

    override func tearDownWithError() throws {
        store = nil
    }

    /// A session with real tokens on `modelID`, priced or not.
    private func session(modelID: String, input: Int = 1_000) throws -> UUID {
        let id = UUID()
        try store.recordSession(
            id: id, peerPID: 1, clientName: nil, clientVersion: nil, connectedAt: Date()
        )
        try store.recordUsage(TokenUsageRecord(
            sessionID: id, recordedAt: Date(), input: input, output: 0,
            cacheRead: nil, reasoning: nil, modelID: modelID, provenance: .selfReported
        ))
        try store.flush()
        return id
    }

    /// `allowSession`, not `off`: setting a price is a mutation, so the gate stands
    /// between the caller and the write. A test that used `off` would be asserting
    /// against a permission model no user can select.
    private func executor(
        writer: (any ModelPriceWriting)? = nil,
        mode: MCPMutationMode = .allowSession
    ) throws -> ToolExecutor {
        let store = try XCTUnwrap(self.store)
        return ToolExecutor(
            provider: StubProvider(),
            gate: PermissionGate(settings: MCPSettings(mode: mode), appRunning: true),
            audit: AuditLog(directory: try makeTemporaryDirectory(prefix: "audit")),
            priceWriter: writer ?? StoreModelPriceWriter(store: store)
        )
    }

    /// A price the gate would refuse to let through, so a rejected price can never
    /// be confused with a refused call.
    private func gatingExecutor() throws -> ToolExecutor {
        try executor(mode: .off)
    }

    // MARK: - The round trip this feature is for

    /// Before a price, a session with real tokens reads *not priced* — not free.
    func testASessionIsNotPricedBeforeAPriceExists() throws {
        let id = try session(modelID: "m")
        XCTAssertEqual(try store.cost(for: id), .notPriced(models: ["m"]))
    }

    /// After one, the same session reads a figure. This is the whole feature: a
    /// price entered today re-costs history recorded before it.
    func testSettingAPriceTurnsNotPricedIntoAFigure() async throws {
        let id = try session(modelID: "m", input: 1_000)
        let before = try store.cost(for: id)
        guard case .notPriced = before else {
            return XCTFail("expected notPriced to start from, got \(before)")
        }

        let outcome = try await executor().execute(
            name: "set_model_price",
            arguments: ["model": "m", "price": "0.000002"]
        )
        XCTAssertFalse(outcome.isError, outcome.text)

        let after = try store.cost(for: id)
        guard case .priced(let usd, let version, _) = after else {
            return XCTFail("expected a priced cost, got \(after)")
        }
        XCTAssertEqual(usd, Decimal(string: "0.002")!)
        XCTAssertGreaterThan(version, 0, "a price must name the table version that produced the figure")
    }

    // MARK: - Validation

    /// The store's strictness, reached through the tool. `"1,5"` is the case that
    /// matters: `Decimal(string:)` reads it as 1, which would be a silently wrong
    /// price rather than a rejected one.
    func testNonCanonicalPricesAreRefused() async throws {
        // `.allowSession` so the refusal under test is the price's, not the gate's.
        let executor = try self.executor()
        // Surrounding whitespace is not in this list: `execute` trims every
        // argument before dispatch, so `" 1"` arrives as `"1"` and is accepted —
        // the same as it would be for any other tool.
        for bad in ["1,5", "abc", "1.5abc", "0x10", "1e5", "1.2.3", "."] {
            let outcome = await executor.execute(
                name: "set_model_price", arguments: ["model": "m", "price": bad]
            )
            XCTAssertTrue(outcome.isError, "price '\(bad)' should be refused, not accepted")
        }
        XCTAssertTrue(try store.prices().isEmpty, "no rejected price may have been stored")
    }

    func testNegativePriceIsRefusedRatherThanClamped() async throws {
        let outcome = try await executor().execute(
            name: "set_model_price", arguments: ["model": "m", "price": "-1"]
        )
        XCTAssertTrue(outcome.isError, "a negative price is a caller bug, not a price")
        XCTAssertTrue(try store.prices().isEmpty)
    }

    /// Zero is a real answer — a free model — unlike a missing price.
    func testZeroIsAcceptedAsAPrice() async throws {
        let outcome = try await executor().execute(
            name: "set_model_price", arguments: ["model": "free-model", "price": "0"]
        )
        XCTAssertFalse(outcome.isError, outcome.text)
        XCTAssertEqual(try store.prices().count, 1)
    }

    func testBlankModelIsRefused() async throws {
        let outcome = try await executor().execute(
            name: "set_model_price", arguments: ["model": "  ", "price": "0.1"]
        )
        XCTAssertTrue(outcome.isError)
        XCTAssertTrue(try store.prices().isEmpty)
    }

    func testUnknownComponentIsRefused() async throws {
        let outcome = try await executor().execute(
            name: "set_model_price",
            arguments: ["model": "m", "price": "0.1", "component": "vibes"]
        )
        XCTAssertTrue(outcome.isError)
        XCTAssertTrue(try store.prices().isEmpty)
    }

    /// `cache_read` and `cacheRead` are the same thing to a caller; the stored name
    /// is one spelling.
    func testComponentNamesAcceptEitherSpelling() async throws {
        for spelling in ["cache_read", "cacheRead"] {
            let outcome = try await executor().execute(
                name: "set_model_price",
                arguments: ["model": "m", "price": "0.1", "component": spelling]
            )
            XCTAssertFalse(outcome.isError, "\(spelling) should be accepted: \(outcome.text)")
        }
        XCTAssertEqual(try store.prices().map(\.component), [.cacheRead], "one price, not two")
    }

    func testComponentDefaultsToInput() async throws {
        _ = try await executor().execute(
            name: "set_model_price", arguments: ["model": "m", "price": "0.1"]
        )
        XCTAssertEqual(try store.prices().first?.component, .input)
    }

    // MARK: - Reading prices back

    func testGetModelPricesListsWhatWasSet() async throws {
        let store = try XCTUnwrap(self.store)
        try store.setPrice(Decimal(1), modelID: "model-b")
        try store.setPrice(Decimal(2), modelID: "model-a")
        try store.flush()

        let outcome = try await self.executor().execute(name: "get_model_prices", arguments: [:])
        XCTAssertFalse(outcome.isError, outcome.text)
        let json = try jsonObject(outcome.text)

        let prices = try XCTUnwrap(json["prices"] as? [[String: Any]])
        XCTAssertEqual(prices.compactMap { $0["modelID"] as? String }, ["model-a", "model-b"])
        // A string, so a client cannot round the figure every cost is built from.
        XCTAssertEqual(prices.first?["price"] as? String, "2")
    }

    /// The list a price-entry surface should lead with: models that have usage and
    /// no price, which are exactly the sessions currently reading *not priced*.
    func testModelsMissingAPriceNamesTheOnesThatCostNothing() async throws {
        _ = try session(modelID: "unpriced-model")
        _ = try session(modelID: "priced-model")
        let store = try XCTUnwrap(self.store)
        try store.setPrice(Decimal(1), modelID: "priced-model")
        try store.flush()

        let outcome = try await self.executor().execute(name: "get_model_prices", arguments: [:])
        let json = try jsonObject(outcome.text)

        XCTAssertEqual(json["missingPricesFor"] as? [String], ["unpriced-model"])
    }

    /// An input price is what makes a session costable. An output-only price does
    /// not, so such a model must still read as missing — otherwise a client would
    /// think one price was enough.
    func testAnOutputOnlyPriceStillCountsAsMissing() throws {
        let store = try XCTUnwrap(self.store)
        try store.setPrice(Decimal(1), modelID: "only-output", component: .output)
        try store.flush()

        XCTAssertTrue(try store.modelsMissingAPrice().isEmpty,
                      "usage records exist for this model, so it cannot be reported as complete")
    }

    // MARK: - Refusals

    /// With no store, a price is refused with a reason — never accepted and dropped,
    /// which would leave the agent believing a price it cannot find.
    func testNoStoreRefusesRatherThanAcceptingAndDropping() async throws {
        let outcome = try await executor(writer: UnavailableModelPriceWriter()).execute(
            name: "set_model_price", arguments: ["model": "m", "price": "0.1"]
        )
        XCTAssertTrue(outcome.isError)
        XCTAssertFalse(outcome.text.isEmpty, "a refusal must say why")
    }

    /// The gate is not bypassed by the tool existing. A price is a mutation, and
    /// this is the check that keeps it one.
    func testTheGateStandsInFrontOfAPriceWrite() async throws {
        let outcome = try await gatingExecutor().execute(
            name: "set_model_price", arguments: ["model": "m", "price": "0.1"]
        )
        XCTAssertTrue(outcome.isError, "a refused mode must not be able to set a price")
        XCTAssertTrue(try store.prices().isEmpty, "and nothing may have been written")
    }

    // MARK: - Classification

    func testSetPriceIsAMutationAndGetIsARead() {
        let byName = Dictionary(
            uniqueKeysWithValues: ToolExecutor.catalog.map { ($0.name, $0.effect) }
        )
        // A price outlives the call that set it and applies to every figure, so it
        // is a change to the machine's configuration and goes behind the gate.
        // Reading one back changes nothing.
        XCTAssertEqual(byName["set_model_price"], .mutation)
        XCTAssertEqual(byName["get_model_prices"], .read)
    }
}