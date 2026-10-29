import Foundation

/// Shared with event-tap callbacks, which may run outside the main actor.
/// An old callback must never inject a new press after termination starts.
final class NativeInteractionLifecycle: @unchecked Sendable {
    struct Token: Sendable { let generation: UInt64; let restoration: Bool }
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var stopping = false
    private var recovering = false
    private var deadline = TimeInterval.infinity
    private var pressDownTag: Int64?
    private var pressUpTags = Set<Int64>()
    private var sessionDown = false, ownerDown = false
    private var sessionUp = false, ownerUp = false
    struct ReleasePlan { let session: Bool; let owner: Bool; var any: Bool { session || owner } }

    var isStopping: Bool { lock.lock(); defer { lock.unlock() }; return stopping }
    var remainingTime: TimeInterval { lock.lock(); defer { lock.unlock() }; return max(0,deadline-ProcessInfo.processInfo.systemUptime) }
    func token(restoration: Bool = false) -> Token? {
        lock.lock(); defer { lock.unlock() }
        guard (!stopping || restoration), (!recovering || restoration), !restoration || ProcessInfo.processInfo.systemUptime < deadline else { return nil }
        return Token(generation:generation,restoration:restoration)
    }
    @discardableResult func beginTermination(budget: TimeInterval) -> Token {
        lock.lock(); defer { lock.unlock() }
        if !stopping { generation &+= 1; stopping=true; recovering=false; deadline=ProcessInfo.processInfo.systemUptime+max(0,budget) }
        return Token(generation:generation,restoration:true)
    }
    func accepts(_ token: Token) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return token.generation == generation && (!stopping || token.restoration) && (!recovering || token.restoration) && (!token.restoration || ProcessInfo.processInfo.systemUptime < deadline)
    }
    func beginRecovery(budget:TimeInterval) -> Token? {
        lock.lock();defer { lock.unlock() }
        guard !stopping else { return nil }
        generation &+= 1;recovering=true;deadline=ProcessInfo.processInfo.systemUptime+max(0,budget)
        return Token(generation:generation,restoration:true)
    }
    func finishRecovery() {
        lock.lock();defer { lock.unlock() }
        guard !stopping else { return }
        generation &+= 1;recovering=false;deadline = .infinity
    }
    /// Renew only restoration work after a completed failed shutdown attempt.
    /// Ordinary tokens remain forbidden; old callbacks stay invalidated.
    func renewRestorationBudget(_ budget: TimeInterval) -> Token {
        lock.lock();defer { lock.unlock() }
        generation &+= 1;stopping=true
        deadline=ProcessInfo.processInfo.systemUptime+max(0,budget)
        return Token(generation:generation,restoration:true)
    }
    func finishTermination() { lock.lock(); generation &+= 1; deadline = 0; lock.unlock() }
    func armPress(downTag: Int64, upTags: [Int64]) {
        lock.lock(); defer { lock.unlock() }
        pressDownTag=downTag;pressUpTags=Set(upTags);sessionDown=false;ownerDown=false;sessionUp=false;ownerUp=false
    }
    func includeUpTag(_ tag: Int64) { lock.lock();pressUpTags.insert(tag);lock.unlock() }
    func notePosted(tag: Int64, isDown: Bool, isUp: Bool, toOwner: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        if isDown && pressDownTag == tag { if toOwner { ownerDown=true } else { sessionDown=true } }
        if isUp && pressUpTags.contains(tag) { if toOwner { ownerUp=true } else { sessionUp=true } }
    }
    func takeReleasePlan() -> ReleasePlan {
        lock.lock(); defer { lock.unlock() }
        let plan=ReleasePlan(session:sessionDown && !sessionUp,owner:ownerDown && !ownerUp)
        pressDownTag=nil;pressUpTags.removeAll();sessionDown=false;ownerDown=false;sessionUp=false;ownerUp=false
        return plan
    }
    /// True only for this app's posted down without its corresponding release.
    func consumePendingPress() -> Bool { takeReleasePlan().any }
    func disarmPress() { _ = consumePendingPress() }
}
