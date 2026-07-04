import AppIntents
import UniformTypeIdentifiers

struct ConnectFlipperIntent: AppIntent {
    static let title: LocalizedStringResource = "Mit Flipper verbinden"
    static let description = IntentDescription("Sucht den gespeicherten Flipper und stellt die Bluetooth-Verbindung her.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = await MainActor.run {
            let manager = FlipperBluetoothManager.shared
            if manager.isConnected {
                return "\(manager.snapshot.name) ist bereits verbunden."
            }
            manager.reconnect()
            return "Die Verbindung zum Flipper wird hergestellt."
        }
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}

struct FlipperStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Flipper-Status"
    static let description = IntentDescription("Gibt Verbindung, Akku und Firmware des Flippers zurück.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let message = await MainActor.run {
            let manager = FlipperBluetoothManager.shared
            guard manager.isConnected else {
                return "Der Flipper ist nicht verbunden."
            }
            let battery = manager.snapshot.batteryLevel.map { "\($0) Prozent Akku" } ?? "Akkustand unbekannt"
            return "\(manager.snapshot.name) ist verbunden, \(battery), Firmware \(manager.snapshot.firmware)."
        }
        return .result(value: message, dialog: IntentDialog(stringLiteral: message))
    }
}

struct FindFlipperIntent: AppIntent {
    static let title: LocalizedStringResource = "Flipper finden"
    static let description = IntentDescription("Löst am verbundenen Flipper Licht, Ton und Vibration aus.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let manager = await FlipperBluetoothManager.shared
        guard await manager.rpcReady else {
            return .result(dialog: "Der Flipper ist nicht verbunden oder RPC ist noch nicht bereit.")
        }
        await manager.playAlert()
        return .result(dialog: "Der Flipper-Alarm wurde ausgelöst.")
    }
}

enum ShortcutRemoteKey: String, AppEnum {
    case up
    case down
    case left
    case right
    case ok
    case back

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Flipper-Taste"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .up: "Hoch",
        .down: "Runter",
        .left: "Links",
        .right: "Rechts",
        .ok: "OK",
        .back: "Zurück",
    ]

    var remoteButton: RemoteButton {
        switch self {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .ok: .ok
        case .back: .back
        }
    }
}

struct PressFlipperButtonIntent: AppIntent {
    static let title: LocalizedStringResource = "Flipper-Taste drücken"
    static let description = IntentDescription("Sendet eine Taste an den verbundenen Flipper.")
    static let openAppWhenRun = false

    @Parameter(title: "Taste")
    var key: ShortcutRemoteKey

    @Parameter(title: "Lange drücken", default: false)
    var longPress: Bool

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let manager = await FlipperBluetoothManager.shared
        guard await manager.rpcReady else {
            return .result(dialog: "Der Flipper ist nicht verbunden oder RPC ist noch nicht bereit.")
        }
        await manager.press(key.remoteButton, long: longPress)
        return .result(dialog: "Die Taste \(key.remoteButton.title) wurde gesendet.")
    }
}

struct SendFileToFlipperIntent: AppIntent {
    static let title: LocalizedStringResource = "Datei an Flipper senden"
    static let description = IntentDescription(
        "Überträgt eine einzelne Datei aus Dateien oder einer vorherigen Kurzbefehle-Aktion auf den Flipper.")
    static let openAppWhenRun = false

    @Parameter(title: "Datei")
    var file: IntentFile

    @Parameter(
        title: "Zielordner",
        description: "Vollständiger Ordnerpfad auf dem Flipper.",
        default: "/ext/dolphin_deck_uploads")
    var destinationFolder: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let manager = await FlipperBluetoothManager.shared
        if !(await manager.isConnected) {
            await manager.reconnect()
        }

