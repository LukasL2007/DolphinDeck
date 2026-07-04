import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var bluetooth: FlipperBluetoothManager

    var body: some View {
        Form {
            Section("Verbindung") {
                Toggle("Automatisch wiederverbinden", isOn: $bluetooth.keepConnected)
                Button("Gespeicherten Flipper vergessen", role: .destructive) {
                    bluetooth.forgetDevice()
                }
            }

            Section("Hintergrundbetrieb") {
                Label("Bluetooth-Zentrale aktiviert", systemImage: "checkmark.shield.fill")
                Text("iOS darf die App für Bluetooth-Ereignisse aufwecken. Nach manuellem Beenden der App ist keine Wiederverbindung möglich, bis sie erneut geöffnet wurde.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Dolphin Deck") {
                LabeledContent("Version", value: "1.1.0")
                Link(
                    "Flipper RPC – Open Source",
                    destination: URL(string: "https://github.com/flipperdevices/flipperzero-protobuf")!)
            }
        }
        .navigationTitle("Einstellungen")
    }
}
