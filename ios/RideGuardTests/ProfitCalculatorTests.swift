import XCTest
@testable import RideGuardCore

/// The numbers in here are the same ones asserted in the Kotlin
/// `ProfitCalculatorTest`. That is the point: a driver who checks the same
/// offer on an iPhone and on an Android phone must get the same verdict, or
/// neither app is trustworthy.
final class ProfitCalculatorTests: XCTestCase {

    /// 7 L/100km at 7.5 RON/L = 0.525 RON/km. Fuel is the whole cost model.
    private let car = VehicleProfile(
        label: "Logan",
        fuelType: .petrol,
        consumptionPer100km: 7.0,
        energyPrice: 7.5,
        currency: "RON"
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
        XCTAssertEqual(e.net, 40.0 - 5.25, accuracy: 1e-9)           // 34.75
        XCTAssertEqual(e.totalCost, e.energyCost, accuracy: 1e-9)
    }

    func testAGoodOfferClearsEverything() throws {
        // 34.75 net over 10 km and 20 min -> 3.475 RON/km, 104.25 RON/h.
        let e = try XCTUnwrap(calc().evaluate(offer(fare: 40.0, pickupKm: 2.0, pickupMin: 5.0, tripKm: 8.0, tripMin: 15.0)))

        XCTAssertEqual(e.netPerKm, 3.475, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(e.netPerHour), 104.25, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(e.deadheadRatio), 0.25, accuracy: 1e-9)
        XCTAssertEqual(e.verdict, .good)
        XCTAssertEqual(e.reasons, ["Clears every target"])
        XCTAssertFalse(e.isLossMaking)
    }

    /// The headline is charged on the FULL distance, so it is always below the
    /// per-km figure a driver would get by dividing the fare by the paid leg.
    /// That gap is the app.
    func testEarningsPerKmUsesEveryKilometreTheCarMoves() throws {
        let e = try XCTUnwrap(calc().evaluate(offer(fare: 40.0, pickupKm: 2.0, pickupMin: 5.0, tripKm: 8.0, tripMin: 15.0)))

        XCTAssertEqual(e.afterCommission, 40.0, accuracy: 1e-9)
        XCTAssertEqual(e.earningsPerKm, 4.0, accuracy: 1e-9)         // 40 / 10, not 40 / 8
        XCTAssertEqual(e.costPerKm, 0.525, accuracy: 1e-9)
        XCTAssertEqual(e.earningsPerKm - e.costPerKm, e.netPerKm, accuracy: 1e-9)
    }

    func testTheClassicTrapLongPickupForAShortCheapRideIsRejected() throws {
        // The offer that LOOKS survivable: 6 lei, 5 km to collect, 2 km paid.
        //
        // On fuel alone this clears zero — 6 lei in, 3.68 of petrol out. Which
        // is exactly why "am I losing money" is the wrong question: 18 minutes
        // of the driver's life for 2.32 lei is 7.75 lei/hour, and no amount of
        // technically-positive arithmetic makes that worth taking.
        let e = try XCTUnwrap(calc().evaluate(offer(fare: 6.0, pickupKm: 5.0, pickupMin: 12.0, tripKm: 2.0, tripMin: 6.0)))

        XCTAssertEqual(e.totalKm, 7.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(e.deadheadRatio), 2.5, accuracy: 1e-9)
        XCTAssertEqual(e.verdict, .bad)
        XCTAssertLessThan(e.netPerKm, thresholds.minNetPerKm)
        XCTAssertLessThan(try XCTUnwrap(e.netPerHour), thresholds.minNetPerHour)
    }

    func testDeadheadRatioAloneCanSinkAnOtherwiseOkayLookingOffer() throws {
        let e = try XCTUnwrap(calc().evaluate(offer(fare: 30.0, pickupKm: 9.0, pickupMin: 18.0, tripKm: 6.0, tripMin: 12.0)))

        XCTAssertGreaterThan(try XCTUnwrap(e.deadheadRatio), thresholds.maxDeadheadRatio)
        XCTAssertTrue(e.reasons.contains { $0.contains("Long pickup") })
        XCTAssertTrue(e.verdict == .marginal || e.verdict == .bad)
    }

