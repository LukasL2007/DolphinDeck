@preconcurrency import CoreBluetooth
@preconcurrency import Combine
import Foundation
@preconcurrency import Peripheral
import WidgetKit

@MainActor
final class FlipperBluetoothManager: NSObject, ObservableObject {
    static let shared = FlipperBluetoothManager()

    @Published private(set) var connectionState: FlipperConnectionState = .idle
    @Published private(set) var discoveredDevices: [FlipperDevice] = []
    @Published private(set) var snapshot = FlipperSnapshot()
    @Published private(set) var lastError: String?
    @Published private(set) var rpcReady = false
    @Published private(set) var rpcBusy = false
    @Published private(set) var lastRPCMessage: String?
    @Published private(set) var screenPixels: [Bool]?
    @Published private(set) var isScreenStreaming = false
    @Published private(set) var detailedInfo: [DeviceInfoItem] = []
    @Published private(set) var isLoadingDetailedInfo = false
    @Published private(set) var detailedInfoError: String?
    @Published private(set) var detailedInfoUpdatedAt: Date?
    @Published private(set) var favoritesDatabase = FileFavoritesDatabase()
    @Published private(set) var isLoadingFavorites = false
    @Published private(set) var favoritesError: String?
    @Published private(set) var favoritesLoaded = false
    @Published private(set) var favoritesSourcePath: String?
    @Published private(set) var fileClipboard: [FlipperStorageItem] = []
    @Published private(set) var fileClipboardMode: FileClipboardMode = .copy
    @Published private(set) var fileOperationProgress: FileOperationProgress?
    @Published private(set) var fileOperationError: String?
    @Published private(set) var favoriteBackups: [FavoriteBackup] = []
    @Published private(set) var pendingRemoteCommands: [RemoteCommand] = []
    @Published private(set) var activeRemoteCommand: RemoteCommand?
    @Published private(set) var remoteHistory: [RemoteButton] = []
    @Published private(set) var isFlipperLocked: Bool?
    @Published private(set) var isUnlockingFlipper = false
    @Published var keepConnected = true

    private static let restorationIdentifier = "de.lukasleipacher.DolphinDeck.central"
    private static let selectedPeripheralKey = "selectedFlipperPeripheral"
    private static let remoteHistoryKey = "remoteButtonHistory"

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var selectedPeripheralID: UUID?
    private var shouldReconnect = true
    private(set) var serialWriteCharacteristic: CBCharacteristic?
    private var flowControlCharacteristic: CBCharacteristic?
    private var restartSessionCharacteristic: CBCharacteristic?
    private var flowControlFreeSpace = 0
    private var rpcSession: FlipperSession?
    private var rpcBridge: RPCPeripheralBridge?
    private var rpcMessageTask: Task<Void, Never>?
    private var remoteQueueTask: Task<Void, Never>?
    private var remoteWorkQueue: [RemoteWorkItem] = []

