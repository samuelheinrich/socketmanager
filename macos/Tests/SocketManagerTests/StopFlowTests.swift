import Foundation
import Testing
import Darwin
import AppKit
@testable import SocketManager
@testable import SocketCore

@MainActor
struct StopFlowTests {
    @Test func confirmationCanBeCancelledAndAcceptedWithoutHidingTheList() async throws {
        let fixture = Process()
        let output = Pipe()
        fixture.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        fixture.arguments = ["-u", "-c", "import socket,time; s=socket.socket(); s.bind(('127.0.0.1',0)); s.listen(1); print(s.getsockname()[1],flush=True); time.sleep(60)"]
        fixture.standardOutput = output
        fixture.standardError = FileHandle.nullDevice
        try fixture.run()
        defer {
            if fixture.isRunning { Darwin.kill(fixture.processIdentifier, SIGKILL) }
            fixture.waitUntilExit()
        }
        let text = try #require(String(data: output.fileHandleForReading.availableData, encoding: .utf8))
        let port = try #require(Int(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        let model = AppModel()
        await model.refresh()
        let entry = try #require(model.entries.first { $0.pid == fixture.processIdentifier && $0.port == port })
        _ = NSApplication.shared
        NSApp.finishLaunching()
        let delegate = AppDelegate(model: model)
        let notification = Notification(name: NSApplication.didFinishLaunchingNotification)
        delegate.applicationDidFinishLaunching(notification)
        defer { delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }
        let anchor = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 100, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        anchor.makeKeyAndOrderFront(nil)
        defer { anchor.orderOut(nil) }
        NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(200))
        let anchorView = try #require(anchor.contentView)
        delegate.popover.show(relativeTo: NSRect(x: 40, y: 40, width: 20, height: 20), of: anchorView, preferredEdge: .minY)
        #expect(delegate.popover.isShown)
        model.requestStop(entry)
        #expect(model.pendingStop?.entry.id == entry.id)
        #expect(fixture.isRunning)
        #expect(model.stopExplanation.contains(String(port)))
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                    windowNumber: 0, context: nil, characters: "\u{1b}",
                                                    charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        #expect(delegate.handleConfirmationKey(escape))
        #expect(model.pendingStop == nil)
        #expect(fixture.isRunning)
        #expect(delegate.popover.isShown)
        model.requestStop(entry)
        let repeatedEnter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                         windowNumber: 0, context: nil, characters: "\r",
                                                         charactersIgnoringModifiers: "\r", isARepeat: true, keyCode: 36))
        #expect(delegate.handleConfirmationKey(repeatedEnter))
        #expect(model.pendingStop != nil)
        let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                windowNumber: 0, context: nil, characters: "\r",
                                                charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        #expect(delegate.handleConfirmationKey(enter))
        // A repeated Enter must not submit another stop operation.
        model.executePendingStop()
        #expect(model.pendingStop == nil)
        #expect(model.isStopping(entry))
        let deadline = Date().addingTimeInterval(5)
        while model.isStopping(entry) && Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        #expect(!model.isStopping(entry))
        #expect(model.scanError == nil)
        #expect(!model.entries.contains { $0.id == entry.id })
        #expect(model.message?.contains("beendet") == true)
        #expect(delegate.popover.isShown)
        fixture.waitUntilExit()
        #expect(!fixture.isRunning)
    }

    @Test func protectedProcessCannotOpenConfirmation() {
        let model = AppModel()
        let entry = SocketEntry(pid: getpid(), port: 3000, addresses: ["127.0.0.1"], command: "test", process: "test",
                                cwd: "", project: "", identity: ProcessIdentity.read(getpid()), container: nil, protectedProcess: true)
        model.requestStop(entry)
        #expect(model.pendingStop == nil)
    }
}
