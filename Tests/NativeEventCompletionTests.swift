import Foundation
@main struct NativeEventCompletionTests {
    static func main() async {
        let cancelled=NativeEventCompletion()
        cancelled.finish(.failure(CancellationError()))
        do {
            try await withCheckedThrowingContinuation { continuation in cancelled.install(continuation) }
            preconditionFailure("A cancelled barrier must not become successful")
        } catch { precondition(error is CancellationError) }
        let completed=NativeEventCompletion()
        do {
            try await withCheckedThrowingContinuation { continuation in
                completed.install(continuation)
                completed.finish(.success(()))
                completed.finish(.failure(CancellationError()))
                completed.finish(.success(()))
            }
        } catch { preconditionFailure("Completion must resume only once") }
        print("PASS: barrier cancellation before install and exactly-once completion")
    }
}
