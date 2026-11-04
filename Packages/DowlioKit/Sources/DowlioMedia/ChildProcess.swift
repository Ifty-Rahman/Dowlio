import Foundation

struct ChildProcess {
    struct Result: Sendable {
        var status: Int32
        var output: Data
        var errorOutput: Data
        var timedOut: Bool

        var errorText: String { String(decoding: errorOutput, as: UTF8.self) }
    }

    enum Failure: Error, Equatable {
        case couldNotStart(String)
    }

    static var environment: [String: String] {
        ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
    }

    static func run(
        _ executable: URL,
        _ arguments: [String],
        timeout: Duration,
        onOutputLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> Result {
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
        let collected = Collected(onOutputLine: onOutputLine)
        output.fileHandleForReading.readabilityHandler = { handle in collected.addOutput(handle.availableData) }
        errors.fileHandleForReading.readabilityHandler = { handle in collected.addErrors(handle.availableData) }

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { finished in continuation.resume(returning: finished.terminationStatus) }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: Failure.couldNotStart(error.localizedDescription))
                    return
                }
                let watchdog = Task.detached {
                    try? await Task.sleep(for: timeout)
                    guard process.isRunning else { return }
                    collected.markTimedOut()
                    stop(process)
                }
                collected.keep(watchdog)
            }
        } onCancel: {
            stop(process)
        }
        collected.cancelWatchdog()
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        collected.addOutput(output.fileHandleForReading.readDataToEndOfFile())
        collected.addErrors(errors.fileHandleForReading.readDataToEndOfFile())
        collected.flushLine()
        try Task.checkCancellation()
        return collected.result(status: status)
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

private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var output = Data()
    private var errors = Data()
    private var pendingLine = Data()
    private var timedOut = false
    private var watchdog: Task<Void, Never>?
    private let onOutputLine: (@Sendable (String) -> Void)?

    init(onOutputLine: (@Sendable (String) -> Void)?) {
        self.onOutputLine = onOutputLine
    }

    func addOutput(_ data: Data) {
        guard !data.isEmpty else { return }
        let lines: [String] = lock.withLock {
            output.append(data)
            guard onOutputLine != nil else { return [] }
            pendingLine.append(data)
            var found: [String] = []
            while let end = pendingLine.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let line = pendingLine[pendingLine.startIndex..<end]
                pendingLine = Data(pendingLine[pendingLine.index(after: end)...])
                if !line.isEmpty { found.append(String(decoding: line, as: UTF8.self)) }
            }
            return found
        }
        lines.forEach { onOutputLine?($0) }
    }

    func flushLine() {
        let line: String? = lock.withLock {
            guard !pendingLine.isEmpty else { return nil }
            defer { pendingLine = Data() }
            return String(decoding: pendingLine, as: UTF8.self)
        }
        if let line { onOutputLine?(line) }
    }

    func addErrors(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.withLock { errors.append(data) }
    }

    func markTimedOut() {
        lock.withLock { timedOut = true }
    }

    func keep(_ task: Task<Void, Never>) {
        lock.withLock { watchdog = task }
    }

    func cancelWatchdog() {
        lock.withLock { watchdog }?.cancel()
    }

    func result(status: Int32) -> ChildProcess.Result {
        lock.withLock { ChildProcess.Result(status: status, output: output, errorOutput: errors, timedOut: timedOut) }
    }
}
