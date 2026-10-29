// Menu bar backend derived from Ice (GPL-3.0). Vertical UI by MacMenuY.
import Combine
import SwiftUI

@MainActor
final class IceBarPanel: NSPanel {
    private weak var appState: AppState?
    private(set) var currentSection: MenuBarSection.Name?
    private var subscriptions = Set<AnyCancellable>()
    private var outsideMonitor: Any?
    private var keyboardMonitor: Any?
    private var presentedDisplayID: CGDirectDisplayID?
    private var openedTimestamp: TimeInterval = 0
    private var generation = 0
    private(set) var lastDismissReason = ""
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(appState: AppState) {
        super.init(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                   backing: .buffered, defer: false)
        self.appState = appState
        title = "Tuckbar"
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = false
        allowsToolTipsWhenApplicationIsInactive = true
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
        backgroundColor = NSColor(calibratedWhite:0.08,alpha:1)
        isOpaque = true
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle, .moveToActiveSpace]
        isReleasedWhenClosed = false
    }

    func performSetup() {
        // A floating drawer follows the active desktop. Closing a Settings
        // window can itself generate an active-space notification on Tahoe;
        // such a notification must not cancel the drawer just opened from it.
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.resizeToCurrentContent() }.store(in:&subscriptions)
        if let appState {
            Publishers.Merge3(appState.imageCache.objectWillChange,
                appState.shelfManager.objectWillChange,appState.preferences.objectWillChange)
                .debounce(for:0.08,scheduler:DispatchQueue.main)
                .sink { [weak self] _ in self?.resizeToCurrentContent() }.store(in:&subscriptions)
        }
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.isVisible == true && event.keyCode == 53 { self?.lastDismissReason = "Escape"; self?.close(); return nil }
            return event
        }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            #if MENUY_VERIFY
            if ProcessInfo.processInfo.arguments.contains("--verification-keep-open") || MenuYDebugHarness.holdShelf { return }
            #endif
            guard let self, isVisible, appState?.shelfManager.isEditing != true,
                  event.timestamp >= openedTimestamp,
                  !frame.contains(NSEvent.mouseLocation) else { return }
            // The status item action handles toggling. Do not close before its click.
            if let appState, let controlFrame = appState.menuBarManager.section(withName: .visible)?.controlItem.windowFrame,
               controlFrame.contains(NSEvent.mouseLocation) { return }
            let point = NSEvent.mouseLocation
            let ticket = generation
            Task {
                try? await Task.sleep(for: .milliseconds(120))
                guard self.isVisible, ticket == self.generation else { return }
                // Activating this app from its Dock icon is a focus action;
                // preserve its own active drawer. Other apps/menu extras close it.
                let inMenuBar = NSScreen.screens.contains { point.y >= $0.frame.maxY - 40 && $0.frame.contains(point) }
                if !inMenuBar && NSWorkspace.shared.frontmostApplication == .current { return }
                self.lastDismissReason = "outside-click at \(point), event=\(event.timestamp), opened=\(self.openedTimestamp), front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil")"
                self.close()
            }
        }
    }

    func show(section: MenuBarSection.Name, on screen: NSScreen, activate: Bool = false) async {
        guard let appState else { return }
        generation += 1
        let ticket = generation
        lastDismissReason = ""
        currentSection = section
        appState.navigationState.isIceBarPresented = true
        if appState.itemManager.itemCache.allItems.isEmpty {
            await appState.itemManager.refreshItems()
        } else {
            await appState.itemManager.cacheItemsIfNeeded()
        }
        guard ticket == generation else { return }
        let hasPermission = ScreenCapture.cachedCheckPermissions() || ScreenCapture.cachedCheckPermissions(reset: true)
        if hasPermission {
            await appState.imageCache.updateCacheWithoutChecks(sections:MenuBarSection.Name.allCases)
        }
        guard ticket == generation else { return }
        presentedDisplayID=screen.displayID
        let rect=contentFrame(on:screen)
        setFrame(rect,display:false)
        alphaValue=appState.preferences.opacity
        appearance=NSAppearance(named:appState.menuCover.isDarkBar(on:screen.displayID) ? .darkAqua : .aqua)
        let hosting=DrawerHostingView(rootView:AnyView(
            MenuYHorizontalShelf(screen:screen,size:rect.size,close:{ [weak self] in self?.close() })
                .environmentObject(appState).environmentObject(appState.shelfManager)
                .environmentObject(appState.imageCache).environmentObject(appState.activity)
                .environmentObject(appState.preferences).environmentObject(appState.menuCover)))
        hosting.sizingOptions=[]
        hosting.frame=CGRect(origin:.zero,size:rect.size)
        hosting.autoresizingMask=[.width,.height]
        contentView=hosting
        openedTimestamp = ProcessInfo.processInfo.systemUptime
        if activate {
            makeKeyAndOrderFront(nil)
        } else { orderFrontRegardless() }
        appState.shelfManager.writeDiagnostics()
        MenuYEvidence.capture(appState:appState)
    }

    private func contentFrame(on screen:NSScreen)->CGRect {
        guard let appState else { return frame }
        let iconSize=CGFloat(appState.preferences.iconSize)
        let items=appState.preferences.ordered(appState.itemManager.itemCache.allItems.filter { $0.info.namespace != .ice },
                                              hasActivity:appState.activity.hasActivity)
        let widths=items.map { item -> CGFloat in
            let size=appState.imageCache.images[item.windowID].map { CGSize(width:$0.width,height:$0.height) }
                ?? item.owningApplication?.icon?.size
            return MenuYBarGeometry.iconWidth(imageSize:size,iconSize:iconSize)
        }
        return MenuYBarGeometry.shelfFrame(screen:screen.frame,visible:screen.visibleFrame,
            menuBarHeight:screen.getMenuBarHeight() ?? NSStatusBar.system.thickness,
            itemWidths:widths,iconSize:iconSize,compact:appState.preferences.style == .compact,
            footerHeight:appState.shelfManager.message == nil ? 0 : 36)
    }
    private func resizeToCurrentContent() {
        guard isVisible,let appState,
              let screen=NSScreen.screens.first(where:{$0.displayID == presentedDisplayID}) ?? self.screen ?? NSScreen.main else { return }
        setFrame(contentFrame(on:screen),display:true)
        alphaValue=appState.preferences.opacity
        appearance=NSAppearance(named:appState.menuCover.isDarkBar(on:screen.displayID) ? .darkAqua : .aqua)
        appState.shelfManager.writeDiagnostics()
    }

    override func close() {
        generation += 1
        orderOut(nil)
        contentView = nil
        currentSection = nil
        if appState?.shelfManager.isEditing == true {
            appState?.shelfManager.isEditing = false
        }
        if appState?.navigationState.isIceBarPresented == true {
            appState?.navigationState.isIceBarPresented = false
        }
        if appState?.settingsWindow?.isVisible != true, NSApp.activationPolicy() != .accessory {
            NSApp.setActivationPolicy(.accessory)
        }
        appState?.shelfManager.writeDiagnostics()
    }
}

