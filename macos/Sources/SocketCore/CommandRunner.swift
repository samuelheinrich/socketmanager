import Foundation
import Darwin

struct CommandResult: Sendable {
    let output: String
    let error: String
    let status: Int32
}

enum CommandRunner {
    /// File-backed output avoids pipe deadlocks with large process/socket lists.
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 5) throws -> CommandResult {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("socketmanager-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("stdout")
        let errorURL = directory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        FileManager.default.createFile(atPath: errorURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: outputURL)
        let error = try FileHandle(forWritingTo: errorURL)
        defer { try? output.close(); try? error.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        process.standardInput = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning {
            process.terminate()
            let grace = Date().addingTimeInterval(0.2)
            while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw SocketError.message("\(URL(fileURLWithPath: executable).lastPathComponent) hat zu lange gebraucht. Bitte erneut versuchen.")
        }
        process.waitUntilExit()
        return CommandResult(output: (try? String(contentsOf: outputURL, encoding: .utf8)) ?? "",
                             error: (try? String(contentsOf: errorURL, encoding: .utf8)) ?? "",
                             status: process.terminationStatus)
    }
}
