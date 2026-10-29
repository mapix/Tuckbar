import Foundation
import CoreGraphics
@main struct NativeReturnEvidenceTests {
    static func main() {
        let original=CGRect(x:-4156,y:0,width:62,height:33)
        let order:[CGWindowID]=[1,8,2,3]
        func proof(_ frame:CGRect,_ current:[CGWindowID],_ originals:[CGWindowID]=order)->NativeReturnEvidence.Assessment {
            NativeReturnEvidence.assess(windowID:8,originalFrame:original,originalOrder:originals,currentFrame:frame,currentOrder:current)
        }
        precondition(proof(original,order).confirmsOriginalPosition,"A registered move that did not alter frame/order needs no return")
        precondition(!proof(CGRect(x:-3000,y:0,width:62,height:33),[1,2,8,3]).confirmsOriginalPosition,"Hidden alone is not proof of original position")
        precondition(!proof(original,[1,2,8,3]).confirmsOriginalPosition,"Even an equal rect must not hide a changed live-neighbor order")
        precondition(proof(CGRect(x:-4000,y:0,width:80,height:33),order).confirmsOriginalPosition,"Native global reflow preserves original slot")
        precondition(!proof(CGRect(x:1096,y:0,width:62,height:33),[1,2,3,8]).confirmsOriginalPosition,"A real reveal requires return")
        precondition(proof(CGRect(x:-4000,y:0,width:62,height:33),[1,8,3]).confirmsOriginalPosition,"Surviving original neighbors define the return slot")
        precondition(proof(original,[1,99,8,98,2,3]).confirmsOriginalPosition,"New app items do not renumber original relative order")
        precondition(!proof(CGRect(x:-4156,y:1000,width:62,height:33),order).confirmsOriginalPosition,"A different display/menu band is not original")
        precondition(proof(original,[8],[8]).confirmsOriginalPosition)
        precondition(!proof(CGRect(x:-3000,y:0,width:62,height:33),[8],[8]).confirmsOriginalPosition,"No surviving neighbor requires exact original rect")
        precondition(!NativeReturnEvidence.assess(windowID:8,originalFrame:nil,originalOrder:order,currentFrame:original,currentOrder:order).confirmsOriginalPosition)
        print("PASS: original-frame/order return evidence, unaltered failed reveal, real movement, global reflow, removed/new neighbors")
    }
}
