import SwiftUI
import AppKit
import SocketCore

struct PopoverView: View {
    @ObservedObject var model: AppModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(nsImage: BrandIcon.image(size: 32)).accessibilityHidden(true)
                    Text("Socket Manager").font(.headline)
                    Spacer()
                    Text("\(model.filteredEntries.count) TCP-Sockets")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Port, Prozess oder Projekt suchen", text: $model.query)
                        .textFieldStyle(.plain).focused($searchFocused)
                        .accessibilityLabel("Sockets filtern")
                    if !model.query.isEmpty {
                        Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).help("Suche löschen").accessibilityLabel("Suche löschen")
                    }
                }
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                Picker("Socket-Ansicht", selection: $model.showAll) {
                    Text("Alle TCP").tag(true)
                    Text("Dev-Server").tag(false)
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            .padding(16)
            Divider()
            if let error = model.scanError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.secondary).padding(16)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    if model.filteredEntries.isEmpty {
                        emptyState.padding(32)
                    } else {
                        ForEach(model.filteredEntries) { entry in
                            SocketRow(entry: entry, model: model)
                            Divider().padding(.horizontal, 16)
                        }
                    }
                }
            }
            .frame(height: listHeight)
            if let request = model.pendingStop {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Label("\(request.entry.name) \(request.force ? "sofort " : "")beenden?", systemImage: "stop.circle")
                        .font(.body.weight(.semibold)).lineLimit(2)
                    Text(model.stopExplanation).font(.callout).foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Text("Enter bestätigt · Escape bricht ab").font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button("Abbrechen") { model.cancelStop() }
                        Button(request.force ? "Sofort beenden" : "Beenden", role: .destructive) { model.executePendingStop() }
                            .keyboardShortcut(.defaultAction)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(12)
                .background(.quaternary)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Beenden bestätigen")
            }
            if let message = model.message {
                Divider()
                HStack(alignment: .top, spacing: 8) {
                    Text(message).font(.callout).textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button { model.message = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("Meldung schließen")
                }.padding(12)
            }
            Divider()
            HStack(spacing: 12) {
                Button { Task { await model.refresh() } } label: {
                    Label("Aktualisieren", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .disabled(model.isLoading).help("Aktualisieren (⌘R)").keyboardShortcut("r")
                .accessibilityLabel("Sockets aktualisieren")
                if model.isLoading {
                    ProgressView().controlSize(.small)
                    Text("Lade …").font(.caption).foregroundStyle(.secondary)
                } else if let date = model.updatedAt {
                    Text("Stand \(date.formatted(date: .omitted, time: .standard))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button { model.openInfo?() } label: { Image(systemName: "info.circle") }
                    .help("Über Socket Manager").accessibilityLabel("Informationen über Socket Manager")
                Button { model.openSettings?() } label: {
                    Image(systemName: "gearshape")
                }
                .help("Einstellungen (⌘,)").keyboardShortcut(",")
                .accessibilityLabel("Einstellungen öffnen")
                Button("Beenden") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }
            .buttonStyle(.borderless).padding(12)
        }
        .frame(width: 512)
        .onAppear { searchFocused = true }
        .background { Button("") { searchFocused = true }.keyboardShortcut("f").hidden() }
    }

    private var listHeight: CGFloat {
        min(model.pendingStop == nil ? 384 : 256, max(144, CGFloat(model.filteredEntries.count) * 112))
    }

    @ViewBuilder private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: model.isLoading ? "network" : "checkmark.circle").font(.title2).foregroundStyle(.secondary)
            Text(model.isLoading && !model.hasLoaded ? "Sockets werden geladen …" : model.scanError != nil ? "Übersicht nicht verfügbar" : !model.query.isEmpty ? "Keine Treffer" : model.showAll ? "Keine lauschenden TCP-Sockets" : "Keine Dev-Server gefunden")
                .font(.headline)
            Text(!model.query.isEmpty ? "Versuche einen anderen Port oder Prozessnamen." : !model.showAll ? "„Alle TCP“ zeigt auch andere Dienste." : "Hier erscheinen lokale Dienste, sobald sie auf einem Port lauschen.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity)
    }
}

private struct SocketRow: View {
    let entry: SocketEntry
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(String(entry.port)).font(.system(.body, design: .monospaced).weight(.semibold))
                        .foregroundStyle(InterfaceColors.port)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(InterfaceColors.port.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    Text(entry.name).font(.body.weight(.semibold)).foregroundStyle(InterfaceColors.application)
                        .lineLimit(1).truncationMode(.middle)
                }
                Button { model.open(entry) } label: {
                    (Text("\(entry.url.scheme ?? "http")://\(entry.host.contains(":") ? "[\(entry.host)]" : entry.host):")
                        .foregroundColor(InterfaceColors.link)
                     + Text(String(entry.port)).foregroundColor(InterfaceColors.port))
                        .font(.system(.body, design: .monospaced)).underline()
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(entry.url.absoluteString) im Browser öffnen")
                .accessibilityLabel("\(entry.url.absoluteString) im Browser öffnen")
                Text(entry.project.isEmpty ? entry.cwd.isEmpty || entry.cwd == "/" ? "Kein Projekt erkannt" : entry.cwd : entry.project)
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 8) {
                    Text("PID \(entry.pid) · \(entry.uptime)")
                    Label(entry.isPublic ? "Alle Interfaces" : "\(entry.host)", systemImage: entry.isPublic ? "network" : "lock")
                        .lineLimit(1)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help("\(entry.command)\n\(entry.cwd)\n\(entry.addresses.joined(separator: ", "))")
            Button { model.requestStop(entry) } label: {
                if model.isStopping(entry) { ProgressView().controlSize(.small).frame(width: 64) }
                else { Text("Beenden").frame(minWidth: 64) }
            }
            .buttonStyle(.bordered)
            .disabled(!entry.canStop || model.isStopping(entry))
            .help(entry.canStop ? "Prozess beenden – anschließend Enter zum Bestätigen" : "Prozess geschützt / keine Berechtigung")
            .accessibilityLabel("\(entry.name) auf Port \(entry.port) beenden")
            Menu {
                Button("Im Browser öffnen") { model.open(entry) }
                Button("Mit HTTPS öffnen") { model.open(entry, secure: true) }
                Button("URL kopieren") { model.copy(entry) }
                Button("Projekt im Finder zeigen") { model.reveal(entry) }.disabled(entry.cwd.isEmpty)
                Divider()
                Button("\(entry.container != nil ? "Container" : "Prozess") beenden …", role: .destructive) {
                    model.requestStop(entry)
                }.disabled(!entry.canStop || model.isStopping(entry))
                Button("Sofort beenden …", role: .destructive) {
                    model.requestStop(entry, force: true)
                }.disabled(!entry.canStop || model.isStopping(entry))
                if !entry.canStop {
                    Text(entry.isDocker ? "Docker-Dienst geschützt" : "Prozess geschützt / keine Berechtigung")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Aktionen für Port \(entry.port)")
            .accessibilityLabel("Aktionen für Port \(entry.port), \(entry.name)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}
