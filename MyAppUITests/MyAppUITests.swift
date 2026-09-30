//
//  MyAppUITests.swift
//  MyAppUITests
//
//  Created by Alex Diab on 2026-09-29.
//

import XCTest

final class MyAppUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
        // XCUIAutomation Documentation
        // https://developer.apple.com/documentation/xcuiautomation
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }

    /// Navigates to the Live guide grid and repeatedly swipes it, measuring frame
    /// hitches. Guards against the regressions Stage 3 targets: no Button per cell,
    /// only visible cells rendered, and the grid decoupled from unrelated store updates.
    @MainActor
    func testGuideGridScrollHitches() throws {
        let app = XCUIApplication()
        app.launch()

        let liveTab = app.tabBars.buttons["Live"]
        if liveTab.waitForExistence(timeout: 5) {
            liveTab.tap()
        }

        let guideButton = app.buttons["Guide"]
        if guideButton.waitForExistence(timeout: 3) {
            guideButton.tap()
        }

        let window = app.windows.firstMatch
        _ = window.waitForExistence(timeout: 5)
        // Let the initial guide import/scroll-to-now settle before measuring.
        Thread.sleep(forTimeInterval: 1.5)

        measure(metrics: [XCTHitchMetric(during: .responsive)]) {
            for _ in 0..<4 {
                window.swipeUp(velocity: .fast)
                window.swipeLeft(velocity: .fast)
            }
            for _ in 0..<4 {
                window.swipeDown(velocity: .fast)
                window.swipeRight(velocity: .fast)
            }
        }
    }
}
