import SwiftUI

struct InfoView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: BrandIcon.image(size: 96)).accessibilityHidden(true)
            VStack(spacing: 4) {
                Text("Socket Manager").font(.title2.weight(.semibold))
                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1.0")")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text("Lokale Dienste im Blick.\nDirekt aus deiner Menüleiste öffnen und beenden.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Divider()
            VStack(spacing: 8) {
                Text("Entwickelt von Samuel Heinrich").font(.body.weight(.medium))
                Link("info@samuel-heinrich.ch", destination: URL(string: "mailto:info@samuel-heinrich.ch")!)
                Link("Quellcode auf GitHub", destination: URL(string: "https://github.com/samuelheinrich/socketmanager")!)
            }
        }
        .padding(32).frame(width: 384)
    }
}
