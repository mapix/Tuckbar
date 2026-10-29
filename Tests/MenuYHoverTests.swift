import Foundation
import CoreGraphics

@main struct MenuYHoverTests {
    static func main() {
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            checks += 1
            precondition(value, message)
        }
        func event(_ state: inout MenuYHoverPolicy, entry: Bool, shelf: Bool = false,
                   visible: Bool = false, opening: Bool = false, busy: Bool = false,
                   at time: Double, keep: Bool = false) -> MenuYHoverPolicy.Action {
            state.update(entryInside: entry, shelfInside: shelf, visible: visible,
                         opening: opening, busy: busy, now: time, keepOpen: keep)
        }

        var state = MenuYHoverPolicy()
        check(event(&state, entry:false, at:0) == .none,"no activation-only open")
        check(event(&state, entry:false, at:100) == .none,"idle timer never opens")
        check(event(&state, entry:true, at:101) == .none,"entry starts intent")
        check(state.showAt == 101.15,"150ms intent")
        check(event(&state, entry:true, at:101.14) == .none,"not early")
        check(event(&state, entry:true, at:101.15) == .show,"deadline opens once")
        check(event(&state, entry:true, opening:true, at:101.16) == .none,"opening is not duplicated")
        check(event(&state, entry:false, shelf:true, visible:true, at:101.2) == .none,"entry-to-shelf transfer holds")
        check(state.hideAt == nil,"no hide during transfer")
        check(event(&state, entry:false, visible:true, at:102) == .none,"leave starts grace")
        check(state.hideAt == 102.2,"200ms leave grace")
        check(event(&state, entry:false, shelf:true, visible:true, at:102.1) == .none,"return during grace")
        check(state.hideAt == nil,"return cancels hide")
        check(event(&state, entry:false, visible:true, at:103) == .none,"leave restarts deadline")
        check(event(&state, entry:false, visible:true, at:103.2) == .hide,"leave closes")
        check(event(&state, entry:false, at:104) == .none,"closed remains closed")

        var closed = MenuYHoverPolicy()
        check(event(&closed,entry:true,at:0) == .none,"new edge arms")
        check(event(&closed,entry:true,at:0.15) == .show,"opens")
        _ = event(&closed,entry:true,visible:true,at:0.2)
        check(event(&closed,entry:true,visible:false,at:1) == .none,"explicit close on entry")
        check(event(&closed,entry:true,at:5) == .none,"stale pointer cannot reopen")
        check(closed.showAt == nil,"no stale intent")
        _ = event(&closed,entry:false,at:6)
        _ = event(&closed,entry:true,at:7)
        check(event(&closed,entry:true,at:7.15) == .show,"fresh re-entry opens")

        var cancelled = MenuYHoverPolicy()
        _ = event(&cancelled,entry:true,at:0)
        _ = event(&cancelled,entry:false,at:0.1)
        check(event(&cancelled,entry:false,at:0.3) == .none,"brief accidental hover cancelled")
        _ = event(&cancelled,entry:true,at:1)
        _ = event(&cancelled,entry:true,opening:true,at:1.15)
        _ = event(&cancelled,entry:false,opening:true,at:1.2)
        check(event(&cancelled,entry:false,opening:true,at:1.4) == .hide,"leaving cancels asynchronous opening")

        var busy = MenuYHoverPolicy()
        _ = event(&busy,entry:true,busy:true,at:0)
        check(event(&busy,entry:true,busy:true,at:0.2) == .none,"original-menu operation not interrupted")
        check(event(&busy,entry:true,busy:false,at:0.31) == .show,"intent resumes after busy")
        _ = event(&busy,entry:false,visible:true,busy:true,at:1)
        check(event(&busy,entry:false,visible:true,busy:true,at:1.2) == .none,"busy hide waits")
        check(event(&busy,entry:false,visible:true,busy:false,at:1.31) == .hide,"settled leave closes")

        var debug = MenuYHoverPolicy()
        check(event(&debug,entry:false,visible:true,at:0,keep:true) == .none,"debug keep")
        check(event(&debug,entry:false,visible:true,at:99,keep:true) == .none,"debug stable without cursor")
        check(debug.hideAt == nil,"debug has no hide timer")
        _ = event(&debug,entry:false,visible:true,at:100)
        check(event(&debug,entry:false,visible:true,at:100.2) == .hide,"normal behavior has no sticky exception")

        var initial = MenuYHoverPolicy()
        initial.primeEntry(true)
        check(event(&initial,entry:true,at:10) == .none,"startup under pointer does not open")
        check(initial.showAt == nil,"startup prime no timer")
        _ = event(&initial,entry:false,at:11)
        _ = event(&initial,entry:true,at:12)
        check(event(&initial,entry:true,at:12.15) == .show,"primed entry opens after new edge")
        check(event(&initial,entry:true,at:.nan) == .none,"invalid timestamp ignored")

        let entry = CGRect(x:1500,y:1084,width:33,height:33)
        let shelf = CGRect(x:0,y:1017,width:1728,height:67)
        check(MenuYHoverPolicy.contains(CGPoint(x:1510,y:1100),in:[entry]),"actual entry")
        check(!MenuYHoverPolicy.contains(CGPoint(x:1000,y:1100),in:[entry]),"empty status area not entry")
        check(MenuYHoverPolicy.contains(CGPoint(x:300,y:1050),in:[shelf]),"full-width shelf region")
        check(!MenuYHoverPolicy.contains(CGPoint(x:300,y:1000),in:[shelf]),"working app outside shelf")
        check(!MenuYHoverPolicy.contains(nil,in:[entry]),"unknown point")
        check(!MenuYHoverPolicy.contains(CGPoint(x:CGFloat.nan,y:0),in:[entry]),"invalid point")
        check(MenuYHoverPolicy.appKitPoint(quartz:CGPoint(x:1510,y:16.5),primaryTop:1117) == CGPoint(x:1510,y:1100.5),"Quartz/AppKit primary")
        check(MenuYHoverPolicy.appKitPoint(quartz:CGPoint(x:-1700,y:-200),primaryTop:1117) == CGPoint(x:-1700,y:1317),"negative display origins")
        print("PASS: \(checks) hover intent/leave/transfer/cancellation/busy/debug/geometry checks")
    }
}
