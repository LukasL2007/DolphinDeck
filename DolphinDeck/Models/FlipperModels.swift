@preconcurrency import CoreBluetooth
import Foundation

enum FlipperConnectionState: Equatable {
    case bluetoothUnavailable
    case idle
    case scanning
    case connecting
    case connected
    case reconnecting

    var title: String {
        switch self {
        case .bluetoothUnavailable: "Bluetooth nicht verfügbar"
        case .idle: "Nicht verbunden"
        case .scanning: "Suche nach Flipper"
        case .connecting: "Verbindung wird hergestellt"
        case .connected: "Verbunden"
        case .reconnecting: "Verbindung wird wiederhergestellt"
        }
    }

    var symbol: String {
        switch self {
        case .bluetoothUnavailable: "bluetooth.slash"
        case .idle: "antenna.radiowaves.left.and.right.slash"
        case .scanning: "dot.radiowaves.left.and.right"
        case .connecting, .reconnecting: "arrow.triangle.2.circlepath"
        case .connected: "checkmark.circle.fill"
        }
    }
}

struct FlipperDevice: Identifiable, Equatable {
    let id: UUID
    var name: String
    var rssi: Int

    var signalBars: Int {
        if rssi >= -55 { return 4 }
        if rssi >= -70 { return 3 }
        if rssi >= -85 { return 2 }
        return 1
    }
}

struct FlipperSnapshot: Equatable {
    var name = "Flipper Zero"
    var firmware = "–"
    var hardware = "–"
    var serialNumber = "–"
    var batteryLevel: Int?
    var protobufVersion = "–"
}

enum DeviceInfoCategory: Int, CaseIterable, Identifiable, Sendable {
    case device
    case firmware
    case battery
    case radio
    case security
    case system
    case other

    var id: Self { self }

    var title: String {
        switch self {
        case .device: "Gerät"
        case .firmware: "Firmware"
        case .battery: "Akku & Energie"
        case .radio: "Funkmodul"
        case .security: "Sicherheit"
        case .system: "System"
        case .other: "Weitere Werte"
        }
    }

    var symbol: String {
        switch self {
        case .device: "memorychip"
        case .firmware: "cpu"
        case .battery: "battery.75percent"
        case .radio: "antenna.radiowaves.left.and.right"
        case .security: "lock.shield"
        case .system: "gearshape.2"
        case .other: "ellipsis.circle"
        }
    }

    static func category(for key: String) -> Self {
        let key = key.lowercased()
        if key.hasPrefix("battery_") || key.hasPrefix("gauge_") ||
            key.hasPrefix("charger_") || key.hasPrefix("capacity_") ||
            key.hasPrefix("charge_") {
            return .battery
        }
        if key.hasPrefix("radio_") { return .radio }
        if key.hasPrefix("firmware_") || key.hasPrefix("protobuf_") ||
            key.hasPrefix("format_") || key.hasPrefix("build_") ||
            key == "target" || key == "software_revision" {
            return .firmware
        }
        if key.hasPrefix("enclave_") || key.hasPrefix("secure_") {
            return .security
        }
        if key.hasPrefix("system_") { return .system }
        if key.hasPrefix("hardware_") || key.hasPrefix("device_") ||
            key.contains("serial") || key == "name" {
            return .device
        }
        return .other
    }
}

struct DeviceInfoItem: Identifiable, Hashable, Sendable {
    let key: String
    let value: String
    let category: DeviceInfoCategory

    var id: String { "\(category.rawValue):\(key)" }

    var displayKey: String {
        key.replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { word in
                let upper = word.uppercased()
                if ["API", "BLE", "FUS", "GIT", "ID", "MAC", "MD5", "NFC", "OTP", "RPC", "SRAM", "U2F"].contains(upper) {
                    return upper
                }
                return word.prefix(1).uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }
}

struct FlipperStorageItem: Identifiable, Hashable, Sendable {
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int?

    var id: String { path }
}

enum FileClipboardMode: String, Sendable {
    case copy
    case move

    var title: String {
        switch self {
        case .copy: "Kopieren"
        case .move: "Verschieben"
        }
    }
}

struct FileOperationProgress: Equatable, Sendable {
    var title: String
    var completed: Int
    var total: Int

