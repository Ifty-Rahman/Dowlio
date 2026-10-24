// Developer tool for driving the download engine. Never shipped in the app or in a release.

import DowlioCore
import DowlioEngine
import Foundation

let usage = """
usage: dowlio-cli get <url> [-c <connections>] [-o <folder>] [--shared-session]
       dowlio-cli resume <partial file>

  get     Download <url> into <folder> (default: the current folder) over up to
          <connections> connections (default: 8, at most 16).
          --shared-session runs all connections in one URLSession instead of one
          session each, for the benchmark.
  resume  Continue the download held by a .dowlio partial file.

  Ctrl-C pauses the download and prints its partial file, for resume.
"""

// Progress lines must reach a pipe as they're printed, not when the tool exits.
setvbuf(stdout, nil, _IOLBF, 0)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(64)
}

enum Command {
    case get(URL, folder: URL, options: RequestOptions, sessions: SessionMode)
    case resume(URL)
}

func parse(_ arguments: [String]) -> Command {
    switch arguments.first {
    case "get":
        guard arguments.count >= 2, let url = URL(string: arguments[1]), url.scheme != nil else { fail(usage) }
        var folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        var options = RequestOptions()
        var sessions = SessionMode.onePerConnection
        var rest = arguments.dropFirst(2)
        while let option = rest.popFirst() {
            switch option {
            case "-o":
                guard let path = rest.popFirst() else { fail(usage) }
                folder = URL(fileURLWithPath: path, isDirectory: true)
            case "-c":
                guard let count = rest.popFirst().flatMap({ Int($0) }) else { fail(usage) }
                options.connections = count
            case "--shared-session":
                sessions = .oneShared
            default:
                fail(usage)
            }
        }
        return .get(url, folder: folder, options: options, sessions: sessions)
    case "resume":
        guard arguments.count == 2 else { fail(usage) }
        return .resume(URL(fileURLWithPath: arguments[1], isDirectory: true))
    default:
        fail(usage)
    }
}

func bytes(_ count: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
}

func progressLine(_ snapshot: DownloadSnapshot) -> String {
    let received = bytes(snapshot.receivedBytes)
    guard let total = snapshot.totalBytes, total > 0 else { return "\(received)  \(snapshot.state)" }
    let percent = Int(Double(snapshot.receivedBytes) / Double(total) * 100)
    let speed = "\(bytes(snapshot.bytesPerSecond))/s"
    let left = snapshot.timeRemaining.map { "\(Int($0.rounded())) s left" } ?? "time left unknown"
    return "\(percent)%  \(received) of \(bytes(total))  \(speed)  \(left)  "
        + "\(snapshot.activeConnections) connections  \(snapshot.state)"
}

func readable(_ error: DownloadError) -> String {
    switch error {
    case .network(let failure): "network error: \(failure.message)"
    default: "\(error)"
    }
}

enum ProgressEvent {
    case snapshot(DownloadSnapshot)
    case tick
}

let command = parse(Array(CommandLine.arguments.dropFirst()))
var configuration = EngineConfiguration()
if case .get(_, _, _, let sessions) = command { configuration.sessions = sessions }
let engine = DownloadEngine(configuration: configuration)
let id: DownloadID
switch command {
case .get(let url, let folder, let options, _):
    id = await engine.add(url: url, to: folder, options: options)
case .resume(let package):
    do {
        id = try await engine.restore(partialFile: package)
    } catch {
        fail("Can't resume \(package.path): its manifest is missing or unreadable.")
    }
    await engine.resume(id)
}

// Ctrl-C pauses the download, so `resume` can continue it, and prints where its partial file is.
signal(SIGINT, SIG_IGN)
let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
interrupt.setEventHandler {
    Task {
        await engine.pause(id)
        let package = await engine.partialFile(of: id)
        print("Paused: \(package?.path ?? "no partial file yet")")
        exit(130)
    }
}
interrupt.resume()

let (events, eventSink) = AsyncStream.makeStream(of: ProgressEvent.self)
let snapshots = await engine.snapshots(of: id)
Task {
    for await snapshot in snapshots { eventSink.yield(.snapshot(snapshot)) }
    eventSink.finish()
}
Task {
    while true {
        eventSink.yield(.tick)
        try? await Task.sleep(for: .seconds(1))
    }
}

var latest: DownloadSnapshot?
for await event in events {
    switch event {
    case .tick:
        if let latest { print(progressLine(latest)) }
    case .snapshot(let snapshot):
        latest = snapshot
        switch snapshot.state {
        case .completed:
            print("Completed: \(snapshot.destinationFolder.appending(path: snapshot.fileName).path)")
            exit(0)
        case .failed(let error):
            print("Failed: \(readable(error))")
            exit(1)
        default:
            break
        }
    }
}
fail("The download ended without finishing.")
