import Foundation
import PencilKit

// One worker owns all file replacements. If another edit arrives before its
// predecessor starts, only the newest immutable snapshot needs serialization.
final class LibraryWriter {
    private let queue = DispatchQueue(label: "goodestnotes.library-writer", qos: .userInitiated)
    private let lock = NSLock()
    private var revisions: [URL: Int] = [:]
    private var errors: [URL: String] = [:]

    func enqueue(_ file: URL, data: @escaping () throws -> Data, finished: @escaping (String?) -> Void) {
        lock.lock()
        let revision = (revisions[file] ?? 0) + 1
        revisions[file] = revision
        lock.unlock()
        queue.async { [self] in
            lock.lock()
            let superseded = revisions[file] != revision
            lock.unlock()
            var failure: String?
            if !superseded {
                do { try data().write(to: file, options: .atomic) }
                catch { failure = error.localizedDescription }
                lock.lock()
                errors[file] = failure
                lock.unlock()
            }
            let result = failure
            DispatchQueue.main.async { finished(result) }
        }
    }

    func flush() -> String? {
        queue.sync {
            lock.lock()
            defer { lock.unlock() }
            return errors.values.first
        }
    }
}
