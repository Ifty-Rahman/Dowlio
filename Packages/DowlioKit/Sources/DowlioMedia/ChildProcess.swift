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

    static func run(
        _ executable: URL, _ arguments: [String], timeout: Duration, onOutputLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> Result {
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
        let run = RunState(onOutputLine: onOutputLine)
        let reading = NSLock()
        output.fileHandleForReading.readabilityHandler = { handle in reading.withLock { run.addOutput(handle.availableData) } }
        errors.fileHandleForReading.readabilityHandler = { handle in reading.withLock { run.addErrors(handle.availableData) } }
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
        reading.withLock {
            run.addOutput(output.fileHandleForReading.readDataToEndOfFile())
            run.addErrors(errors.fileHandleForReading.readDataToEndOfFile())
        }
        run.finishLine()
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
    private var pendingLine = Data()
    private let onOutputLine: (@Sendable (String) -> Void)?

    init(onOutputLine: (@Sendable (String) -> Void)?) {
        self.onOutputLine = onOutputLine
    }

    var isCancelled: Bool { lock.withLock { cancelled } }

    func addOutput(_ data: Data) {
        guard !data.isEmpty else { return }
        let lines: [String] = lock.withLock {
            guard onOutputLine != nil else {
                output.append(data)
                return []
            }
            pendingLine.append(data)
            let parts = pendingLine.split(separator: 0x0A, omittingEmptySubsequences: false)
            pendingLine = Data(parts.last ?? Data())
            return parts.dropLast().map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .newlines) }.filter { !$0.isEmpty }
        }
        lines.forEach { onOutputLine?($0) }
    }

    func finishLine() {
        let line: String? = lock.withLock {
            defer { pendingLine = Data() }
            return pendingLine.isEmpty ? nil : String(decoding: pendingLine, as: UTF8.self)
        }
        if let line, !line.isEmpty { onOutputLine?(line) }
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