    var fraction: Double {
        guard total > 0 else { return 0 }
        return Double(completed) / Double(total)
    }
}

struct FileFavoriteEntry: Identifiable, Hashable, Sendable {
    var favorite: Bool
    var category: Int
    var addedAt: UInt32
    var lastOpenedAt: UInt32
    var manualOrder: UInt32
    var name: String
    var launcherID: String
    var path: String

    var id: String { path }
}

struct FavoriteFileMetadata: Equatable, Sendable {
    var exists = false
    var size: Int?
    var modifiedAt: Date?
    var hash: String?
}

struct FavoriteBackup: Identifiable, Hashable, Sendable {
    let url: URL
    let createdAt: Date
    let entryCount: Int

    var id: URL { url }
}

struct FileFavoritesDatabase: Equatable, Sendable {
    static let cacheKey = "cachedFileFavoritesDatabase"
    static let configPath = "/ext/apps_data/flipper_file_favorites/favorites.cfg"
    static let backupPath = "/ext/apps_data/flipper_file_favorites/favorites.backup.cfg"
    static let internalBackupPath = "/int/flipper_file_favorites/favorites.cfg"

    var confirmRisky = true
    var recursiveFolders = true
    var customNames = ["Custom 1", "Custom 2", "Custom 3", "Custom 4"]
    var watchedFolders: [String] = []
    var sortModes: [Int: Int] = [2: 4]
    var entries: [FileFavoriteEntry] = []

