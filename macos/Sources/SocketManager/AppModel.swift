import AppKit
import Combine
import ServiceManagement
import SocketCore

@MainActor
final class AppModel: ObservableObject {
    struct StopRequest {
        let entry: SocketEntry
        let force: Bool
    }
    @Published var entries: [SocketEntry] = []
    @Published var query = ""
    @Published var isLoading = false
    @Published var hasLoaded = false
    @Published var updatedAt: Date?
    @Published var message: String?
    @Published var scanError: String?
    @Published var stopping: Set<String> = []
    @Published var pendingStop: StopRequest?
    @Published var showAll: Bool {
        didSet { UserDefaults.standard.set(showAll, forKey: "showAllSockets") }
    }
    @Published var refreshInterval: Double {
        didSet { UserDefaults.standard.set(refreshInterval, forKey: "refreshInterval") }
    }
    @Published var loginStatus = SMAppService.mainApp.status
    private let service = SocketService()
    private var polling: Task<Void, Never>?
    var openSettings: (() -> Void)?
    var openInfo: (() -> Void)?

    init() {
        let defaults = UserDefaults.standard
        showAll = defaults.object(forKey: "showAllSockets") as? Bool ?? true
        let stored = defaults.double(forKey: "refreshInterval")
        refreshInterval = [3.0, 5.0, 10.0].contains(stored) ? stored : 3
    }

    var filteredEntries: [SocketEntry] {
        entries.filter { (showAll || $0.isDevelopmentServer) && $0.matches(query.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    func startPolling() {
        guard polling == nil else { return }
        loginStatus = SMAppService.mainApp.status
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(for: .seconds(self.refreshInterval))
            }
        }
    }

    func stopPolling() {
        polling?.cancel()
        polling = nil
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            entries = try await service.collect()
            hasLoaded = true
            updatedAt = Date()
            scanError = nil
        } catch {
            scanError = error.localizedDescription
        }
    }

    func open(_ entry: SocketEntry, secure: Bool = false) {
        var components = URLComponents(url: entry.url, resolvingAgainstBaseURL: false)!
        if secure { components.scheme = "https" }
        if let url = components.url, !NSWorkspace.shared.open(url) { message = "Die URL konnte nicht geöffnet werden." }
    }

    func copy(_ entry: SocketEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.url.absoluteString, forType: .string)
        message = "URL kopiert: \(entry.url.absoluteString)"
    }

    func reveal(_ entry: SocketEntry) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: entry.cwd)
    }

    func isStopping(_ entry: SocketEntry) -> Bool { stopping.contains(operationKey(entry)) }

    private func operationKey(_ entry: SocketEntry) -> String {
        entry.container.map { "container:\($0.id)" }
            ?? "process:\(entry.pid):\(entry.identity?.startedSeconds ?? 0):\(entry.identity?.startedMicroseconds ?? 0)"
    }

    func requestStop(_ entry: SocketEntry, force: Bool = false) {
        guard entry.canStop, !isStopping(entry) else { return }
        pendingStop = StopRequest(entry: entry, force: force)
        message = nil
    }

    func cancelStop() { pendingStop = nil }

    var stopExplanation: String {
        guard let request = pendingStop else { return "" }
        if request.entry.container != nil {
            return "Der gesamte Container und alle seine veröffentlichten Ports werden beendet."
        }
        let ports = entries.filter { $0.pid == request.entry.pid }.map { String($0.port) }.joined(separator: ", ")
        return "PID \(request.entry.pid) · Port(s) \(ports)\n"
            + (request.force ? "SIGKILL beendet den Prozess sofort." : "SIGTERM, nach 2 Sekunden bei Bedarf SIGKILL.")
    }

    func executePendingStop() {
        guard let request = pendingStop else { return }
        pendingStop = nil
        let entry = request.entry
        let key = operationKey(entry)
        guard entry.canStop, !stopping.contains(key) else { return }
        stopping.insert(key)
        message = "\(entry.name) wird beendet …"
        Task {
            do { message = try await service.stop(entry, force: request.force) }
            catch { message = error.localizedDescription }
            // Let an existing scan finish, then read a fresh snapshot after the stop.
            while isLoading { try? await Task.sleep(for: .milliseconds(25)) }
            await refresh()
            stopping.remove(key)
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch { message = "Autostart konnte nicht geändert werden: \(error.localizedDescription)" }
        loginStatus = SMAppService.mainApp.status
    }
}
