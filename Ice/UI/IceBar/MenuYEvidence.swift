import AppKit

@MainActor enum MenuYEvidence {
    /// Explicit, local-only runtime evidence. Includes non-registered system
    /// windows so an unmasked high-level indicator cannot evade screenshot QA.
    static func capture(appState: AppState) {
        let args=ProcessInfo.processInfo.arguments
        guard let index=args.firstIndex(of:"--evidence-dir"),args.indices.contains(index+1),
              let screen=NSScreen.main,ScreenCapture.cachedCheckPermissions() else { return }
        let folder=URL(fileURLWithPath:args[index+1],isDirectory:true)
        try? FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let display=CGDisplayBounds(screen.displayID)
        let thickness=screen.getMenuBarHeight() ?? NSStatusBar.system.thickness
        let strip=CGRect(x:display.minX,y:display.minY,width:display.width,height:thickness)
        let windows=WindowInfo.getOnScreenWindows().filter { $0.frame.intersects(strip) && $0.layer>=24 && $0.layer<10_000 && $0.title != "Software Cursor" }
        if let image=ScreenCapture.captureWindows(windows.map(\.windowID),screenBounds:strip,option:[.boundsIgnoreFraming,.bestResolution]) {
            save(image,to:folder.appendingPathComponent("primary-menubar.png"))
        }
        let rows=windows.map { window -> [String:Any] in
            ["id":window.windowID,"name":window.title ?? "","owner":window.ownerName ?? "",
             "pid":window.ownerPID,"level":window.layer,"frame":NSStringFromRect(window.frame)]
        }
        if let data=try? JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]) {
            try? data.write(to:folder.appendingPathComponent("primary-window-stack.json"),options:.atomic)
        }
        let shelf=appState.menuBarManager.iceBarPanel
        if shelf.isVisible,let id=CGWindowID(safeWindowNumber:shelf.windowNumber),
           let image=ScreenCapture.captureWindow(id,option:[.boundsIgnoreFraming,.bestResolution]) {
            save(image,to:folder.appendingPathComponent("expanded-shelf.png"))
        }
    }
    private static func save(_ image:CGImage,to url:URL) {
        if let data=NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]) { try? data.write(to:url,options:.atomic) }
    }
}
