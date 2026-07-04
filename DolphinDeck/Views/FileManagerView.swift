import SwiftUI
import UniformTypeIdentifiers

struct FileManagerView: View {
    @EnvironmentObject private var bluetooth: FlipperBluetoothManager
    let path: String

    @State private var items: [FlipperStorageItem] = []
    @State private var isLoading = false
    @State private var isOperating = false
    @State private var errorMessage: String?
    @State private var operationMessage: String?
    @State private var deleteCandidate: FlipperStorageItem?
    @State private var showFileImporter = false
    @State private var showFolderImporter = false
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var selection = Set<String>()
    @State private var isSelecting = false
    @State private var showBatchDelete = false
    @State private var showRename = false
    @State private var renameText = ""

    private var selectedItems: [FlipperStorageItem] {
        items.filter { selection.contains($0.path) }
    }

    init(path: String = "/ext") {
        self.path = path
    }

    private var canManageItems: Bool {
        path != "/"
    }

    private var hasSelection: Bool {
        !selection.isEmpty
    }

    private var clipboardActionTitle: String {
        bluetooth.fileClipboardMode == .copy ? "Paste" : "Move"
    }

    private var clipboardActionSymbol: String {
        bluetooth.fileClipboardMode == .copy ? "doc.on.clipboard" : "arrow.right.doc.on.clipboard"
    }

    private var clipboardSectionSymbol: String {
        bluetooth.fileClipboardMode == .copy ? "doc.on.doc" : "arrow.right.doc.on.clipboard"
    }

    private var otherStoragePath: String {
        path == "/ext" ? "/int" : "/ext"
    }

    private var otherStorageTitle: String {
        path == "/ext" ? "Interner Speicher" : "SD-Karte"
    }

    private var otherStorageSymbol: String {
        path == "/ext" ? "internaldrive" : "sdcard"
    }