    func testASingleMissIsMarginalNotBad() throws {
        // Clears net and per-hour comfortably; only the deadhead ratio misses,
        // so the driver gets to use their judgement.
        let e = try XCTUnwrap(calc().evaluate(offer(fare: 60.0, pickupKm: 9.0, pickupMin: 10.0, tripKm: 6.0, tripMin: 12.0)))

        XCTAssertEqual(try XCTUnwrap(e.deadheadRatio), 1.5, accuracy: 1e-9)
        XCTAssertEqual(e.verdict, .marginal)
        XCTAssertEqual(e.reasons.count, 1)
    }

    func testGrossFareHasCommissionRemovedBeforeCosts() throws {
        // Not a default anywhere any more, but the model still has to be able
        // to do it for a market whose card shows a gross fare.
        let calculator = ProfitCalculator(vehicle: car, thresholds: thresholds, commissionRateFor: { _ in 0.20 })
        let e = try XCTUnwrap(calculator.evaluate(
            offer(fare: 50.0, pickupKm: 2.0, pickupMin: 5.0, tripKm: 8.0, tripMin: 15.0, net: false)
        ))

        XCTAssertEqual(e.gross, 50.0, accuracy: 1e-9)
        XCTAssertEqual(e.commission, 10.0, accuracy: 1e-9)
        XCTAssertEqual(e.afterCommission, 40.0, accuracy: 1e-9)
        XCTAssertEqual(e.net, 40.0 - 5.25, accuracy: 1e-9)
    }

    func testNetFareReconstructsTheGrossForDisplay() throws {
        let calculator = ProfitCalculator(vehicle: car, thresholds: thresholds, commissionRateFor: { _ in 0.20 })
        let e = try XCTUnwrap(calculator.evaluate(
            offer(fare: 40.0, pickupKm: 2.0, pickupMin: 5.0, tripKm: 8.0, tripMin: 15.0, net: true)
        ))

        XCTAssertEqual(e.gross, 50.0, accuracy: 1e-6)
        XCTAssertEqual(e.commission, 10.0, accuracy: 1e-6)
        XCTAssertEqual(e.net, 40.0 - 5.25, accuracy: 1e-9)
    }

    func testABarelyReadCardReturnsUnknownRatherThanBluffingAGreenLight() throws {
        let e = try XCTUnwrap(calc().evaluate(
            offer(fare: 40.0, pickupKm: 2.0, pickupMin: 5.0, tripKm: 8.0, tripMin: 15.0, confidence: 0.4)
        ))
        XCTAssertEqual(e.verdict, .unknown)
    }

    func testMissingTimeStillYieldsPerKmNumbers() throws {
        let e = try XCTUnwrap(calc().evaluate(offer(fare: 40.0, pickupKm: 2.0, pickupMin: nil, tripKm: 8.0, tripMin: nil)))

        XCTAssertEqual(e.netPerKm, 3.475, accuracy: 1e-6)
        XCTAssertNil(e.netPerHour)
        XCTAssertNil(e.totalMin)
    }

    func testElectricCarCostsAreComputedOffKWh() throws {
        let ev = VehicleProfile(
            fuelType: .electric,
            consumptionPer100km: 18.0,   // kWh/100km
            energyPrice: 1.2            // RON/kWh
        )
        let calculator = ProfitCalculator(vehicle: ev, thresholds: thresholds)
        let e = try XCTUnwrap(calculator.evaluate(
            offer(fare: 40.0, pickupKm: 2.0, pickupMin: 5.0, tripKm: 8.0, tripMin: 15.0)
        ))

        XCTAssertEqual(e.energyCost, 10.0 * 0.216, accuracy: 1e-9)
        XCTAssertGreaterThan(e.net, 35.0)
    }

    func testAnOfferWithNoDistanceOrNoFareIsNotComputable() {
        XCTAssertNil(calc().evaluate(offer(fare: 40.0, pickupKm: nil, pickupMin: 5.0, tripKm: nil, tripMin: 15.0)))
        XCTAssertNil(calc().evaluate(offer(fare: 0.0, pickupKm: 2.0, pickupMin: 5.0, tripKm: 8.0, tripMin: 15.0)))
    }

