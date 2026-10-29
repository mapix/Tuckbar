//
//  MenuBarItemImageCache.swift
//  Ice
//

import Cocoa
import Combine

/// Cache for menu bar item images.
@MainActor
final class MenuBarItemImageCache: ObservableObject {
    /// The cached item images.
    @Published private(set) var images = [CGWindowID: CGImage]()

    /// The screen of the cached item images.
    private(set) var screen: NSScreen?

    /// The height of the menu bar of the cached item images.
    private(set) var menuBarHeight: CGFloat?

    /// The shared app state.
    private weak var appState: AppState?

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()
    private var updateTask: Task<Void, Never>?
    private var itemCacheAtLastPublish: MenuBarItemManager.ItemCache?

    /// Dedicated serial queue for blocking WindowServer capture calls, keeping
    /// ScreenCaptureKit / SLSWindowListCreateImageFromArrayProxying off the
    /// Swift concurrency cooperative thread pool (inspired by leonardovida/icey).
    private static let captureQueue = DispatchQueue(
        label: "io.novarock.MacMenuY.ImageCapture",
        qos: .userInitiated
    )

    private nonisolated static func onCaptureQueue(_ work: @escaping @Sendable () -> [CGWindowID: CGImage]) async -> [CGWindowID: CGImage] {
        await withCheckedContinuation { continuation in
            captureQueue.async {
                continuation.resume(returning: work())
            }
        }
    }

    nonisolated private static func hasSamePixels(_ a: CGImage, _ b: CGImage) -> Bool {
        if a === b { return true }
        guard a.width == b.width, a.height == b.height, a.width > 0, a.height > 0,
              a.bitsPerComponent == b.bitsPerComponent, a.bitsPerPixel == b.bitsPerPixel,
              a.bytesPerRow == b.bytesPerRow, a.bitmapInfo == b.bitmapInfo,
              let dataA = a.dataProvider?.data, let dataB = b.dataProvider?.data,
              let bytesA = CFDataGetBytePtr(dataA), let bytesB = CFDataGetBytePtr(dataB) else {
            return false
        }
        let bytesPerRow = a.bytesPerRow
        let rowLength = (a.width * a.bitsPerPixel + 7) / 8
        let requiredLength = (a.height - 1) * bytesPerRow + rowLength
        guard CFDataGetLength(dataA) >= requiredLength, CFDataGetLength(dataB) >= requiredLength else {
            return false
        }
        for row in 0..<a.height {
            let offset = row * bytesPerRow
            if memcmp(bytesA + offset, bytesB + offset, rowLength) != 0 {
                return false
            }
        }
        return true
    }

    /// Creates a cache with the given app state.
    init(appState: AppState) {
        self.appState = appState
    }

    /// Sets up the cache.
    @MainActor
    func performSetup() {
        configureCancellables()
    }

