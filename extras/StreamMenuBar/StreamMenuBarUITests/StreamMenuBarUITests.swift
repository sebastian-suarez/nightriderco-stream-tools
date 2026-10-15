//
//  StreamMenuBarUITests.swift
//  StreamMenuBarUITests
//
//  Created by Sebastian Suarez on 13/10/26.
//

import XCTest

final class StreamMenuBarUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Smoke test: the status item appears, its menu has the actions, and Settings opens with the Kick app form.
    @MainActor
    func testMenuOpensSettings() throws {
        let app = XCUIApplication()
        app.launch()
        defer { app.terminate() }

        let statusItem = app.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 10), "The menu bar item should appear")
        statusItem.click()

        // Scope to the status item's menu: SwiftUI also builds a (hidden) app menu with its own Settings… item.
        let dropdown = statusItem.menus.firstMatch
        let settingsItem = dropdown.menuItems["Settings…"]
        XCTAssertTrue(settingsItem.waitForExistence(timeout: 5), "The dropdown should list Settings")
        XCTAssertTrue(dropdown.menuItems["Quit Stream menu bar"].exists)
        settingsItem.click()

        let clientID = app.textFields["clientID"]
        XCTAssertTrue(clientID.waitForExistence(timeout: 10),
                      "Settings should show the Kick app form. Windows: \(app.windows.allElementsBoundByIndex.map(\.title)). Tree: \(app.debugDescription.prefix(6000))")
        XCTAssertTrue(app.secureTextFields["clientSecret"].exists)
        XCTAssertTrue(app.buttons["saveCredentials"].exists)
        XCTAssertTrue(app.popUpButtons["refreshInterval"].exists, "Settings should show the refresh interval")
    }
}
