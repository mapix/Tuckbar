//
//  AppDelegate.swift
//  Ice
//

import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private weak var appState: AppState?
    private var isTerminationPending=false

    // MARK: NSApplicationDelegate Methods

    func applicationWillFinishLaunching(_ notification: Notification) {
        if let bundleID=Bundle.main.bundleIdentifier,
           let existing=NSRunningApplication.runningApplications(withBundleIdentifier:bundleID)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }) {
            existing.activate(options:[.activateIgnoringOtherApps])
            NSApp.terminate(nil)
            return
        }
        guard let appState else {
            Logger.appDelegate.warning("Missing app state in applicationWillFinishLaunching")
            return
        }

        // Assign the delegate to the shared app state.
        appState.assignAppDelegate(self)

        // Allow the app to set the cursor in the background.
        appState.setsCursorInBackground = true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let appState else {
            Logger.appDelegate.warning("Missing app state in applicationDidFinishLaunching")
            return
        }

        // Dismiss the windows.
        appState.dismissSettingsWindow()
        appState.dismissPermissionsWindow()

        // Hide the main menu to make more space in the menu bar.
        if let mainMenu = NSApp.mainMenu {
            for item in mainMenu.items {
                item.isHidden = true
            }
        }

        // Perform setup after a small delay to ensure that the settings window
        // has been assigned.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard !appState.isPreview else {
                return
            }
            // If we have the required permissions, set up the shared app state.
            // Otherwise, open the permissions window.
            switch appState.permissionsManager.permissionsState {
            case .hasAllPermissions, .hasRequiredPermissions:
                appState.performSetup()
            case .missingPermissions:
                appState.activate(withPolicy: .regular)
                appState.openPermissionsWindow()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Deactivate and set the policy to accessory when all windows are closed.
        if appState?.navigationState.isIceBarPresented != true {
            appState?.deactivate(withPolicy: .accessory)
        }
        return false
    }

    func applicationShouldHandleReopen(_ sender:NSApplication, hasVisibleWindows:Bool)->Bool {
        guard let appState else { return false }
        if appState.permissionsManager.permissionsState == .missingPermissions {
            appState.openPermissionsWindow()
        } else {
            appState.menuCover.update()
            #if MENUY_VERIFY
            if ProcessInfo.processInfo.arguments.contains("--verification-keep-open") {
                appState.menuBarManager.section(withName:.visible)?.controlItem.openDrawer()
            }
            #endif
        }
        return false
    }

    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
        guard let appState,!appState.menuBarManager.sections.isEmpty else { return .terminateNow }
        if isTerminationPending { return .terminateLater }
        isTerminationPending=true
        appState.hover.stop()
        appState.menuBarManager.iceBarPanel.close()
        appState.imageCache.stop()
        Task { @MainActor in
            let report=await appState.itemManager.prepareForTermination(timeout:3)
            let value:[String:Any]=["restored":report.restoredCount,"remaining":report.remainingWindowIDs,
                                   "elapsed":report.elapsed]
            let args=ProcessInfo.processInfo.arguments
            if let i=args.firstIndex(of:"--diagnostics-path"),args.indices.contains(i+1),
               let data=try? JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]) {
                try? data.write(to:URL(fileURLWithPath:args[i+1]+".exit.json"),options:.atomic)
            }
            sender.reply(toApplicationShouldTerminate:true)
        }
        return .terminateLater
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    // MARK: Other Methods

    /// Assigns the app state to the delegate.
    func assignAppState(_ appState: AppState) {
        guard self.appState == nil else {
            Logger.appDelegate.warning("Multiple attempts made to assign app state")
            return
        }
        self.appState = appState
    }

    /// Opens the settings window and activates the app.
    @objc func openSettingsWindow() {
        guard let appState else {
            Logger.appDelegate.error("Failed to open settings window")
            return
        }
        // Small delay makes this more reliable.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            appState.activate(withPolicy: .regular)
            appState.openSettingsWindow()
        }
    }
}

// MARK: - Logger
private extension Logger {
    static let appDelegate = Logger(category: "AppDelegate")
}