    var favorites: [FileFavoriteEntry] {
        entries.filter(\.favorite).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    init() {}

    init(text: String) throws {
        let cleaned = text
            .replacingOccurrences(of: "\u{feff}", with: "")
            .replacingOccurrences(of: "\0", with: "")
        guard cleaned.split(whereSeparator: \.isNewline).first?
            .trimmingCharacters(in: .whitespacesAndNewlines) == "FFF2" else {
            throw FileFavoritesError.invalidFormat
        }
        self.init()
        for rawLine in cleaned.split(whereSeparator: \.isNewline).dropFirst() {
            let fields = rawLine.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard let type = fields.first else { continue }
            switch type {
            case "SET" where fields.count >= 3:
                confirmRisky = fields[1] != "0"
                recursiveFolders = fields[2] != "0"
            case "CUSTOM" where fields.count >= 3:
                if let index = Int(fields[1]), customNames.indices.contains(index) {
                    customNames[index] = fields[2]
                }
            case "WATCH" where fields.count >= 2:
                watchedFolders.append(fields[1])
            case "SORT" where fields.count >= 3:
                if let category = Int(fields[1]), let mode = Int(fields[2]) {
                    sortModes[category] = mode
                }
            case "ENTRY" where fields.count >= 8:
                entries.append(FileFavoriteEntry(
                    favorite: fields[1] != "0",
                    category: Int(fields[2]) ?? 12,
                    addedAt: UInt32(fields[3]) ?? 0,
                    lastOpenedAt: UInt32(fields[4]) ?? 0,
                    manualOrder: UInt32(fields[5]) ?? 0,
                    name: fields[6],
                    launcherID: fields.count >= 9 ? fields[7] : "",
                    path: fields.count >= 9 ? fields[8] : fields[7]))
            default:
                continue
            }
        }
    }

    mutating func addFavorite(path: String) {
        if let index = entries.firstIndex(where: { $0.path == path }) {
            entries[index].favorite = true
            return
        }
        addEntry(path: path, favorite: true)
    }

    mutating func addEntry(path: String, favorite: Bool = false) {
        guard !entries.contains(where: { $0.path == path }), entries.count < 128 else { return }
        let name = path.split(separator: "/").last.map(String.init) ?? path
        entries.append(FileFavoriteEntry(
            favorite: favorite,
            category: Self.category(for: path),
            addedAt: UInt32(Date().timeIntervalSince1970),
            lastOpenedAt: 0,
            manualOrder: UInt32(entries.count),
            name: name,
            launcherID: "",
            path: path))
    }

    mutating func removeFavorite(path: String) {
        guard let index = entries.firstIndex(where: { $0.path == path }) else { return }
        entries[index].favorite = false
    }

    mutating func removeWatchedFolder(_ folder: String) {
        watchedFolders.removeAll { $0 == folder }
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        entries.removeAll { $0.path == folder || $0.path.hasPrefix(prefix) }
    }

    var serialized: String {
        var lines = ["FFF2", "SET\t\(confirmRisky ? 1 : 0)\t\(recursiveFolders ? 1 : 0)"]
        for (index, name) in customNames.enumerated() {
            lines.append("CUSTOM\t\(index)\t\(Self.sanitize(name))")
        }
        lines.append(contentsOf: watchedFolders.map { "WATCH\t\(Self.sanitize($0))" })
        for category in 0...16 {
            lines.append("SORT\t\(category)\t\(sortModes[category] ?? (category == 2 ? 4 : 0))")
        }
        for entry in entries {
            lines.append([
                "ENTRY",
                entry.favorite ? "1" : "0",
                String(entry.category),
                String(entry.addedAt),
                String(entry.lastOpenedAt),
                String(entry.manualOrder),
                Self.sanitize(entry.name),
                Self.sanitize(entry.launcherID),
                Self.sanitize(entry.path),
            ].joined(separator: "\t"))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func sanitize(_ value: String) -> String {
        value.replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func category(for path: String) -> Int {
        let lower = path.lowercased()
        if lower.hasSuffix(".sub") { return 3 }
        if lower.hasSuffix(".nfc") { return 4 }
        if lower.hasSuffix(".rfid") { return 5 }
        if lower.hasSuffix(".ir") { return 6 }
        if lower.hasSuffix(".ibtn") { return 7 }
        if lower.contains("/badusb/") || lower.contains("/bad_kb/") { return 8 }
        if lower.contains("/u2f/") { return 9 }
        if lower.hasSuffix(".js") { return 10 }
        if lower.hasSuffix(".fap") { return 11 }
        return 12
    }
}

enum FileFavoritesError: LocalizedError {
    case invalidFormat
    case notInstalled

    var errorDescription: String? {
        switch self {
        case .invalidFormat: "Die File-Favorites-Datenbank hat ein unbekanntes Format."
        case .notInstalled: "Keine File-Favorites-Datenbank auf dem Flipper gefunden."
        }
    }
}

enum RemoteButton: String, CaseIterable, Codable, Sendable {
    case up
    case down
    case left
    case right
    case ok
    case back

    var title: String {
        switch self {
        case .up: "Hoch"
        case .down: "Runter"
        case .left: "Links"
        case .right: "Rechts"
        case .ok: "OK"
        case .back: "Zurück"
        }
    }

    var symbol: String {
        switch self {
        case .up: "chevron.up"
        case .down: "chevron.down"
        case .left: "chevron.left"
        case .right: "chevron.right"
        case .ok: "circle.fill"
        case .back: "arrow.uturn.backward"
        }
    }
}

struct RemoteCommand: Identifiable, Equatable, Sendable {
    let id: UUID
    let button: RemoteButton
    let isLong: Bool

    init(id: UUID = UUID(), button: RemoteButton, isLong: Bool = false) {
        self.id = id
        self.button = button
        self.isLong = isLong
    }
}

@MainActor
enum FlipperUUID {
    static let advertisedServices = [
        CBUUID(string: "3080"),
        CBUUID(string: "3081"),
        CBUUID(string: "3082"),
        CBUUID(string: "3083"),
    ]

    static let deviceInformation = CBUUID(string: "180A")
    static let battery = CBUUID(string: "180F")
    static let serial = CBUUID(string: "8FE5B3D5-2E7F-4A98-2A48-7ACC60FE0000")

    static let manufacturerName = CBUUID(string: "2A29")
    static let serialNumber = CBUUID(string: "2A25")
    static let firmwareRevision = CBUUID(string: "2A26")
    static let softwareRevision = CBUUID(string: "2A28")
    static let batteryLevel = CBUUID(string: "2A19")
    static let protobufRevision = CBUUID(string: "03F6666D-AE5E-47C8-8E1A-5D873EB5A933")
    static let serialRead = CBUUID(string: "19ED82AE-ED21-4C9D-4145-228E61FE0000")
    static let serialWrite = CBUUID(string: "19ED82AE-ED21-4C9D-4145-228E62FE0000")
    static let flowControl = CBUUID(string: "19ED82AE-ED21-4C9D-4145-228E63FE0000")
    static let restartSession = CBUUID(string: "19ED82AE-ED21-4C9D-4145-228E64FE0000")
}
