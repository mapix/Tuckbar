import AppKit
import SwiftUI

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
    @State private var editing = false
    let screen: NSScreen
    let size: CGSize
    let close: () -> Void
    private var items: [MenuBarItem] {
        let base = appState.itemManager.itemCache.allItems.filter { $0.info.namespace != .ice }
        return prefs.ordered(base, hasActivity: { activity.hasActivity($0) }).filter {
            query.isEmpty || ($0.displayName + " " + ($0.title ?? "")).localizedStandardContains(query)
        }
    }
    private func activateFirstMatch() {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !shelf.isBusy,
              let item = items.first else { return }
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
        VStack(spacing:0) {
            HStack(spacing:12) {
                MenuYSearchField(text: $query, isDark: cover.isDarkBar(on: screen.displayID), onSubmit: activateFirstMatch)
                    .padding(.horizontal, 6).frame(width: 220, height: 26)
                    .background(cover.foregroundColor(for: screen.displayID).opacity(0.1), in: RoundedRectangle(cornerRadius: 6))

                Text("\(items.count) 项").font(.system(size:11)).foregroundStyle(.secondary)
                if activity.unreadCount>0 { Label("\(activity.unreadCount) 条应用提示未读",systemImage:"bell.badge").font(.caption).lineLimit(1) }
                else if activity.changedAppCount>0 { Label("\(activity.changedAppCount) 个图标有变化",systemImage:"circle.fill").font(.caption).lineLimit(1) }
                Spacer(minLength:8)
                if shelf.isBusy { ProgressView().controlSize(.small) }
                Toggle(isOn:$editing) { Image(systemName:"pin") }.toggleStyle(.button)
                    .accessibilityLabel("整理图标").help("整理模式：点击图标固定/收回").disabled(shelf.isBusy)
                Button { shelf.toggleEnabled() } label: { Image(systemName:shelf.isEnabled ? "pause.circle" : "play.circle") }
                    .help(shelf.isEnabled ? "停用收纳" : "启用收纳").accessibilityLabel(shelf.isEnabled ? "停用收纳" : "启用收纳").disabled(shelf.isBusy)
                Button { close(); appState.appDelegate?.openSettingsWindow() } label: { Image(systemName:"gearshape") }.help("设置").accessibilityLabel("打开设置")
                Button { NSApp.terminate(nil) } label: { Image(systemName:"power") }.help("退出 MacMenuY").accessibilityLabel("退出 MacMenuY")
                Button(action:close) { Image(systemName:"xmark") }.help("关闭收纳栏").accessibilityLabel("关闭收纳栏")
            }.buttonStyle(.plain).padding(.horizontal, MenuYBarGeometry.horizontalPadding).frame(height: MenuYBarGeometry.headerHeight)
            Rectangle().fill(cover.foregroundColor(for: screen.displayID).opacity(0.12)).frame(height: MenuYBarGeometry.dividerHeight)
            ScrollView(.vertical) {
                MenuYFlowLayout(spacing:spacing,rowHeight:rowHeight) {
                    ForEach(items,id:\.windowID) { item in
                        MenuYIcon(item:item,iconSize:prefs.iconSize,markActivity:true,closeShelf:true,editing:editing,
                                  maximumWidth: max(1, width - MenuYBarGeometry.horizontalPadding * 2), rowHeight: rowHeight)
                    }
                    if items.isEmpty { Text("没有匹配的菜单栏项目").font(.caption).padding(8) }
                }.padding(.horizontal, MenuYBarGeometry.horizontalPadding)
            }.scrollIndicators(.visible)
            if let error=shelf.message {
                HStack { Image(systemName:"exclamationmark.triangle"); Text(error).font(.caption); Spacer(); Button("关闭提示") { shelf.message=nil } }
                    .foregroundStyle(.orange).padding(8)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(cover.foregroundColor(for: screen.displayID))
        .background {
            ZStack {
                if let bg = cover.backgrounds[screen.displayID] { Image(nsImage: bg).resizable() }
                else { Color(red: 0.08, green: 0.08, blue: 0.08) }
                if prefs.style == .glass { Rectangle().fill(.regularMaterial).opacity(0.35) }
            }
        }.clipped()
        .overlay(alignment: .bottom) {
            Rectangle().fill(cover.foregroundColor(for: screen.displayID).opacity(0.22)).frame(height: 1)
        }
        .environment(\.colorScheme, cover.isDarkBar(on: screen.displayID) ? .dark : .light)
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
        let status = activity.unread[item.info.description].flatMap { $0 > 0 ? " · 应用提示未读 \($0)" : nil }
            ?? (activity.hasActivity(item) ? " · 图标有变化" : "")
        return item.displayName + status
    }
    var body: some View {
        ZStack(alignment:.bottomTrailing) {
            Group {
                if let image { Image(nsImage:image).resizable().aspectRatio(contentMode:.fit).frame(width: max(1, width - MenuYBarGeometry.iconHorizontalPadding), height: iconSize) }
                else { Image(systemName:"app.dashed").frame(width:iconSize,height:iconSize) }
            }.frame(width: width, height: rowHeight)
                .background(hovering ? Color.primary.opacity(0.12) : .clear,in:RoundedRectangle(cornerRadius:5))
                .overlay {
                    MenuYInputView(label: editing ? (shelf.isPinned(item) ? "收回 " : "固定 ") + item.displayName : "打开 " + item.displayName,
                                   help: helpText) { button,flags,count in
                        Task {
                            if editing && button == .left { await shelf.toggle(item) }
                            else { await shelf.activate(item,button:button,modifiers:flags,clickCount:count,closeShelf:closeShelf) }
                        }
                    }
                }
            if editing { Image(systemName:shelf.isPinned(item) ? "pin.fill" : "pin").font(.system(size:9)).foregroundStyle(shelf.isPinned(item) ? .green : .secondary).allowsHitTesting(false) }
            else if markActivity && activity.hasActivity(item) { Circle().fill(.orange).frame(width:4,height:4).padding(2).allowsHitTesting(false) }
        }.onHover { hovering=$0 }.disabled(shelf.isBusy)
    }
}
private struct MenuYInputView: NSViewRepresentable {
    final class InputView: NSView {
        var action: (CGMouseButton,NSEvent.ModifierFlags,Int)->Void = { _,_,_ in }
        var down: CGPoint?
        var acceptsInput = true
        override func acceptsFirstMouse(for event:NSEvent?)->Bool { true }
        override var acceptsFirstResponder: Bool { true }
        override func mouseDown(with event:NSEvent) { if acceptsInput { down=event.locationInWindow } }
        override func rightMouseDown(with event:NSEvent) { if acceptsInput { down=event.locationInWindow } }
        override func otherMouseDown(with event:NSEvent) { if acceptsInput { down=event.locationInWindow } }
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
            defer { down = nil }
            guard acceptsInput, let down, bounds.contains(convert(event.locationInWindow, from: nil)),
                  hypot(event.locationInWindow.x-down.x,event.locationInWindow.y-down.y)<6 else { return }
            action(button,event.modifierFlags,event.clickCount)
        }
        override func accessibilityPerformPress()->Bool { guard acceptsInput else { return false }; action(.left,[],1); return true }
    }
    @Environment(\.isEnabled) private var isEnabled
    let label:String
    let help:String
    let action:(CGMouseButton,NSEvent.ModifierFlags,Int)->Void
    func makeNSView(context:Context)->InputView { let v=InputView();v.setAccessibilityElement(true);v.setAccessibilityRole(.button);return v }
    func updateNSView(_ view:InputView,context:Context) { view.action=action; view.acceptsInput=isEnabled; view.toolTip=help; view.setAccessibilityLabel(label); view.setAccessibilityEnabled(isEnabled) }
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
