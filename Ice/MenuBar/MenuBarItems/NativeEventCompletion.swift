import Foundation

/// One completion shared by an event tap, its timeout and task cancellation.
final class NativeEventCompletion: @unchecked Sendable {
    private let lock=NSLock()
    private var continuation: CheckedContinuation<Void,Error>?
    private var result: Result<Void,Error>?
    var isFinished: Bool { lock.lock();defer{lock.unlock()};return result != nil }
    func install(_ continuation: CheckedContinuation<Void,Error>) {
        lock.lock(); let finished=result
        if finished == nil { self.continuation=continuation }
        lock.unlock()
        if let finished { continuation.resume(with:finished) }
    }
    func finish(_ result: Result<Void,Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock();return }
        self.result=result;let continuation=self.continuation;self.continuation=nil
        lock.unlock();continuation?.resume(with:result)
    }
}
