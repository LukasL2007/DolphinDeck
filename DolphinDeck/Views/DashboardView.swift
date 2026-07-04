import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var bluetooth: FlipperBluetoothManager

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                connectionHero
                if bluetooth.isConnected {
                    deviceGrid
                } else {
                    quickConnect
                }
                shortcutsCard
                roadmapCard
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Dolphin Deck")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Image(systemName: bluetooth.connectionState.symbol)
                    .foregroundStyle(bluetooth.isConnected ? .green : .orange)
            }
        }
    }

    private var connectionHero: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(bluetooth.snapshot.name)
                        .font(.title2.bold())
                    Text(bluetooth.connectionState.title)
                        .foregroundStyle(.white.opacity(0.78))
                }
                Spacer()
                Image("DolphinDeckLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(.white.opacity(0.25), lineWidth: 1)
                    }
            }

            if let battery = bluetooth.snapshot.batteryLevel {
                HStack {
                    Image(systemName: batterySymbol(battery))
                    Text("\(battery) %")
                    Spacer()
                    Text(bluetooth.snapshot.firmware)
                }
                .font(.subheadline.weight(.semibold))
            }
        }
        .foregroundStyle(.white)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [.orange, Color(red: 0.95, green: 0.25, blue: 0.12)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: .orange.opacity(0.25), radius: 18, y: 8)
    }

    private var quickConnect: some View {
        VStack(spacing: 12) {
            Image(systemName: "wave.3.right.circle.fill")
                .font(.system(size: 42))
                .foregroundStyle(.orange)
            Text("Bereit zum Verbinden")
                .font(.headline)
            Text("Bluetooth am Flipper aktivieren und die Suche starten.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button {
                bluetooth.startScanning()
            } label: {
                Label("Flipper suchen", systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
        .deckCard()
    }

    private var deviceGrid: some View {
        LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 12) {
            MetricCard(title: "Firmware", value: bluetooth.snapshot.firmware, symbol: "cpu")
            MetricCard(
                title: "Akku",
                value: bluetooth.snapshot.batteryLevel.map { "\($0) %" } ?? "–",
                symbol: "battery.75percent")
            MetricCard(title: "Hardware", value: bluetooth.snapshot.hardware, symbol: "memorychip")
            MetricCard(title: "RPC", value: bluetooth.snapshot.protobufVersion, symbol: "arrow.left.arrow.right")
        }
    }

    private var shortcutsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Apple Kurzbefehle", systemImage: "wand.and.stars")
                .font(.headline)
            Text("„Flipper verbinden“ und „Flipper-Status“ stehen nach der Installation direkt in Kurzbefehle und Siri bereit.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .deckCard()
    }

    private var roadmapCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Als Nächstes", systemImage: "sparkles")
                .font(.headline)
            Label("File Favorites und Dateimanager sind bereit", systemImage: "star.square.on.square.fill")
            Label("Display und Tasten sind im Remote-Tab", systemImage: "rectangle.inset.filled.and.person.filled")
            Label("Automationen im Hintergrund ausführen", systemImage: "bolt.badge.clock")
        }
        .font(.subheadline)
        .deckCard()
    }

    private func batterySymbol(_ level: Int) -> String {
        switch level {
        case 76...: "battery.100percent"
        case 51...: "battery.75percent"
        case 26...: "battery.50percent"
        default: "battery.25percent"
        }
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.orange)
            Text(value)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .deckCard()
    }
}

extension View {
    func deckCard() -> some View {
        padding(16)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