    /// Configures the internal observers for the cache.
    @MainActor
    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        if let appState {
            Publishers.Merge3(
                // Update every 3 seconds at minimum.
                Timer.publish(every: 3, on: .main, in: .default).autoconnect().mapToVoid(),

                // Update when the active space or screen parameters change.
                Publishers.Merge(
                    NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification),
                    NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
                )
                .mapToVoid(),

                // Update when the average menu bar color or cached items change.
                Publishers.Merge(
                    appState.menuBarManager.$averageColorInfo.removeDuplicates().mapToVoid(),
                    appState.itemManager.$itemCache.removeDuplicates().mapToVoid()
                )
            )
            .throttle(for: 0.5, scheduler: DispatchQueue.main, latest: false)
            .sink { [weak self] in
                guard let self else {
                    return
                }
                Task.detached {
                    if ScreenCapture.cachedCheckPermissions() {
                        await self.updateCache()
                    }
                }
            }
            .store(in: &c)
        }

        cancellables = c
    }

    func stop() { cancellables.removeAll(); updateTask?.cancel() }

    /// Logs a reason for skipping the cache.
    private func logSkippingCache(reason: String) {
        Logger.imageCache.debug("Skipping menu bar item image cache as \(reason)")
    }

    /// Returns a Boolean value that indicates whether caching menu bar items failed for
    /// the given section.
    @MainActor
    func cacheFailed(for section: MenuBarSection.Name) -> Bool {
        guard ScreenCapture.cachedCheckPermissions() else {
            return true
        }
        let items = appState?.itemManager.itemCache[section] ?? []
        guard !items.isEmpty else {
            return false
        }
        let keys = Set(images.keys)
        for item in items where keys.contains(item.windowID) {
            return false
        }
        return true
    }

    /// Captures the images of the current menu bar items and returns a dictionary containing
    /// the images, keyed by the current menu bar item infos.
    func createImages(for section: MenuBarSection.Name, screen: NSScreen) async -> [CGWindowID: CGImage] {
        guard let appState else {
            return [:]
        }

        let items = appState.itemManager.itemCache[section]
        let backingScaleFactor = screen.backingScaleFactor
        let displayBounds = CGDisplayBounds(screen.displayID)
        let thickness = NSStatusBar.system.thickness
        return await Self.onCaptureQueue {
            Self.captureImages(items: items, backingScaleFactor: backingScaleFactor,
                               displayBounds: displayBounds, thickness: thickness)
        }
    }
    nonisolated private static func captureImages(items:[MenuBarItem], backingScaleFactor:CGFloat,
                                                  displayBounds:CGRect, thickness:CGFloat) -> [CGWindowID:CGImage] {
        var images=[CGWindowID:CGImage]()
        let option: CGWindowImageOption = [.boundsIgnoreFraming, .bestResolution]
        let defaultItemThickness = thickness * backingScaleFactor

        var itemFrames = [CGWindowID: CGRect]()
        var windowIDs = [CGWindowID]()
        var frame = CGRect.null

        for item in items {
            let windowID = item.windowID
            guard
                // Use the most up-to-date window frame.
                let itemFrame = Bridging.getWindowFrame(for: windowID),
                abs(itemFrame.minY - displayBounds.minY) <= 4
            else {
                continue
            }
            itemFrames[windowID] = itemFrame
            windowIDs.append(windowID)
            frame = frame.union(itemFrame)
        }

        if
            frame.width > 0,
            let compositeImage = ScreenCapture.captureWindows(windowIDs, option: option)
        {
            let actualScale = CGFloat(compositeImage.width) / frame.width
            if actualScale >= 0.5 && actualScale <= 4.0 {
                let scaledThickness = thickness * actualScale
                var failedIDs = [CGWindowID]()
                for windowID in windowIDs {
                    guard let itemFrame = itemFrames[windowID] else {
                        continue
                    }

                    let cropFrame = CGRect(
                        x: (itemFrame.origin.x - frame.origin.x) * actualScale,
                        y: (itemFrame.origin.y - frame.origin.y) * actualScale + max(0, (itemFrame.height * actualScale - scaledThickness) / 2),
                        width: itemFrame.width * actualScale,
                        height: min(scaledThickness, itemFrame.height * actualScale)
                    )

                    if let itemImage = compositeImage.cropping(to: cropFrame) {
                        images[windowID] = itemImage
                    } else {
                        failedIDs.append(windowID)
                    }
                }
                if failedIDs.isEmpty {
                    return images
                }
                windowIDs = failedIDs
            }
        }

        if !windowIDs.isEmpty {
            Logger.imageCache.warning("Composite image capture incomplete. Capturing remaining items individually.")

            for windowID in windowIDs {
                guard let itemFrame = itemFrames[windowID], itemFrame.width > 0 else {
                    continue
                }

                guard let itemImage = ScreenCapture.captureWindow(windowID, option: option) else {
                    continue
                }
                let actualScale = (CGFloat(itemImage.width) / itemFrame.width)
                let scale = (actualScale >= 0.5 && actualScale <= 4.0) ? actualScale : backingScaleFactor
                let scaledThickness = thickness * scale
                let cropFrame = CGRect(
                    x: 0,
                    y: max(0, ((itemFrame.height * scale) / 2) - (scaledThickness / 2)),
                    width: itemFrame.width * scale,
                    height: min(scaledThickness, itemFrame.height * scale)
                )

                if let croppedImage = itemImage.cropping(to: cropFrame) {
                    images[windowID] = croppedImage
                }
            }
        }

        return images
    }

    /// Updates the cache for the given sections, without checking whether caching is necessary.
    func updateCacheWithoutChecks(sections:[MenuBarSection.Name]) async {
        if let current=updateTask { await current.value; return }
        let ownedTask=Task<Void,Never> { [weak self] in
            guard let self else { return }
            await performUpdate(sections:sections)
        }
        updateTask=ownedTask
        await ownedTask.value
        updateTask=nil
    }
    private func performUpdate(sections:[MenuBarSection.Name]) async {
        guard let appState,let targetScreen=NSScreen.main else { return }
        var newImages=[CGWindowID:CGImage]()
        for section in sections {
            guard !appState.itemManager.itemCache[section].isEmpty,!Task.isCancelled else { continue }
            let sectionImages=await createImages(for:section,screen:targetScreen)
            newImages.merge(sectionImages) { _,new in new }
        }
        guard !Task.isCancelled,!appState.itemManager.isMovingItem else { return }
        let currentCache = appState.itemManager.itemCache
        let liveIDs=Set(currentCache.allItems.map(\.windowID))
        var updated=images.filter { liveIDs.contains($0.key) }
        var changed = updated.count != images.count || itemCacheAtLastPublish != currentCache
        for (id,image) in newImages where liveIDs.contains(id) {
            if let existing = updated[id], Self.hasSamePixels(existing, image) {
                continue
            }
            updated[id] = image
            changed = true
        }
        // Publish the screen metadata before the image dictionary on the same actor.
        screen=targetScreen
        menuBarHeight=targetScreen.getMenuBarHeight()
        if changed {
            images=updated
            itemCacheAtLastPublish = currentCache
        }
    }

    /// Updates the cache for the given sections, if necessary.
    func updateCache(sections: [MenuBarSection.Name]) async {
        guard let appState else {
            return
        }

        let isIceBarPresented = appState.navigationState.isIceBarPresented
        let isSearchPresented = appState.navigationState.isSearchPresented

        guard !appState.itemManager.isMovingItem else {
            logSkippingCache(reason: "an item is currently being moved")
            return
        }

        guard !appState.itemManager.itemHasRecentlyMoved else {
            logSkippingCache(reason: "an item was recently moved")
            return
        }

        await updateCacheWithoutChecks(sections: sections)
    }

    /// Updates the cache for all sections, if necessary.
    func updateCache() async {
        guard let appState else {
            return
        }

        let isIceBarPresented = appState.navigationState.isIceBarPresented
        let isSearchPresented = appState.navigationState.isSearchPresented
        let isSettingsPresented = appState.navigationState.isSettingsPresented

        var sectionsNeedingDisplay = [MenuBarSection.Name]()
        if isSettingsPresented || isSearchPresented {
            sectionsNeedingDisplay = MenuBarSection.Name.allCases
        } else {
            sectionsNeedingDisplay = MenuBarSection.Name.allCases
        }

        await updateCache(sections: sectionsNeedingDisplay)
    }
}

// MARK: - Logger

private extension Logger {
    static let imageCache = Logger(category: "MenuBarItemImageCache")
}
