// MacMenuY has no remote update feed. Never load the upstream Ice updater.
import SwiftUI
@MainActor
final class UpdatesManager: NSObject, ObservableObject, BindingExposable {
    @Published var canCheckForUpdates = false
    @Published var lastUpdateCheckDate: Date?
    @Published var automaticallyChecksForUpdates = false
    @Published var automaticallyDownloadsUpdates = false
    private(set) weak var appState: AppState?
    init(appState: AppState) { self.appState = appState; super.init() }
    func performSetup() { }
    @objc func checkForUpdates() { }
}
