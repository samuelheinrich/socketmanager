import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Allgemein") {
                Toggle("Beim Anmelden starten", isOn: Binding(
                    get: { model.loginStatus == .enabled || model.loginStatus == .requiresApproval },
                    set: { model.setLaunchAtLogin($0) }
                ))
                if model.loginStatus == .requiresApproval {
                    Button("In den Systemeinstellungen erlauben …") { SMAppService.openSystemSettingsLoginItems() }
                }
                Picker("Aktualisieren alle", selection: $model.refreshInterval) {
                    Text("3 Sekunden").tag(3.0)
                    Text("5 Sekunden").tag(5.0)
                    Text("10 Sekunden").tag(10.0)
                }
                Text("Die Liste aktualisiert sich nur, solange das Menü geöffnet ist.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Socket-Übersicht") {
                Text("Zeigt lauschende TCP-Sockets, die dein Benutzer lesen darf. „Dev-Server“ filtert nach typischen Ports und Prozessnamen.")
                Text("Öffnen verwendet HTTP, für Ports 443 und 8443 HTTPS. Über das Aktionsmenü kannst du HTTPS auch für andere Ports wählen.")
                    .foregroundStyle(.secondary)
                Text("Beenden stoppt den gesamten Prozess, inklusive seiner anderen Ports. Docker-Dienste werden nur über den zugeordneten Container beendet.")
                    .foregroundStyle(.secondary)
            }
            Section("Info") {
                Text("Socket Manager · Samuel Heinrich")
                Link("info@samuel-heinrich.ch", destination: URL(string: "mailto:info@samuel-heinrich.ch")!)
                Button("Über Socket Manager …") { model.openInfo?() }
            }
            if let message = model.message {
                Section { Text(message).textSelection(.enabled) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 448, height: 512)
        .padding(.vertical, 8)
    }
}
