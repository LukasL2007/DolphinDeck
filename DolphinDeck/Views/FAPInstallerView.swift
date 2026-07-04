import SwiftUI
import UniformTypeIdentifiers

struct FAPInstallerView: View {
    @EnvironmentObject private var bluetooth: FlipperBluetoothManager

    @State private var destinationFolder = "/ext/apps/Tools"
    @State private var downloadURL = ""
    @State private var showImporter = false
    @State private var isInstalling = false
    @State private var statusMessage: String?
    @State private var installedPath: String?
    @State private var overwriteExisting = true

    private let favoritesReleaseURL =
        "https://github.com/LukasL2007/FlipperFileFavorites/releases/latest/download/flipper_file_favorites.fap"

    private var normalizedDestinationFolder: String {
        let trimmed = destinationFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/ext/apps/Tools" }
        let withLeadingSlash = trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
        return withLeadingSlash.hasSuffix("/") ? String(withLeadingSlash.dropLast()) : withLeadingSlash
    }

    private var installedFolderPath: String? {
        guard let installedPath else { return nil }
        let folder = (installedPath as NSString).deletingLastPathComponent
        return folder.isEmpty ? nil : folder
    }

    var body: some View {
        Form {
            Section {
                Button {
                    Task {
                        await installFromURL(
                            favoritesReleaseURL,
                            preferredName: "flipper_file_favorites.fap")
                    }
                } label: {
                    Label(
                        "File Favorites installieren/aktualisieren",
                        systemImage: "star.square.on.square.fill")
                }
                Text("Lädt die aktuelle Release-Version aus deinem GitHub-Repository.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Ein-Klick-Installation")
            }

            Section("Allgemeiner FAP-Installer") {
                Button {
                    showImporter = true
                } label: {
                    Label("Lokale .fap auswählen", systemImage: "doc.badge.plus")
                }

                TextField("Direkte HTTPS-Adresse", text: $downloadURL)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()

                Button {
                    Task { await installFromURL(downloadURL, preferredName: nil) }
                } label: {
                    Label("Von URL installieren", systemImage: "arrow.down.circle")
                }
                .disabled(URL(string: downloadURL)?.scheme?.lowercased() != "https")
            }

            Section("Zielordner") {
                Picker("Kategorie", selection: $destinationFolder) {
                    Text("Tools").tag("/ext/apps/Tools")
                    Text("GPIO").tag("/ext/apps/GPIO")
                    Text("Games").tag("/ext/apps/Games")
                    Text("NFC").tag("/ext/apps/NFC")
                    Text("Sub-GHz").tag("/ext/apps/Sub-GHz")
                    Text("Bluetooth").tag("/ext/apps/Bluetooth")
                }
                TextField("Eigener Zielpfad", text: $destinationFolder)
                    .font(.caption.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Toggle("Vorhandene FAP ersetzen", isOn: $overwriteExisting)
            }

            if let installedPath {
                Section("Installiert") {
                    Text(installedPath)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)

                    if let installedFolderPath {
                        NavigationLink {
                            FileManagerView(path: installedFolderPath)
                        } label: {
                            Label("Im Dateimanager öffnen", systemImage: "folder")
                        }
                    }

                    Button {
                        Task { await bluetooth.launchFile(at: installedPath) }
                    } label: {
                        Label("App auf dem Flipper starten", systemImage: "play.fill")
                    }
                }
            }

            if let statusMessage {
                Section("Status") {
                    Text(statusMessage)
                }
            }

            Section {
                Label(
                    "Installiere nur FAP-Dateien aus Quellen, denen du vertraust.",
                    systemImage: "exclamationmark.shield.fill")
                    .foregroundStyle(.orange)
            }
        }
        .navigationTitle("FAP-Installer")
        .overlay {
            if isInstalling {
                ProgressView("FAP wird übertragen …")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            Task { await installLocal(result) }
        }
    }

    private func installLocal(_ result: Result<[URL], Error>) async {
        do {
            guard let url = try result.get().first else { return }
            guard url.pathExtension.lowercased() == "fap" else {
                statusMessage = "Die ausgewählte Datei hat keine .fap-Endung."
                return
            }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            try await install(data: data, name: url.lastPathComponent)
        } catch {
            statusMessage = "Import fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    private func installFromURL(
        _ value: String,
        preferredName: String?
    ) async {
        guard let url = URL(string: value), url.scheme?.lowercased() == "https" else {
            statusMessage = "Bitte eine gültige HTTPS-Adresse eingeben."
            return
        }
        isInstalling = true
        defer { isInstalling = false }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            let responseName = response.suggestedFilename
            let name = preferredName ?? responseName ?? url.lastPathComponent
            guard name.lowercased().hasSuffix(".fap") else {
                statusMessage = "Die heruntergeladene Datei ist keine FAP."
                return
            }
            try await install(data: data, name: name)
        } catch {
            statusMessage = "Download fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    private func install(data: Data, name: String) async throws {
        isInstalling = true
        defer { isInstalling = false }
        guard bluetooth.rpcReady else {
            statusMessage = "Der Flipper ist nicht verbunden oder RPC ist nicht bereit."
            return
        }
        let folder = normalizedDestinationFolder
        try await bluetooth.createDirectory(at: folder)
        let path = folder + "/" + name
        let existingItems = try await bluetooth.listDirectory(at: folder)
        if existingItems.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            if overwriteExisting {
                try? await bluetooth.deleteStorageItem(at: path, recursively: false)
            } else {
                installedPath = path
                statusMessage = "\(name) liegt bereits im Zielordner."
                return
            }
        }
        try await bluetooth.uploadFile(data: data, to: path)
        installedPath = path
        statusMessage = "\(name) wurde erfolgreich installiert."
    }
}
