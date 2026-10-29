import AppKit
import SwiftUI

enum MenuYDuskPalette {
    // Paper (deep slate: oklch(17.5% 0.014 268) .. oklch(25% 0.017 268))
    static let paper = Color(red: 0.086, green: 0.094, blue: 0.133)
    static let paper2 = Color(red: 0.114, green: 0.125, blue: 0.173)
    static let paper3 = Color(red: 0.145, green: 0.157, blue: 0.212)
    static let rule = Color(red: 0.220, green: 0.235, blue: 0.302)

    // Ink (warm bone: oklch(96% 0.006 75) & cool slate)
    static let ink = Color(red: 0.961, green: 0.953, blue: 0.937)
    static let ink2 = Color(red: 0.816, green: 0.827, blue: 0.867)
    static let muted = Color(red: 0.620, green: 0.635, blue: 0.694)

    // Two signals, two jobs: Periwinkle (done/pinned/primary) & Apricot (open/attention/editing)
    static let periwinkle = Color(red: 0.663, green: 0.694, blue: 0.949)
    static let periwinkleInk = Color(red: 0.082, green: 0.094, blue: 0.176)
    static let apricot = Color(red: 0.922, green: 0.725, blue: 0.510)
    static let apricotInk = Color(red: 0.165, green: 0.110, blue: 0.055)

    // Bone wells
    static let well = Color(red: 0.949, green: 0.941, blue: 0.922)
    static let card = Color(red: 0.992, green: 0.988, blue: 0.980)
}

struct MenuYDuskDot: View {
    var size: CGFloat = 10
    var body: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [MenuYDuskPalette.apricot, MenuYDuskPalette.periwinkle, MenuYDuskPalette.paper3],
                    center: UnitPoint(x: 0.32, y: 0.28),
                    startRadius: 0,
                    endRadius: size * 0.85
                )
            )
            .frame(width: size, height: size)
            .shadow(color: MenuYDuskPalette.periwinkle.opacity(0.32), radius: 5, x: 0, y: 0)
    }
}

struct MenuYFlowLayout: Layout {
    var spacing: CGFloat = 6
    var rowHeight: CGFloat = 33
    private func plan(width: CGFloat, subviews: Subviews) -> MenuYBarGeometry.FlowPlan {
        MenuYBarGeometry.flowPlan(itemWidths: subviews.map { $0.sizeThatFits(.unspecified).width },
                                  availableWidth: width, rowHeight: rowHeight, spacing: spacing)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        plan(width: proposal.width ?? 1000, subviews: subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = plan(width: bounds.width, subviews: subviews)
        for (index, view) in subviews.enumerated() {
            let point = result.positions[index]
            view.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y + rowHeight / 2),
                       anchor: .leading, proposal: ProposedViewSize(width: result.widths[index], height: rowHeight))
        }
    }
}

