import Foundation
import Darwin

public struct ProcessIdentity: Hashable, Sendable {
    public let pid: Int32
    public let parentPID: Int32
    public let userID: UInt32
    public let startedSeconds: UInt64
    public let startedMicroseconds: UInt64

    public init(pid: Int32, parentPID: Int32, userID: UInt32,
                startedSeconds: UInt64, startedMicroseconds: UInt64) {
        self.pid = pid
        self.parentPID = parentPID
        self.userID = userID
        self.startedSeconds = startedSeconds
        self.startedMicroseconds = startedMicroseconds
    }

    public static func read(_ pid: Int32) -> Self? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Self(pid: pid, parentPID: Int32(info.pbi_ppid), userID: info.pbi_uid,
                    startedSeconds: info.pbi_start_tvsec, startedMicroseconds: info.pbi_start_tvusec)
    }

    public func isSameProcess(as other: Self?) -> Bool {
        guard let other else { return false }
        return pid == other.pid && userID == other.userID
            && startedSeconds == other.startedSeconds && startedMicroseconds == other.startedMicroseconds
    }
}

public struct Container: Hashable, Sendable {
    public let id: String
    public let name: String
}

public struct SocketEntry: Identifiable, Hashable, Sendable {
    public let pid: Int32
    public let port: Int
    public let addresses: [String]
    public let command: String
    public let process: String
    public let cwd: String
    public let project: String
    public let identity: ProcessIdentity?
    public let container: Container?
    public let protectedProcess: Bool

    public var id: String { "\(pid):\(identity?.startedSeconds ?? 0):\(identity?.startedMicroseconds ?? 0):\(port)" }
    public var isDocker: Bool { Self.isDockerCommand(command) }
    public var canStop: Bool {
        !protectedProcess && (container != nil || (!isDocker && identity?.userID == getuid()))
    }
    public var name: String { container.map { "Docker · \($0.name)" } ?? process }
    public var host: String {
        if addresses.contains(where: { ["*", "0.0.0.0", "127.0.0.1"].contains($0) }) { return "127.0.0.1" }
        if addresses.contains(where: { ["::", "::1"].contains($0) }) { return "::1" }
        return addresses.first ?? "127.0.0.1"
    }
    public var url: URL {
        var parts = URLComponents()
        parts.scheme = [443, 8443].contains(port) ? "https" : "http"
        parts.host = host.contains(":") ? "[\(host)]" : host
        parts.port = port
        parts.path = "/"
        return parts.url!
    }
    public var isPublic: Bool { addresses.contains { ["*", "0.0.0.0", "::"].contains($0) } }
    public var uptime: String {
        guard let start = identity?.startedSeconds else { return "–" }
        let seconds = max(0, Int(Date().timeIntervalSince1970) - Int(start))
        if seconds >= 86400 { return "\(seconds / 86400)d \(seconds % 86400 / 3600)h" }
        if seconds >= 3600 { return "\(seconds / 3600)h \(seconds % 3600 / 60)m" }
        return "\(seconds / 60)m"
    }
    public var isDevelopmentServer: Bool {
        guard addresses.contains(where: { ["*", "0.0.0.0", "127.0.0.1", "::", "::1"].contains($0) }) else { return false }
        if container != nil { return true }
        if Self.matches(command, pattern: "rapportd|onedrive|dropbox|google ?drive|spotify|steam|sharingd|controlcenter|airplay|mysqld|postgres|redis-server|mongod|com\\.apple") { return false }
        if [80, 443, 1313, 3000, 4200, 4321, 5000, 5173, 5174, 7777, 8080, 8081, 8888, 9000].contains(port)
            || (3000...3100).contains(port) || (8000...8999).contains(port) { return true }
        return Self.matches(command, pattern: "(?:^|[/\\s])(?:node|npm|npx|pnpm|yarn|bun|deno|vite|next|nuxt|python[0-9.]*|uvicorn|gunicorn|flask|ruby|rails|php|caddy|nginx|httpd|go|java|cargo|miniserve|dotnet)(?:$|\\s)")
    }
    public func matches(_ query: String) -> Bool {
        query.isEmpty || "\(port) \(pid) \(name) \(project) \(cwd) \(command) \(addresses.joined(separator: " "))"
            .localizedCaseInsensitiveContains(query)
    }
    static func matches(_ text: String, pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
    static func isDockerCommand(_ command: String) -> Bool {
        matches(command, pattern: "com\\.docker|docker-proxy|dockerd|colima|vpnkit|containerd")
    }
}

public enum SocketError: LocalizedError, Sendable {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}
