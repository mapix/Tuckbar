//
//  SettingsWindow.swift
//  Ice
//

import SwiftUI

struct SettingsWindow: Scene {
    @ObservedObject var appState: AppState

    var body: some Scene {
        Window(Constants.settingsWindowTitle, id: Constants.settingsWindowID) {
            SettingsView()
                .readWindow { window in
                    guard let window else {
                        return
                    }
                    appState.assignSettingsWindow(window)
                }
                .frame(minWidth: 720, minHeight: 540)
        }
        .commandsRemoved()
        .windowResizability(.contentSize)
        .defaultSize(width: 820, height: 650)
        .environmentObject(appState)
        .environmentObject(appState.navigationState)
        .environmentObject(appState.shelfManager)
        .environmentObject(appState.imageCache)
        .environmentObject(appState.preferences)
        .environmentObject(appState.activity)
    }
}