struct MenuYHorizontalShelf: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var shelf: ShelfManager
    @EnvironmentObject var cache: MenuBarItemImageCache
    @EnvironmentObject var activity: MenuYActivity
    @EnvironmentObject var prefs: MenuYPreferences
    @EnvironmentObject var cover: MenuYMenuCover
    @State private var query = ""
    let screen: NSScreen
    let size: CGSize
    let close: () -> Void
    private var editing: Bool { shelf.isEditing }
    private var items: [MenuBarItem] {
        let base = appState.itemManager.itemCache.allItems.filter { $0.info.namespace != .ice }
        return prefs.ordered(base, hasActivity: { activity.hasActivity($0) }).filter {
            query.isEmpty || ($0.displayName + " " + ($0.title ?? "")).localizedStandardContains(query)
        }
    }
    private func activateFirstMatch() {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !shelf.isBusy,
              let item = items.first else { return }
        guard !editing || (item.isMovable && item.canBeHidden) else { return }
        Task {
            if editing { await shelf.toggle(item) }
            else { await shelf.activate(item, button: .left, modifiers: NSEvent.modifierFlags, clickCount: 1, closeShelf: true) }
        }
    }
    private var spacing: CGFloat { prefs.style == .compact ? 3 : 6 }
    private var rowHeight: CGFloat { MenuYBarGeometry.rowHeight(iconSize: prefs.iconSize, compact: prefs.style == .compact) }
    var body: some View {
        GeometryReader { geometry in
            content(width: geometry.size.width)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain).accessibilityIdentifier("MacMenuY-horizontal-shelf")
    }
    private func content(width: CGFloat) -> some View {
        let isDark = cover.isDarkBar(on: screen.displayID)
        let fg = isDark ? MenuYDuskPalette.ink : Color.black
        let mutedFg = isDark ? MenuYDuskPalette.ink2 : Color.black.opacity(0.66)
        let pinnedCount = items.filter { shelf.isPinned($0) }.count
        let hiddenCount = max(0, items.count - pinnedCount)
        return VStack(spacing:0) {
            HStack(spacing:10) {
                HStack(spacing:7) {
                    MenuYDuskDot(size: 9)
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(MenuYDuskPalette.periwinkle.opacity(0.9))
                    MenuYSearchField(text: $query, isDark: isDark, onSubmit: activateFirstMatch)
                        .frame(width: 192, height: 22)
                }
                .padding(.horizontal, 9)
                .frame(height: 25)
                .background(
                    isDark ? MenuYDuskPalette.paper.opacity(0.76) : Color.black.opacity(0.07),
                    in: Capsule()
                )
                .overlay(
                    Capsule().strokeBorder(
                        isDark ? MenuYDuskPalette.ink.opacity(0.11) : Color.black.opacity(0.14),
                        lineWidth: 0.75
                    )
                )

                HStack(spacing: 6) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(MenuYDuskPalette.periwinkle)
                            .frame(width: 5.5, height: 5.5)
                        Text("\(hiddenCount) 项收起，\(pinnedCount) 项常驻")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(mutedFg)
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        isDark ? MenuYDuskPalette.periwinkle.opacity(0.11) : Color.black.opacity(0.05),
                        in: Capsule()
                    )
                    .overlay(
                        Capsule().strokeBorder(MenuYDuskPalette.periwinkle.opacity(0.24), lineWidth: 0.5)
                    )

                    if editing {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(MenuYDuskPalette.apricot)
                                .frame(width: 5.5, height: 5.5)
                            Text("整理锁定中，自动隐藏已暂停")
                                .font(.system(size: 10.5, weight: .semibold))
                        }
                        .foregroundStyle(isDark ? MenuYDuskPalette.apricot : MenuYDuskPalette.apricotInk)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(MenuYDuskPalette.apricot.opacity(isDark ? 0.18 : 0.28), in: Capsule())
                        .overlay(
                            Capsule().strokeBorder(MenuYDuskPalette.apricot.opacity(0.45), lineWidth: 0.75)
                        )
                    } else if activity.unreadCount > 0 {
                        Label("\(activity.unreadCount) 条未读" + (activity.unreadStale.contains { (activity.unread[$0] ?? 0) > 0 } ? "（上次确认）" : ""), systemImage: "bell.badge.fill")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(isDark ? MenuYDuskPalette.apricot : MenuYDuskPalette.apricotInk)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2.5)
                            .background(MenuYDuskPalette.apricot.opacity(0.18), in: Capsule())
                            .overlay(Capsule().strokeBorder(MenuYDuskPalette.apricot.opacity(0.38), lineWidth: 0.5))
                            .lineLimit(1)
                    } else if activity.changedAppCount > 0 {
                        Label("\(activity.changedAppCount) 项有更新", systemImage: "sparkles")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(MenuYDuskPalette.apricot)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength:8)
                if shelf.isBusy { ProgressView().controlSize(.small).scaleEffect(0.75) }
                Button {
                    shelf.isEditing.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: editing ? "pin.fill" : "pin")
                            .font(.system(size: 11, weight: .semibold))
                        Text(editing ? "完成整理" : "整理")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        editing
                            ? MenuYDuskPalette.periwinkle
                            : (isDark ? MenuYDuskPalette.paper3.opacity(0.85) : Color.black.opacity(0.08)),
                        in: Capsule()
                    )
                    .overlay(
                        Capsule().strokeBorder(
                            editing ? Color.white.opacity(0.28) : MenuYDuskPalette.ink.opacity(0.12),
                            lineWidth: 0.75
                        )
                    )
                    .foregroundStyle(editing ? MenuYDuskPalette.periwinkleInk : fg)
                }
                .accessibilityLabel("整理图标")
                .help(editing ? "点击退出整理模式并恢复自动隐藏" : "整理模式：锁定面板不自动隐藏，点击图标切换常驻/收起")
                .disabled(shelf.isBusy)

                HStack(spacing: 4) {
                    Button { shelf.toggleEnabled() } label: {
                        Image(systemName: shelf.isEnabled ? "pause.circle" : "play.circle")
                            .font(.system(size: 12.5))
                            .frame(width: 24, height: 22)
                            .background(
                                isDark ? MenuYDuskPalette.paper3.opacity(0.72) : Color.black.opacity(0.07),
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(MenuYDuskPalette.ink.opacity(0.09), lineWidth: 0.5)
                            )
                    }
                    .help(shelf.isEnabled ? "停用收纳" : "启用收纳")
                    .accessibilityLabel(shelf.isEnabled ? "停用收纳" : "启用收纳")
                    .disabled(shelf.isBusy)

                    Button { close(); appState.appDelegate?.openSettingsWindow() } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 12))
                            .frame(width: 24, height: 22)
                            .background(
                                isDark ? MenuYDuskPalette.paper3.opacity(0.72) : Color.black.opacity(0.07),
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(MenuYDuskPalette.ink.opacity(0.09), lineWidth: 0.5)
                            )
                    }
                    .help("Tuckbar 设置")
                    .accessibilityLabel("打开设置")

                    Button { NSApp.terminate(nil) } label: {
                        Image(systemName: "power")
                            .font(.system(size: 11.5))
                            .frame(width: 24, height: 22)
                            .background(
                                isDark ? MenuYDuskPalette.paper3.opacity(0.72) : Color.black.opacity(0.07),
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(MenuYDuskPalette.ink.opacity(0.09), lineWidth: 0.5)
                            )
                    }
                    .help("退出 Tuckbar")
                    .accessibilityLabel("退出 Tuckbar")

                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 24, height: 22)
                            .background(
                                isDark ? MenuYDuskPalette.paper3.opacity(0.72) : Color.black.opacity(0.07),
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(MenuYDuskPalette.ink.opacity(0.09), lineWidth: 0.5)
                            )
                    }
                    .help("关闭收纳栏")
                    .accessibilityLabel("关闭收纳栏")
                }
            }.buttonStyle(.plain).padding(.horizontal, MenuYBarGeometry.horizontalPadding).frame(height: MenuYBarGeometry.headerHeight)
            Rectangle().fill(isDark ? MenuYDuskPalette.rule.opacity(0.75) : Color.black.opacity(0.12)).frame(height: MenuYBarGeometry.dividerHeight)
            ScrollView(.vertical) {
                MenuYFlowLayout(spacing:spacing,rowHeight:rowHeight) {
                    ForEach(items,id:\.windowID) { item in
                        MenuYIcon(item:item,iconSize:prefs.iconSize,markActivity:true,closeShelf:true,editing:editing,
                                  maximumWidth: max(1, width - MenuYBarGeometry.horizontalPadding * 2), rowHeight: rowHeight)
                    }
                    if items.isEmpty { Text("没有匹配的菜单栏项目").font(.caption).foregroundStyle(mutedFg).padding(8) }
                }.padding(.horizontal, MenuYBarGeometry.horizontalPadding)
            }.scrollIndicators(.visible)
            if let error=shelf.message {
                HStack { Image(systemName:"exclamationmark.triangle"); Text(error).font(.caption); Spacer(); Button("关闭提示") { shelf.message=nil } }
                    .foregroundStyle(MenuYDuskPalette.apricot).padding(8)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(fg)
        .background {
            ZStack {
                if let bg = cover.backgrounds[screen.displayID] {
                    Image(nsImage: bg).resizable()
                    if isDark {
                        MenuYDuskPalette.paper2.opacity(0.72)
                    }
                } else {
                    LinearGradient(
                        colors: [MenuYDuskPalette.paper, MenuYDuskPalette.paper2],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                if prefs.style == .glass {
                    Rectangle().fill(.ultraThinMaterial).opacity(0.55)
                }
            }
        }.clipped()
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(isDark ? 0.12 : 0.35)).frame(height: 1)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(isDark ? MenuYDuskPalette.rule : Color.black.opacity(0.18)).frame(height: 1)
        }
        .environment(\.colorScheme, isDark ? .dark : .light)
    }
}

