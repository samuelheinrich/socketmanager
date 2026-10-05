import AppKit
import SwiftUI
import SocketCore
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model: AppModel
    private var statusItem: NSStatusItem?
    let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var infoWindow: NSWindow?
    private var previewWindow: NSWindow?
    private var keyboardMonitor: Any?

    init(model: AppModel = AppModel()) {
        self.model = model
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        if let button = item.button {
            button.image = BrandIcon.image(size: 18, template: true)
            button.toolTip = "Socket Manager – lokale TCP-Sockets"
            button.setAccessibilityLabel("Socket Manager öffnen")
            button.target = self
            button.action = #selector(togglePopover)
        }
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        let content = NSHostingController(rootView: PopoverView(model: model))
        content.sizingOptions = [.preferredContentSize]
        popover.contentViewController = content
        model.openSettings = { [weak self] in self?.showSettings() }
        model.openInfo = { [weak self] in self?.showInfo() }
        installMainMenu()
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.handleConfirmationKey(event) == true { return nil }
            if event.keyCode == 53, NSApp.modalWindow == nil, self?.popover.isShown == true {
                self?.popover.performClose(nil)
                return nil
            }
            return event
        }
        // Deterministic render path for local UI verification, never shown during normal launch.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if arguments.contains("--light") { NSApp.appearance = NSAppearance(named: .aqua) }
        if arguments.contains("--preview") || arguments.contains("--render-preview") {
            if let index = arguments.firstIndex(of: "--preview-query"), arguments.indices.contains(index + 1) {
                model.query = arguments[index + 1]
            }
            showPreview()
            if let index = arguments.firstIndex(of: "--render-preview"), arguments.indices.contains(index + 1) {
                let path = arguments[index + 1]
                Task {
                    await model.refresh()
                    while model.isLoading { try? await Task.sleep(for: .milliseconds(25)) }
                    if let index = arguments.firstIndex(of: "--preview-confirm"), arguments.indices.contains(index + 1),
                       let port = Int(arguments[index + 1]), let entry = model.entries.first(where: { $0.port == port }) {
                        model.requestStop(entry)
                    }
                    try? await Task.sleep(for: .milliseconds(500))
                    renderPreview(to: path)
                    NSApp.terminate(nil)
                }
            }
        }
    }

    @objc func togglePopover() {
        if popover.isShown { popover.performClose(nil) }
        else if let button = statusItem?.button {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            model.startPolling()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        model.stopPolling()
        model.cancelStop()
    }

    func handleConfirmationKey(_ event: NSEvent) -> Bool {
        guard model.pendingStop != nil, event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        if event.keyCode == 53 { model.cancelStop(); return true }
        if event.keyCode == 36 || event.keyCode == 76 {
            if !event.isARepeat { model.executePendingStop() }
            return true
        }
        return false
    }

    @objc private func showSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let controller = NSHostingController(rootView: SettingsView(model: model))
            let window = NSWindow(contentViewController: controller)
            window.title = "Socket Manager – Einstellungen"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        model.loginStatus = SMAppService.mainApp.status
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func refreshSockets() { Task { await model.refresh() } }

    @objc private func showInfo() {
        popover.performClose(nil)
        if infoWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: InfoView()))
            window.title = "Über Socket Manager"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            infoWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        infoWindow?.makeKeyAndOrderFront(nil)
    }

    private func installMainMenu() {
        let menu = NSMenu()
        let appMenu = NSMenu()
        let root = NSMenuItem()
        root.submenu = appMenu
        menu.addItem(root)
        let info = NSMenuItem(title: "Über Socket Manager", action: #selector(showInfo), keyEquivalent: "")
        info.target = self
        appMenu.addItem(info)
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: "Einstellungen …", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        let refresh = NSMenuItem(title: "Sockets aktualisieren", action: #selector(refreshSockets), keyEquivalent: "r")
        refresh.target = self
        appMenu.addItem(refresh)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Socket Manager beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenu(title: "Bearbeiten")
        let editRoot = NSMenuItem(title: "Bearbeiten", action: nil, keyEquivalent: "")
        editRoot.submenu = edit
        menu.addItem(editRoot)
        edit.addItem(withTitle: "Ausschneiden", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Kopieren", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Einfügen", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Alles auswählen", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = menu
    }

    private func showPreview() {
        let window = NSWindow(contentViewController: NSHostingController(rootView: PopoverView(model: model)))
        window.title = "Socket Manager – Preview"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        previewWindow = window
        model.startPolling()
    }

    private func renderPreview(to path: String) {
        guard let view = previewWindow?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        // Hosting views are transparent; include the native window surface without screen-recording permissions.
        guard let surface = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: bitmap.pixelsWide,
                                             pixelsHigh: bitmap.pixelsHigh, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: surface)?.cgContext,
              let content = bitmap.cgImage else { return }
        let bounds = CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            context.setFillColor(NSColor.windowBackgroundColor.cgColor)
            context.fill(bounds)
        }
        context.draw(content, in: bounds)
        if let png = surface.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        popover.performClose(nil)
        model.stopPolling()
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }
}

if let index = CommandLine.arguments.firstIndex(of: "--export-icon"), CommandLine.arguments.indices.contains(index + 1) {
    try BrandIcon.exportIconset(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
