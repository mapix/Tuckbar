// MacMenuY contributors — GPL-3.0; see LICENSE and NOTICE.md.
import Foundation
import CoreGraphics
@main struct JournalTests {
    static func main() {
        let name="MacMenuY.Journal.Test."+UUID().uuidString
        let defaults=UserDefaults(suiteName:name)!
        defer { defaults.removePersistentDomain(forName:name) }
        let store=NativeRestorationJournalStore(defaults:defaults)
        precondition(store.load().isEmpty)
        let identity=NativeRestorationIdentity(namespace:"app.fixture",title:"Fixture-8",windowID:82)
        let target=NativeRestorationIdentity(namespace:"app.fixture",title:"Fixture-7",windowID:71)
        let rect=NativeRestorationRect(CGRect(x:-5000,y:0,width:44,height:33))
        let entry=NativeRestorationJournalEntry(id:UUID(),item:identity,target:target,side:.right,
            section:"hidden",sourceBundleID:"app.fixture",menuBand:NativeRestorationRect(CGRect(x:0,y:0,width:1728,height:33)),
            originalFrame:rect,originalOrder:[identity,target],originalOnScreen:false,recordedAt:1234)
        precondition(entry.valid && identity.isStable)
        precondition(store.save([entry]))
        let restored=NativeRestorationJournalStore(defaults:defaults).load()
        precondition(restored == [entry] && restored[0].originalFrame?.rect.minX == -5000)
        var invalid=entry;invalid.menuBand.width = .nan
        precondition(!store.save([invalid]))
        precondition(NativeRestorationJournalStore(defaults:defaults).load() == [entry])
        precondition(store.save([]) && store.load().isEmpty)
        let damaged=Data("invalid evidence".utf8)
        defaults.set(damaged,forKey:NativeRestorationJournalStore.key)
        let bad=NativeRestorationJournalStore(defaults:defaults)
        precondition(bad.load().isEmpty && bad.error != nil)
        precondition(defaults.data(forKey:NativeRestorationJournalStore.key) == damaged)
        precondition(defaults.data(forKey:NativeRestorationJournalStore.key+".invalid") == damaged)
        precondition(!NativeRestorationIdentity(namespace:"unresolved.window.82",title:"Item-0",windowID:82).isStable)
        let lifecycle=NativeInteractionLifecycle()
        let ordinary=lifecycle.token()!
        let recovery=lifecycle.beginRecovery(budget:1)!
        precondition(!lifecycle.accepts(ordinary) && lifecycle.token() == nil && lifecycle.accepts(recovery))
        lifecycle.finishRecovery()
        precondition(!lifecycle.accepts(recovery) && lifecycle.token() != nil)
        let shutdown=lifecycle.beginTermination(budget:1)
        precondition(lifecycle.token() == nil && lifecycle.accepts(shutdown))
        lifecycle.finishTermination()
        let retry=lifecycle.renewRestorationBudget(1)
        precondition(lifecycle.token() == nil && !lifecycle.accepts(shutdown) && lifecycle.accepts(retry))
        print("PASS: persistent restoration journal, corrupt/invalid evidence preservation and one-way bounded recovery/retry lifecycle")
    }
}
