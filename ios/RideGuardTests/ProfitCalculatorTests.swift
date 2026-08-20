import XCTest
@testable import RideGuardCore

/// The numbers in here are the same ones asserted in the Kotlin
/// `ProfitCalculatorTest`. That is the point: a driver who checks the same
/// offer on an iPhone and on an Android phone must get the same verdict, or
/// neither app is trustworthy.
final class ProfitCalculatorTests: XCTestCase {

    /// 7 L/100km at 7.5 RON/L = 0.525 RON/km fuel, plus 0.35 RON/km wear.
    private let car = VehicleProfile(
        label: "Logan",
        fuelType: .petrol,
        consumptionPer100km: 7.0,
        energyPrice: 7.5,
        currency: "RON",
        wearCostPerKm: 0.35
    )

    private let thresholds = DriverThresholds(
        minNetPerHour: 40.0,
        minNetPerKm: 1.5,
        maxDeadheadRatio: 0.8
    )

    private func calc(commission: Double = 0.0) -> ProfitCalculator {
        ProfitCalculator(vehicle: car, thresholds: thresholds, commissionRateFor: { _ in commission })
    }

    private func offer(
        fare: Double,
        pickupKm: Double?,
        pickupMin: Double?,
        tripKm: Double?,
        tripMin: Double?,
        net: Bool = true,
        confidence: Float = 1
    ) -> RideOffer {
        RideOffer(
            platform: .bolt,
            fare: fare,
            currency: "RON",
            pickupKm: pickupKm,
            pickupMin: pickupMin,
            tripKm: tripKm,
            tripMin: tripMin,
            fareIsNet: net,
            parseConfidence: confidence
        )
    }

    func testCostIsChargedOnPickupPlusTripNotJustThePaidLeg() throws {
        // 2 km pickup + 8 km trip = 10 km of real driving.
        let e = try XCTUnwrap(calc().evaluate(offer(fare: 40.0, pickupKm: 2.0, pickupMin: 5.0, tripKm: 8.0, tripMin: 15.0)))

        XCTAssertEqual(e.totalKm, 10.0, accuracy: 1e-9)
        XCTAssertEqual(e.energyCost, 10.0 * 0.525, accuracy: 1e-9)   // 5.25
        XCTAssertEqual(e.wearCost, 10.0 * 0.35, accuracy: 1e-9)      // 3.50
        XCTAssertEqual(e.net, 40.0 - 5.25 - 3.50, accuracy: 1e-9)    // 31.25
    }

    func testAGoodOfferClearsEverything() throws {
        // 31.25 net over 10 km and 20 min -> 3.13 RON/km, 93.75 RON/h.
        let e = try XCTUnwrap(calc().evaluate(offer(fare: 40.0, pickupKm: 2.0, pickupMin: 5.0, tripKm: 8.0, tripMin: 15.0)))

        XCTAssertEqual(e.netPerKm, 3.125, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(e.netPerHour), 93.75, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(e.deadheadRatio), 0.25, accuracy: 1e-9)
        XCTAssertEqual(e.verdict, .good)
        XCTAssertEqual(e.reasons, ["Clears every target"])
        XCTAssertFalse(e.isLossMaking)
    }

    func testTheClassicTrapLongPickupForAShortCheapRideIsALoss() throws {
        // The offer that LOOKS survivable: 6 lei, 5 km to collect, 2 km paid.
        // 7 km x 0.875 RON/km = 6.125 of cost against 6.00 of fare.
        let e = try XCTUnwrap(calc().evaluate(offer(fare: 6.0, pickupKm: 5.0, pickupMin: 12.0, tripKm: 2.0, tripMin: 6.0)))

        XCTAssertEqual(e.totalKm, 7.0, accuracy: 1e-9)
        XCTAssertEqual(e.net, 6.0 - 3.675 - 2.45, accuracy: 1e-9)    // -0.125
        XCTAssertTrue(e.isLossMaking, "should be loss-making")
        XCTAssertEqual(e.verdict, .bad)
        XCTAssertEqual(try XCTUnwrap(e.deadheadRatio), 2.5, accuracy: 1e-9)
        XCTAssertTrue(e.reasons.contains { $0.contains("Loses") })
    }

    func testALongDeadheadSinksAnOfferThatLooksFineOnTheCard() throws {
        // 30 lei is a perfectly respectable-looking fare. You drive 9 km to
        // collect for a 6 km ride, so the real numbers are 1.13 RON/km and
        // 33.75 RON/h against a 1.5 and 40 bar: three misses, so BAD.
        let e = try XCTUnwrap(calc().evaluate(offer(fare: 30.0, pickupKm: 9.0, pickupMin: 18.0, tripKm: 6.0, tripMin: 12.0)))

        XCTAssertEqual(e.totalKm, 15.0, accuracy: 1e-9)
        XCTAssertEqual(e.net, 16.875, accuracy: 1e-9)
        XCTAssertFalse(e.isLossMaking, "it still makes money — that is what makes it a trap")
        XCTAssertEqual(e.netPerKm, 1.125, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(e.netPerHour), 33.75, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(e.deadheadRatio), 1.5, accuracy: 1e-9)
        XCTAssertEqual(e.verdict, .bad)
        XCTAssertTrue(e.reasons.contains { $0.contains("Long pickup") })
    }

