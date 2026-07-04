import SwiftUI

struct DevicesView: View {
    @EnvironmentObject private var bluetooth: FlipperBluetoothManager

    var body: some View {
        List {
            if bluetooth.isConnected {
                Section("Verbunden") {
                    LabeledContent("Name", value: bluetooth.snapshot.name)
                    LabeledContent("Seriennummer", value: bluetooth.snapshot.serialNumber)
                    LabeledContent("Firmware", value: bluetooth.snapshot.firmware)
                    Button("Verbindung trennen", role: .destructive) {
                        bluetooth.disconnect()
                    }
                }
            }

            Section("Gefundene Geräte") {
                if bluetooth.discoveredDevices.isEmpty {
                    ContentUnavailableView(
                        "Kein Flipper gefunden",
                        systemImage: "dot.radiowaves.left.and.right",
                        description: Text("Starte die Suche und halte den Flipper in der Nähe."))
                } else {
                    ForEach(bluetooth.discoveredDevices) { device in
                        Button {
                            bluetooth.connect(to: device)
                        } label: {
                            HStack {
                                Image(systemName: "externaldrive.fill.badge.wifi")
                                    .foregroundStyle(.orange)
                                VStack(alignment: .leading) {
                                    Text(device.name)
                                        .foregroundStyle(.primary)
                                    Text("\(device.rssi) dBm")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                SignalBars(level: device.signalBars)
                            }
                        }
                    }
                }
            }

            if let error = bluetooth.lastError {
                Section("Letzter Fehler") {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Flipper")
        .toolbar {
            Button {
                bluetooth.connectionState == .scanning ?
                    bluetooth.stopScanning() :
                    bluetooth.startScanning()
            } label: {
                Image(systemName: bluetooth.connectionState == .scanning ? "stop.fill" : "arrow.clockwise")
            }
        }
        .onAppear {
            if !bluetooth.isConnected {
                bluetooth.startScanning()
            }
        }
    }
}

private struct SignalBars: View {
    let level: Int

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...4, id: \.self) { bar in
                Capsule()
                    .fill(bar <= level ? Color.green : Color.secondary.opacity(0.25))
                    .frame(width: 3, height: CGFloat(4 + bar * 3))
            }
        }
    }
}
