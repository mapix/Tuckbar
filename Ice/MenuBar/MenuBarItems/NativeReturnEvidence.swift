import Foundation
import CoreGraphics

/// Evidence about this item's original slot, not merely whether it is hidden.
enum NativeReturnEvidence {
    struct Assessment {
        let sameMenuBand: Bool
        let frameMatches: Bool
        let orderMatches: Bool
        let hasSurvivingNeighbor: Bool
        var confirmsOriginalPosition: Bool {
            sameMenuBand && (hasSurvivingNeighbor ? orderMatches : frameMatches)
        }
    }
    static func assess(windowID: CGWindowID, originalFrame: CGRect?, originalOrder: [CGWindowID],
                       currentFrame: CGRect?, currentOrder: [CGWindowID]) -> Assessment {
        guard let originalFrame,let currentFrame,originalFrame.width>0,currentFrame.width>0 else {
            return Assessment(sameMenuBand:false,frameMatches:false,orderMatches:false,hasSurvivingNeighbor:false)
        }
        let sameBand=abs(originalFrame.minY-currentFrame.minY)<=0.5
        let sameFrame=abs(originalFrame.minX-currentFrame.minX)<=0.5 && sameBand &&
            abs(originalFrame.width-currentFrame.width)<=0.5 && abs(originalFrame.height-currentFrame.height)<=0.5
        let live=Set(currentOrder), old=unique(originalOrder), survivors=old.filter { live.contains($0) }
        let oldSet=Set(old), now=unique(currentOrder).filter { oldSet.contains($0) }
        guard let oldIndex=survivors.firstIndex(of:windowID),let newIndex=now.firstIndex(of:windowID) else {
            return Assessment(sameMenuBand:sameBand,frameMatches:sameFrame,orderMatches:false,hasSurvivingNeighbor:false)
        }
        let oldLeft=oldIndex>0 ? survivors[oldIndex-1] : nil
        let oldRight=oldIndex+1<survivors.count ? survivors[oldIndex+1] : nil
        let newLeft=newIndex>0 ? now[newIndex-1] : nil
        let newRight=newIndex+1<now.count ? now[newIndex+1] : nil
        return Assessment(sameMenuBand:sameBand,frameMatches:sameFrame,
            orderMatches:oldLeft == newLeft && oldRight == newRight,
            hasSurvivingNeighbor:oldLeft != nil || oldRight != nil)
    }
    static func unique(_ ids: [CGWindowID]) -> [CGWindowID] {
        var seen=Set<CGWindowID>();return ids.filter { seen.insert($0).inserted }
    }
}
