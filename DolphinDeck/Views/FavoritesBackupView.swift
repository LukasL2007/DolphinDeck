import SwiftUI

struct FavoritesBackupView: View {
    @EnvironmentObject private var bluetooth: FlipperBluetoothManager
    @State private var restoreCandidate: FavoriteBackup?

    var body: some View {
        List {
            Section {
                Button {
                    bluetooth.createFavoriteBackup()
                } label: {
                    Label("Neue Version sichern", systemImage: "externaldrive.badge.plus")
                }

                LabeledContent("Automatische Sicherung", value: "Alle 6 Stunden vor Änderungen")
                LabeledContent("Aufbewahrung", value: "30 Versionen")
            } footer: {
                Text("Zusätzlich wird weiterhin der interne qFlipper-Backup-Spiegel aktualisiert.")
            }

            Section("Versionen") {
                if bluetooth.favoriteBackups.isEmpty {
                    ContentUnavailableView(
                        "Noch keine Backups",
                        systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                } else {
                    ForEach(bluetooth.favoriteBackups) { backup in
                        Button {
                            restoreCandidate = backup
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(backup.createdAt.formatted(
                                        date: .abbreviated,
                                        time: .shortened))
                                        .foregroundStyle(.primary)
                                    Text("\(backup.entryCount) Einträge")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                ShareLink(item: backup.url) {
                                    Image(systemName: "square.and.arrow.up")
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                bluetooth.deleteFavoriteBackup(backup)
                            } label: {
                                Label("Löschen", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Favoriten-Backups")
        .confirmationDialog(
            "Diese Version wiederherstellen?",
            isPresented: Binding(
                get: { restoreCandidate != nil },
                set: { if !$0 { restoreCandidate = nil } }),
            titleVisibility: .visible
        ) {
            Button("Auf Flipper wiederherstellen") {
                guard let restoreCandidate else { return }
                Task { await bluetooth.restoreFavoriteBackup(restoreCandidate) }
                self.restoreCandidate = nil
            }
            Button("Abbrechen", role: .cancel) {
                restoreCandidate = nil
            }
        }
    }
}
