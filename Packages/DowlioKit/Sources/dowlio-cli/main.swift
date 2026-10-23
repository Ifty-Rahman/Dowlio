// Developer tool for driving the download engine. Never shipped in the app or in a release.

import DowlioCore
import DowlioEngine
import Foundation

let usage = """
usage: dowlio-cli get <url> [-c <connections>] [-o <folder>]

  get   Download <url> into <folder> (default: the current folder) over up to
        <connections> connections (default: 8, at most 16).
"""

// Progress lines must reach a pipe as they're printed, not when the tool exits.
setvbuf(stdout, nil, _IOLBF, 0)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(64)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.first == "get", arguments.count >= 2, let url = URL(string: arguments[1]), url.scheme != nil else {
    fail(usage)
}

var folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
var options = RequestOptions()
var rest = arguments.dropFirst(2)
while let option = rest.popFirst() {
    switch option {
    case "-o":
        guard let path = rest.popFirst() else { fail(usage) }
        folder = URL(fileURLWithPath: path, isDirectory: true)
    case "-c":
        guard let count = rest.popFirst().flatMap({ Int($0) }) else { fail(usage) }
        options.connections = count
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

/// The newest snapshot, shared between the snapshot loop and the once-a-second printer.
actor Latest {
    var snapshot: DownloadSnapshot?
    func set(_ snapshot: DownloadSnapshot) { self.snapshot = snapshot }
}

let engine = DownloadEngine()
let id = await engine.add(url: url, to: folder, options: options)
let latest = Latest()

// One progress line a second, including while no bytes arrive.
let printer = Task {
    while !Task.isCancelled {
        if let snapshot = await latest.snapshot { print(progressLine(snapshot)) }
        try? await Task.sleep(for: .seconds(1))
    }
}

for await snapshot in await engine.snapshots(of: id) {
    await latest.set(snapshot)
    switch snapshot.state {
    case .completed:
        printer.cancel()
        print("Completed: \(folder.appending(path: snapshot.fileName).path)")
        exit(0)
    case .failed(let error):
        printer.cancel()
        print("Failed: \(error)")
        exit(1)
    default:
        break
    }
}
fail("The download ended without finishing.")