    override private init() {
        super.init()
        if let cached = UserDefaults.standard.string(forKey: FileFavoritesDatabase.cacheKey),
           let database = try? FileFavoritesDatabase(text: cached) {
            favoritesDatabase = database
        }
        favoriteBackups = Self.loadFavoriteBackups()
        remoteHistory = UserDefaults.standard.stringArray(
            forKey: Self.remoteHistoryKey)?
            .compactMap(RemoteButton.init(rawValue:)) ?? []
        if let value = UserDefaults.standard.string(forKey: Self.selectedPeripheralKey) {
            selectedPeripheralID = UUID(uuidString: value)
        }
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [
                CBCentralManagerOptionRestoreIdentifierKey: Self.restorationIdentifier,
                CBCentralManagerOptionShowPowerAlertKey: true,
            ])
        updateSharedWidgetState()
    }

    var isConnected: Bool {
        connectionState == .connected
    }

    func startScanning() {
        guard central.state == .poweredOn else {
            connectionState = .bluetoothUnavailable
            return
        }
        lastError = nil
        connectionState = .scanning
        central.scanForPeripherals(
            withServices: FlipperUUID.advertisedServices,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func stopScanning() {
        central.stopScan()
        if connectionState == .scanning {
            connectionState = .idle
        }
    }

    func connect(to device: FlipperDevice) {
        guard let candidate = central.retrievePeripherals(withIdentifiers: [device.id]).first else {
            startScanning()
            return
        }
        connect(candidate)
    }

    func reconnect() {
        guard central.state == .poweredOn else { return }
        if let selectedPeripheralID,
           let known = central.retrievePeripherals(withIdentifiers: [selectedPeripheralID]).first {
            connectionState = .reconnecting
            connect(known)
        } else {
            startScanning()
        }
    }

    func disconnect() {
        shouldReconnect = false
        closeRPCSession()
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        self.peripheral = nil
        snapshot = FlipperSnapshot()
        connectionState = .idle
    }

    func forgetDevice() {
        disconnect()
        selectedPeripheralID = nil
        UserDefaults.standard.removeObject(forKey: Self.selectedPeripheralKey)
    }

    private func connect(_ peripheral: CBPeripheral) {
        shouldReconnect = keepConnected
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        selectedPeripheralID = peripheral.identifier
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.selectedPeripheralKey)
        snapshot.name = peripheral.name ?? "Flipper Zero"
        connectionState = .connecting
        central.connect(
            peripheral,
            options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
    }

    private func scheduleReconnect() {
        guard keepConnected, shouldReconnect else { return }
        connectionState = .reconnecting
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.reconnect()
        }
    }

    private func updateDevice(_ peripheral: CBPeripheral, rssi: NSNumber) {
        let device = FlipperDevice(
            id: peripheral.identifier,
            name: peripheral.name ?? "Flipper Zero",
            rssi: rssi.intValue)
        if let index = discoveredDevices.firstIndex(where: { $0.id == device.id }) {
            discoveredDevices[index] = device
        } else {
            discoveredDevices.append(device)
            discoveredDevices.sort { $0.rssi > $1.rssi }
        }
    }

    private func readKnownCharacteristics(from service: CBService) {
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case FlipperUUID.serialRead:
                peripheral?.setNotifyValue(true, for: characteristic)
            case FlipperUUID.serialWrite:
                serialWriteCharacteristic = characteristic
            case FlipperUUID.flowControl:
                flowControlCharacteristic = characteristic
                peripheral?.setNotifyValue(true, for: characteristic)
                peripheral?.readValue(for: characteristic)
            case FlipperUUID.restartSession:
                restartSessionCharacteristic = characteristic
            case FlipperUUID.batteryLevel,
                 FlipperUUID.manufacturerName,
                 FlipperUUID.serialNumber,
                 FlipperUUID.firmwareRevision,
                 FlipperUUID.softwareRevision,
                 FlipperUUID.protobufRevision:
                peripheral?.readValue(for: characteristic)
            default:
                break
            }
        }
        if service.uuid == FlipperUUID.serial {
            startRPCSessionIfReady()
        }
    }

    private func startRPCSessionIfReady() {
        guard rpcSession == nil,
              serialWriteCharacteristic != nil,
              flowControlCharacteristic != nil else {
            return
        }
        guard let peripheral, let serialWriteCharacteristic else { return }
        let bridge = RPCPeripheralBridge(
            peripheral: peripheral,
            serialWrite: serialWriteCharacteristic,
            restartSession: restartSessionCharacteristic,
            name: snapshot.name)
        bridge.updateFreeSpace(flowControlFreeSpace)
        let session = FlipperSession(peripheral: bridge)
        rpcBridge = bridge
        rpcSession = session
        FlipperSession.current = session
        rpcReady = true
        lastRPCMessage = "RPC verbunden"
        rpcMessageTask = Task { [weak self] in
            for await message in session.message {
                guard !Task.isCancelled else { return }
                if case .screenFrame(let frame) = message {
                    self?.screenPixels = frame.pixels
                }
            }
        }
    }

    private func closeRPCSession() {
        let session = rpcSession
        rpcMessageTask?.cancel()
        rpcMessageTask = nil
        rpcSession = nil
        rpcBridge = nil
        FlipperSession.current = nil
        rpcReady = false
        isScreenStreaming = false
        screenPixels = nil
        detailedInfo = []
        detailedInfoError = nil
        detailedInfoUpdatedAt = nil
        favoritesDatabase = FileFavoritesDatabase()
        favoritesError = nil
        favoritesLoaded = false
        favoritesSourcePath = nil
        fileClipboard = []
        fileOperationProgress = nil
        fileOperationError = nil
        clearRemoteQueue()
        isFlipperLocked = nil
        isUnlockingFlipper = false
        flowControlFreeSpace = 0
        serialWriteCharacteristic = nil
        flowControlCharacteristic = nil
        restartSessionCharacteristic = nil
        if let session {
            Task {
                await session.close()
            }
        }
    }

    func playAlert() async {
        guard let rpcSession else {
            lastRPCMessage = "RPC ist noch nicht bereit"
            return
        }
        rpcBusy = true
        defer { rpcBusy = false }
        do {
            try await rpcSession.playAlert()
            lastRPCMessage = "Alarm ausgelöst"
        } catch {
            lastRPCMessage = "Alarm fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    func enqueueRemotePress(_ button: RemoteButton, long: Bool = false) {
        enqueueRemoteCommand(
            RemoteCommand(button: button, isLong: long),
            completion: nil)
    }

    func press(_ button: RemoteButton, long: Bool = false) async {
        await withCheckedContinuation { continuation in
            enqueueRemoteCommand(
                RemoteCommand(button: button, isLong: long),
                completion: continuation)
        }
    }

    private func enqueueRemoteCommand(
        _ command: RemoteCommand,
        completion: CheckedContinuation<Void, Never>?
    ) {
        guard rpcSession != nil else {
            lastRPCMessage = "RPC ist noch nicht bereit"
            completion?.resume()
            return
        }
        pendingRemoteCommands.append(command)
        remoteWorkQueue.append(RemoteWorkItem(
            command: command,
            completion: completion))
        guard remoteQueueTask == nil else { return }
        remoteQueueTask = Task { [weak self] in
            await self?.processRemoteQueue()
        }
    }

    private func processRemoteQueue() async {
        while !remoteWorkQueue.isEmpty, !Task.isCancelled {
            let work = remoteWorkQueue.removeFirst()
            pendingRemoteCommands.removeAll { $0.id == work.command.id }
            activeRemoteCommand = work.command
            await sendRemoteCommand(work.command)
            rememberRemoteButton(work.command.button)
            activeRemoteCommand = nil
            work.completion?.resume()
            try? await Task.sleep(for: .milliseconds(35))
        }
        activeRemoteCommand = nil
        remoteQueueTask = nil
    }

    private func sendRemoteCommand(_ command: RemoteCommand) async {
        guard let rpcSession else {
            lastRPCMessage = "RPC ist noch nicht bereit"
            return
        }
        let key: Peripheral.InputKey = switch command.button {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .ok: .enter
        case .back: .back
        }
        rpcBusy = true
        defer { rpcBusy = false }
        do {
            try await rpcSession.pressButton(key, isLong: command.isLong)
            lastRPCMessage = "\(command.button.title) gesendet"
        } catch {
            lastRPCMessage = "Taste fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    private func rememberRemoteButton(_ button: RemoteButton) {
        remoteHistory.insert(button, at: 0)
        remoteHistory = Array(remoteHistory.prefix(30))
        UserDefaults.standard.set(
            remoteHistory.map(\.rawValue),
            forKey: Self.remoteHistoryKey)
    }

    func clearRemoteHistory() {
        remoteHistory = []
        UserDefaults.standard.removeObject(forKey: Self.remoteHistoryKey)
    }

    private func clearRemoteQueue() {
        remoteQueueTask?.cancel()
        remoteQueueTask = nil
        for work in remoteWorkQueue {
            work.completion?.resume()
        }
        remoteWorkQueue = []
        pendingRemoteCommands = []
        activeRemoteCommand = nil
    }

    func refreshLockState() async {
        guard let rpcSession else {
            isFlipperLocked = nil
            return
        }
        do {
            isFlipperLocked = try await rpcSession.isDesktopLocked
        } catch {
            isFlipperLocked = nil
        }
    }

    func unlockFlipper() async {
        guard let rpcSession else {
            lastRPCMessage = "RPC ist noch nicht bereit"
            return
        }
        guard !isUnlockingFlipper else { return }
        guard activeRemoteCommand == nil, pendingRemoteCommands.isEmpty else {
            lastRPCMessage = "Entsperren wartet, bis alle Tasten gesendet wurden"
            return
        }
        isUnlockingFlipper = true
        rpcBusy = true
        defer {
            rpcBusy = false
            isUnlockingFlipper = false
        }
        do {
            try await rpcSession.unlock()
            isFlipperLocked = try? await rpcSession.isDesktopLocked
            lastRPCMessage = isFlipperLocked == true
                ? "Der Flipper meldet sich weiterhin als gesperrt"
                : "Flipper entsperrt"
        } catch {
            lastRPCMessage = "Entsperren fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    func startScreenStream() async {
        guard let rpcSession, !isScreenStreaming else { return }
        do {
            try await rpcSession.startStreaming()
            isScreenStreaming = true
            lastRPCMessage = "Displayübertragung aktiv"
        } catch {
            lastRPCMessage = "Displaystart fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    func stopScreenStream() async {
        guard let rpcSession, isScreenStreaming else { return }
        do {
            try await rpcSession.stopStreaming()
        } catch {
            lastRPCMessage = "Displaystopp fehlgeschlagen: \(error.localizedDescription)"
        }
        isScreenStreaming = false
        screenPixels = nil
    }

    func refreshDetailedInfo() async {
        guard let rpcSession else {
            detailedInfoError = "RPC ist noch nicht bereit."
            return
        }
        isLoadingDetailedInfo = true
        detailedInfoError = nil
        defer { isLoadingDetailedInfo = false }

        do {
            var values: [String: String] = [:]
            for try await (key, value) in rpcSession.deviceInfo() {
                values[key] = value
            }
            for try await (key, value) in rpcSession.powerInfo() {
                values[key] = value
            }

            let fallbacks = [
                "device_name": snapshot.name,
                "serial_number": snapshot.serialNumber,
                "firmware_version": snapshot.firmware,
                "hardware_version": snapshot.hardware,
                "protobuf_version": snapshot.protobufVersion,
                "charge_level": snapshot.batteryLevel.map(String.init) ?? "–",
            ]
            for (key, value) in fallbacks where values[key] == nil && value != "–" {
                values[key] = value
            }

            detailedInfo = values.map { key, value in
                DeviceInfoItem(
                    key: key,
                    value: value,
                    category: DeviceInfoCategory.category(for: key))
            }
            .sorted {
                if $0.category.rawValue != $1.category.rawValue {
                    return $0.category.rawValue < $1.category.rawValue
                }
                return $0.displayKey.localizedCaseInsensitiveCompare($1.displayKey) == .orderedAscending
            }
            detailedInfoUpdatedAt = Date()
            lastRPCMessage = "\(detailedInfo.count) Gerätewerte geladen"
        } catch {
            detailedInfoError = error.localizedDescription
        }
    }

    func listDirectory(at path: String) async throws -> [FlipperStorageItem] {
        guard let rpcSession else { throw FileFavoritesError.notInstalled }
        let parent = Peripheral.Path(string: path)
        let elements = try await rpcSession.listDirectory(
            at: parent,
            calculatingMD5: false,
            sizeLimit: 0)
        return elements.map { element in
            let childPath = parent.appending(element.name).string
            switch element {
            case .directory:
                return FlipperStorageItem(
                    name: element.name,
                    path: childPath,
                    isDirectory: true,
                    size: nil)
            case .file(let file):
                return FlipperStorageItem(
                    name: file.name,
                    path: childPath,
                    isDirectory: false,
                    size: file.size)
            }
        }
        .sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func readFile(at path: String) async throws -> Data {
        guard let rpcSession else { throw FileFavoritesError.notInstalled }
        var result = Data()
        for try await bytes in rpcSession.readFile(at: Peripheral.Path(string: path)) {
            result.append(contentsOf: bytes)
        }
        return result
    }

    @discardableResult
    func launchFile(at path: String) async -> Bool {
        guard let rpcSession else {
            lastRPCMessage = "RPC ist noch nicht bereit"
            return false
        }
        rpcBusy = true
        defer { rpcBusy = false }
        do {
            try await rpcSession.appLoadFile(Peripheral.Path(string: path))
            lastRPCMessage = "\(path.split(separator: "/").last ?? "Datei") gestartet"
            return true
        } catch {
            lastRPCMessage = "Datei konnte nicht gestartet werden: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func executeFavorite(at path: String) async -> Bool {
        if !isConnected {
            reconnect()
        }
        for _ in 0..<30 {
            if rpcReady { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard rpcReady else {
            lastRPCMessage = "Der Flipper konnte nicht rechtzeitig verbunden werden"
            return false
        }

        let success = await launchFile(at: path)
        guard success else { return false }

        if path.lowercased().hasSuffix(".sub") {
            // Opening a saved Sub-GHz file lands on the transmitter screen.
            // Send one deliberate OK event only after that screen has loaded.
            try? await Task.sleep(for: .milliseconds(900))
            await press(.ok)
            lastRPCMessage = "\(path.split(separator: "/").last ?? "Sub-GHz-Signal") gesendet"
        }

        if let index = favoritesDatabase.entries.firstIndex(where: { $0.path == path }) {
            var database = favoritesDatabase
            database.entries[index].lastOpenedAt = UInt32(Date().timeIntervalSince1970)
            await saveFavorites(database)
        }
        return true
    }

    func refreshFavorites() async {
        guard rpcSession != nil else {
            favoritesError = "RPC ist noch nicht bereit."
            return
        }
        isLoadingFavorites = true
        favoritesError = nil
        defer { isLoadingFavorites = false }

        var candidatePaths = [
            FileFavoritesDatabase.configPath,
            FileFavoritesDatabase.backupPath,
            FileFavoritesDatabase.internalBackupPath,
        ]

        if let appDataItems = try? await listDirectory(at: "/ext/apps_data") {
            for directory in appDataItems where directory.isDirectory &&
                directory.name.lowercased().contains("favorite") {
                if let files = try? await listDirectory(at: directory.path) {
                    candidatePaths.append(contentsOf: files
                        .filter { !$0.isDirectory && $0.name.lowercased().hasSuffix(".cfg") }
                        .map(\.path))
                }
            }
        }
        var seenPaths = Set<String>()
        candidatePaths = candidatePaths.filter { seenPaths.insert($0).inserted }

        var failures: [String] = []
        for path in candidatePaths {
            do {
                let data = try await readFile(at: path)
                guard let text = String(data: data, encoding: .utf8) else {
                    throw FileFavoritesError.invalidFormat
                }
                favoritesDatabase = try FileFavoritesDatabase(text: text)
                UserDefaults.standard.set(
                    favoritesDatabase.serialized,
                    forKey: FileFavoritesDatabase.cacheKey)
                favoritesLoaded = true
                favoritesSourcePath = path
                updateSharedWidgetState()
                lastRPCMessage = "\(favoritesDatabase.entries.count) File-Favorites-Einträge geladen"
                return
            } catch {
                failures.append("\(path): \(error.localizedDescription)")
                continue
            }
        }
        favoritesLoaded = false
        favoritesSourcePath = nil
        favoritesError = failures.isEmpty
            ? FileFavoritesError.notInstalled.localizedDescription
            : "Datenbank nicht lesbar. \(failures.joined(separator: " · "))"
    }

    func setFavorite(path: String, enabled: Bool) async {
        if favoritesDatabase.entries.isEmpty {
            await refreshFavorites()
        }
        var database = favoritesDatabase
        if enabled {
            database.addFavorite(path: path)
        } else {
            database.removeFavorite(path: path)
        }
        await saveFavorites(database)
    }

    func openFavorite(_ entry: FileFavoriteEntry) async {
        var database = favoritesDatabase
        if let index = database.entries.firstIndex(where: { $0.path == entry.path }) {
            database.entries[index].lastOpenedAt = UInt32(Date().timeIntervalSince1970)
            await saveFavorites(database)
        }
        await launchFile(at: entry.path)
    }

    func saveFavoriteEntry(
        originalPath: String,
        name: String,
        category: Int,
        launcherID: String,
        favorite: Bool
    ) async {
        var database = favoritesDatabase
        guard let index = database.entries.firstIndex(where: { $0.path == originalPath }) else {
            favoritesError = "Der Eintrag wurde zwischenzeitlich entfernt."
            return
        }
        let cleanName = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(63)
        guard !cleanName.isEmpty else {
            favoritesError = "Der Anzeigename darf nicht leer sein."
            return
        }
        let cleanLauncher = launcherID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(31)
        database.entries[index].name = String(cleanName)
        database.entries[index].category = min(16, max(3, category))
        database.entries[index].launcherID =
            cleanLauncher.lowercased() == "auto" ? "" : String(cleanLauncher)
        database.entries[index].favorite = favorite
        await saveFavorites(database)
    }

    func relinkFavorite(originalPath: String, to newPath: String) async {
        var database = favoritesDatabase
        guard !database.entries.contains(where: { $0.path == newPath && $0.path != originalPath }) else {
            favoritesError = "Diese Datei ist bereits in File Favorites verknüpft."
            return
        }
        guard let index = database.entries.firstIndex(where: { $0.path == originalPath }) else {
            favoritesError = "Der ursprüngliche Eintrag wurde nicht gefunden."
            return
        }
        database.entries[index].path = String(newPath.prefix(255))
        database.entries[index].name =
            newPath.split(separator: "/").last.map(String.init) ?? newPath
        if database.entries[index].category < 13 {
            var detected = FileFavoritesDatabase()
            detected.addEntry(path: newPath)
            database.entries[index].category = detected.entries.first?.category ?? 12
        }
        await saveFavorites(database)
    }

    func removeFavoriteEntry(path: String) async {
        var database = favoritesDatabase
        database.entries.removeAll { $0.path == path }
        for index in database.entries.indices {
            database.entries[index].manualOrder = UInt32(index)
        }
        await saveFavorites(database)
    }

    func moveFavoriteEntry(path: String, in category: Int, down: Bool) async {
        var database = favoritesDatabase
        let visible = database.entries.indices
            .filter { index in
                let entry = database.entries[index]
                switch category {
                case 0: return true
                case 1: return entry.favorite
                case 2: return entry.lastOpenedAt > 0
                default: return entry.category == category
                }
            }
            .sorted {
                database.entries[$0].manualOrder < database.entries[$1].manualOrder
            }
        guard let position = visible.firstIndex(where: { database.entries[$0].path == path }) else {
            return
        }
        let otherPosition = down ? position + 1 : position - 1
        guard visible.indices.contains(otherPosition) else { return }
        let index = visible[position]
        let otherIndex = visible[otherPosition]
        let order = database.entries[index].manualOrder
        database.entries[index].manualOrder = database.entries[otherIndex].manualOrder
        database.entries[otherIndex].manualOrder = order
        database.sortModes[category] = 0
        await saveFavorites(database)
    }

    func setFavoritesSortMode(_ mode: Int, for category: Int) async {
        guard (0...5).contains(mode), (0...16).contains(category) else { return }
        var database = favoritesDatabase
        database.sortModes[category] = mode
        await saveFavorites(database)
    }

    func favoriteFileMetadata(at path: String) async -> FavoriteFileMetadata {
        guard let rpcSession else { return FavoriteFileMetadata() }
        do {
            async let size = rpcSession.getSize(at: Peripheral.Path(string: path))
            async let timestamp = rpcSession.getTimestamp(at: Peripheral.Path(string: path))
            return try await FavoriteFileMetadata(
                exists: true,
                size: size,
                modifiedAt: timestamp,
                hash: nil)
        } catch {
            return FavoriteFileMetadata()
        }
    }

    func favoriteFileHash(at path: String) async throws -> String {
        guard let rpcSession else { throw FileFavoritesError.notInstalled }
        return try await rpcSession.calculateFileHash(
            at: Peripheral.Path(string: path)).value
    }

    func removeWatchedFolder(_ folder: String) async {
        var database = favoritesDatabase
        database.removeWatchedFolder(folder)
        await saveFavorites(database)
    }

    func importFavoritesFolder(_ folder: String) async {
        if !favoritesLoaded {
            await refreshFavorites()
        }
        guard favoritesDatabase.watchedFolders.contains(folder) ||
            favoritesDatabase.watchedFolders.count < 8 else {
            favoritesError = "Es können höchstens acht importierte Ordner gespeichert werden."
            return
        }

        isLoadingFavorites = true
        favoritesError = nil
        defer { isLoadingFavorites = false }
        do {
            var database = favoritesDatabase
            if !database.watchedFolders.contains(folder) {
                database.watchedFolders.append(folder)
            }
            let remaining = max(0, 128 - database.entries.count)
            let files = try await collectFiles(
                below: folder,
                depth: 0,
                maxDepth: database.recursiveFolders ? 8 : 0,
                limit: remaining)
            let previousCount = database.entries.count
            for file in files {
                database.addEntry(path: file)
            }
            await saveFavorites(database)
            lastRPCMessage = "\(database.entries.count - previousCount) Dateien aus Ordner importiert"
        } catch {
            favoritesError = "Ordnerimport fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    private func collectFiles(
        below folder: String,
        depth: Int,
        maxDepth: Int,
        limit: Int
    ) async throws -> [String] {
        guard limit > 0 else { return [] }
        var result: [String] = []
        for item in try await listDirectory(at: folder) {
            if item.isDirectory {
                guard depth < maxDepth else { continue }
                let nested = try await collectFiles(
                    below: item.path,
                    depth: depth + 1,
                    maxDepth: maxDepth,
                    limit: limit - result.count)
                result.append(contentsOf: nested)
            } else {
                result.append(item.path)
            }
            if result.count >= limit { break }
        }
        return result
    }

    private func saveFavorites(_ database: FileFavoritesDatabase) async {
        guard let rpcSession else {
            favoritesError = "RPC ist noch nicht bereit."
            return
        }
        isLoadingFavorites = true
        favoritesError = nil
        defer { isLoadingFavorites = false }
        do {
            if favoritesLoaded, favoritesDatabase.serialized != database.serialized {
                createAutomaticFavoriteBackupIfNeeded()
            }
            try? await rpcSession.createFile(
                at: Peripheral.Path(string: "/ext/apps_data/flipper_file_favorites"),
                isDirectory: true)
            try await writeFavoritesDatabase(
                database,
                to: FileFavoritesDatabase.configPath,
                using: rpcSession)

            try? await writeFavoritesDatabase(
                database,
                to: FileFavoritesDatabase.backupPath,
                using: rpcSession)
            try? await rpcSession.createFile(
                at: Peripheral.Path(string: "/int/flipper_file_favorites"),
                isDirectory: true)
            try? await writeFavoritesDatabase(
                database,
                to: FileFavoritesDatabase.internalBackupPath,
                using: rpcSession)
            favoritesDatabase = database
            UserDefaults.standard.set(
                database.serialized,
                forKey: FileFavoritesDatabase.cacheKey)
            favoritesLoaded = true
            favoritesSourcePath = FileFavoritesDatabase.configPath
            updateSharedWidgetState()
            lastRPCMessage = "File Favorites und Backup-Spiegel gespeichert"
        } catch {
            favoritesError = "Speichern fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    func createFavoriteBackup() {
        createFavoriteBackup(from: favoritesDatabase)
        lastRPCMessage = "Versioniertes File-Favorites-Backup erstellt"
    }

    func restoreFavoriteBackup(_ backup: FavoriteBackup) async {
        do {
            let text = try String(contentsOf: backup.url, encoding: .utf8)
            let database = try FileFavoritesDatabase(text: text)
            await saveFavorites(database)
            lastRPCMessage = "Backup mit \(database.entries.count) Einträgen wiederhergestellt"
        } catch {
            favoritesError = "Backup konnte nicht wiederhergestellt werden: \(error.localizedDescription)"
        }
    }

    func deleteFavoriteBackup(_ backup: FavoriteBackup) {
        do {
            try FileManager.default.removeItem(at: backup.url)
            favoriteBackups.removeAll { $0.id == backup.id }
        } catch {
            favoritesError = "Backup konnte nicht gelöscht werden: \(error.localizedDescription)"
        }
    }

    private func createAutomaticFavoriteBackupIfNeeded() {
        let lastDate = UserDefaults.standard.object(
            forKey: "lastAutomaticFavoritesBackup") as? Date
        guard lastDate == nil || Date().timeIntervalSince(lastDate!) > 21_600 else { return }
        createFavoriteBackup(from: favoritesDatabase)
        UserDefaults.standard.set(Date(), forKey: "lastAutomaticFavoritesBackup")
    }

    private func createFavoriteBackup(from database: FileFavoritesDatabase) {
        do {
            let directory = Self.favoriteBackupsDirectory
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true)

            if let newest = favoriteBackups.first,
               let current = try? String(contentsOf: newest.url, encoding: .utf8),
               current == database.serialized {
                return
            }

            let timestamp = Int(Date().timeIntervalSince1970)
            let url = directory.appendingPathComponent(
                "favorites-\(timestamp)-\(database.entries.count).fff2")
            try database.serialized.write(to: url, atomically: true, encoding: .utf8)
            favoriteBackups = Self.loadFavoriteBackups()

            for backup in favoriteBackups.dropFirst(30) {
                try? FileManager.default.removeItem(at: backup.url)
            }
            favoriteBackups = Self.loadFavoriteBackups()
        } catch {
            favoritesError = "Lokales Backup fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    private static var favoriteBackupsDirectory: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask)[0]
            .appendingPathComponent("DolphinDeck", isDirectory: true)
            .appendingPathComponent("FavoriteBackups", isDirectory: true)
    }

    private static func loadFavoriteBackups() -> [FavoriteBackup] {
        let directory = favoriteBackupsDirectory
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]) else {
            return []
        }
        return urls.compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  let database = try? FileFavoritesDatabase(text: text) else {
                return nil
            }
            let values = try? url.resourceValues(forKeys: [.creationDateKey])
            return FavoriteBackup(
                url: url,
                createdAt: values?.creationDate ?? .distantPast,
                entryCount: database.entries.count)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    private func writeFavoritesDatabase(
        _ database: FileFavoritesDatabase,
        to path: String,
        using session: FlipperSession
    ) async throws {
        for try await _ in session.writeFile(
            at: Peripheral.Path(string: path),
            bytes: Array(database.serialized.utf8)) {}
    }

    func uploadFile(data: Data, to path: String) async throws {
        guard let rpcSession else { throw FileFavoritesError.notInstalled }
        for try await _ in rpcSession.writeFile(
            at: Peripheral.Path(string: path),
            bytes: Array(data)) {}
        lastRPCMessage = "\(path.split(separator: "/").last ?? "Datei") hochgeladen"
    }

    func createDirectory(at path: String) async throws {
        guard let rpcSession else { throw FileFavoritesError.notInstalled }
        do {
            try await rpcSession.createFile(
                at: Peripheral.Path(string: path),
                isDirectory: true)
        } catch {
            // A directory that already exists is a successful precondition for imports.
            if (try? await listDirectory(at: path)) == nil {
                throw error
            }
        }
        lastRPCMessage = "Ordner angelegt"
    }

    func deleteStorageItem(at path: String, recursively: Bool) async throws {
        guard let rpcSession else { throw FileFavoritesError.notInstalled }
        try await rpcSession.deleteFile(
            at: Peripheral.Path(string: path),
            force: recursively)

        if favoritesDatabase.entries.contains(where: { $0.path == path || $0.path.hasPrefix(path + "/") }) {
            var database = favoritesDatabase
            database.entries.removeAll { $0.path == path || $0.path.hasPrefix(path + "/") }
            database.watchedFolders.removeAll { $0 == path || $0.hasPrefix(path + "/") }
            await saveFavorites(database)
        }
        lastRPCMessage = "\(path.split(separator: "/").last ?? "Eintrag") gelöscht"
    }

    func setFileClipboard(
        _ items: [FlipperStorageItem],
        mode: FileClipboardMode
    ) {
        fileClipboard = items.sorted {
            $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending
        }
        fileClipboardMode = mode
        fileOperationError = nil
        lastRPCMessage = "\(items.count) Einträge zum \(mode.title.lowercased()) vorgemerkt"
    }

    func clearFileClipboard() {
        fileClipboard = []
        fileOperationProgress = nil
        fileOperationError = nil
    }

    @discardableResult
    func pasteFileClipboard(into destinationFolder: String) async -> Bool {
        guard let rpcSession, !fileClipboard.isEmpty else { return false }
        let sources = fileClipboard
        fileOperationError = nil
        fileOperationProgress = FileOperationProgress(
            title: fileClipboardMode.title,
            completed: 0,
            total: sources.count)
        var pathChanges: [(old: String, new: String)] = []
        var failures: [String] = []

        for (offset, item) in sources.enumerated() {
            if item.isDirectory &&
                (destinationFolder == item.path || destinationFolder.hasPrefix(item.path + "/")) {
                failures.append("\(item.name): Ziel liegt im Quellordner")
                fileOperationProgress?.completed = offset + 1
                continue
            }
            let sourceParent = (item.path as NSString).deletingLastPathComponent
            if sourceParent == destinationFolder && fileClipboardMode == .move {
                fileOperationProgress?.completed = offset + 1
                continue
            }

            do {
                let destination = try await availableDestinationPath(
                    folder: destinationFolder,
                    preferredName: item.name)
                switch fileClipboardMode {
                case .copy:
                    try await copyStorageItem(item, to: destination)
                case .move:
                    do {
                        try await rpcSession.moveFile(
                            from: Peripheral.Path(string: item.path),
                            to: Peripheral.Path(string: destination))
                    } catch {
                        try await copyStorageItem(item, to: destination)
                        try await rpcSession.deleteFile(
                            at: Peripheral.Path(string: item.path),
                            force: item.isDirectory)
                    }
                    pathChanges.append((item.path, destination))
                }
            } catch {
                failures.append("\(item.name): \(error.localizedDescription)")
            }
            fileOperationProgress?.completed = offset + 1
        }

        if !pathChanges.isEmpty {
            await updateFavoritePaths(pathChanges)
        }
        if fileClipboardMode == .move && failures.isEmpty {
            fileClipboard = []
        }
        fileOperationProgress = nil
        fileOperationError = failures.isEmpty ? nil : failures.joined(separator: "\n")
        lastRPCMessage = failures.isEmpty
            ? "\(sources.count) Einträge verarbeitet"
            : "\(sources.count - failures.count) von \(sources.count) Einträgen verarbeitet"
        return failures.isEmpty
    }

    func deleteStorageItems(_ items: [FlipperStorageItem]) async -> Bool {
        guard let rpcSession, !items.isEmpty else { return false }
        fileOperationError = nil
        fileOperationProgress = FileOperationProgress(
            title: "Löschen",
            completed: 0,
            total: items.count)
        var deletedPaths: [String] = []
        var failures: [String] = []

        for (offset, item) in items.enumerated() {
            do {
                try await rpcSession.deleteFile(
                    at: Peripheral.Path(string: item.path),
                    force: item.isDirectory)
                deletedPaths.append(item.path)
            } catch {
                failures.append("\(item.name): \(error.localizedDescription)")
            }
            fileOperationProgress?.completed = offset + 1
        }

        if !deletedPaths.isEmpty {
            var database = favoritesDatabase
            database.entries.removeAll { entry in
                deletedPaths.contains { entry.path == $0 || entry.path.hasPrefix($0 + "/") }
            }
            database.watchedFolders.removeAll { folder in
                deletedPaths.contains { folder == $0 || folder.hasPrefix($0 + "/") }
            }
            await saveFavorites(database)
        }
        fileOperationProgress = nil
        fileOperationError = failures.isEmpty ? nil : failures.joined(separator: "\n")
        lastRPCMessage = "\(deletedPaths.count) Einträge gelöscht"
        return failures.isEmpty
    }

    func renameStorageItem(_ item: FlipperStorageItem, to newName: String) async throws {
        guard let rpcSession else { throw FileFavoritesError.notInstalled }
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let parent = (item.path as NSString).deletingLastPathComponent
        let destination = joinPath(parent, name)
        guard destination != item.path else { return }
        let siblings = try await listDirectory(at: parent)
        guard !siblings.contains(where: { $0.path == destination }) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try await rpcSession.moveFile(
            from: Peripheral.Path(string: item.path),
            to: Peripheral.Path(string: destination))
        await updateFavoritePaths([(item.path, destination)])
        lastRPCMessage = "„\(item.name)“ umbenannt"
    }

    private func copyStorageItem(
        _ item: FlipperStorageItem,
        to destination: String
    ) async throws {
        if item.isDirectory {
            try await createDirectory(at: destination)
            for child in try await listDirectory(at: item.path) {
                try await copyStorageItem(
                    child,
                    to: joinPath(destination, child.name))
            }
        } else {
            try await uploadFile(
                data: try await readFile(at: item.path),
                to: destination)
        }
    }

    private func availableDestinationPath(
        folder: String,
        preferredName: String
    ) async throws -> String {
        let existing = Set(try await listDirectory(at: folder).map { $0.name.lowercased() })
        if !existing.contains(preferredName.lowercased()) {
            return joinPath(folder, preferredName)
        }

        let extensionName = (preferredName as NSString).pathExtension
        let baseName = (preferredName as NSString).deletingPathExtension
        for suffix in 1...999 {
            let copySuffix = suffix == 1 ? " Kopie" : " Kopie \(suffix)"
            let candidate = extensionName.isEmpty
                ? baseName + copySuffix
                : baseName + copySuffix + "." + extensionName
            if !existing.contains(candidate.lowercased()) {
                return joinPath(folder, candidate)
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    private func updateFavoritePaths(_ changes: [(old: String, new: String)]) async {
        var database = favoritesDatabase
        var changed = false
        for index in database.entries.indices {
            for change in changes {
                if database.entries[index].path == change.old {
                    database.entries[index].path = change.new
                    changed = true
                } else if database.entries[index].path.hasPrefix(change.old + "/") {
                    database.entries[index].path =
                        change.new + String(database.entries[index].path.dropFirst(change.old.count))
                    changed = true
                }
            }
        }
        for index in database.watchedFolders.indices {
            for change in changes {
                if database.watchedFolders[index] == change.old {
                    database.watchedFolders[index] = change.new
                    changed = true
                } else if database.watchedFolders[index].hasPrefix(change.old + "/") {
                    database.watchedFolders[index] =
                        change.new + String(database.watchedFolders[index].dropFirst(change.old.count))
                    changed = true
                }
            }
        }
        if changed { await saveFavorites(database) }
    }

    private func joinPath(_ folder: String, _ name: String) -> String {
        let cleanName = name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return folder.hasSuffix("/") ? folder + cleanName : folder + "/" + cleanName
    }

    func runPing() async -> String {
        guard let rpcSession else { return "RPC ist noch nicht bereit." }
        let payload = Array("DolphinDeck".utf8)
        let started = ContinuousClock.now
        do {
            let response = try await rpcSession.ping(payload)
            let duration = started.duration(to: .now)
            guard response == payload else { return "Antwortdaten stimmen nicht überein." }
            return "Ping erfolgreich · \(duration.formatted(.units(allowed: [.milliseconds], width: .abbreviated)))"
        } catch {
            return "Ping fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    func rebootFlipper() async {
        guard let rpcSession else {
            lastRPCMessage = "RPC ist noch nicht bereit"
            return
        }
        do {
            try await rpcSession.reboot(to: .os)
            lastRPCMessage = "Flipper wird neu gestartet"
        } catch {
            lastRPCMessage = "Neustart fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    private func updateSharedWidgetState() {
        guard let defaults = UserDefaults(
            suiteName: "group.de.lukasleipacher.DolphinDeck") else {
            return
        }
        defaults.set(isConnected, forKey: "connected")
        defaults.set(snapshot.name, forKey: "name")
        if let battery = snapshot.batteryLevel {
            defaults.set(battery, forKey: "battery")
        } else {
            defaults.removeObject(forKey: "battery")
        }
        defaults.set(favoritesDatabase.entries.count, forKey: "favorites")
        defaults.set(snapshot.firmware, forKey: "firmware")
        let subGHzFavorites = favoritesDatabase.entries.filter {
            $0.favorite && $0.path.lowercased().hasSuffix(".sub")
        }
        let markedFavorites = favoritesDatabase.entries.filter(\.favorite)
        let quickFavorites = Array(
            (!subGHzFavorites.isEmpty
             ? subGHzFavorites
             : (markedFavorites.isEmpty ? favoritesDatabase.entries : markedFavorites))
                .prefix(3))
        defaults.set(quickFavorites.map(\.name), forKey: "quickFavoriteNames")
        defaults.set(quickFavorites.map(\.path), forKey: "quickFavoritePaths")
        WidgetCenter.shared.reloadAllTimelines()
    }
}

private struct RemoteWorkItem {
    let command: RemoteCommand
    let completion: CheckedContinuation<Void, Never>?
}

extension FlipperBluetoothManager: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if selectedPeripheralID != nil {
                reconnect()
            } else {
                connectionState = .idle
            }
        default:
            connectionState = .bluetoothUnavailable
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        updateDevice(peripheral, rssi: RSSI)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        self.peripheral = peripheral
        peripheral.delegate = self
        snapshot.name = peripheral.name ?? "Flipper Zero"
        connectionState = .connected
        lastError = nil
        updateSharedWidgetState()
        peripheral.discoverServices([
            FlipperUUID.deviceInformation,
            FlipperUUID.battery,
            FlipperUUID.serial,
        ])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Swift.Error?
    ) {
        lastError = error?.localizedDescription ?? "Verbindung fehlgeschlagen"
        scheduleReconnect()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Swift.Error?
    ) {
        closeRPCSession()
        if let error {
            lastError = error.localizedDescription
        }
        updateSharedWidgetState()
        scheduleReconnect()
    }

    func centralManager(
        _ central: CBCentralManager,
        willRestoreState dict: [String: Any]
    ) {
        guard let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first else {
            return
        }
        peripheral = restored
        restored.delegate = self
        selectedPeripheralID = restored.identifier
        snapshot.name = restored.name ?? "Flipper Zero"
        connectionState = restored.state == .connected ? .connected : .reconnecting
        if restored.state == .connected {
            restored.discoverServices([
                FlipperUUID.deviceInformation,
                FlipperUUID.battery,
                FlipperUUID.serial,
            ])
        }
    }
}

extension FlipperBluetoothManager: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Swift.Error?) {
        if let error {
            lastError = error.localizedDescription
            return
        }
        for service in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Swift.Error?
    ) {
        if let error {
            lastError = error.localizedDescription
            return
        }
        readKnownCharacteristics(from: service)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Swift.Error?
    ) {
        if let error {
            lastError = error.localizedDescription
            return
        }
        guard let data = characteristic.value else { return }
        switch characteristic.uuid {
        case FlipperUUID.serialRead:
            rpcBridge?.receive(data)
        case FlipperUUID.flowControl:
            flowControlFreeSpace = data.prefix(4).reduce(0) { partial, byte in
                (partial << 8) | Int(byte)
            }
            if flowControlFreeSpace > 0 {
                rpcBridge?.updateFreeSpace(flowControlFreeSpace)
            }
        case FlipperUUID.batteryLevel:
            snapshot.batteryLevel = data.first.map(Int.init)
        case FlipperUUID.serialNumber:
            snapshot.serialNumber = String(data: data, encoding: .utf8) ?? "–"
        case FlipperUUID.firmwareRevision:
            snapshot.firmware = String(data: data, encoding: .utf8) ?? "–"
        case FlipperUUID.softwareRevision:
            snapshot.hardware = String(data: data, encoding: .utf8) ?? "–"
        case FlipperUUID.protobufRevision:
            snapshot.protobufVersion = String(data: data, encoding: .utf8) ?? "–"
        default:
            break
        }
        updateSharedWidgetState()
    }
}

private final class RPCPeripheralBridge: @unchecked Sendable, BluetoothPeripheral {
    let id: UUID
    let name: String
    let color: Peripheral.FlipperColor = .unknown
    var state: Peripheral.FlipperState = .connected
    let services: [Peripheral.FlipperService] = []

    private let peripheral: CBPeripheral
    private let serialWrite: CBCharacteristic
    private let restartCharacteristic: CBCharacteristic?
    private let writeLimit: Int
    private let lock = NSLock()
    private var freeSpace = 0

    private let infoSubject = PassthroughSubject<Void, Never>()
    private let canWriteSubject = PassthroughSubject<Void, Never>()
    private let receivedSubject = PassthroughSubject<Data, Never>()

    var info: AnyPublisher<Void, Never> { infoSubject.eraseToAnyPublisher() }
    var canWrite: AnyPublisher<Void, Never> { canWriteSubject.eraseToAnyPublisher() }
    var received: AnyPublisher<Data, Never> { receivedSubject.eraseToAnyPublisher() }

    var maximumWriteValueLength: Int {
        lock.withLock { min(freeSpace, writeLimit) }
    }

    init(
        peripheral: CBPeripheral,
        serialWrite: CBCharacteristic,
        restartSession: CBCharacteristic?,
        name: String
    ) {
        self.id = peripheral.identifier
        self.name = name
        self.peripheral = peripheral
        self.serialWrite = serialWrite
        self.restartCharacteristic = restartSession
        self.writeLimit = peripheral.maximumWriteValueLength(for: .withoutResponse)
    }

    func updateFreeSpace(_ value: Int) {
        lock.withLock { freeSpace = max(0, value) }
        if value > 0 { canWriteSubject.send(()) }
    }

    func receive(_ data: Data) {
        receivedSubject.send(data)
    }

    func send(_ data: Data) {
        lock.withLock { freeSpace = max(0, freeSpace - data.count) }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            peripheral.writeValue(data, for: serialWrite, type: .withResponse)
        }
    }

    func restartSession() {
        guard let restartCharacteristic else { return }
        DispatchQueue.main.async { [weak self] in
            self?.peripheral.writeValue(Data([0]), for: restartCharacteristic, type: .withResponse)
        }
    }

    func onConnecting() { state = .connecting }
    func onConnect() { state = .connected }
    func onDisconnect() { state = .disconnected }
    func onError(_ error: Swift.Error) {}
}
