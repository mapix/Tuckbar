import AppKit
import Combine
import CryptoKit
import SwiftUI

/// Compatibility name for the native appearance provider. This object only
/// reads native background/entry geometry. It never creates or covers a window.
@MainActor final class MenuYMenuCover: ObservableObject {
    @Published private(set) var backgrounds = [CGDirectDisplayID: NSImage]()
    @Published private(set) var textColor = Color.white
    @Published private(set) var shelfIsVisible = false
    @Published private(set) var captureFailures = [CGDirectDisplayID: String]()
    private var darkBars = [CGDirectDisplayID: Bool]()
    private var backgroundDigests = [CGDirectDisplayID: Data]()
    private weak var appState: AppState?
    private var subscriptions = Set<AnyCancellable>()
    private var capturesInFlight = Set<CGDirectDisplayID>()
    private var lastCaptureTime = [CGDirectDisplayID: TimeInterval]()
    private let captureQueue = DispatchQueue(label: "io.novarock.MacMenuY.menu-background", qos: .utility)

    init(appState: AppState) { self.appState = appState }

    func performSetup() {
        guard let appState else { return }
        Timer.publish(every: 3, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.update() }.store(in: &subscriptions)
        appState.navigationState.$isIceBarPresented.receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                if self?.shelfIsVisible != value { self?.shelfIsVisible = value }
                if value { self?.update() }
            }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.lastCaptureTime.removeAll(); self?.update() }.store(in: &subscriptions)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .sink { [weak self] _ in self?.lastCaptureTime.removeAll(); self?.update() }.store(in: &subscriptions)
        update()
    }

    func foregroundColor(for displayID: CGDirectDisplayID) -> Color { isDarkBar(on: displayID) ? .white : .black }
    func isDarkBar(on displayID: CGDirectDisplayID) -> Bool { darkBars[displayID] ?? true }
    // No presentation window exists in this provider.
    var visibleFrames: [CGDirectDisplayID: CGRect] { [:] }

    /// The actual app-owned NSStatusItem is the only hover entry. WindowServer
    /// coordinates use a top-left origin; convert to AppKit's global bottom-left.
    var entryFrames: [CGDirectDisplayID: CGRect] {
        guard let appState,
              let id = appState.menuBarManager.section(withName: .visible)?.controlItem.windowID,
              let entry = WindowInfo(windowID: id), entry.isOnScreen,
              let primary = NSScreen.screens.first else { return [:] }
        let frame = CGRect(x: entry.frame.minX, y: primary.frame.maxY - entry.frame.maxY,
                           width: entry.frame.width, height: entry.frame.height)
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) else { return [:] }
        return [screen.displayID: frame]
    }
    func diagnostics() -> [[String: Any]] {
        // Kept empty so window/composite audits cannot mistake appearance data
        // for a visible cover over the original menu bar.
        []
    }

    func update() {
        guard appState != nil else { return }
        let screens = NSScreen.screens
        let active = Set(screens.map(\.displayID))
        for id in Array(backgrounds.keys) where !active.contains(id) {
            backgrounds.removeValue(forKey: id); darkBars.removeValue(forKey: id)
            backgroundDigests.removeValue(forKey: id); lastCaptureTime.removeValue(forKey: id)
            captureFailures.removeValue(forKey: id)
        }
        let snapshot = WindowInfo.getOnScreenWindows()
        for screen in screens {
            let bounds = CGDisplayBounds(screen.displayID)
            guard let bar = snapshot.first(where: {
                $0.isWindowServerWindow && $0.title == "Menubar" &&
                abs($0.frame.minX - bounds.minX) < 1 && abs($0.frame.width - bounds.width) <= 2 &&
                $0.frame.maxY > bounds.minY && $0.frame.minY < bounds.minY + 40
            }) else { continue }
            // Only backgrounds are included: no status windows, app windows,
            // screen overlays, pointer or MacMenuY's own shelf.
            let backgroundWindows = snapshot.filter { window in
                guard window.frame.intersects(bar.frame) else { return false }
                let name = window.title ?? ""
                return (window.isWindowServerWindow && (name == "underbelly" || name.contains("Backstop"))) ||
                    (window.owningApplication?.bundleIdentifier == "com.apple.dock" && name.hasPrefix("Wallpaper"))
            }
            let rect = CGRect(x: bar.frame.minX + bar.frame.width * 0.75, y: bar.frame.minY,
                              width: bar.frame.width * 0.25, height: bar.frame.height)
            requestBackground(bar: bar, backgroundWindows: backgroundWindows, displayID: screen.displayID, rect: rect)
        }
    }

    private func requestBackground(bar: WindowInfo, backgroundWindows: [WindowInfo], displayID: CGDirectDisplayID, rect: CGRect) {
        guard !capturesInFlight.contains(displayID), ScreenCapture.cachedCheckPermissions() else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - (lastCaptureTime[displayID] ?? -.infinity) >= 2.8 else { return }
        lastCaptureTime[displayID] = now; capturesInFlight.insert(displayID)
        let windowIDs = backgroundWindows.map(\.windowID), barFrame = bar.frame
        captureQueue.async { [weak self] in
            // Menubar alone is transparent on Tahoe and contains app-menu
            // labels. Capture only its native underbelly/wallpaper/backstop so
            // no foreground menu text can leak into the expanded shelf.
            let captured = ScreenCapture.captureWindows(windowIDs, screenBounds: barFrame, option: [.boundsIgnoreFraming, .bestResolution])
            let image = captured.flatMap { MenuYBackplate.opaque($0, width: $0.width, height: $0.height) }
            let crop: CGImage?
            if let image, barFrame.width > 0 {
                let scale = CGFloat(image.width) / barFrame.width
                let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
                let requested = CGRect(x: (rect.minX - barFrame.minX) * scale, y: 0,
                                       width: rect.width * scale, height: CGFloat(image.height))
                crop = image.cropping(to: requested.intersection(imageBounds))
            } else { crop = nil }
            let digest = crop?.dataProvider?.data.map { Data(SHA256.hash(data: $0 as Data)) }
            var pixel = [UInt8](repeating: 0, count: 4)
            pixel.withUnsafeMutableBytes { bytes in
                if let crop, let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                    context.interpolationQuality = .high
                    context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                }
            }
            let dark = Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2]) <= 420
            Task { @MainActor [weak self] in
                guard let self else { return }
                capturesInFlight.remove(displayID)
                guard NSScreen.screens.contains(where: { $0.displayID == displayID }) else { return }
                guard let crop else { captureFailures[displayID] = "无法读取原菜单栏背景"; return }
                captureFailures.removeValue(forKey: displayID)
                if backgroundDigests[displayID] != digest || backgrounds[displayID]?.size != rect.size {
                    backgroundDigests[displayID] = digest; darkBars[displayID] = dark
                    backgrounds[displayID] = NSImage(cgImage: crop, size: rect.size)
                    if NSScreen.main?.displayID == displayID { textColor = dark ? .white : .black }
                }
            }
        }
    }

    func passthrough(_ operation: () async throws -> Void) async rethrows {
        try await operation()
    }
}