private final class DrawerHostingView: NSHostingView<AnyView> {
    override var safeAreaInsets: NSEdgeInsets { .init() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private enum DrawerFilter: String, CaseIterable {
    case hidden = "已收起", pinned = "菜单栏", all = "全部"
}

private struct DrawerContent: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var itemManager: MenuBarItemManager
    @EnvironmentObject var imageCache: MenuBarItemImageCache
    @EnvironmentObject var shelf: ShelfManager
    @State private var query = ""
    @State private var filter = DrawerFilter.hidden
    let screen: NSScreen
    let panelSize: CGSize
    let closePanel: () -> Void

    private var allItems: [MenuBarItem] {
        var seen = Set<CGWindowID>()
        return itemManager.itemCache.allItems.filter { item in
            item.info.namespace != .ice && item.owningApplication != .current && seen.insert(item.windowID).inserted
        }.sorted { lhs, rhs in
            lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }
    private var items: [MenuBarItem] {
        allItems.filter { item in
            let matchesSection = filter == .all || (filter == .pinned ? shelf.isPinned(item) : !shelf.isPinned(item))
            let text = item.displayName + " " + (item.title ?? "")
            return matchesSection && (query.isEmpty || text.localizedStandardContains(query))
        }
    }
    private var hiddenCount: Int { allItems.filter { !shelf.isPinned($0) }.count }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "tray.full.fill").foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("MacMenuY").font(.system(size: 15, weight: .semibold))
                    Text("\(hiddenCount) 个已收起 · \(allItems.count - hiddenCount) 个在菜单栏")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                if shelf.isBusy { ProgressView().controlSize(.small) }
                Button(action: closePanel) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).accessibilityLabel("关闭面板")
            }.padding(.horizontal, 16).padding(.vertical, 12)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索菜单栏项目", text: $query).textFieldStyle(.plain)
                    .accessibilityIdentifier("drawer-search")
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).accessibilityLabel("清除搜索")
                }
            }.padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 12)
            Picker("项目范围", selection: $filter) {
                ForEach(DrawerFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 12).padding(.vertical, 10)
            Divider()
            if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: query.isEmpty ? "tray" : "magnifyingglass").font(.title2)
                    Text(query.isEmpty ? "这里还没有项目" : "没有匹配的项目").font(.callout)
                    if allItems.isEmpty { Text("点击刷新，或检查辅助功能权限。") }
                }.foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 2) {
                        ForEach(items, id: \.windowID) { item in
                            DrawerRow(item: item, showTitle: allItems.filter { $0.info.namespace == item.info.namespace }.count > 1,
                                      closePanel: closePanel)
                        }
                    }.padding(6)
                }.scrollIndicators(.visible)
            }
            Divider()
            if let message = shelf.message {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(message).font(.caption).lineLimit(3)
                    Spacer()
                    Button { shelf.message = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                }.foregroundStyle(.orange).padding(10)
            }
            HStack(spacing: 12) {
                Button { Task { await shelf.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("刷新图标")
                Button(shelf.isEnabled ? "暂停折叠" : "恢复折叠") { shelf.toggleEnabled() }
                Spacer()
                Button { closePanel(); appState.appDelegate?.openSettingsWindow() } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("MacMenuY 设置")
            }.buttonStyle(.borderless).font(.caption).padding(.horizontal, 14).padding(.vertical, 10)
            Text("点击打开 · 右键原菜单 · 图钉固定/收回").font(.system(size: 10))
                .foregroundStyle(.secondary).padding(.bottom, 10)
        }
        .frame(width: panelSize.width, height: panelSize.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.12), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .disabled(shelf.isBusy)
        .accessibilityIdentifier("MacMenuY-drawer")
    }
}

