import CryptoKit
import SwiftUI
import UserNotifications

struct DolphinDeckBridgeView: View {
    @EnvironmentObject private var bluetooth: FlipperBluetoothManager

    @State private var isInstalling = false
    @State private var installStatus: String?
    @State private var selectedRangeMode: DolphinDeckRangeMode = .direct

    private let releaseURL = URL(
        string: "https://github.com/LukasL2007/DolphinDeck/releases/latest/download/dolphin_deck_bridge.fap")!
    private let checksumURL = URL(
        string: "https://github.com/LukasL2007/DolphinDeck/releases/latest/download/dolphin_deck_bridge.fap.sha256")!
    private let installFolder = "/ext/apps/Tools"
    private let installPath = "/ext/apps/Tools/dolphin_deck_bridge.fap"

    var body: some View {
        Form {
            Section("Verbindung") {
                Label(
                    bluetooth.bridgeState.title,
                    systemImage: bluetooth.bridgeState.symbol)
                    .foregroundStyle(bridgeColor)

                Toggle(
                    "Nach Bluetooth-Verbindung automatisch starten",
                    isOn: $bluetooth.bridgeAutoStart)

                HStack {
                    Button("Bridge starten") {
                        Task { await bluetooth.startDolphinDeckBridge() }
                    }
                    .disabled(!bluetooth.rpcReady || bluetooth.bridgeState == .starting)

                    Spacer()

                    Button("Stoppen", role: .destructive) {
                        Task { await bluetooth.stopDolphinDeckBridge() }
                    }
                    .disabled(bluetooth.bridgeState != .connected)
                }
            }

            Section("Flipper-App") {
                Button {
                    Task { await installBridge() }
                } label: {
                    Label(
                        "Bridge installieren/aktualisieren",
                        systemImage: "arrow.down.app.fill")
                }
                .disabled(!bluetooth.rpcReady || isInstalling)

                if isInstalling {
                    ProgressView("Release wird geladen und übertragen …")
                }
                if let installStatus {
                    Text(installStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("FAP und SHA-256-Prüfsumme werden aus demselben GitHub-Release geladen. Erst nach erfolgreicher Integritätsprüfung wird nach \(installPath) übertragen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Reichweite & Steuerung") {
                Picker("Verbindungsmodus", selection: $selectedRangeMode) {
                    ForEach(DolphinDeckRangeMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .onChange(of: selectedRangeMode) { _, newValue in
                    Task { await bluetooth.setBridgeRangeMode(newValue) }
                }

                Text(selectedRangeMode.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if selectedRangeMode != .direct {
                    LabeledContent("Flipper UART", value: "115200 Baud, 3.3 V")
                    LabeledContent("Protokoll", value: "DD1 Textbefehle")
                }
            }

            Section("iPhone-Suchhinweis") {
                Button {
                    Task { await bluetooth.requestBridgeNotificationPermission() }
                } label: {
                    Label(
                        bluetooth.bridgeNotificationAuthorized
                            ? "Mitteilungen freigegeben"
                            : "Mitteilungen & Ton freigeben",
                        systemImage: bluetooth.bridgeNotificationAuthorized
                            ? "checkmark.circle.fill"
                            : "bell.badge.fill")
                }
                Text("„Find iPhone“ löst einen hörbaren Dolphin-Deck-Hinweis mit Vibration aus. Apples geschützter „Wo ist?“-Dauerton steht Drittanbieter-Apps nicht als API zur Verfügung.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let event = bluetooth.lastBridgeEvent {
                Section("Letzter Flipper-Befehl") {
                    Text(event)
                        .font(.body.monospaced())
                }
            }

            if let result = bluetooth.lastBridgeResult {
                Section("Status") {
                    Text(result)
                }
            }

            Section("iOS-Systemgrenzen") {
                Label("Suchton & Mitteilung", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Label("Medientasten über ESP32 BLE HID", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Label("Display sperren: keine öffentliche iOS-API", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                Label("Home/App-Wechsel: experimentell über BLE HID", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .navigationTitle("Dolphin Deck Bridge")
        .task {
            selectedRangeMode = bluetooth.bridgeRangeMode
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            if settings.authorizationStatus == .authorized ||
                settings.authorizationStatus == .provisional {
                await bluetooth.requestBridgeNotificationPermission()
            }
        }
    }

    private var bridgeColor: Color {
        switch bluetooth.bridgeState {
        case .connected: .green
        case .failed: .red
        case .starting: .orange
        default: .secondary
        }
    }

    private func installBridge() async {
        guard bluetooth.rpcReady else {
            installStatus = "Der Flipper ist nicht RPC-bereit."
            return
        }
        isInstalling = true
        defer { isInstalling = false }
        do {
            async let download = URLSession.shared.data(from: releaseURL)
            async let checksumDownload = URLSession.shared.data(from: checksumURL)
            let ((data, response), (checksumData, checksumResponse)) =
                try await (download, checksumDownload)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let checksumHTTP = checksumResponse as? HTTPURLResponse,
                  (200..<300).contains(checksumHTTP.statusCode),
                  data.count > 1_024,
                  data.prefix(4) == Data([0x7f, 0x45, 0x4c, 0x46]) else {
                throw URLError(.cannotDecodeContentData)
            }
            let expectedHash = String(decoding: checksumData, as: UTF8.self)
                .split(whereSeparator: \.isWhitespace)
                .first
                .map(String.init)?
                .lowercased()
            let actualHash = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
            guard expectedHash == actualHash else {
                throw BridgeInstallError.checksumMismatch
            }
            try await bluetooth.createDirectory(at: installFolder)
            try? await bluetooth.deleteStorageItem(at: installPath, recursively: false)
            try await bluetooth.uploadFile(data: data, to: installPath)
            installStatus = "Bridge-FAP erfolgreich installiert."
            await bluetooth.startDolphinDeckBridge()
        } catch {
            installStatus = "Installation fehlgeschlagen: \(error.localizedDescription)"
        }
    }
}

private enum BridgeInstallError: LocalizedError {
    case checksumMismatch

    var errorDescription: String? {
        "Die SHA-256-Prüfsumme der FAP stimmt nicht mit dem Release überein."
    }
}