        for _ in 0..<30 {
            if await manager.rpcReady { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        guard await manager.rpcReady else {
            return .result(dialog: "Der Flipper konnte nicht rechtzeitig verbunden werden.")
        }

        let folder = normalizedFlipperFolder(destinationFolder)
        guard folder.hasPrefix("/ext") || folder.hasPrefix("/int") else {
            return .result(dialog: "Der Zielordner muss unter /ext oder /int liegen.")
        }
        let filename = sanitizedFlipperFilename(file.filename)
        guard !filename.isEmpty else {
            return .result(dialog: "Die Datei hat keinen gültigen Namen.")
        }

        do {
            try? await manager.createDirectory(at: folder)
            let target = folder + "/" + filename
            try await manager.uploadFile(data: file.data, to: target)
            return .result(dialog: "„\(filename)“ wurde nach \(folder) übertragen.")
        } catch {
            return .result(dialog: IntentDialog(
                stringLiteral: "Übertragung fehlgeschlagen: \(error.localizedDescription)"))
        }
    }
}

private func normalizedFlipperFolder(_ rawValue: String) -> String {
    var path = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if !path.hasPrefix("/") { path = "/" + path }
    while path.count > 1, path.hasSuffix("/") {
        path.removeLast()
    }
    return path
}

private func sanitizedFlipperFilename(_ rawValue: String) -> String {
    rawValue
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "\\", with: "_")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

struct FavoriteShortcutEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Flipper-Favorit"
    static let defaultQuery = FavoriteShortcutQuery()

    let id: String
    let name: String
    let category: Int

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(id)")
    }
}

struct FavoriteShortcutQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [FavoriteShortcutEntity] {
        cachedFavorites().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [FavoriteShortcutEntity] {
        cachedFavorites().filter {
            $0.name.localizedCaseInsensitiveContains(string) ||
                $0.id.localizedCaseInsensitiveContains(string)
        }
    }

    func suggestedEntities() async throws -> [FavoriteShortcutEntity] {
        cachedFavorites()
    }

    private func cachedFavorites() -> [FavoriteShortcutEntity] {
        guard let text = UserDefaults.standard.string(forKey: FileFavoritesDatabase.cacheKey),
              let database = try? FileFavoritesDatabase(text: text) else {
            return []
        }
        return database.entries.map {
            FavoriteShortcutEntity(
                id: $0.path,
                name: $0.name,
                category: $0.category)
        }
        .sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}

struct OpenFlipperFavoriteIntent: AppIntent {
    static let title: LocalizedStringResource = "Flipper-Favorit öffnen"
    static let description = IntentDescription(
        "Öffnet eine Datei aus Flipper File Favorites in ihrer Original-App.")
    static let openAppWhenRun = false

    @Parameter(title: "Favorit")
    var favorite: FavoriteShortcutEntity

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let manager = await FlipperBluetoothManager.shared
        if !(await manager.isConnected) {
            await manager.reconnect()
        }

        for _ in 0..<24 {
            if await manager.rpcReady { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        guard await manager.rpcReady else {
            return .result(dialog: "Der Flipper konnte nicht rechtzeitig verbunden werden.")
        }
        await manager.launchFile(at: favorite.id)
        return .result(dialog: "„\(favorite.name)“ wurde auf dem Flipper geöffnet.")
    }
}

struct DolphinDeckShortcuts: AppShortcutsProvider {
    static let shortcutTileColor: ShortcutTileColor = .orange

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ConnectFlipperIntent(),
            phrases: [
                "\(.applicationName) mit Flipper verbinden",
                "Verbinde meinen Flipper mit \(.applicationName)",
            ],
            shortTitle: "Flipper verbinden",
            systemImageName: "link")
        AppShortcut(
            intent: FlipperStatusIntent(),
            phrases: [
                "Flipper Status mit \(.applicationName)",
                "Wie geht es meinem Flipper in \(.applicationName)",
            ],
            shortTitle: "Flipper-Status",
            systemImageName: "battery.75percent")
        AppShortcut(
            intent: FindFlipperIntent(),
            phrases: [
                "Finde meinen Flipper mit \(.applicationName)",
                "Flipper Alarm mit \(.applicationName)",
            ],
            shortTitle: "Flipper finden",
            systemImageName: "bell.and.waves.left.and.right.fill")
        AppShortcut(
            intent: OpenFlipperFavoriteIntent(),
            phrases: [
                "\(.applicationName) Flipper-Favorit öffnen",
                "Öffne einen Flipper-Favoriten mit \(.applicationName)",
            ],
            shortTitle: "Favorit öffnen",
            systemImageName: "star.fill")
        AppShortcut(
            intent: SendFileToFlipperIntent(),
            phrases: [
                "Datei mit \(.applicationName) an den Flipper senden",
                "\(.applicationName) Datei übertragen",
            ],
            shortTitle: "Datei senden",
            systemImageName: "doc.badge.arrow.up")
    }
}
