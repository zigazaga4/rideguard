import XCTest

/// Everything about typing in this app that a compiler cannot check.
///
/// The history here is the argument for the suite. Shipped once: eight
/// `.decimalPad` fields with no return key and no Done button, so the keyboard
/// could not be dismissed at all. Shipped again while "fixing" it: a keyboard
/// toolbar declared per-field, which renders one Done button *per field*,
/// because that toolbar contributes to the screen's accessory view and not to
/// the field's. Both built cleanly and passed every unit test.
final class KeyboardTests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// Onboarding, parked on the vehicle step — the screen with two decimal
    /// fields and a fixed footer, which is where all three bugs met.
    private func launchToVehicleStep() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-RideGuardUITestResetState"]
        app.launch()

        let advance = app.buttons["Continue"]
        XCTAssertTrue(advance.waitForExistence(timeout: 15), "onboarding never appeared")
        advance.tap()

        let consumption = app.textFields["decimal.Consumption"]
        XCTAssertTrue(
            consumption.waitForExistence(timeout: 5),
            "the vehicle step did not appear"
        )
        return app
    }

    /// The regression the driver actually reported: "I have like 2 done buttons".
    func testThereIsExactlyOneDoneButton() {
        let app = launchToVehicleStep()
        app.textFields["decimal.Consumption"].tap()

        XCTAssertTrue(
            app.keyboards.element.waitForExistence(timeout: 5),
            "tapping a decimal field did not raise the keyboard"
        )

        let dones = app.buttons.matching(identifier: "Done")
        XCTAssertEqual(
            dones.count, 1,
            """
            Expected exactly one Done button, found \(dones.count). A keyboard \
            toolbar declared on the field contributes one per field.
            """
        )
    }

    /// A `.decimalPad` has no return key. Without Done there is no way out.
    func testDoneDismissesTheKeyboard() {
        let app = launchToVehicleStep()
        app.textFields["decimal.Consumption"].tap()
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 5))

        app.buttons["Done"].firstMatch.tap()

        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: app.keyboards.element)
        waitForExpectations(timeout: 5)
    }

    /// The footer used to be lifted by SwiftUI's keyboard avoidance and parked
    /// on top of the number pad, covering the row being edited.
    func testTheFooterGetsOutOfTheWayWhileTyping() {
        let app = launchToVehicleStep()
        let advance = app.buttons["Continue"]
        XCTAssertTrue(advance.exists, "the footer should be visible before typing")

        app.textFields["decimal.Consumption"].tap()
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 5))

        let hidden = NSPredicate(format: "exists == false")
        expectation(for: hidden, evaluatedWith: advance)
        waitForExpectations(timeout: 5)

        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(
            advance.waitForExistence(timeout: 5),
            "the footer never came back after dismissing the keyboard"
        )
    }

    /// The other half of the complaint: the field being edited has to be
    /// visible. A field underneath the keyboard is a field you are typing into
    /// blind.
    func testTheFocusedFieldIsNotUnderTheKeyboard() {
        let app = launchToVehicleStep()

        // Price sits lower on the screen than Consumption, so it is the one
        // that has to be scrolled up.
        let price = app.textFields.matching(
            NSPredicate(format: "identifier BEGINSWITH 'decimal.Price'")
        ).firstMatch
        XCTAssertTrue(price.waitForExistence(timeout: 5), "no price field")
        price.tap()

        let keyboard = app.keyboards.element
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))

        // Let the scroll settle before measuring.
        Thread.sleep(forTimeInterval: 1.0)

        XCTAssertTrue(
            price.frame.maxY <= keyboard.frame.minY,
            """
            The focused field (maxY \(price.frame.maxY)) is under the keyboard \
            (minY \(keyboard.frame.minY)) — the view did not scroll it clear.
            """
        )
    }

    /// Settings has four decimal fields, so it is the screen where a per-field
    /// toolbar would have rendered four Done buttons.
    func testSettingsAlsoHasExactlyOneDoneButton() {
        let app = XCUIApplication()
        app.launchArguments += ["-RideGuardUITestResetState"]
        app.launch()

        // Straight through onboarding: welcome, vehicle, targets, howItWorks, ready.
        let advance = app.buttons["Continue"]
        XCTAssertTrue(advance.waitForExistence(timeout: 15))
        for _ in 1...4 {
            XCTAssertTrue(advance.waitForExistence(timeout: 5))
            advance.tap()
        }
        app.buttons["Start"].tap()

        let settings = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "never reached the app")
        settings.tap()

        let target = app.textFields["decimal.Minimum net per hour"]
        XCTAssertTrue(target.waitForExistence(timeout: 5), "no threshold field in Settings")
        target.tap()
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 5))

        let dones = app.buttons.matching(identifier: "Done")
        XCTAssertEqual(dones.count, 1, "Settings shows \(dones.count) Done buttons")
    }
}
