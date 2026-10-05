import Foundation
import Testing
import Darwin
@testable import SocketCore

struct SocketCoreTests {
    @Test func listenersHandleIPv6AndMalformedRecords() {
        let rows = SocketService.parseListeners("p42\nn127.0.0.1:3000\nn[::1]:3000\nn*:8080\nn[fe80::1]:9000\nninvalid\nn*:99999\npbroken\nn*:5000\n")
        #expect(rows == [Listener(pid: 42, port: 3000, address: "127.0.0.1"),
                         Listener(pid: 42, port: 3000, address: "::1"),
                         Listener(pid: 42, port: 8080, address: "*"),
                         Listener(pid: 42, port: 9000, address: "fe80::1")])
    }

    @Test func dockerOnlyMapsPublishedTCPPorts() {
        let json = """
        {"ID":"aabbccddeeff","Names":"web","Ports":"0.0.0.0:8080->80/tcp, [::]:8080->80/tcp, 127.0.0.1:5353->53/udp, 9000/tcp"}
        {"ID":"112233445566","Names":"api","Ports":"127.0.0.1:3000->3000/tcp"}
        {"ID":"--bad","Names":"unsafe","Ports":"0.0.0.0:4000->80/tcp"}
        """
        let containers = SocketService.parseContainers(json)
        #expect(containers.count == 2)
        #expect(containers[8080]?.name == "web")
        #expect(containers[3000]?.id == "112233445566")
        #expect(containers[5353] == nil)
        #expect(containers[9000] == nil)
        #expect(containers[4000] == nil)
    }

    @Test func identityDetectsPIDReuseButAllowsReparenting() {
        let old = ProcessIdentity(pid: 42, parentPID: 100, userID: 501, startedSeconds: 1000, startedMicroseconds: 100)
        #expect(!old.isSameProcess(as: nil))
        #expect(!old.isSameProcess(as: ProcessIdentity(pid: 42, parentPID: 100, userID: 501, startedSeconds: 1000, startedMicroseconds: 101)))
        #expect(old.isSameProcess(as: ProcessIdentity(pid: 42, parentPID: 1, userID: 501, startedSeconds: 1000, startedMicroseconds: 100)))
    }

    @Test func ambiguousDockerBindingsCannotSelectTheWrongContainer() {
        let mapping = SocketService.parseContainers("""
        {"ID":"aabbccddeeff","Names":"one","Ports":"127.0.0.1:8080->80/tcp"}
        {"ID":"112233445566","Names":"two","Ports":"127.0.0.2:8080->80/tcp"}
        """)
        #expect(mapping[8080] == nil)
    }

    @Test func processNamesPreserveSpacesInExecutablePaths() {
        #expect(SocketService.shortCommand("/Applications/Google Drive.app/Contents/MacOS/Google Drive --start", executablePath: "/Applications/Google Drive.app/Contents/MacOS/Google Drive") == "Google Drive")
        #expect(SocketService.shortCommand("/some folder/python3 -m http.server 3000", executablePath: "/some folder/python3") == "python3 http.server")
    }

    @Test func urlsAndFiltersHandleIPv6AndSystemNoise() {
        let ipv6 = entry(pid: 42, port: 5173, addresses: ["::1"], command: "/usr/bin/node app.js")
        #expect(ipv6.url.absoluteString == "http://[::1]:5173/")
        #expect(ipv6.isDevelopmentServer)
        #expect(ipv6.matches("APP.js"))
        #expect(!ipv6.isPublic)
        #expect(entry(pid: 42, port: 443, addresses: ["*"], command: "caddy").url.absoluteString == "https://127.0.0.1:443/")
        #expect(!entry(pid: 42, port: 8080, addresses: ["*"], command: "/usr/bin/rapportd").isDevelopmentServer)
        #expect(!entry(pid: 42, port: 8080, addresses: ["*"], command: "com.docker.backend").canStop)
    }

    @Test func commandTimeoutIsBounded() throws {
        let start = Date()
        #expect(throws: SocketError.self) {
            try CommandRunner.run("/bin/sleep", ["10"], timeout: 0.1)
        }
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test func ownProcessIsProtected() async throws {
        #expect(SocketService.protectedPIDs().contains(getpid()))
        let service = SocketService()
        let own = entry(pid: getpid(), port: 3000, addresses: ["127.0.0.1"], command: "test", protected: true)
        await #expect(throws: SocketError.self) { try await service.stop(own) }
    }

    @Test func detectsAndStopsOnlyOurTestServer() async throws {
        let fixture = try ServerFixture()
        defer { fixture.cleanup() }
        let service = SocketService()
        let rows = try await service.collect()
        let server = try #require(rows.first { $0.pid == fixture.process.processIdentifier && $0.port == fixture.port })
        #expect(server.addresses == ["127.0.0.1"])
        #expect(server.canStop)
        let changed = ProcessIdentity(pid: server.pid, parentPID: 1, userID: getuid(), startedSeconds: 1, startedMicroseconds: 0)
        let stale = entry(pid: server.pid, port: server.port, addresses: server.addresses, command: server.command, identity: changed)
        await #expect(throws: SocketError.self) { try await service.stop(stale) }
        #expect(fixture.process.isRunning)
        _ = try await service.stop(server)
        fixture.process.waitUntilExit()
        #expect(!fixture.process.isRunning)
        #expect(try await service.collect().allSatisfy { $0.pid != server.pid })
    }

    @Test func escalatesUnresponsiveTestServerAndSupportsForce() async throws {
        for force in [false, true] {
            let fixture = try ServerFixture(ignoreTerm: true)
            defer { fixture.cleanup() }
            let service = SocketService()
            let rows = try await service.collect()
            let server = try #require(rows.first { $0.pid == fixture.process.processIdentifier && $0.port == fixture.port })
            _ = try await service.stop(server, force: force)
            fixture.process.waitUntilExit()
            #expect(fixture.process.terminationStatus == SIGKILL)
        }
    }

    private func entry(pid: Int32, port: Int, addresses: [String], command: String,
                       identity: ProcessIdentity? = nil, protected: Bool = false) -> SocketEntry {
        SocketEntry(pid: pid, port: port, addresses: addresses, command: command,
                    process: SocketService.shortCommand(command), cwd: "/tmp/test-project", project: "test-project",
                    identity: identity ?? ProcessIdentity.read(pid), container: nil, protectedProcess: protected)
    }
}

private final class ServerFixture: @unchecked Sendable {
    let process = Process()
    let port: Int

    init(ignoreTerm: Bool = false) throws {
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", """
        import socket, signal, time
        \(ignoreTerm ? "signal.signal(signal.SIGTERM, signal.SIG_IGN)" : "")
        s = socket.socket()
        s.bind(('127.0.0.1', 0))
        s.listen(1)
        print(s.getsockname()[1], flush=True)
        time.sleep(60)
        """]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.availableData
        guard let text = String(data: data, encoding: .utf8), let port = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            if process.isRunning { process.terminate() }
            throw SocketError.message("Testserver konnte nicht gestartet werden.")
        }
        self.port = port
    }

    func cleanup() {
        if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }
}
