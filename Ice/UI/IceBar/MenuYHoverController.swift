import AppKit
import Combine

@MainActor
final class MenuYHoverController {
    private weak var appState: AppState?
    private var policy = MenuYHoverPolicy()
    private var subscriptions = Set<AnyCancellable>()
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var deadlineTimer: Timer?
    private var openingTask: Task<Void, Never>?
    private var latestPoint: CGPoint?
    private var latestEventTimestamp: TimeInterval = -.infinity
    private var positionPoll: Timer?
    private var didPrimeNativeRegion = false
    private var openingGeneration: UInt64 = 0
    private var started = false
    private var cachedEntryID: CGWindowID?
    private var entryIDCheckedAt: TimeInterval = -.infinity

    init(appState: AppState) { self.appState = appState }

    func performSetup() {
        guard !started, let appState else { return }
        started = true
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.observe(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.observe(event)
            return event
        }
        // A remote NSStatusItem is hosted by Control Center. Normal event
        // monitors are primary; a low-frequency position snapshot covers
        // missed remote tracking events without opening from stale positions.
        let poll = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.started else { return }
                self.latestPoint = NSEvent.mouseLocation
                self.evaluate()
            }
        }
        positionPoll = poll
        RunLoop.main.add(poll, forMode: .common)
        appState.shelfManager.$isBusy.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.evaluate() }.store(in: &subscriptions)
        appState.shelfManager.$isEnabled.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.policy.resetEntry(); self.didPrimeNativeRegion = false
                self.evaluate()
            }.store(in: &subscriptions)
        appState.navigationState.$isIceBarPresented.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.evaluate() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.evaluate() }.store(in: &subscriptions)
    }

    /// Optional tracking edge hook; the native status item region is authoritative.
    func entryHover(_ inside: Bool) {
        guard started else { return }
        if let event = NSApp.currentEvent,
           [.mouseMoved, .mouseEntered, .mouseExited, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(event.type),
           let point = point(for: event) {
            latestPoint = point
            latestEventTimestamp = max(latestEventTimestamp, event.timestamp)
        } else {
            // Sample once at the immediate edge callback. Timer/deadline work
            // only uses this immutable point or newer event snapshots.
            latestPoint = NSEvent.mouseLocation
        }
        // Ignore an obsolete callback edge if the immutable point no longer
        // belongs to the native entry. Poll/event geometry remains authoritative.
        evaluate()
    }

    func stop() {
        started = false
        deadlineTimer?.invalidate(); deadlineTimer = nil
        openingGeneration &+= 1
        if openingTask != nil { appState?.menuBarManager.iceBarPanel.close() }
        openingTask?.cancel(); openingTask = nil
        if let token = globalMonitor { NSEvent.removeMonitor(token) }; globalMonitor = nil
        if let token = localMonitor { NSEvent.removeMonitor(token) }; localMonitor = nil
        positionPoll?.invalidate(); positionPoll = nil
        subscriptions.removeAll()
        policy = MenuYHoverPolicy(); didPrimeNativeRegion = false; latestPoint = nil
        cachedEntryID = nil; entryIDCheckedAt = -.infinity
    }

    private func observe(_ event: NSEvent) {
        guard started, event.timestamp >= latestEventTimestamp, let point = point(for: event) else { return }
        latestPoint = point; latestEventTimestamp = event.timestamp
        evaluate()
    }

    private func point(for event: NSEvent) -> CGPoint? {
        if let cg = event.cgEvent {
            let top = NSScreen.screens.first?.frame.maxY ?? CGDisplayBounds(CGMainDisplayID()).height
            return MenuYHoverPolicy.appKitPoint(quartz: cg.location, primaryTop: top)
        }
        if let window = event.window { return window.convertPoint(toScreen: event.locationInWindow) }
        return nil
    }

    private func nativeEntryFrame() -> CGRect? {
        guard let appState else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        if cachedEntryID == nil || now-entryIDCheckedAt >= 1 {
            cachedEntryID = appState.menuBarManager.section(withName: .visible)?.controlItem.windowID
            entryIDCheckedAt = now
        }
        guard let id = cachedEntryID, let frame = Bridging.getWindowFrame(for: id),
              frame.width > 0, frame.height > 0, frame.height < 100 else {
            cachedEntryID = nil
            return nil
        }
        let top = NSScreen.screens.first?.frame.maxY ?? CGDisplayBounds(CGMainDisplayID()).height
        return CGRect(x: frame.minX, y: top-frame.maxY, width: frame.width, height: frame.height)
    }

    private var keepOpenForVerification: Bool {
        #if MENUY_VERIFY
        return ProcessInfo.processInfo.arguments.contains("--verification-keep-open") || MenuYDebugHarness.holdShelf
        #else
        return false
        #endif
    }

    private func evaluate() {
        guard started, let appState else { return }
        let panel = appState.menuBarManager.iceBarPanel
        let nativeFrame = nativeEntryFrame()
        let insideEntry = MenuYHoverPolicy.contains(latestPoint, in: nativeFrame.map { [$0] } ?? [])
        if nativeFrame != nil, !didPrimeNativeRegion {
            // Baseline a newly-created entry. Starting the app under an
            // unmoving pointer is not a fresh hover-enter gesture.
            policy.primeEntry(insideEntry); didPrimeNativeRegion = true
        }
        let insideShelf = panel.isVisible && MenuYHoverPolicy.contains(latestPoint, in: [panel.frame])
        let action = policy.update(entryInside: insideEntry, shelfInside: insideShelf,
            visible: panel.isVisible, opening: openingTask != nil,
            busy: appState.shelfManager.isBusy,
            now: ProcessInfo.processInfo.systemUptime, keepOpen: keepOpenForVerification)
        switch action {
        case .none: break
        case .show:
            guard openingTask == nil,
                  let screen = NSScreen.screens.first(where: { MenuYHoverPolicy.contains(latestPoint, in: [$0.frame]) }) ?? NSScreen.main else { break }
            openingGeneration &+= 1
            let ticket = openingGeneration
            openingTask = Task { [weak self, weak appState] in
                guard let self, let appState, !Task.isCancelled else { return }
                // Own this task so leaving during the image/cache await can
                // cancel it and invalidate IceBarPanel's show generation.
                await appState.menuBarManager.iceBarPanel.show(section: .hidden, on: screen, activate:false)
                guard self.openingGeneration == ticket, self.started else { return }
                self.openingTask = nil
                self.evaluate()
            }
        case .hide:
            openingGeneration &+= 1
            openingTask?.cancel(); openingTask = nil
            panel.close()
        }
        scheduleDeadline()
    }

    private func scheduleDeadline() {
        deadlineTimer?.invalidate(); deadlineTimer = nil
        guard started, let deadline = policy.nextDeadline else { return }
        let delay = max(0.001, deadline-ProcessInfo.processInfo.systemUptime)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        deadlineTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}