    /// A parse that found only the paid leg still computes — against that leg
    /// alone, which UNDERSTATES the cost. That is survivable only because such
    /// a parse carries a confidence penalty and surfaces as UNKNOWN; the number
    /// itself must never be presented as if the deadhead were zero.
    func testASingleLegParseFallsBackToTheTripLegAndSaysSo() throws {
        let e = try XCTUnwrap(calc().evaluate(
            offer(fare: 20.0, pickupKm: nil, pickupMin: nil, tripKm: 6.0, tripMin: 14.0, confidence: 0.5)
        ))

        XCTAssertEqual(e.totalKm, 6.0, accuracy: 1e-9)
        XCTAssertNil(e.deadheadRatio)
        XCTAssertEqual(e.verdict, .unknown)
    }

    // ---------------------------------------------------------------------
    // Regression guards for what the real driver apps actually print.
    //
    // Both are transcribed from screenshots of live offers in Romania. They
    // exist because the app previously assumed Bolt showed a GROSS fare and
    // skimmed 20% off it, which made every Bolt offer read 20% worse than
    // reality. Nothing crashed, no test failed — the numbers were simply,
    // quietly wrong. If someone "restores" a commission default, these two
    // break loudly.
    // ---------------------------------------------------------------------

    func testBoltCardSaysNetTaxeIncluseSoNothingIsSkimmedOffIt() throws {
        // Screenshot: "11,62 lei (NET, taxe incluse)", 6 min / 2.8 km pickup,
        // 6 min / 3 km trip.
        let bolt = RideOffer(
            platform: .bolt,
            fare: 11.62,
            currency: "lei",
            pickupKm: 2.8, pickupMin: 6.0,
            tripKm: 3.0, tripMin: 6.0,
            fareIsNet: Platform.bolt.fareShownIsNetByDefault
        )
        let e = try XCTUnwrap(ProfitCalculator(vehicle: car, thresholds: thresholds).evaluate(bolt))

        // The driver is promised 11.62 and the app must agree, to the cent.
        XCTAssertEqual(e.afterCommission, 11.62, accuracy: 1e-9)
        XCTAssertEqual(e.commission, 0.0, accuracy: 1e-9)
        XCTAssertEqual(e.totalKm, 5.8, accuracy: 1e-9)
        XCTAssertEqual(e.net, 11.62 - 5.8 * 0.525, accuracy: 1e-9)   // 8.575
    }

    func testUberCardSaysCastigNetFaraComisionulUberSoNothingIsSkimmedOffIt() throws {
        // Screenshot: "78,16 RON", "Câștig net (fără comisionul Uber)",
        // 12 min / 5.4 km pickup, 57 min / 29.0 km trip.
        let uber = RideOffer(
            platform: .uber,
            fare: 78.16,
            currency: "RON",
            pickupKm: 5.4, pickupMin: 12.0,
            tripKm: 29.0, tripMin: 57.0,
            fareIsNet: Platform.uber.fareShownIsNetByDefault
        )
        let e = try XCTUnwrap(ProfitCalculator(vehicle: car, thresholds: thresholds).evaluate(uber))

        XCTAssertEqual(e.afterCommission, 78.16, accuracy: 1e-9)
        XCTAssertEqual(e.totalKm, 34.4, accuracy: 1e-9)
        // A genuinely good long run: 1.75 RON/km and 52 RON/h after fuel.
        XCTAssertEqual(e.verdict, .good)
        XCTAssertGreaterThan(e.netPerKm, thresholds.minNetPerKm)
        XCTAssertGreaterThan(try XCTUnwrap(e.netPerHour), thresholds.minNetPerHour)
    }

    func testNoPlatformCarriesACommissionDefault() {
        for platform in Platform.allCases {
            XCTAssertEqual(platform.defaultCommissionRate, 0.0, "\(platform) must not skim the fare")
            XCTAssertTrue(platform.fareShownIsNetByDefault, "\(platform) shows the driver's own take")
        }
    }

    func testVehicleCostIsFuelOnly() {
        XCTAssertEqual(car.totalCostPerKm, car.energyCostPerKm, accuracy: 1e-12)
        XCTAssertEqual(car.energyCostPerKm, 0.525, accuracy: 1e-12)
        XCTAssertTrue(car.isPlausible)
        XCTAssertFalse(VehicleProfile(consumptionPer100km: 0, energyPrice: 7.5).isPlausible)
        XCTAssertFalse(VehicleProfile(consumptionPer100km: 7, energyPrice: 0).isPlausible)
    }
}
