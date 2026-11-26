import XCTest

final class ClassroomTests:XCTestCase {
    @MainActor func testWritingDuringPlaybackAndPageRecovery() throws {
        continueAfterFailure=false
        let app=XCUIApplication()
        app.launchArguments=["--classroom-ui-test"];app.launch()
        let desk=app.buttons["Open circuit lesson"]
        if !desk.waitForExistence(timeout:3) {
            let writingDesk=app.descendants(matching:.any).matching(identifier:"Writing desk").firstMatch
            if writingDesk.exists {writingDesk.tap()}
        }
        XCTAssertTrue(desk.waitForExistence(timeout:8));desk.tap()
        let play=app.buttons["Play teaching visual"];XCTAssertTrue(play.waitForExistence(timeout:12));play.tap()
        XCTAssertTrue(app.buttons["Turn motion off"].exists)
        let canvas=app.scrollViews["Writing canvas"]
        let source=canvas.exists ? canvas : app
        let start=source.coordinate(withNormalizedOffset:CGVector(dx:0.69,dy:0.66)),end=source.coordinate(withNormalizedOffset:CGVector(dx:0.79,dy:0.70))
        start.press(forDuration:0.05,thenDragTo:end)
        XCTAssertTrue(app.buttons["Turn motion off"].exists)
        let frame=XCTAttachment(screenshot:app.screenshot());frame.name="Writing while the circuit plays";frame.lifetime = .keepAlways;add(frame)
        app.buttons["Turn motion off"].tap()
        app.buttons["Add page"].tap()
        app.buttons["Page actions"].tap();app.buttons["Page notes"].tap()
        let text=app.textViews["Page notes"];XCTAssertTrue(text.waitForExistence(timeout:5));text.tap();text.typeText("The switch closes.")
        app.buttons["Save"].tap()
        #if os(iOS) && !targetEnvironment(macCatalyst)
        XCUIDevice.shared.press(.home)
        #endif
        app.terminate();app.launch()
        XCTAssertTrue(app.buttons["Page actions"].waitForExistence(timeout:12))
        app.buttons["Page actions"].tap();app.buttons["Page notes"].tap()
        XCTAssertEqual(app.textViews["Page notes"].value as? String,"The switch closes.")
    }
}
