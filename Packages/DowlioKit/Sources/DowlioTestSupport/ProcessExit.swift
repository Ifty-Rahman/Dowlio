import Foundation

extension Process {
    package func runWatchingExit() throws -> DispatchSemaphore {
        let exited = DispatchSemaphore(value: 0)
        terminationHandler = { _ in exited.signal() }
        try run()
        return exited
    }

    package func runUntilExit() throws {
        try runWatchingExit().wait()
    }
}
