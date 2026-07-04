import Security
import SwiftUI
import UniformTypeIdentifiers

struct UFBTBuilderView: View {
    @EnvironmentObject private var bluetooth: FlipperBluetoothManager

    @AppStorage("ufbtBuildServerURL")
    private var serverURL = ""
    @AppStorage("ufbtDestinationFolder")
    private var destinationFolder = "/ext/apps/Tools"

    @State private var accessToken = UFBTTokenStore.load()
    @State private var sourceProject: UFBTSourceProject?
    @State private var showFolderImporter = false
    @State private var isWorking = false
    @State private var statusMessage: String?
    @State private var buildLog: String?
    @State private var installedPath: String?
    @State private var overwriteExisting = true

    var body: some View {
        Form {
            Section("Quellcode") {
                Button {
                    showFolderImporter = true
                } label: {
                    Label("uFBT-Projektordner auswählen", systemImage: "folder.badge.plus")
                }

                if let sourceProject {
                    LabeledContent("Projekt", value: sourceProject.name)
                    LabeledContent("Dateien", value: "\(sourceProject.files.count)")
                    LabeledContent(
                        "Quellcodegröße",
                        value: ByteCountFormatter.string(
                            fromByteCount: Int64(sourceProject.totalBytes),
                            countStyle: .file))
                    Label("application.fam gefunden", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                } else {
                    Text("Wähle den Ordner aus, in dem die application.fam der Flipper-App liegt.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("uFBT Build-Host") {
                TextField("https://build.example.com", text: $serverURL)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()

                SecureField("Zugriffstoken (optional)", text: $accessToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: accessToken) { _, newValue in
                        UFBTTokenStore.save(newValue)
                    }

                Text("Für unterwegs sollte der Build-Host über HTTPS oder ein privates VPN wie Tailscale erreichbar sein.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Installation auf dem Flipper") {
                Picker("Ziel", selection: $destinationFolder) {
                    Text("Tools").tag("/ext/apps/Tools")
                    Text("GPIO").tag("/ext/apps/GPIO")
                    Text("Games").tag("/ext/apps/Games")
                    Text("NFC").tag("/ext/apps/NFC")
                    Text("Sub-GHz").tag("/ext/apps/Sub-GHz")
                    Text("Bluetooth").tag("/ext/apps/Bluetooth")
                }
                TextField("Eigener Zielordner", text: $destinationFolder)
                    .font(.caption.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Toggle("Vorhandene FAP ersetzen", isOn: $overwriteExisting)

                Button {
                    Task { await buildAndInstall() }
                } label: {
                    Label("Mit uFBT bauen und installieren", systemImage: "hammer.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(
                    sourceProject == nil ||
                    normalizedServerURL == nil ||
                    !bluetooth.rpcReady ||
                    isWorking)
            }

            if let installedPath {
                Section("Installiert") {
                    Text(installedPath)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
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

            if let buildLog, !buildLog.isEmpty {
                Section("uFBT-Ausgabe") {
                    Text(buildLog)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("uFBT Build & Install")
        .overlay {
            if isWorking {
                ProgressView("Quellcode wird gebaut …")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .fileImporter(
            isPresented: $showFolderImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            Task { await importSourceFolder(result) }
        }
    }

    private var normalizedServerURL: URL? {
        var value = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        guard let baseURL = URL(string: value),
              ["http", "https"].contains(baseURL.scheme?.lowercased() ?? "") else {
            return nil
        }
        return baseURL.appendingPathComponent("build")
    }

    private var normalizedDestinationFolder: String {
        var value = destinationFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.hasPrefix("/") { value = "/" + value }
        while value.count > 1, value.hasSuffix("/") { value.removeLast() }
        return value
    }

    private func importSourceFolder(_ result: Result<[URL], Error>) async {
        do {
            guard let folder = try result.get().first else { return }
            let access = folder.startAccessingSecurityScopedResource()
            defer { if access { folder.stopAccessingSecurityScopedResource() } }
            sourceProject = try UFBTSourceProject.load(from: folder)
            statusMessage = "Quellcodeordner ist bereit."
            buildLog = nil
            installedPath = nil
        } catch {
            sourceProject = nil
            statusMessage = "Ordner konnte nicht gelesen werden: \(error.localizedDescription)"
        }
    }

    private func buildAndInstall() async {
        guard let sourceProject, let endpoint = normalizedServerURL else { return }
        guard bluetooth.rpcReady else {
            statusMessage = "Der Flipper ist nicht verbunden oder RPC ist nicht bereit."
            return
        }

        isWorking = true
        defer { isWorking = false }
        statusMessage = "Projekt wird an den uFBT-Build-Host übertragen."
        buildLog = nil
        installedPath = nil

        do {
            let requestBody = try JSONEncoder().encode(UFBTBuildRequest(
                projectName: sourceProject.name,
                files: sourceProject.files))
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.httpBody = requestBody
            request.timeoutInterval = 600
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if !accessToken.isEmpty {
                request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            }

            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 600
            configuration.timeoutIntervalForResource = 900
            let (data, response) = try await URLSession(configuration: configuration)
                .data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw UFBTBuildError.invalidResponse
            }

            let decoded = try JSONDecoder().decode(UFBTBuildResponse.self, from: data)
            buildLog = decoded.log
            guard (200..<300).contains(http.statusCode), decoded.success,
                  let fap = decoded.fap, !fap.isEmpty,
                  let fileName = decoded.fileName else {
                throw UFBTBuildError.server(decoded.message ?? "Der uFBT-Build ist fehlgeschlagen.")
            }

            let folder = normalizedDestinationFolder
            guard folder.hasPrefix("/ext/apps/") else {
                throw UFBTBuildError.server("Der Zielordner muss unter /ext/apps liegen.")
            }
            try? await bluetooth.createDirectory(at: folder)
            let remotePath = folder + "/" + sanitizedFileName(fileName)
            if overwriteExisting {
                try? await bluetooth.deleteStorageItem(at: remotePath, recursively: false)
            }
            try await bluetooth.uploadFile(data: fap, to: remotePath)
            installedPath = remotePath
            statusMessage = "\(fileName) wurde gebaut und auf dem Flipper installiert."
        } catch {
            statusMessage = "uFBT fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    private func sanitizedFileName(_ rawValue: String) -> String {
        let value = rawValue
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
        return value.lowercased().hasSuffix(".fap") ? value : value + ".fap"
    }
}

private struct UFBTSourceProject: Sendable {
    let name: String
    let files: [UFBTSourceFile]
    let totalBytes: Int

    static func load(from root: URL) throws -> Self {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            throw UFBTBuildError.unreadableFolder
        }

        let excludedFolders: Set<String> = [".git", ".ufbt", "build", "dist", "DerivedData"]
        var files: [UFBTSourceFile] = []
        var totalBytes = 0
        var foundManifest = false

        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: keys)
            if values.isDirectory == true {
                if excludedFolders.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true else { continue }

            let relativePath = String(url.path.dropFirst(root.path.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !relativePath.isEmpty else { continue }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            totalBytes += data.count
            guard totalBytes <= 12_000_000, files.count < 1_000 else {
                throw UFBTBuildError.projectTooLarge
            }
            if url.lastPathComponent == "application.fam" {
                foundManifest = true
            }
            files.append(UFBTSourceFile(path: relativePath, data: data))
        }

        guard foundManifest else { throw UFBTBuildError.missingManifest }
        guard !files.isEmpty else { throw UFBTBuildError.unreadableFolder }
        return UFBTSourceProject(
            name: root.lastPathComponent,
            files: files.sorted { $0.path < $1.path },
            totalBytes: totalBytes)
    }
}

private struct UFBTSourceFile: Codable, Sendable {
    let path: String
    let data: Data
}

private struct UFBTBuildRequest: Encodable {
    let projectName: String
    let files: [UFBTSourceFile]
}

private struct UFBTBuildResponse: Decodable {
    let success: Bool
    let message: String?
    let fileName: String?
    let fap: Data?
    let log: String?
}

private enum UFBTBuildError: LocalizedError {
    case unreadableFolder
    case missingManifest
    case projectTooLarge
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .unreadableFolder: "Der Quellcodeordner ist leer oder nicht lesbar."
        case .missingManifest: "Im Projekt wurde keine application.fam gefunden."
        case .projectTooLarge: "Das Projekt überschreitet 12 MB oder 1.000 Dateien."
        case .invalidResponse: "Der Build-Host hat keine gültige Antwort geliefert."
        case .server(let message): message
        }
    }
}

private enum UFBTTokenStore {
    private static let service = "de.lukasleipacher.DolphinDeck"
    private static let account = "ufbt-build-token"

    static func load() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func save(_ value: String) {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(baseQuery as CFDictionary)
        guard !value.isEmpty, let data = value.data(using: .utf8) else { return }
        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }
}