struct MenuYIcon: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var shelf: ShelfManager
    @EnvironmentObject var cache: MenuBarItemImageCache
    @EnvironmentObject var activity: MenuYActivity
    @State private var hovering=false
    let item: MenuBarItem
    let iconSize: CGFloat
    let markActivity: Bool
    let closeShelf: Bool
    var editing=false
    var maximumWidth: CGFloat = .greatestFiniteMagnitude
    var rowHeight: CGFloat = 33
    private var image: NSImage? {
        if let image=cache.images[item.windowID] {
            let scale=cache.screen?.backingScaleFactor ?? 2
            return NSImage(cgImage:image,size:CGSize(width:CGFloat(image.width)/scale,height:CGFloat(image.height)/scale))
        }
        return item.owningApplication?.icon
    }
    private var width: CGFloat {
        MenuYBarGeometry.iconWidth(imageSize: image?.size, iconSize: iconSize, maximumWidth: maximumWidth)
    }
    private var helpText: String {
        let status = activity.unread[item.info.description].flatMap { $0 > 0 ? "，应用提示未读 \($0)" + (activity.unreadStale.contains(item.info.description) ? "（上次确认）" : "") : nil }
            ?? (activity.hasActivity(item) ? "，图标有变化" : "")
        return item.displayName + status + (editing && !canPin ? "，系统固定项目" : "")
    }
    private var canPin: Bool { item.isMovable && item.canBeHidden }
    private var inputLabel: String {
        if editing && !canPin { return "系统固定项目 " + item.displayName }
        return editing ? (shelf.isPinned(item) ? "收回 " : "固定 ") + item.displayName : "打开 " + item.displayName
    }
    var body: some View {
        let isPinned = shelf.isPinned(item)
        let hasUnreadOrChange = markActivity && activity.hasActivity(item)
        ZStack(alignment:.bottomTrailing) {
            Group {
                if let image { Image(nsImage:image).resizable().aspectRatio(contentMode:.fit).frame(width: max(1, width - MenuYBarGeometry.iconHorizontalPadding), height: iconSize) }
                else { Image(systemName:"app.dashed").frame(width:iconSize,height:iconSize) }
            }.frame(width: width, height: rowHeight)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(
                            hovering
                                ? MenuYDuskPalette.periwinkle.opacity(0.18)
                                : (editing
                                    ? (isPinned ? MenuYDuskPalette.periwinkle.opacity(0.14) : MenuYDuskPalette.ink.opacity(0.05))
                                    : (hasUnreadOrChange ? MenuYDuskPalette.apricot.opacity(0.09) : .clear))
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(
                            editing
                                ? (isPinned ? MenuYDuskPalette.periwinkle.opacity(0.68) : MenuYDuskPalette.ink.opacity(0.16))
                                : (hovering ? MenuYDuskPalette.periwinkle.opacity(0.38) : (hasUnreadOrChange ? MenuYDuskPalette.apricot.opacity(0.35) : .clear)),
                            lineWidth: 1
                        )
                )
                .overlay {
                    MenuYInputView(label: inputLabel,
                                   help: helpText, identifier: "menuy.item.\(item.windowID)") { button,flags,count in
                        Task {
                            if editing && button == .left { if canPin { await shelf.toggle(item) } }
                            else { await shelf.activate(item,button:button,modifiers:flags,clickCount:count,closeShelf:closeShelf) }
                        }
                    }
                }
            if editing {
                Image(systemName:canPin ? (isPinned ? "pin.fill" : "pin") : "lock.fill")
                    .font(.system(size:9, weight: .bold))
                    .foregroundStyle(canPin && isPinned ? MenuYDuskPalette.periwinkle : MenuYDuskPalette.muted)
                    .padding(3)
                    .background(MenuYDuskPalette.paper.opacity(0.88), in: Circle())
                    .overlay(Circle().strokeBorder(canPin && isPinned ? MenuYDuskPalette.periwinkle.opacity(0.55) : Color.clear, lineWidth: 0.75))
                    .padding(2)
                    .allowsHitTesting(false)
            }
            else if hasUnreadOrChange {
                Circle()
                    .fill(MenuYDuskPalette.apricot)
                    .frame(width: 5.5, height: 5.5)
                    .shadow(color: MenuYDuskPalette.apricot.opacity(0.5), radius: 3)
                    .padding(3)
                    .allowsHitTesting(false)
            }
        }.onHover { hovering=$0 }.disabled(shelf.isBusy || (editing && !canPin))
    }
}
private struct MenuYInputView: NSViewRepresentable {
    final class InputView: NSView {
        var action: (CGMouseButton,NSEvent.ModifierFlags,Int)->Void = { _,_,_ in }
        var down: CGPoint?
        var downFlags: NSEvent.ModifierFlags = []
        var acceptsInput = true
        override func acceptsFirstMouse(for event:NSEvent?)->Bool { true }
        override var acceptsFirstResponder: Bool { false }
        override var needsPanelToBecomeKey: Bool { false }
        override func mouseDown(with event:NSEvent) { if acceptsInput { down=event.locationInWindow; downFlags=event.modifierFlags } }
        override func rightMouseDown(with event:NSEvent) { if acceptsInput { down=event.locationInWindow; downFlags=event.modifierFlags } }
        override func otherMouseDown(with event:NSEvent) { if acceptsInput { down=event.locationInWindow; downFlags=event.modifierFlags } }
        override func mouseUp(with event:NSEvent) { click(event,.left) }
        override func rightMouseUp(with event:NSEvent) { click(event,.right) }
        override func otherMouseUp(with event:NSEvent) { click(event,.center) }
        override func keyDown(with event: NSEvent) {
            guard acceptsInput else { return }
            if [36, 49, 76].contains(event.keyCode) { action(.left, event.modifierFlags, 1) }
            else if event.keyCode == 110 || (event.keyCode == 109 && event.modifierFlags.contains(.shift)) { action(.right, event.modifierFlags, 1) }
            else { super.keyDown(with: event) }
        }
        private func click(_ event:NSEvent,_ button:CGMouseButton) {
            defer { down = nil; downFlags = [] }
            guard acceptsInput, let down, bounds.contains(convert(event.locationInWindow, from: nil)),
                  hypot(event.locationInWindow.x-down.x,event.locationInWindow.y-down.y)<6 else { return }
            let upFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let downMask = downFlags.intersection(.deviceIndependentFlagsMask)
            let hidFlags = CGEventSource.flagsState(.hidSystemState)
            let cmdLeft = CGEventSource.keyState(.hidSystemState, key: 55) || CGEventSource.keyState(.combinedSessionState, key: 55)
            let cmdRight = CGEventSource.keyState(.hidSystemState, key: 54) || CGEventSource.keyState(.combinedSessionState, key: 54)
            var effectiveFlags = upFlags.intersection(downMask)
            if effectiveFlags.contains(.command) && !cmdLeft && !cmdRight && !hidFlags.contains(.maskCommand) {
                effectiveFlags.remove(.command)
            }
            action(button, effectiveFlags, event.clickCount)
        }
        override func accessibilityPerformPress()->Bool { guard acceptsInput else { return false }; action(.left,[],1); return true }
    }
    @Environment(\.isEnabled) private var isEnabled
    let label:String
    let help:String
    let identifier:String
    let action:(CGMouseButton,NSEvent.ModifierFlags,Int)->Void
    func makeNSView(context:Context)->InputView { let v=InputView();v.setAccessibilityElement(true);v.setAccessibilityRole(.button);return v }
    func updateNSView(_ view:InputView,context:Context) { view.action=action; view.acceptsInput=isEnabled; view.toolTip=help; view.setAccessibilityLabel(label); view.setAccessibilityIdentifier(identifier); view.setAccessibilityEnabled(isEnabled) }
}


