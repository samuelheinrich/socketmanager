import Foundation
import Darwin

struct Listener: Hashable {
    let pid: Int32
    let port: Int
    let address: String
}

public actor SocketService {
    public init() {}

    public func collect() throws -> [SocketEntry] {
        let sockets = try CommandRunner.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pn"])
        // lsof returns 1 when no sockets match. Diagnostics must not become a false empty state.
        guard sockets.status == 0 || (sockets.status == 1 && sockets.error.isEmpty && sockets.output.isEmpty) else {
            throw SocketError.message("Sockets konnten nicht gelesen werden: \(sockets.error.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let listeners = Self.parseListeners(sockets.output)
        guard !listeners.isEmpty else { return [] }
        let ps = try CommandRunner.run("/bin/ps", ["-axo", "pid=,command="])
        guard ps.status == 0 else { throw SocketError.message("Prozessliste konnte nicht gelesen werden.") }
        let commands = Self.parseCommands(ps.output)
        let pids = Set(listeners.map(\.pid)).sorted()
        let cwdOutput = try? CommandRunner.run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-p", pids.map(String.init).joined(separator: ","), "-F", "pn"])
        let directories = Self.parseDirectories(cwdOutput?.output ?? "")
        let protected = Self.protectedPIDs()
        let docker = listeners.contains { SocketEntry.isDockerCommand(commands[$0.pid] ?? "") }
            ? Self.dockerContainers() : [:]
        let grouped = Dictionary(grouping: listeners, by: { "\($0.pid):\($0.port)" })
        return grouped.values.compactMap { values -> SocketEntry? in
            guard let first = values.first else { return nil }
            let command = commands[first.pid] ?? ""
            let cwd = directories[first.pid] ?? ""
            // Only Docker-owned listeners may be mapped to containers.
            let container = SocketEntry.isDockerCommand(command) ? docker[first.port] : nil
            return SocketEntry(pid: first.pid, port: first.port, addresses: Set(values.map(\.address)).sorted(),
                               command: command, process: Self.shortCommand(command, executablePath: Self.executablePath(first.pid)), cwd: cwd,
                               project: container?.name ?? Self.projectName(cwd), identity: ProcessIdentity.read(first.pid),
                               container: container, protectedProcess: protected.contains(first.pid) || first.pid <= 1)
        }.sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
    }

    public func stop(_ entry: SocketEntry, force: Bool = false) throws -> String {
        do {
            let message = try performStop(entry, force: force)
            Self.log(entry, message: message)
            return message
        } catch {
            Self.log(entry, message: "FEHLER: \(error.localizedDescription)")
            throw error
        }
    }

    private func performStop(_ entry: SocketEntry, force: Bool) throws -> String {
        guard entry.canStop, !Self.protectedPIDs().contains(entry.pid), entry.pid > 1 else {
            throw SocketError.message("Dieser Prozess ist geschützt oder gehört einem anderen Benutzer.")
        }
        if let container = entry.container {
            guard let docker = Self.dockerExecutable() else { throw SocketError.message("Docker wurde nicht gefunden.") }
            guard Self.dockerContainers()[entry.port]?.id == container.id else {
                throw SocketError.message("Die Container-Zuordnung hat sich geändert. Bitte die Liste aktualisieren.")
            }
            let result = try CommandRunner.run(docker, [force ? "kill" : "stop", container.id], timeout: 15)
            guard result.status == 0 else { throw SocketError.message("Docker: \(result.error.trimmingCharacters(in: .whitespacesAndNewlines))") }
            return "Container \(container.name) beendet."
        }
        guard !entry.isDocker, let identity = entry.identity,
              identity.isSameProcess(as: ProcessIdentity.read(entry.pid)) else {
            throw SocketError.message("Der ursprüngliche Prozess läuft nicht mehr. Bitte die Liste aktualisieren.")
        }
        // Recheck ownership of the selected listener immediately before signalling.
        let current = try CommandRunner.run("/usr/sbin/lsof", ["-nP", "-a", "-p", String(entry.pid), "-iTCP:\(entry.port)", "-sTCP:LISTEN", "-F", "pn"])
        guard Self.parseListeners(current.output).contains(where: { $0.pid == entry.pid && $0.port == entry.port }),
              identity.isSameProcess(as: ProcessIdentity.read(entry.pid)) else {
            throw SocketError.message("Der ausgewählte Socket läuft nicht mehr. Bitte die Liste aktualisieren.")
        }
        try Self.signal(entry.pid, force ? SIGKILL : SIGTERM)
        let deadline = Date().addingTimeInterval(2)
        while identity.isSameProcess(as: ProcessIdentity.read(entry.pid)) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if !force && identity.isSameProcess(as: ProcessIdentity.read(entry.pid)) {
            try Self.signal(entry.pid, SIGKILL)
            return "Prozess \(entry.pid) zwangsweise beendet."
        }
        return "Prozess \(entry.pid) beendet."
    }

    static func signal(_ pid: Int32, _ signal: Int32) throws {
        guard Darwin.kill(pid, signal) == 0 else {
            if errno == ESRCH { return }
            throw SocketError.message(errno == EPERM ? "Keine Berechtigung, diesen Prozess zu beenden." : "Prozess konnte nicht beendet werden: \(String(cString: strerror(errno)))")
        }
    }

    static func protectedPIDs() -> Set<Int32> {
        var protected: Set<Int32> = [1]
        var pid = getpid()
        while pid > 1 && protected.insert(pid).inserted {
            guard let identity = ProcessIdentity.read(pid) else { break }
            pid = identity.parentPID
        }
        return protected
    }

    static func parseListeners(_ output: String) -> [Listener] {
        var pid: Int32?
        var rows: [Listener] = []
        for line in output.split(separator: "\n") {
            if line.first == "p" { pid = Int32(line.dropFirst()) }
            if line.first == "n", let pid, pid > 0, let colon = line.lastIndex(of: ":"),
               let port = Int(line[line.index(after: colon)...]), (1...65535).contains(port) {
                let host = String(line[line.index(after: line.startIndex)..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                rows.append(Listener(pid: pid, port: port, address: host.isEmpty ? "*" : host))
            }
        }
        return rows
    }

    static func parseCommands(_ output: String) -> [Int32: String] {
        var commands: [Int32: String] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            if fields.count == 2, let pid = Int32(fields[0]) { commands[pid] = String(fields[1]) }
        }
        return commands
    }

    static func parseDirectories(_ output: String) -> [Int32: String] {
        var pid: Int32?
        var directories: [Int32: String] = [:]
        for line in output.split(separator: "\n") {
            if line.first == "p" { pid = Int32(line.dropFirst()) }
            if line.first == "n", let pid { directories[pid] = String(line.dropFirst()) }
        }
        return directories
    }

    static func executablePath(_ pid: Int32) -> String {
        // PROC_PIDPATHINFO_MAXSIZE is a C expression macro unavailable to Swift.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return "" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func shortCommand(_ command: String, executablePath: String = "") -> String {
        let tokens = command.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let executable = tokens.first else { return "Unbekannter Prozess" }
        let name = URL(fileURLWithPath: executablePath.isEmpty ? executable : executablePath).lastPathComponent
        let interpreter = name.lowercased()
        if ["node", "python", "python3", "ruby", "php", "bun", "deno", "java"].contains(interpreter)
            || interpreter.hasPrefix("python3.") {
            let arguments = !executablePath.isEmpty && command.hasPrefix(executablePath)
                ? command.dropFirst(executablePath.count).split(whereSeparator: \.isWhitespace).map(String.init)
                : Array(tokens.dropFirst())
            if let module = arguments.firstIndex(of: "-m"), arguments.indices.contains(module + 1) { return "\(name) \(arguments[module + 1])" }
            if arguments.contains("-c") { return "\(name) -c" }
            if let script = arguments.first(where: { !$0.hasPrefix("-") }) { return "\(name) \(URL(fileURLWithPath: script).lastPathComponent)" }
        }
        return name
    }

    static func projectName(_ cwd: String) -> String {
        guard !cwd.isEmpty, cwd != "/" else { return "" }
        var directory = URL(fileURLWithPath: cwd)
        for _ in 0..<16 {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) { return directory.lastPathComponent }
            if directory.path == "/" { break }
            directory.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    static func dockerExecutable() -> String? {
        ["/opt/homebrew/bin/docker", "/usr/local/bin/docker", "/Applications/Docker.app/Contents/Resources/bin/docker"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func dockerContainers() -> [Int: Container] {
        guard let executable = dockerExecutable(),
              let result = try? CommandRunner.run(executable, ["ps", "--format", "{{json .}}"], timeout: 2), result.status == 0 else { return [:] }
        return parseContainers(result.output)
    }

    static func parseContainers(_ output: String) -> [Int: Container] {
        var containers: [Int: Container] = [:]
        var ambiguousPorts: Set<Int> = []
        guard let regex = try? NSRegularExpression(pattern: ":([0-9]+)->[0-9]+/tcp") else { return [:] }
        for line in output.split(separator: "\n") {
            guard let data = String(line).data(using: .utf8),
                  let row = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  let id = row["ID"], id.range(of: "^[a-f0-9]{12,64}$", options: .regularExpression) != nil,
                  let name = row["Names"], let ports = row["Ports"] else { continue }
            for match in regex.matches(in: ports, range: NSRange(ports.startIndex..., in: ports)) {
                if let range = Range(match.range(at: 1), in: ports), let port = Int(ports[range]) {
                    if let previous = containers[port], previous.id != id { ambiguousPorts.insert(port) }
                    containers[port] = Container(id: id, name: name)
                }
            }
        }
        return containers.filter { !ambiguousPorts.contains($0.key) }
    }

    static func log(_ entry: SocketEntry, message: String) {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state")
        let file = directory.appendingPathComponent("socketmanager.log")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeMessage = message.replacingOccurrences(of: "\n", with: " ")
        let line = "\(ISO8601DateFormatter().string(from: Date())) port \(entry.port) pid \(entry.pid) \(entry.name) [\(entry.project)] \(safeMessage)\n"
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }
}
