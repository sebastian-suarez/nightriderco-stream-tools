//
//  StreamMenuBarApp.swift
//  StreamMenuBar
//
//  Created by Sebastian Suarez on 13/10/26.
//

import SwiftUI

@main
struct StreamMenuBarApp: App {
    private let model = AppModel()

    init() {
        model.start()
    }

    var body: some Scene {
        // Menu bar only (LSUIElement = YES): this is the app's primary scene.
        MenuBarExtra {
            MenuContentView(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(model: model)
        }
    }
}