private struct DrawerRow: View {
    @EnvironmentObject var itemManager: MenuBarItemManager
    @EnvironmentObject var imageCache: MenuBarItemImageCache
    @EnvironmentObject var shelf: ShelfManager
    @State private var hovering = false
    let item: MenuBarItem
    let showTitle: Bool
    let closePanel: () -> Void

    private var image: NSImage? {
        if let cg = imageCache.images[item.windowID] {
            let scale = imageCache.screen?.backingScaleFactor ?? 2
            return NSImage(cgImage: cg, size: CGSize(width: CGFloat(cg.width) / scale, height: CGFloat(cg.height) / scale))
        }
        return item.owningApplication?.icon
    }
    private var label: String {
        showTitle && !(item.title ?? "").isEmpty ? item.displayName + " · " + (item.title ?? "") : item.displayName
    }
    private func open(_ button: CGMouseButton) {
        closePanel()
        Task {
            try? await Task.sleep(for: .milliseconds(25))
            itemManager.tempShowItem(item, clickWhenFinished: true, mouseButton: button)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 10) {
                Group {
                    if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit) }
                    else { Image(systemName: "app.dashed").foregroundStyle(.secondary) }
                }.frame(width: 28, height: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.displayName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if showTitle, let title = item.title, !title.isEmpty {
                        Text(title).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
            }.padding(.leading, 10).frame(maxWidth: .infinity).frame(height: 42)
                .contentShape(Rectangle())
                .overlay { DrawerClickView(left: { open(.left) }, right: { open(.right) }, label: label) }
            if item.isMovable && item.canBeHidden {
                Button {
                    Task { await shelf.toggle(item) }
                } label: {
                    Image(systemName: shelf.isPinned(item) ? "pin.fill" : "pin")
                        .foregroundStyle(shelf.isPinned(item) ? Color.accentColor : Color.secondary)
                        .frame(width: 34, height: 34)
                }.buttonStyle(.borderless)
                    .help(shelf.isPinned(item) ? "收回弹出列表" : "固定到菜单栏")
                    .accessibilityLabel("\(shelf.isPinned(item) ? "收回" : "固定") \(label)")
            } else {
                Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(.tertiary)
                    .frame(width: 34).help("macOS 强制保留的系统项目")
            }
        }
        .background(hovering ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .onHover { hovering = $0 }
    }
}

private struct DrawerClickView: NSViewRepresentable {
    final class ClickView: NSView {
        var left: () -> Void = {}
        var right: () -> Void = {}
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { left() } }
        override func rightMouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { right() } }
        override func accessibilityPerformPress() -> Bool { left(); return true }
    }
    let left: () -> Void
    let right: () -> Void
    let label: String
    func makeNSView(context: Context) -> ClickView {
        let view = ClickView()
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        return view
    }
    func updateNSView(_ view: ClickView, context: Context) {
        view.left = left; view.right = right
        view.setAccessibilityLabel("打开 " + label)
        view.toolTip = label
    }
}
