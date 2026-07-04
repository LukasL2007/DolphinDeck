import SwiftUI

struct FilePreviewEditorView: View {
    @EnvironmentObject private var bluetooth: FlipperBluetoothManager
    let item: FlipperStorageItem

    @State private var text = ""
    @State private var originalText = ""
    @State private var hexPreview = ""
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var savedMessage: String?

    private var canEdit: Bool {
        !originalText.isEmpty || (!isLoading && hexPreview.isEmpty)
    }

    private var interestingFields: [(String, String)] {
        let keys = [
            "Filetype", "Version", "Device type", "Protocol", "Frequency",
            "Preset", "Modulation", "UID", "Name", "Address",
        ]
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  keys.contains(where: { $0.caseInsensitiveCompare(parts[0]) == .orderedSame }) else {
                return nil
            }
            return (
                parts[0],
                parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    var body: some View {
        List {
            if !interestingFields.isEmpty {
                Section("Erkannte Felder") {
                    ForEach(Array(interestingFields.enumerated()), id: \.offset) { _, field in
                        LabeledContent(field.0, value: field.1)
                    }
                }
            }

            Section {
                if isLoading {
                    ProgressView("Datei wird geladen …")
                } else if let errorMessage {
                    ContentUnavailableView(
                        "Vorschau nicht verfügbar",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage))
                } else if !hexPreview.isEmpty {
                    ScrollView(.horizontal) {
                        Text(hexPreview)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                } else {
                    TextEditor(text: $text)
                        .font(.body.monospaced())
                        .frame(minHeight: 360)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            } header: {
                Text(hexPreview.isEmpty ? "Textinhalt" : "Hex-Vorschau")
            } footer: {
                if let savedMessage {
                    Text(savedMessage)
                        .foregroundStyle(.green)
                } else if canEdit {
                    Text("Änderungen werden erst mit „Speichern“ auf den Flipper übertragen.")
                }
            }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canEdit {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Speichern") {
                        Task { await save() }
                    }
                    .disabled(isSaving || text == originalText)
                }
            }
        }
        .task {
            await load()
        }
    }

    private func load() async {
        guard item.size.map({ $0 <= 2_000_000 }) ?? true else {
            errorMessage = "Dateien über 2 MB werden aus Stabilitätsgründen nicht im Editor geöffnet."
            isLoading = false
            return
        }
        do {
            let data = try await bluetooth.readFile(at: item.path)
            if let decoded = String(data: data, encoding: .utf8) {
                text = decoded
                originalText = decoded
            } else {
                hexPreview = data.prefix(2_048).enumerated().map { index, byte in
                    let value = String(format: "%02X", byte)
                    return (index + 1).isMultiple(of: 16) ? value + "\n" : value + " "
                }.joined()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await bluetooth.uploadFile(
                data: Data(text.utf8),
                to: item.path)
            originalText = text
            savedMessage = "Datei erfolgreich gespeichert."
        } catch {
            errorMessage = "Speichern fehlgeschlagen: \(error.localizedDescription)"
        }
    }
}
