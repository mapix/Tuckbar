#if MENUY_VERIFY
import AppKit
import SwiftUI

/// Test-only native control surface. It drives the real pointer/hover pipeline,
/// never substitutes a screenshot or invokes a fake menu callback.
@MainActor final class MenuYDebugHarness: ObservableObject {
    static let shared=MenuYDebugHarness()
    static var holdShelf=false
    @Published var status="就绪"
    private weak var appState:AppState?
    private var window:NSWindow?
    func setup(appState:AppState) {
        self.appState=appState
        guard ProcessInfo.processInfo.arguments.contains("--verification-panel") else { return }
        let window=NSWindow(contentRect:CGRect(x:80,y:120,width:500,height:270),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.title="MacMenuY · 原生验证";window.isReleasedWhenClosed=false
        window.contentView=NSHostingView(rootView:DebugView().environmentObject(self))
        self.window=window;window.makeKeyAndOrderFront(nil)
    }
    func preview() { Self.holdShelf=true;appState?.menuBarManager.section(withName:.visible)?.controlItem.openDrawer() }
    func runHoverScenario() {
        guard let appState,let screen=NSScreen.main,
              let id=appState.menuBarManager.section(withName:.visible)?.controlItem.windowID,
              let entry=Bridging.getWindowFrame(for:id) else { status="缺少真实入口";return }
        Self.holdShelf=false
        status="验证真实鼠标悬浮…"
        Task { @MainActor in
            let original=CGEvent(source:nil)?.location
            let display=CGDisplayBounds(screen.displayID)
            let outside=CGPoint(x:display.midX,y:display.minY+display.height*0.55)
            move(outside);try? await Task.sleep(for:.milliseconds(350))
            let before=appState.menuBarManager.iceBarPanel.isVisible
            move(CGPoint(x:entry.midX,y:entry.midY))
            let deadline=ProcessInfo.processInfo.systemUptime+3
            while !appState.menuBarManager.iceBarPanel.isVisible && ProcessInfo.processInfo.systemUptime<deadline {
                try? await Task.sleep(for:.milliseconds(30))
            }
            let panel=appState.menuBarManager.iceBarPanel
            let entered=panel.isVisible
            let rect=panel.frame
            let inside=CGPoint(x:screen.frame.minX+min(480,screen.frame.width/2),y:screen.frame.maxY-(rect.maxY-16))
            move(inside);try? await Task.sleep(for:.milliseconds(350))
            let stayed=panel.isVisible
            MenuYEvidence.capture(appState:appState)
            move(outside);try? await Task.sleep(for:.milliseconds(450))
            let left=panel.isVisible
            let report:[String:Any]=["before":before,"afterEntry":entered,"insideShelf":stayed,"afterLeave":left,
                                   "frame":NSStringFromRect(rect),"opacity":panel.alphaValue,
                                   "passed": !before && entered && stayed && !left]
            write(report,name:"hover-runtime.json")
            status=report["passed"] as? Bool == true ? "真实悬浮往返通过" : "悬浮验收失败，见记录"
            if let original { move(original) }
        }
    }
    func nativeFixtureMenu(_ button:CGMouseButton, option:Bool=false) {
        guard let appState,let item=appState.itemManager.itemCache.allItems.first(where:{$0.title == "Fixture-8"}) else { status="缺少F08";return }
        status="发送F08原生菜单 \(button.rawValue)…"
        Task { @MainActor in
            await appState.shelfManager.activate(item,button:button,modifiers:option ? [.option] : [],clickCount:1,closeShelf:true)
            status=appState.shelfManager.message ?? "F08请求已发送；以原客户端回调验收"
        }
    }
    func accessibilityCalibration() {
        guard let appState,let item=appState.itemManager.itemCache.allItems.first(where:{$0.title == "Fixture-8"}),
              let pid=item.sourcePID else { status="缺少F08源进程";return }
        var raw:CFTypeRef?
        let app=AXUIElementCreateApplication(pid)
        guard AXUIElementCopyAttributeValue(app,"AXExtrasMenuBar" as CFString,&raw) == .success,let raw else { return }
        let bar=raw as! AXUIElement
        var list:CFTypeRef?
        AXUIElementCopyAttributeValue(bar,"AXChildren" as CFString,&list)
        let children=list as? [AXUIElement] ?? []
        for child in children {
            var help:CFTypeRef?
            AXUIElementCopyAttributeValue(child,"AXDescription" as CFString,&help)
            if (help as? String ?? "").contains("Fixture 8") {
                let result=AXUIElementPerformAction(child,kAXPressAction as CFString)
                status="原生AX校准：\(result.rawValue)；检查fixture回调"
                return
            }
        }
        status="未找到校准AX元素"
    }

    private func move(_ point:CGPoint) {
        CGEvent(mouseEventSource:nil,mouseType:.mouseMoved,mouseCursorPosition:point,mouseButton:.left)?.post(tap:.cghidEventTap)
    }
    private func write(_ report:[String:Any],name:String) {
        let args=ProcessInfo.processInfo.arguments
        guard let i=args.firstIndex(of:"--evidence-dir"),args.indices.contains(i+1),
              let data=try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) else { return }
        let folder=URL(fileURLWithPath:args[i+1]);try? FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        try? data.write(to:folder.appendingPathComponent(name),options:.atomic)
    }
    private struct DebugView:View {
        @EnvironmentObject var harness:MenuYDebugHarness
        var body:some View {
            VStack(alignment:.leading,spacing:16) {
                Text("测试真实原生入口与鼠标，不替换运行逻辑").font(.headline)
                HStack {
                    Button("真实悬浮往返验收") { harness.runHoverScenario() }
                    Button("固定展开预览（调试）") { harness.preview() }
                }
                HStack {
                    Button("F08 左键原菜单") { harness.nativeFixtureMenu(.left) }
                    Button("F08 右键原菜单") { harness.nativeFixtureMenu(.right) }
                    Button("F08 Option 原菜单") { harness.nativeFixtureMenu(.left,option:true) }
                }
                Button("原客户端 AX 校准") { harness.accessibilityCalibration() }
                Text(harness.status).font(.caption)
            }.padding(22).frame(width:500,height:270)
        }
    }
}
#endif
