import Foundation

struct ChildProcess {
    struct Result: Sendable {
        var status: Int32
        var output: Data
        var errorOutput: Data
        var timedOut: Bool

        var errorText: String { String(decoding: errorOutput, as: UTF8.self) }
    }

    struct CouldNotStart: Error, Equatable {
        var reason: String
    }

    static var environment: [String: String] {
        ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
    }

    static func run(_ executable: URL, _ arguments: [String], timeout: Duration) async throws -> Result {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        let run = RunState()
        output.fileHandleForReading.readabilityHandler = { handle in run.addOutput(handle.availableData) }
        errors.fileHandleForReading.readabilityHandler = { handle in run.addErrors(handle.availableData) }
        let watchdog = Task.detached {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            run.markTimedOut()
            stop(process)
        }
        defer { watchdog.cancel() }

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { finished in continuation.resume(returning: finished.terminationStatus) }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: CouldNotStart(reason: error.localizedDescription))
                    return
                }
                if run.isCancelled { stop(process) }
            }
        } onCancel: {
            run.markCancelled()
            stop(process)
        }
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        run.addOutput(output.fileHandleForReading.readDataToEndOfFile())
        run.addErrors(errors.fileHandleForReading.readDataToEndOfFile())
        try Task.checkCancellation()
        return run.result(status: status)
    }

    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}

private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private var output = Data()
    private var errors = Data()
    private var timedOut = false
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    func addOutput(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.withLock { output.append(data) }
    }

    func addErrors(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.withLock { errors.append(data) }
    }

    func markTimedOut() {
        lock.withLock { timedOut = true }
    }

    func markCancelled() {
        lock.withLock { cancelled = true }
    }

    func result(status: Int32) -> ChildProcess.Result {
        lock.withLock { ChildProcess.Result(status: status, output: output, errorOutput: errors, timedOut: timedOut) }
    }
}
