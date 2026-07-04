import SwiftUI

struct MoreView: View {
    @EnvironmentObject private var bluetooth: FlipperBluetoothManager
    @State private var pingResult: String?
    @State private var showRebootConfirmation = false

    var body: some View {
        List {
            Section("Dateien") {
                NavigationLink {
                    FileManagerView()
                } label: {
                    MoreMenuRow("Dateimanager", systemImage: "folder")
                }
                NavigationLink {
                    FavoritesBackupView()
                } label: {
                    MoreMenuRow(
                        "Versionierte Favoriten-Backups",
                        systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                }
                NavigationLink {
                    FAPInstallerView()
                } label: {
                    MoreMenuRow(
                        "FAP-Installer & Updates",
                        systemImage: "shippingbox.and.arrow.backward")
                }
                NavigationLink {
                    UFBTBuilderView()
                } label: {
                    MoreMenuRow("uFBT Build & Install", systemImage: "hammer.fill")
                }
            }

            Section("Diagnose") {
                NavigationLink {
                    DeviceInfoView()
                } label: {
                    MoreMenuRow(
                        "Geräteinformationen",
                        systemImage: "list.bullet.rectangle")
                }

                Button {
                    Task { pingResult = await bluetooth.runPing() }
                } label: {
                    MoreMenuRow(
                        "Verbindung testen",
                        systemImage: "waveform.path.ecg")
                }
                .disabled(!bluetooth.rpcReady)

                if let pingResult {
                    Text(pingResult)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Dolphin Deck") {
                NavigationLink {
                    DolphinDeckBridgeView()
                } label: {
                    MoreMenuRow(
                        "Flipper-App & iPhone-Bridge",
                        systemImage: "point.3.connected.trianglepath.dotted")
                }
                NavigationLink {
                    AutomationsView()
                } label: {
                    MoreMenuRow(
                        "Abläufe & Kurzbefehle",
                        systemImage: "bolt.fill")
                }
                NavigationLink {
                    SettingsView()
                } label: {
                    MoreMenuRow("Einstellungen", systemImage: "gearshape.fill")
                }
            }

            Section("Flipper") {
                Button(role: .destructive) {
                    showRebootConfirmation = true
                } label: {
                    Label("Flipper neu starten", systemImage: "power")
                }
                .disabled(!bluetooth.rpcReady)
            }
        }
        .navigationTitle("Mehr")
        .tint(.orange)
        .confirmationDialog(
            "Flipper wirklich neu starten?",
            isPresented: $showRebootConfirmation,
            titleVisibility: .visible
        ) {
            Button("Neu starten", role: .destructive) {
                Task { await bluetooth.rebootFlipper() }
            }
            Button("Abbrechen", role: .cancel) {}
        }
    }
}

private struct MoreMenuRow: View {
    let title: LocalizedStringKey
    let systemImage: String

    init(_ title: LocalizedStringKey, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.orange)
                .frame(width: 24)
            Text(title)
                .foregroundStyle(.primary)
        }
        .contentShape(Rectangle())
    }
}