    func testASingleMissIsMarginalNotBad() throws {
        // Same shape, but the fare covers the per-hour bar: only the deadhead
        // ratio misses, so the driver gets to use their judgement.
        let e = try XCTUnwrap(calc().evaluate(offer(fare: 60.0, pickupKm: 9.0, pickupMin: 10.0, tripKm: 6.0, tripMin: 12.0)))

        XCTAssertEqual(try XCTUnwrap(e.deadheadRatio), 1.5, accuracy: 1e-9)
        XCTAssertEqual(e.verdict, .marginal)
        XCTAssertEqual(e.reasons.count, 1)
    }

    func testGrossFareHasCommissionRemovedBeforeCosts() throws {
        // Bolt-style: card shows 50 gross, platform takes 20%.
        let calculator = ProfitCalculator(vehicle: car, thresholds: thresholds, commissionRateFor: { _ in 0.20 })
        let e = try XCTUnwrap(calculator.evaluate(
            offer(fare: 50.0, pickupKm: 2.0, pickupMin: 5.0, tripKm: 8.0, tripMin: 15.0, net: false)
        ))

        XCTAssertEqual(e.gross, 50.0, accuracy: 1e-9)
        XCTAssertEqual(e.commission, 10.0, accuracy: 1e-9)
        XCTAssertEqual(e.net, 40.0 - 5.25 - 3.50, accuracy: 1e-9)
    }

    func testNetFareReconstructsTheGrossForDisplay() throws {
        // Uber-style: card shows 40 already net, platform took 20%.
        let calculator = ProfitCalculator(vehicle: car, thresholds: thresholds, commissionRateFor: { _ in 0.20 })
        let e = try XCTUnwrap(calculator.evaluate(
            offer(fare: 40.0, pickupKm: 2.0, pickupMin: 5.0, tripKm: 8.0, tripMin: 15.0, net: true)
        ))

        XCTAssertEqual(e.gross, 50.0, accuracy: 1e-6)
        XCTAssertEqual(e.commission, 10.0, accuracy: 1e-6)
        XCTAssertEqual(e.net, 40.0 - 5.25 - 3.50, accuracy: 1e-9)
    }

    func testABarelyReadCardReturnsUnknownRatherThanBluffingAGreenLight() throws {
        let e = try XCTUnwrap(calc().evaluate(
            offer(fare: 40.0, pickupKm: 2.0, pickupMin: 5.0, tripKm: 8.0, tripMin: 15.0, confidence: 0.4)
        ))
        XCTAssertEqual(e.verdict, .unknown)
    }

    func testMissingTimeStillYieldsPerKmNumbers() throws {
        let e = try XCTUnwrap(calc().evaluate(offer(fare: 40.0, pickupKm: 2.0, pickupMin: nil, tripKm: 8.0, tripMin: nil)))

        XCTAssertEqual(e.netPerKm, 3.125, accuracy: 1e-6)
        XCTAssertNil(e.netPerHour)
        XCTAssertNil(e.totalMin)
    }

    func testElectricCarCostsAreComputedOffKWh() throws {
        let ev = VehicleProfile(
            fuelType: .electric,
            consumptionPer100km: 18.0,   // kWh/100km
            energyPrice: 1.2,            // RON/kWh
            wearCostPerKm: 0.25
        )
        let calculator = ProfitCalculator(vehicle: ev, thresholds: thresholds, commissionRateFor: { _ in 0.0 })
        let e = try XCTUnwrap(calculator.evaluate(
            offer(fare: 40.0, pickupKm: 2.0, pickupMin: 5.0, tripKm: 8.0, tripMin: 15.0)
        ))

        XCTAssertEqual(e.energyCost, 10.0 * 0.216, accuracy: 1e-9)
        XCTAssertTrue(e.net > 35.0)
    }

    func testAnOfferWithNoDistanceIsNotComputable() {
        XCTAssertNil(calc().evaluate(offer(fare: 40.0, pickupKm: nil, pickupMin: 5.0, tripKm: nil, tripMin: 15.0)))
        XCTAssertNil(calc().evaluate(offer(fare: 0.0, pickupKm: 2.0, pickupMin: 5.0, tripKm: 8.0, tripMin: 15.0)))
    }

    /// A single-leg parse (pickup unknown) must not be flattered by pretending
    /// the deadhead was zero: `totalKm` is nil, so there is nothing to compute.
    func testAPartialParseRefusesToInventAZeroKmPickup() {
        XCTAssertNil(calc().evaluate(offer(fare: 20.0, pickupKm: nil, pickupMin: nil, tripKm: 6.0, tripMin: 14.0)))
    }
}