    var body: some View {
        List {
            Section {
                Label(path, systemImage: "externaldrive.fill")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if path == "/ext" || path == "/int" {
                Section("Speicherorte") {
                    NavigationLink {
                        FileManagerView(path: otherStoragePath)
                    } label: {
                        Label(otherStorageTitle, systemImage: otherStorageSymbol)
                    }
                }
            }

            if path != "/", !bluetooth.fileClipboard.isEmpty {
                Section("Zwischenablage") {
                    Button {
                        Task { await pasteClipboard() }
                    } label: {
                        HStack {
                            Label(
                                "\(bluetooth.fileClipboard.count) Einträge hier einfügen",
                                systemImage: clipboardSectionSymbol)
                            Spacer()
                            Text(bluetooth.fileClipboardMode.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button("Zwischenablage leeren", role: .destructive) {
                        bluetooth.clearFileClipboard()
                    }
                }
            }

            if let errorMessage {
                ContentUnavailableView(
                    "Ordner nicht lesbar",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage))
            } else {
                ForEach(items) { item in
                    storageRow(item)
                }
            }

            if let operationMessage {
                Section("Letzte Aktion") {
                    Text(operationMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let operationError = bluetooth.fileOperationError {
                Section("Nicht vollständig ausgeführt") {
                    Text(operationError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .overlay {
            if let progress = bluetooth.fileOperationProgress {
                VStack(spacing: 10) {
                    ProgressView(value: progress.fraction)
                        .frame(width: 190)
                    Text("\(progress.title) · \(progress.completed)/\(progress.total)")
                        .font(.caption)
                }
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            } else if isLoading || isOperating {
                ProgressView(isOperating ? "Dateivorgang läuft …" : "Ordner wird geladen …")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            } else if items.isEmpty, errorMessage == nil {
                ContentUnavailableView("Ordner ist leer", systemImage: "folder")
            }
        }
        .navigationTitle(path == "/" ? "Dateimanager" : (path.split(separator: "/").last.map(String.init) ?? path))
        .toolbar {
            if canManageItems {
                ToolbarItem(placement: .topBarLeading) {
                    Button(isSelecting ? "Fertig" : "Auswählen") {
                        withAnimation {
                            isSelecting.toggle()
                            if !isSelecting { selection.removeAll() }
                        }
                    }
                }
            }
            if canManageItems, isSelecting {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(selection.count == items.count ? "Keine" : "Alle") {
                        toggleAllItems()
                    }
                    .disabled(items.isEmpty)
                }

                ToolbarItemGroup(placement: .bottomBar) {
                    Button {
                        prepareClipboard(mode: .copy)
                    } label: {
                        Label("Kopieren", systemImage: "doc.on.doc")
                            .labelStyle(.iconOnly)
                    }
                    .disabled(!hasSelection || isOperating)

                    Button {
                        prepareClipboard(mode: .move)
                    } label: {
                        Label("Ausschneiden", systemImage: "scissors")
                            .labelStyle(.iconOnly)
                    }
                    .disabled(!hasSelection || isOperating)

                    Text("\(selection.count) ausgewählt")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)

                    if !bluetooth.fileClipboard.isEmpty {
                        Button {
                            Task { await pasteClipboard() }
                        } label: {
                            Label(clipboardActionTitle, systemImage: clipboardActionSymbol)
                                .labelStyle(.iconOnly)
                        }
                        .disabled(isOperating)
                    }

                    Menu {
                        selectionMoreMenu
                    } label: {
                        Label("Mehr", systemImage: "ellipsis.circle")
                            .labelStyle(.iconOnly)
                    }
                    .disabled(!hasSelection || isOperating)

                    Button(role: .destructive) {
                        showBatchDelete = true
                    } label: {
                        Label("Löschen", systemImage: "trash")
                            .labelStyle(.iconOnly)
                    }
                    .disabled(!hasSelection || isOperating)
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if canManageItems, !isSelecting {
                    Menu {
                        Button {
                            showFileImporter = true
                        } label: {
                            Label("Dateien hochladen", systemImage: "doc.badge.plus")
                        }
                        Button {
                            showFolderImporter = true
                        } label: {
                            Label("Ordnerstruktur hochladen", systemImage: "folder.badge.plus")
                        }
                        Button {
                            showNewFolder = true
                        } label: {
                            Label("Neuer Ordner", systemImage: "folder.badge.plus")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(isOperating)
                }

                if canManageItems, !isSelecting {
                    Menu {
                        fileActionsMenu
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .disabled(isOperating || (!hasSelection && bluetooth.fileClipboard.isEmpty))
                }

                if !isSelecting {
                    Button {
                        Task { await load() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isOperating)
                }
            }
        }
        .task(id: path) {
            await load()
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            Task { await importFiles(result) }
        }
        .fileImporter(
            isPresented: $showFolderImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: true
        ) { result in
            Task { await importFolders(result) }
        }
        .alert("Neuer Ordner", isPresented: $showNewFolder) {
            TextField("Ordnername", text: $newFolderName)
            Button("Anlegen") {
                let name = newFolderName
                newFolderName = ""
                Task { await createFolder(named: name) }
            }
            Button("Abbrechen", role: .cancel) {
                newFolderName = ""
            }
        } message: {
            Text("Der Ordner wird unter \(path) angelegt.")
        }
        .alert("Umbenennen", isPresented: $showRename) {
            TextField("Neuer Name", text: $renameText)
            Button("Umbenennen") {
                Task { await renameSelectedItem() }
            }
            Button("Abbrechen", role: .cancel) {}
        }
        .confirmationDialog(
            "\(selection.count) ausgewählte Einträge löschen?",
            isPresented: $showBatchDelete,
            titleVisibility: .visible
        ) {
            Button("Dateien und Ordner endgültig löschen", role: .destructive) {
                Task { await deleteSelection() }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Ordner werden einschließlich ihres gesamten Inhalts gelöscht.")
        }
        .confirmationDialog(
            deleteCandidate?.isDirectory == true
                ? "Kompletten Ordner löschen?"
                : "Datei löschen?",
            isPresented: Binding(
                get: { deleteCandidate != nil },
                set: { if !$0 { deleteCandidate = nil } }),
            titleVisibility: .visible
        ) {
            Button("Endgültig löschen", role: .destructive) {
                guard let deleteCandidate else { return }
                Task { await delete(deleteCandidate) }
                self.deleteCandidate = nil
            }
            Button("Abbrechen", role: .cancel) {
                deleteCandidate = nil
            }
        } message: {
            if let deleteCandidate {
                Text(deleteCandidate.isDirectory
                     ? "Alle enthaltenen Dateien und Unterordner werden vom Flipper gelöscht."
                     : deleteCandidate.path)
            }
        }
    }

    @ViewBuilder
    private func storageRow(_ item: FlipperStorageItem) -> some View {
        if isSelecting {
            Button {
                toggleSelection(for: item)
            } label: {
                HStack(spacing: 12) {
                    selectionIndicator(for: item)
                    fileRow(item)
                }
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
        } else if item.isDirectory {
            HStack(spacing: 10) {
                selectionButton(for: item)
                NavigationLink {
                    FileManagerView(path: item.path)
                } label: {
                    fileRow(item)
                }
            }
            .modifier(StorageDeleteActions(
                enabled: path != "/",
                onImportFavorites: {
                    Task { await bluetooth.importFavoritesFolder(item.path) }
                },
                onDelete: { deleteCandidate = item }))
        } else {
            HStack(spacing: 10) {
                selectionButton(for: item)
                NavigationLink {
                    FlipperFileDetailView(item: item)
                } label: {
                    fileRow(item)
                }
            }
            .contextMenu {
                Button {
                    Task { await bluetooth.setFavorite(path: item.path, enabled: true) }
                } label: {
                    Label("Zu File Favorites", systemImage: "star")
                }
                Button {
                    Task { await bluetooth.launchFile(at: item.path) }
                } label: {
                    Label("Auf Flipper öffnen", systemImage: "play.fill")
                }
                Button(role: .destructive) {
                    deleteCandidate = item
                } label: {
                    Label("Löschen", systemImage: "trash")
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    deleteCandidate = item
                } label: {
                    Label("Löschen", systemImage: "trash")
                }
            }
        }
    }

    private func fileRow(_ item: FlipperStorageItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                .foregroundStyle(item.isDirectory ? .orange : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .lineLimit(1)
                if let size = item.size {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func selectionButton(for item: FlipperStorageItem) -> some View {
        Button {
            withAnimation {
                isSelecting = true
                toggleSelection(for: item)
            }
        } label: {
            selectionIndicator(for: item)
                .frame(width: 30, height: 42)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.name) auswählen")
    }

    private func selectionIndicator(for item: FlipperStorageItem) -> some View {
        Image(systemName: selection.contains(item.path) ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(selection.contains(item.path) ? .orange : .secondary)
    }

    @ViewBuilder
    private var fileActionsMenu: some View {
        if hasSelection {
            Button {
                prepareClipboard(mode: .copy)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }

            Button {
                prepareClipboard(mode: .move)
            } label: {
                Label("Cut", systemImage: "scissors")
            }

            if selection.count == 1 {
                Button {
                    renameText = selectedItems.first?.name ?? ""
                    showRename = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
            }

            Button {
                Task { await addSelectionToFavorites() }
            } label: {
                Label("Zu File Favorites", systemImage: "star")
            }

            Button(role: .destructive) {
                showBatchDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }

        if !bluetooth.fileClipboard.isEmpty {
            if hasSelection {
                Divider()
            }

            Button {
                Task { await pasteClipboard() }
            } label: {
                Label(clipboardActionTitle, systemImage: clipboardActionSymbol)
            }

            Button("Zwischenablage leeren", role: .destructive) {
                bluetooth.clearFileClipboard()
                operationMessage = "Zwischenablage geleert."
            }
        }
    }

    @ViewBuilder
    private var selectionMoreMenu: some View {
        Button {
            prepareClipboard(mode: .copy)
        } label: {
            Label("Kopieren", systemImage: "doc.on.doc")
        }

        Button {
            prepareClipboard(mode: .move)
        } label: {
            Label("Ausschneiden", systemImage: "scissors")
        }

        if selection.count == 1 {
            Button {
                renameText = selectedItems.first?.name ?? ""
                showRename = true
            } label: {
                Label("Umbenennen", systemImage: "pencil")
            }
        }

        Button {
            Task { await addSelectionToFavorites() }
        } label: {
            Label("Zu File Favorites", systemImage: "star")
        }

        if !bluetooth.fileClipboard.isEmpty {
            Divider()
            Button {
                Task { await pasteClipboard() }
            } label: {
                Label(clipboardActionTitle, systemImage: clipboardActionSymbol)
            }
            Button("Zwischenablage leeren", role: .destructive) {
                bluetooth.clearFileClipboard()
                operationMessage = "Zwischenablage geleert."
            }
        }

        Divider()
        Button(role: .destructive) {
            showBatchDelete = true
        } label: {
            Label("Löschen", systemImage: "trash")
        }
    }

    private func load() async {
        guard bluetooth.rpcReady else {
            errorMessage = "RPC ist noch nicht bereit."
            return
        }
        if path == "/" {
            items = [
                FlipperStorageItem(name: "SD-Karte", path: "/ext", isDirectory: true, size: nil),
                FlipperStorageItem(name: "Interner Speicher", path: "/int", isDirectory: true, size: nil),
            ]
            errorMessage = nil
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            items = try await bluetooth.listDirectory(at: path)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func pasteClipboard() async {
        isOperating = true
        defer { isOperating = false }
        let success = await bluetooth.pasteFileClipboard(into: path)
        operationMessage = success
            ? "Zwischenablage vollständig eingefügt."
            : "Einige Einträge konnten nicht eingefügt werden."
        await load()
    }

    private func deleteSelection() async {
        let targets = selectedItems
        guard !targets.isEmpty else { return }
        isOperating = true
        defer { isOperating = false }
        let success = await bluetooth.deleteStorageItems(targets)
        operationMessage = success
            ? "\(targets.count) Einträge gelöscht."
            : "Einige Einträge konnten nicht gelöscht werden."
        finishSelection()
        await load()
    }

    private func renameSelectedItem() async {
        guard let item = selectedItems.first else { return }
        isOperating = true
        defer { isOperating = false }
        do {
            try await bluetooth.renameStorageItem(item, to: renameText)
            operationMessage = "„\(item.name)“ wurde umbenannt."
            finishSelection()
            await load()
        } catch {
            errorMessage = "Umbenennen fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    private func addSelectionToFavorites() async {
        let targets = selectedItems
        guard !targets.isEmpty else { return }
        isOperating = true
        defer { isOperating = false }
        for item in targets {
            if item.isDirectory {
                await bluetooth.importFavoritesFolder(item.path)
            } else {
                await bluetooth.setFavorite(path: item.path, enabled: true)
            }
        }
        operationMessage = "\(targets.count) Einträge an File Favorites übergeben."
        finishSelection()
    }

    private func finishSelection() {
        selection.removeAll()
        isSelecting = false
    }

    private func prepareClipboard(mode: FileClipboardMode) {
        let targets = selectedItems
        guard !targets.isEmpty else { return }
        bluetooth.setFileClipboard(targets, mode: mode)
        operationMessage = mode == .copy
            ? "\(targets.count) Einträge für Copy vorgemerkt."
            : "\(targets.count) Einträge für Cut vorgemerkt."
        finishSelection()
    }

    private func toggleSelection(for item: FlipperStorageItem) {
        if selection.contains(item.path) {
            selection.remove(item.path)
        } else {
            selection.insert(item.path)
        }
    }

    private func toggleAllItems() {
        if selection.count == items.count {
            selection.removeAll()
        } else {
            selection = Set(items.map(\.path))
        }
    }

    private func importFiles(_ result: Result<[URL], Error>) async {
        do {
            let urls = try result.get()
            guard !urls.isEmpty else { return }
            isOperating = true
            errorMessage = nil
            defer { isOperating = false }

            var uploaded = 0
            for url in urls {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let values = try url.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else { continue }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                try await bluetooth.uploadFile(
                    data: data,
                    to: childPath(url.lastPathComponent))
                uploaded += 1
            }
            operationMessage = "\(uploaded) Datei\(uploaded == 1 ? "" : "en") hochgeladen."
            await load()
        } catch {
            isOperating = false
            errorMessage = "Upload fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    private func importFolders(_ result: Result<[URL], Error>) async {
        do {
            let urls = try result.get()
            guard !urls.isEmpty else { return }
            isOperating = true
            errorMessage = nil
            defer { isOperating = false }

            var uploadedFiles = 0
            for folderURL in urls {
                let access = folderURL.startAccessingSecurityScopedResource()
                defer { if access { folderURL.stopAccessingSecurityScopedResource() } }

                let remoteRoot = childPath(folderURL.lastPathComponent)
                try await bluetooth.createDirectory(at: remoteRoot)
                let localItems = try collectFolderItems(at: folderURL)
                for localItem in localItems {
                    let remotePath = remoteRoot + "/" + localItem.relativePath
                    if localItem.isDirectory {
                        try await bluetooth.createDirectory(at: remotePath)
                    } else {
                        let data = try Data(contentsOf: localItem.url, options: .mappedIfSafe)
                        try await bluetooth.uploadFile(data: data, to: remotePath)
                        uploadedFiles += 1
                    }
                }
            }
            operationMessage = "\(uploadedFiles) Dateien samt Ordnerstruktur hochgeladen."
            await load()
        } catch {
            isOperating = false
            errorMessage = "Ordnerimport fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    private func createFolder(named rawName: String) async {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/") else {
            errorMessage = "Der Ordnername darf nicht leer sein und keinen Schrägstrich enthalten."
            return
        }
        isOperating = true
        defer { isOperating = false }
        do {
            try await bluetooth.createDirectory(at: childPath(name))
            operationMessage = "Ordner „\(name)“ angelegt."
            await load()
        } catch {
            errorMessage = "Ordner konnte nicht angelegt werden: \(error.localizedDescription)"
        }
    }

    private func delete(_ item: FlipperStorageItem) async {
        isOperating = true
        errorMessage = nil
        defer { isOperating = false }
        do {
            try await bluetooth.deleteStorageItem(
                at: item.path,
                recursively: item.isDirectory)
            operationMessage = "„\(item.name)“ wurde gelöscht."
            await load()
        } catch {
            errorMessage = "Löschen fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    private func childPath(_ name: String) -> String {
        let cleanName = name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path.hasSuffix("/") ? path + cleanName : path + "/" + cleanName
    }
}

private struct LocalFolderItem: Sendable {
    let url: URL
    let relativePath: String
    let isDirectory: Bool
}

private func collectFolderItems(at folderURL: URL) throws -> [LocalFolderItem] {
    let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
    guard let enumerator = FileManager.default.enumerator(
        at: folderURL,
        includingPropertiesForKeys: keys,
        options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
        return []
    }

    var result: [LocalFolderItem] = []
    for case let localURL as URL in enumerator {
        let relative = String(localURL.path.dropFirst(folderURL.path.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !relative.isEmpty else { continue }
        let values = try localURL.resourceValues(forKeys: Set(keys))
        if values.isDirectory == true {
            result.append(LocalFolderItem(
                url: localURL,
                relativePath: relative,
                isDirectory: true))
        } else if values.isRegularFile == true {
            result.append(LocalFolderItem(
                url: localURL,
                relativePath: relative,
                isDirectory: false))
        }
    }
    return result
}

private struct StorageDeleteActions: ViewModifier {
    let enabled: Bool
    let onImportFavorites: () -> Void
    let onDelete: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .contextMenu {
                    Button(action: onImportFavorites) {
                        Label("In File Favorites importieren", systemImage: "star.square.on.square")
                    }
                    Button(role: .destructive, action: onDelete) {
                        Label("Ordner vollständig löschen", systemImage: "trash")
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive, action: onDelete) {
                        Label("Löschen", systemImage: "trash")
                    }
                }
        } else {
            content
        }
    }
}

private struct FlipperFileDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var bluetooth: FlipperBluetoothManager
    let item: FlipperStorageItem
    @State private var confirmDelete = false
    @State private var errorMessage: String?

    private var isFavorite: Bool {
        bluetooth.favoritesDatabase.entries.contains { $0.path == item.path && $0.favorite }
    }

    var body: some View {
        List {
            Section("Datei") {
                LabeledContent("Name", value: item.name)
                LabeledContent("Pfad") {
                    Text(item.path)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
                if let size = item.size {
                    LabeledContent(
                        "Größe",
                        value: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                }
            }

            Section("Aktionen") {
                NavigationLink {
                    FilePreviewEditorView(item: item)
                } label: {
                    Label("Vorschau & Editor", systemImage: "doc.text.magnifyingglass")
                }

                Button {
                    Task { await bluetooth.launchFile(at: item.path) }
                } label: {
                    Label("Auf dem Flipper öffnen", systemImage: "play.fill")
                }

                Button {
                    Task { await bluetooth.setFavorite(path: item.path, enabled: !isFavorite) }
                } label: {
                    Label(
                        isFavorite ? "Aus File Favorites entfernen" : "Zu File Favorites hinzufügen",
                        systemImage: isFavorite ? "star.slash" : "star")
                }

                Button("Datei löschen", systemImage: "trash", role: .destructive) {
                    confirmDelete = true
                }
            }

            if let errorMessage {
                Section("Fehler") {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Datei endgültig löschen?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Löschen", role: .destructive) {
                Task {
                    do {
                        try await bluetooth.deleteStorageItem(at: item.path, recursively: false)
                        dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text(item.path)
        }
    }
}
