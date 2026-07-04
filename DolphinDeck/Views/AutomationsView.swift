import SwiftUI

struct AutomationsView: View {
    @EnvironmentObject private var bluetooth: FlipperBluetoothManager
    @State private var actionMessage: String?
    @State private var isRunning = false

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: bluetooth.rpcReady
                          ? "bolt.horizontal.circle.fill"
                          : "bolt.slash.circle")
                        .font(.system(size: 34))
                        .foregroundStyle(bluetooth.rpcReady ? .green : .orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(bluetooth.rpcReady ? "Automationen bereit" : "Flipper verbinden")
                            .font(.headline)
                        Text(bluetooth.rpcReady
                             ? "\(bluetooth.snapshot.name) kann Aktionen direkt ausführen."
                             : "Die Aktionen werden aktiv, sobald RPC bereit ist.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Sofort ausführen") {
                Button {
                    Task { await testConnection() }
                } label: {
                    AutomationActionRow(
                        icon: "waveform.path.ecg",
                        color: .blue,
                        title: "Verbindung prüfen",
                        subtitle: "RPC, Gerätename und Akku aktualisieren")
                }

                Button {
                    bluetooth.createFavoriteBackup()
                    actionMessage = "File Favorites wurden lokal gesichert."
                } label: {
                    AutomationActionRow(
                        icon: "externaldrive.badge.icloud",
                        color: .orange,
                        title: "Favoriten sichern",
                        subtitle: "\(bluetooth.favoritesDatabase.entries.count) Einträge versioniert sichern")
                }

                Button {
                    Task {
                        isRunning = true
                        await bluetooth.playAlert()
                        actionMessage = bluetooth.lastRPCMessage
                        isRunning = false
                    }
                } label: {
                    AutomationActionRow(
                        icon: "bell.and.waves.left.and.right.fill",
                        color: .pink,
                        title: "Flipper finden",
                        subtitle: "Ton, Licht und Vibration auslösen")
                }
                .disabled(!bluetooth.rpcReady)

                Button {
                    Task {
                        isRunning = true
                        await bluetooth.unlockFlipper()
                        actionMessage = bluetooth.lastRPCMessage
                        isRunning = false
                    }
                } label: {
                    AutomationActionRow(
                        icon: "lock.open.fill",
                        color: .orange,
                        title: "Flipper entsperren",
                        subtitle: "Offizielle RPC-Entsperrung ohne PIN-Speicherung")
                }
                .disabled(
                    !bluetooth.rpcReady ||
                    bluetooth.isUnlockingFlipper ||
                    bluetooth.activeRemoteCommand != nil ||
                    !bluetooth.pendingRemoteCommands.isEmpty)
            }

            Section("Automatisch") {
                Toggle(isOn: $bluetooth.keepConnected) {
                    Label("Verbindung halten", systemImage: "link")
                }
                LabeledContent {
                    Text("Aktiv")
                        .foregroundStyle(.green)
                } label: {
                    Label("Versionierte Backups", systemImage: "clock.arrow.circlepath")
                }
                NavigationLink {
                    FavoritesBackupView()
                } label: {
                    Label("Backup-Verlauf öffnen", systemImage: "archivebox")
                }
            }

            Section {
                Label("Flipper verbinden", systemImage: "antenna.radiowaves.left.and.right")
                Label("Flipper-Status", systemImage: "info.circle")
                Label("Flipper-Favorit öffnen", systemImage: "star.fill")
                Label("Favorit oder Signal ausführen", systemImage: "antenna.radiowaves.left.and.right")
                Label("Virtuelle Taste senden", systemImage: "gamecontroller.fill")
                Label("Datei an Flipper senden", systemImage: "doc.badge.arrow.up")
            } header: {
                Text("Apple Kurzbefehle")
            } footer: {
                Text("Diese Aktionen erscheinen in Kurzbefehle und lassen sich in persönliche Automationen einbauen.")
            }

            if let actionMessage {
                Section("Letzte Aktion") {
                    Text(actionMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Abläufe")
        .overlay {
            if isRunning {
                ProgressView("Aktion wird ausgeführt …")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .tint(.orange)
    }

    private func testConnection() async {
        guard bluetooth.rpcReady else {
            actionMessage = "RPC ist noch nicht bereit."
            return
        }
        isRunning = true
        actionMessage = await bluetooth.runPing()
        isRunning = false
    }
}

private struct AutomationActionRow: View {
    let icon: String
    let color: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .font(.headline)
                .frame(width: 38, height: 38)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "play.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
        .contentShape(Rectangle())
    }
}