/// NSSearchField keeps the native search/clear affordances and explicitly avoids
/// the white NSTextField backing seen in transparent Tahoe hosting windows.
private struct MenuYSearchField: NSViewRepresentable {
    @Binding var text: String
    let isDark: Bool
    let onSubmit: () -> Void
    final class Field: NSSearchField {
        private var requestedFocus = false
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var needsPanelToBecomeKey: Bool { true }
        override func mouseDown(with event: NSEvent) {
            window?.makeKey()
            super.mouseDown(with: event)
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, !requestedFocus else { return }
            requestedFocus = true
            DispatchQueue.main.async { [weak self] in
                guard let self, window?.isVisible == true, window?.isKeyWindow == true else { return }
                window?.makeFirstResponder(self)
            }
        }
    }
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: MenuYSearchField
        init(_ parent: MenuYSearchField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }
        @objc func searchChanged(_ sender: NSSearchField) { parent.text = sender.stringValue }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.text = (control as? NSSearchField)?.stringValue ?? parent.text
                parent.onSubmit(); return true
            }
            return false
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.delegate = context.coordinator; field.target = context.coordinator
        field.action = #selector(Coordinator.searchChanged(_:))
        field.placeholderString = "检索全部菜单栏项目"
        field.sendsSearchStringImmediately = true; field.sendsWholeSearchString = false
        field.recentsAutosaveName = nil
        field.isBezeled = false; field.isBordered = false; field.drawsBackground = false
        field.backgroundColor = .clear; field.focusRingType = .none
        field.controlSize = .small; field.font = .systemFont(ofSize: 12)
        field.setAccessibilityLabel("检索全部菜单栏项目")
        field.setAccessibilityIdentifier("menuy-search")
        field.toolTip = "输入名称后按 Return 打开，Esc 收起"
        return field
    }
    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        field.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        field.drawsBackground = false
        field.textColor = isDark ? .white : .black
        if let cell = field.cell as? NSTextFieldCell {
            cell.drawsBackground = false; cell.backgroundColor = .clear
            cell.placeholderAttributedString = NSAttributedString(string: "检索全部菜单栏项目", attributes: [
                .foregroundColor: (isDark ? NSColor.white : NSColor.black).withAlphaComponent(0.55),
                .font: NSFont.systemFont(ofSize: 12)
            ])
        }
    }
}
