import SwiftUI

struct RemoteControlView: View {
    @EnvironmentObject private var bluetooth: FlipperBluetoothManager

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                statusCard
                displayCard
                remotePad
                actionButtons
                if let message = bluetooth.lastRPCMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Remote")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            remoteTimelineBar
        }
        .task(id: bluetooth.rpcReady) {
            if bluetooth.rpcReady {
                await bluetooth.startScreenStream()
                await bluetooth.refreshLockState()
            }
        }
        .onDisappear {
            Task { await bluetooth.stopScreenStream() }
        }
    }

    private var displayCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Flipper Display", systemImage: "rectangle.inset.filled")
                    .font(.headline)
                Spacer()
                if bluetooth.isScreenStreaming {
                    Circle()
                        .fill(.green)
                        .frame(width: 8, height: 8)
                    Text("LIVE")
                        .font(.caption.bold())
                        .foregroundStyle(.green)
                } else if bluetooth.rpcReady {
                    Button("Starten") {
                        Task { await bluetooth.startScreenStream() }
                    }
                    .font(.caption.bold())
                }
            }

            FlipperDisplayCanvas(pixels: bluetooth.screenPixels)
                .aspectRatio(2, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.white.opacity(0.12), lineWidth: 1)
                }
        }
        .deckCard()
    }

    private var statusCard: some View {
        HStack(spacing: 12) {
            Image(systemName: bluetooth.rpcReady ? "checkmark.circle.fill" : "ellipsis.circle")
                .font(.title2)
                .foregroundStyle(bluetooth.rpcReady ? .green : .orange)
            VStack(alignment: .leading) {
                Text(bluetooth.rpcReady ? "RPC bereit" : "RPC wird vorbereitet")
                    .font(.headline)
                Text(bluetooth.isConnected ? bluetooth.snapshot.name : "Flipper nicht verbunden")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if bluetooth.activeRemoteCommand != nil {
                ProgressView()
            } else if !bluetooth.pendingRemoteCommands.isEmpty {
                Text("\(bluetooth.pendingRemoteCommands.count) wartet")
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
            }
        }
        .deckCard()
    }

    private var remotePad: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 36, style: .continuous)
                .fill(.thinMaterial)
                .frame(height: 330)

            VStack(spacing: 14) {
                RemotePadButton(button: .up)
                HStack(spacing: 28) {
                    RemotePadButton(button: .left)
                    RemotePadButton(button: .ok, accent: true)
                    RemotePadButton(button: .right)
                }
                RemotePadButton(button: .down)
            }
        }
        .environmentObject(bluetooth)
        .opacity(bluetooth.rpcReady ? 1 : 0.45)
        .allowsHitTesting(bluetooth.rpcReady)
    }

    private var remoteTimelineBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Tasten")
                    .font(.caption.bold())
                Text(bluetooth.pendingRemoteCommands.isEmpty ? "Verlauf" : "Als Nächstes")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider()
                .frame(height: 38)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if let active = bluetooth.activeRemoteCommand {
                        RemoteTimelineSymbol(
                            button: active.button,
                            color: .orange,
                            showsProgress: true)
                    }

                    ForEach(bluetooth.pendingRemoteCommands) { command in
                        RemoteTimelineSymbol(
                            button: command.button,
                            color: .orange.opacity(0.75))
                    }

                    if bluetooth.activeRemoteCommand == nil,
                       bluetooth.pendingRemoteCommands.isEmpty {
                        ForEach(
                            Array(bluetooth.remoteHistory.prefix(20).enumerated()),
                            id: \.offset
                        ) { entry in
                            RemoteTimelineSymbol(
                                button: entry.element,
                                color: .secondary)
                        }
                    }

                    if bluetooth.activeRemoteCommand == nil,
                       bluetooth.pendingRemoteCommands.isEmpty,
                       bluetooth.remoteHistory.isEmpty {
                        Text("Noch keine Eingaben")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 8)
            }

            Button {
                bluetooth.clearRemoteHistory()
            } label: {
                Image(systemName: "trash")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(bluetooth.remoteHistory.isEmpty)
        }
        .padding(.horizontal, 14)
        .frame(height: 68)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    bluetooth.enqueueRemotePress(.back)
                } label: {
                    Label("Zurück", systemImage: "arrow.uturn.backward")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    Task { await bluetooth.playAlert() }
                } label: {
                    Label("Finden", systemImage: "bell.and.waves.left.and.right.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            Button {
                Task { await bluetooth.unlockFlipper() }
            } label: {
                HStack {
                    if bluetooth.isUnlockingFlipper {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: bluetooth.isFlipperLocked == false
                              ? "lock.open.fill"
                              : "lock.open")
                    }
                    Text(bluetooth.isUnlockingFlipper
                         ? "Flipper wird entsperrt …"
                         : (bluetooth.isFlipperLocked == false
                            ? "Flipper ist entsperrt"
                            : "Flipper entsperren"))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .disabled(
                bluetooth.isUnlockingFlipper ||
                bluetooth.activeRemoteCommand != nil ||
                !bluetooth.pendingRemoteCommands.isEmpty)
        }
        .disabled(!bluetooth.rpcReady)
    }
}

private struct RemoteTimelineSymbol: View {
    let button: RemoteButton
    let color: Color
    var showsProgress = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.15))
            Image(systemName: button.symbol)
                .font(.caption.bold())
                .foregroundStyle(color)
            if showsProgress {
                ProgressView()
                    .controlSize(.mini)
                    .offset(x: 13, y: -13)
            }
        }
        .frame(width: 34, height: 34)
        .accessibilityLabel(button.title)
    }
}

private struct FlipperDisplayCanvas: View {
    let pixels: [Bool]?

    var body: some View {
        Canvas { context, size in
            let background = Path(CGRect(origin: .zero, size: size))
            context.fill(background, with: .color(Color(red: 0.94, green: 0.52, blue: 0.12)))

            guard let pixels, pixels.count == 128 * 64 else { return }
            let pixelWidth = size.width / 128
            let pixelHeight = size.height / 64
            var activePixels = Path()
            for index in pixels.indices where pixels[index] {
                let x = CGFloat(index % 128) * pixelWidth
                let y = CGFloat(index / 128) * pixelHeight
                activePixels.addRect(
                    CGRect(x: x, y: y, width: pixelWidth + 0.15, height: pixelHeight + 0.15))
            }
            context.fill(activePixels, with: .color(Color(red: 0.12, green: 0.09, blue: 0.05)))
        }
        .overlay {
            if pixels == nil {
                VStack(spacing: 6) {
                    Image(systemName: "display")
                    Text("Warte auf Displaydaten …")
                        .font(.caption)
                }
                .foregroundStyle(.black.opacity(0.55))
            }
        }
        .accessibilityLabel("Live-Display des Flipper Zero")
    }
}

private struct RemotePadButton: View {
    @EnvironmentObject private var bluetooth: FlipperBluetoothManager
    let button: RemoteButton
    var accent = false

    var body: some View {
        Button {
            bluetooth.enqueueRemotePress(button)
        } label: {
            Image(systemName: button.symbol)
                .font(accent ? .title3 : .title2.bold())
                .frame(width: 72, height: 72)
                .background(
                    accent ? AnyShapeStyle(Color.orange.gradient) : AnyShapeStyle(.ultraThinMaterial),
                    in: Circle())
                .foregroundStyle(accent ? .white : .primary)
                .shadow(color: accent ? .orange.opacity(0.3) : .clear, radius: 12, y: 5)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(button.title)
    }
}
