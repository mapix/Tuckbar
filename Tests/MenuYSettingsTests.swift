import Foundation
import CoreGraphics

@main struct MenuYSettingsTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        checks += 1
        precondition(condition(), "FAIL: \(label)")
    }
    static func image(background: CGFloat, badge: Bool = false, offset: CGFloat = 0) -> CGImage {
        let context = CGContext(data: nil, width: 48, height: 24, bitsPerComponent: 8, bytesPerRow: 48*4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: background, green: background, blue: background, alpha: 1))
        context.fill(CGRect(x: 0,y: 0,width: 48,height: 24))
        context.setFillColor(CGColor(gray: 1,alpha: 1))
        context.fill(CGRect(x: 10+offset,y: 5,width: 15,height: 14))
        if badge { context.setFillColor(CGColor(red: 1,green: 0,blue: 0,alpha: 1));context.fillEllipse(in: CGRect(x: 28,y: 13,width: 8,height: 8)) }
        return context.makeImage()!
    }
    static func main() throws {
        let defaults = MenuYStoredPreferences()
        check(defaults.opacity == 0.9, "default opacity")
        check(defaults.iconSize == 24 && defaults.style == .native && defaults.sortMode == .original, "native defaults")
        for value in [-9.0, 0.0, 0.2] { check(MenuYStoredPreferences.validOpacity(value) == 0.4, "opacity lower bound") }
        for value in [1.1, 99.0] { check(MenuYStoredPreferences.validOpacity(value) == 1, "opacity upper bound") }
        check(MenuYStoredPreferences.validOpacity(.nan) == 0.9 && MenuYStoredPreferences.validOpacity(.infinity) == 0.9, "nonfinite opacity")
        check(MenuYStoredPreferences.validIconSize(23.6) == 24 && MenuYStoredPreferences.validIconSize(100) == 36, "icon size bounds")
        check(MenuYStoredPreferences.validIconSize(.nan) == 24, "nonfinite icon size")
        let rule = MenuYSortRule(pattern: "*Chrome*",priority: -1)
        let value = MenuYStoredPreferences(opacity: 0.75,iconSize: 28,style: .glass,sortMode: .recent,
                                            rules: [rule],activityEnabled: false,ignoredApps: ["app.music"],lastUsed: ["k": 123])
        let roundtrip = try JSONDecoder().decode(MenuYStoredPreferences.self,from: JSONEncoder().encode(value))
        check(roundtrip == value, "full config roundtrip")
        let partial = try JSONDecoder().decode(MenuYStoredPreferences.self,from: Data("{\"opacity\":0.75}".utf8))
        check(partial.opacity == 0.75 && partial.iconSize == 24 && partial.activityEnabled, "partial old schema")
        let future = try JSONDecoder().decode(MenuYStoredPreferences.self,from: Data("{\"opacity\":0.8,\"style\":\"future\",\"ignoredApps\":[\"x\"]}".utf8))
        check(future.opacity == 0.8 && future.style == .native && future.ignoredApps == ["x"], "unknown enum does not reset unrelated values")
        let duplicates = MenuYStoredPreferences.validRules([rule,rule])
        check(duplicates.count == 1, "duplicate rule identity")
        check(MenuYStoredPreferences.validHistory(["bad": .nan,"negative": -1,"valid": 5]) == ["valid":5], "history validity")

        let patterns: [(String,String,String,Bool)] = [
            ("*Chrome*","Google Chrome","com.google.chrome",true),
            ("com.example.?pp","Other","com.example.app",true),
            ("  *Chrome*  ","Google Chrome","none",true),
            ("*微信*","微信","none",true),
            ("a.b","axb","none",false),
            ("[app]","[app]","none",true),
            ("","Chrome","none",false),
            ("APP","app","none",true),
            ("Chrome","Google Chrome","none",false)
        ]
        for (p,n,i,expected) in patterns { check(MenuYOrdering.matches(p,name:n,identifier:i) == expected, "glob \(p)") }
        let records = [
            MenuYOrderValue(key:"b",name:"Beta",identifier:"app.beta",originalIndex:0,hasActivity:false,lastUsed:1),
            MenuYOrderValue(key:"a",name:"Alpha",identifier:"app.alpha",originalIndex:1,hasActivity:true,lastUsed:2),
            MenuYOrderValue(key:"c",name:"Alpha",identifier:"app.alpha2",originalIndex:2,hasActivity:false,lastUsed:0)
        ]
        check(MenuYOrdering.ordered(records,mode:.original,rules:[]).map(\.key) == ["b","a","c"], "original stable order")
        check(MenuYOrdering.ordered(records,mode:.alphabetical,rules:[]).map(\.key) == ["a","c","b"], "alphabetic stable tie")
        check(MenuYOrdering.ordered(records,mode:.activity,rules:[]).map(\.key) == ["a","b","c"], "activity stable tie")
        check(MenuYOrdering.ordered(records,mode:.recent,rules:[]).map(\.key) == ["a","b","c"], "recent stable tie")
        check(MenuYOrdering.ordered(records,mode:.alphabetical,rules:[MenuYSortRule(pattern:"app.beta",priority:-2)]).map(\.key) == ["b","a","c"], "rules before base sort")
        check(MenuYOrdering.priorities(for:records,rules:[MenuYSortRule(pattern:"*",priority:8),MenuYSortRule(pattern:"app.alpha",priority:-5)])["a"] == -5, "strongest matching rule")

        let hints: [(String,Int?)] = [
            ("Fixture 32, 3 unread notifications",3), ("Battery 32%",nil), ("未读：12",12),
            ("有3条未读消息",3), ("3 NEW MESSAGES",3), ("Unread messages: 4",4),
            ("0 unread notifications",0), ("12 notifications",nil), ("13 unreadable files",nil),
            ("2 unread and 4 unread",nil), ("-3 unread",nil), ("1.5 unread",nil), ("1e4 unread",nil),
            ("unread: -3",nil), ("999999 unread",nil), ("32 unread notifications, app version 17",32)
        ]
        for (text,count) in hints { check(MenuYUnreadHint.count(text) == count, "hint \(text)") }
        let hosted = CGRect(x:-5497,y:0,width:44,height:33)
        let matching = CGRect(x:-5496,y:4.5,width:42,height:24)
        let other = CGRect(x:-5455,y:4.5,width:42,height:24)
        check(MenuYHintGeometry.bestIndex(window:hosted,children:[matching,other]) == 0, "offscreen identity")
        check(MenuYHintGeometry.bestIndex(window:hosted,children:[other,matching]) == 1, "reordered AX child identity")
        check(MenuYHintGeometry.bestIndex(window:hosted,children:[matching,matching]) == nil, "ambiguous identity rejected")
        check(MenuYHintGeometry.bestIndex(window:hosted,children:[.zero,other]) == nil, "zero frame and unrelated item")
        let wide=CGRect(x:100,y:0,width:166,height:33), icon=CGRect(x:120,y:4.5,width:24,height:24)
        check(MenuYHintGeometry.bestIndex(window:wide,children:[icon]) == 0, "wide music item icon frame")
        check(MenuYHintGeometry.bestIndex(window:wide,children:[icon,CGRect(x:180,y:4.5,width:24,height:24)]) == nil, "ambiguous wide item")
        let plain=MenuYVisualFingerprint.digest(image(background:0))
        check(plain == MenuYVisualFingerprint.digest(image(background:0.2)), "background does not count as glyph change")
        check(plain != MenuYVisualFingerprint.digest(image(background:0,badge:true)), "native badge pixels detected")
        check(plain != MenuYVisualFingerprint.digest(image(background:0,offset:3)), "animation is visual activity")
        check(MenuYUnreadHint.count("animation changed") == nil, "animation does not become unread")
        var history = MenuYHintHistory()
        history.apply(["a":.confirmed(3),"b":.confirmed(8)],activeKeys:["a","b"],now:100)
        check(history.values == ["a":3,"b":8] && history.stale.isEmpty, "confirmed initial unread state")
        history.apply(["a":.confirmed(2)],activeKeys:["a","b"],now:200)
        check(history.values["b"] == 8 && history.confirmedAt["b"] == 100 && history.stale.contains("b"), "budget cutoff retains previous value and time")
        check(history.values["a"] == 2 && history.confirmedAt["a"] == 200 && !history.stale.contains("a"), "visited target refreshes")
        history.apply(["a":.unavailable],activeKeys:["a","b"],now:250)
        check(history.values["a"] == 2 && history.confirmedAt["a"] == 200 && history.stale.contains("a"), "AX failure is not zero")
        history.apply([:],activeKeys:["a","b"],now:275)
        check(history.values == ["a":2,"b":8], "entire incomplete scan preserves confirmations")
        history.apply(["a":.confirmed(0),"b":.absent],activeKeys:["a","b"],now:300)
        check(history.values["a"] == 0 && history.confirmedAt["a"] == 300 && !history.stale.contains("a"), "explicit current zero clears stale")
        check(history.values["b"] == nil && history.confirmedAt["b"] == nil && !history.stale.contains("b"), "completed no-hint read removes old hint")
        history.apply(["a":.confirmed(9)],activeKeys:[],now:400)
        check(history.values.isEmpty && history.confirmedAt.isEmpty && history.stale.isEmpty, "exited target cannot return through late result")
        check(MenuYHintObservation.completed(text:"2 unread and 4 unread") == .unavailable, "ambiguous unread is unknown")
        check(MenuYHintObservation.completed(text:"Battery 32%") == .absent, "completed ordinary state has no hint")
        print("PASS: \(checks) preferences/order/indicator/geometry checks")
    }
}
