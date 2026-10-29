import Foundation
import CoreGraphics
@main struct NativeInteractionPolicyTests {
    static func main() {
        precondition(!NativeInteractionPolicy.hasTransientModifiers(1 << 16), "Caps Lock must not block an automatic reveal")
        precondition(NativeInteractionPolicy.hasTransientModifiers(1 << 19), "Option is a transient physical key")
        precondition(!NativeInteractionPolicy.hasTransientModifiers(0))
        let display = CGRect(x:0,y:0,width:1728,height:1117)
        precondition(NativeInteractionPolicy.isClickable(frame:CGRect(x:1592,y:0,width:138,height:33),isOnScreen:true,display:display,minimumX:980))
        precondition(!NativeInteractionPolicy.isClickable(frame:CGRect(x:800,y:0,width:30,height:33),isOnScreen:true,display:display,minimumX:980), "A geometrically onscreen icon under the notch is not clickable")
        precondition(!NativeInteractionPolicy.isClickable(frame:CGRect(x:-4000,y:0,width:30,height:33),isOnScreen:false,display:display,minimumX:980))
        precondition(NativeInteractionPolicy.isClickCenterSafe(frame:CGRect(x:950,y:0,width:100,height:33),isOnScreen:true,display:display,minimumX:980),"Temporary reveal accepts a safe visible center without strict left-edge/adjacency")
        precondition(!NativeInteractionPolicy.isClickCenterSafe(frame:CGRect(x:850,y:0,width:100,height:33),isOnScreen:true,display:display,minimumX:980),"A center under the notch remains invalid")
        precondition(!NativeInteractionPolicy.isClickCenterSafe(frame:CGRect(x:-4000,y:0,width:100,height:33),isOnScreen:false,display:display,minimumX:980))
        let menuBand = CGRect(x:0,y:0,width:1728,height:33)
        precondition(NativeInteractionPolicy.retainsTemporaryItem(layer:101,frame:CGRect(x:1000,y:33,width:200,height:300),popupLayer:101,menuBand:menuBand))
        precondition(NativeInteractionPolicy.retainsTemporaryItem(layer:1000,frame:CGRect(x:1200,y:35,width:400,height:600),popupLayer:101,menuBand:menuBand), "An inactive accessory popover must remain visible")
        precondition(!NativeInteractionPolicy.retainsTemporaryItem(layer:0,frame:CGRect(x:200,y:120,width:800,height:600),popupLayer:101,menuBand:menuBand), "A normal app window must not leave its icon permanently revealed")
        precondition(!NativeInteractionPolicy.retainsTemporaryItem(layer:1001,frame:CGRect(x:0,y:0,width:1,height:1),popupLayer:101,menuBand:menuBand))
        let main = URL(fileURLWithPath:"/Applications/Example.app")
        let helper = URL(fileURLWithPath:"/Applications/Example.app/Contents/Frameworks/Example Helper.app")
        precondition(NativeInteractionPolicy.sameApplicationFamily(main,helper))
        precondition(!NativeInteractionPolicy.sameApplicationFamily(main,URL(fileURLWithPath:"/Applications/Example.app.fake/Other.app")))
        precondition(!NativeInteractionPolicy.sameApplicationFamily(main,URL(fileURLWithPath:"/Applications/Other.app")))
        print("PASS: native reveal policy (Caps Lock, notch bounds, accessory popovers, app-window return, helper family)")
    }
}
