import SwiftUI

struct DeviceInfoView: View {
    @EnvironmentObject private var bluetooth: FlipperBluetoothManager
    @State private var searchText = ""

    private var filteredItems: [DeviceInfoItem] {
        guard !searchText.isEmpty else { return bluetooth.detailedInfo }
        return bluetooth.detailedInfo.filter {
            $0.displayKey.localizedCaseInsensitiveContains(searchText) ||
                $0.value.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var exportText: String {
        var lines = ["Dolphin Deck – Geräteinformationen", bluetooth.snapshot.name, ""]
        for category in DeviceInfoCategory.allCases {
            let items = bluetooth.detailedInfo.filter { $0.category == category }
            guard !items.isEmpty else { continue }
            lines.append("[\(category.title)]")
            lines.append(contentsOf: items.map { "\($0.key): \($0.value)" })
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        List {
            if let updated = bluetooth.detailedInfoUpdatedAt {
                Section {
                    LabeledContent("Aktualisiert") {
                        Text(updated, style: .relative)
                    }
                }
            }

            ForEach(DeviceInfoCategory.allCases) { category in
                let items = filteredItems.filter { $0.category == category }
                if !items.isEmpty {
                    Section {
                        ForEach(items) { item in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.displayKey)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Text(item.value)
                                    .font(.body.monospaced())
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.vertical, 3)
                        }
                    } header: {
                        Label(category.title, systemImage: category.symbol)
                    }
                }
            }
        }
        .overlay {
            if bluetooth.isLoadingDetailedInfo {
                ProgressView("Gerätewerte werden gelesen …")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            } else if bluetooth.detailedInfo.isEmpty, let error = bluetooth.detailedInfoError {
                ContentUnavailableView(
                    "Informationen nicht verfügbar",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error))
            }
        }
        .navigationTitle("Geräteinformationen")
        .searchable(text: $searchText, prompt: "Wert oder Inhalt")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                ShareLink(item: exportText) {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(bluetooth.detailedInfo.isEmpty)
                Button {
                    Task { await bluetooth.refreshDetailedInfo() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(!bluetooth.rpcReady || bluetooth.isLoadingDetailedInfo)
            }
        }
        .task(id: bluetooth.rpcReady) {
            guard bluetooth.rpcReady, bluetooth.detailedInfo.isEmpty else { return }
            await bluetooth.refreshDetailedInfo()
        }
    }
}
