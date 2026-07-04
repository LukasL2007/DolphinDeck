import SwiftUI

struct FileFavoritesView: View {
    @EnvironmentObject private var bluetooth: FlipperBluetoothManager
    @State private var searchText = ""

    private var searchResults: [FileFavoriteEntry] {
        bluetooth.favoritesDatabase.entries.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
                $0.path.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        List {
            statusSection

            if searchText.isEmpty {
                Section("Kategorien") {
                    ForEach(0..<17, id: \.self) { category in
                        NavigationLink {
                            FileFavoritesCategoryView(category: category)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: categorySymbol(category))
                                    .foregroundStyle(categoryColor(category))
                                    .frame(width: 26)
                                Text(categoryTitle(category, database: bluetooth.favoritesDatabase))
                                Spacer()
                                Text("\(entries(for: category, in: bluetooth.favoritesDatabase).count)")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                }

                Section("Aktionen") {
                    NavigationLink {
                        FileManagerView()
                    } label: {
                        Label("Datei hinzufügen", systemImage: "plus")
                    }

                    NavigationLink {
                        FileManagerView()
                    } label: {
                        Label("Ordner hinzufügen", systemImage: "folder.badge.plus")
                    }

                    NavigationLink {
                        FileFavoritesFoldersView()
                    } label: {
                        HStack {
                            Label("Importierte Ordner", systemImage: "folder.badge.gearshape")
                            Spacer()
                            Text("\(bluetooth.favoritesDatabase.watchedFolders.count)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Section("Suchergebnisse") {
                    if searchResults.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                    } else {
                        ForEach(searchResults) { entry in
                            favoriteRow(entry)
                        }
                    }
                }
            }
        }
        .navigationTitle("File Favorites")
        .searchable(text: $searchText, prompt: "Dateien durchsuchen")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await bluetooth.refreshFavorites() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(!bluetooth.rpcReady || bluetooth.isLoadingFavorites)
            }
        }
        .overlay {
            if bluetooth.isLoadingFavorites {
                ProgressView("FFF2-Datenbank wird gelesen …")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .task(id: bluetooth.rpcReady) {
            guard bluetooth.rpcReady else { return }
            await bluetooth.refreshFavorites()
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: bluetooth.favoritesLoaded
                      ? "checkmark.circle.fill"
                      : "exclamationmark.triangle.fill")
                    .foregroundStyle(bluetooth.favoritesLoaded ? .green : .orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(bluetooth.favoritesLoaded
                         ? "\(bluetooth.favoritesDatabase.entries.count) Einträge geladen"
                         : "Datenbank noch nicht geladen")
                        .font(.headline)
                    if let path = bluetooth.favoritesSourcePath {
                        Text(path)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    } else if let error = bluetooth.favoritesError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func favoriteRow(_ entry: FileFavoriteEntry) -> some View {
        NavigationLink {
            FileFavoriteDetailView(entry: entry, listCategory: 0)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: categorySymbol(entry.category))
                    .foregroundStyle(categoryColor(entry.category))
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.name)
                        .foregroundStyle(.primary)
                    Text(entry.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if entry.favorite {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
        .contextMenu {
            Button {
                Task {
                    await bluetooth.setFavorite(path: entry.path, enabled: !entry.favorite)
                }
            } label: {
                Label(
                    entry.favorite ? "Favorit entfernen" : "Als Favorit markieren",
                    systemImage: entry.favorite ? "star.slash" : "star")
            }
        }
    }
}

private struct FileFavoritesCategoryView: View {
    @EnvironmentObject private var bluetooth: FlipperBluetoothManager
    let category: Int

    private var categoryEntries: [FileFavoriteEntry] {
        entries(for: category, in: bluetooth.favoritesDatabase)
    }

    var body: some View {
        List {
            if categoryEntries.isEmpty {
                ContentUnavailableView(
                    "Keine Dateien hinzugefügt",
                    systemImage: categorySymbol(category),
                    description: Text("Im Dateimanager kannst du Dateien zu File Favorites hinzufügen."))
            } else {
                ForEach(categoryEntries) { entry in
                    NavigationLink {
                        FileFavoriteDetailView(entry: entry, listCategory: category)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: categorySymbol(entry.category))
                                .foregroundStyle(categoryColor(entry.category))
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.name)
                                    .foregroundStyle(.primary)
                                Text(entry.path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if entry.favorite {
                                Image(systemName: "star.fill")
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    .contextMenu {
                        Button {
                            Task {
                                await bluetooth.setFavorite(
                                    path: entry.path,
                                    enabled: !entry.favorite)
                            }
                        } label: {
                            Label(
                                entry.favorite ? "Favorit entfernen" : "Als Favorit markieren",
                                systemImage: entry.favorite ? "star.slash" : "star")
                        }
                    }
                }
            }
        }
        .navigationTitle(categoryTitle(category, database: bluetooth.favoritesDatabase))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Menu {
                ForEach(0..<6, id: \.self) { mode in
                    Button {
                        Task { await bluetooth.setFavoritesSortMode(mode, for: category) }
                    } label: {
                        if bluetooth.favoritesDatabase.sortModes[category] == mode {
                            Label(sortModeTitle(mode), systemImage: "checkmark")
                        } else {
                            Text(sortModeTitle(mode))
                        }
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
        }
    }
}

private struct FileFavoriteDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var bluetooth: FlipperBluetoothManager

    let listCategory: Int
    @State private var currentPath: String
    @State private var name: String
    @State private var category: Int
    @State private var launcherID: String
    @State private var favorite: Bool
    @State private var metadata = FavoriteFileMetadata()
    @State private var calculatedHash: String?
    @State private var statusMessage: String?
    @State private var showRiskConfirmation = false
    @State private var showRemoveConfirmation = false
    @State private var showDeleteConfirmation = false
    @State private var showRelinkPicker = false

    private let addedAt: UInt32
    private let lastOpenedAt: UInt32
    private let manualOrder: UInt32

    init(entry: FileFavoriteEntry, listCategory: Int) {
        self.listCategory = listCategory
        self.addedAt = entry.addedAt
        self.lastOpenedAt = entry.lastOpenedAt
        self.manualOrder = entry.manualOrder
        _currentPath = State(initialValue: entry.path)
        _name = State(initialValue: entry.name)
        _category = State(initialValue: entry.category)
        _launcherID = State(initialValue: entry.launcherID)
        _favorite = State(initialValue: entry.favorite)
    }

    var body: some View {
        Form {
            headerSection
            quickActionsSection
            appearanceSection
            launcherSection
            orderingSection
            relinkSection
            informationSection
            databaseSection
            dangerSection
            if let statusMessage {
                Section("Status") {
                    Text(statusMessage)
                        .font(.caption)
                }
            }
        }
        .navigationTitle("Datei-Einstellungen")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Speichern") {
                    Task {
                        await bluetooth.saveFavoriteEntry(
                            originalPath: currentPath,
                            name: name,
                            category: category,
                            launcherID: launcherID,
                            favorite: favorite)
                        statusMessage = bluetooth.favoritesError ?? "Änderungen gespeichert."
                    }
                }
                .fontWeight(.semibold)
            }
        }
        .task(id: currentPath) {
            metadata = await bluetooth.favoriteFileMetadata(at: currentPath)
        }
        .sheet(isPresented: $showRelinkPicker) {
            NavigationStack {
                FlipperFilePickerView { newItem in
                    let oldPath = currentPath
                    currentPath = newItem.path
                    name = newItem.name
                    calculatedHash = nil
                    showRelinkPicker = false
                    Task {
                        await bluetooth.relinkFavorite(
                            originalPath: oldPath,
                            to: newItem.path)
                        metadata = await bluetooth.favoriteFileMetadata(at: newItem.path)
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Abbrechen") {
                            showRelinkPicker = false
                        }
                    }
                }
            }
        }
        .confirmationDialog(
            "Diese Datei kann senden oder Aktionen ausführen.",
            isPresented: $showRiskConfirmation,
            titleVisibility: .visible
        ) {
            Button("Trotzdem öffnen") {
                openFile()
            }
            Button("Abbrechen", role: .cancel) {}
        }
        .confirmationDialog(
            "Verknüpfung aus File Favorites entfernen?",
            isPresented: $showRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Verknüpfung entfernen", role: .destructive) {
                Task {
                    await bluetooth.removeFavoriteEntry(path: currentPath)
                    dismiss()
                }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Die Originaldatei wird nicht gelöscht.")
        }
        .confirmationDialog(
            "Originaldatei endgültig löschen?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Datei endgültig löschen", role: .destructive) {
                Task {
                    do {
                        try await bluetooth.deleteStorageItem(
                            at: currentPath,
                            recursively: false)
                        dismiss()
                    } catch {
                        statusMessage = error.localizedDescription
                    }
                }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text(currentPath)
        }
    }

    private var headerSection: some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: categorySymbol(category))
                    .font(.title)
                    .foregroundStyle(categoryColor(category))
                    .frame(width: 44, height: 44)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text(name.isEmpty ? "Unbenannter Eintrag" : name)
                        .font(.headline)
                    Label(fileStatusTitle, systemImage: fileStatusSymbol)
                        .font(.caption)
                        .foregroundStyle(metadata.exists ? .green : .orange)
                }
            }
        }
    }

    private var quickActionsSection: some View {
        Section("Schnellaktionen") {
            Button {
                if category == 3 || category == 8 {
                    showRiskConfirmation = true
                } else {
                    openFile()
                }
            } label: {
                Label("In der Original-App öffnen", systemImage: "play.fill")
            }
            .disabled(!metadata.exists)

            Toggle(isOn: $favorite) {
                Label("Als Favorit markieren", systemImage: favorite ? "star.fill" : "star")
            }
        }
    }

    private var appearanceSection: some View {
        Section("Darstellung") {
            TextField("Anzeigename", text: $name)
                .textInputAutocapitalization(.never)
            Picker("Kategorie", selection: $category) {
                ForEach(3..<17, id: \.self) { value in
                    Text(categoryTitle(value, database: bluetooth.favoritesDatabase))
                        .tag(value)
                }
            }
        }
    }

    private var launcherSection: some View {
        Section {
            TextField("auto oder App-ID", text: $launcherID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            LabeledContent("Automatische App", value: automaticLauncherText)
            Button("Auf automatische Auswahl zurücksetzen") {
                launcherID = ""
            }
        } header: {
            Text("Launcher-App-ID")
        } footer: {
            Text("Eine eigene App-ID überschreibt die automatische Zuordnung. „auto“ oder ein leeres Feld setzt sie zurück.")
        }
    }

    private var orderingSection: some View {
        Section("Manuelle Reihenfolge") {
            HStack {
                Button {
                    moveEntry(down: false)
                } label: {
                    Label("Nach oben", systemImage: "arrow.up")
                }
                Spacer()
                Button {
                    moveEntry(down: true)
                } label: {
                    Label("Nach unten", systemImage: "arrow.down")
                }
            }
            LabeledContent("Manuelle Position", value: manualPositionText)
        }
    }

    private var relinkSection: some View {
        Section("Datei neu verknüpfen") {
            Button {
                showRelinkPicker = true
            } label: {
                Label("Andere Datei auswählen", systemImage: "link")
            }
            Text(currentPath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var informationSection: some View {
        Section("Dateiinformationen") {
            LabeledContent("Dateityp", value: fileExtension)
            if let sizeText {
                LabeledContent("Größe", value: sizeText)
            }
            if let modifiedText {
                LabeledContent("Geändert", value: modifiedText)
            }
            LabeledContent("Hinzugefügt", value: timestampText(addedAt))
            LabeledContent("Zuletzt geöffnet", value: lastOpenedText)
            LabeledContent("Kategorie-ID", value: String(category))
            LabeledContent("Launcher", value: launcherID.isEmpty ? "auto" : launcherID)

            if let calculatedHash {
                LabeledContent("MD5") {
                    Text(calculatedHash)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            } else {
                Button {
                    Task { await calculateHash() }
                } label: {
                    Label("MD5-Prüfsumme berechnen", systemImage: "number")
                }
                .disabled(!metadata.exists)
            }
        }
    }

    private var databaseSection: some View {
        Section {
            Button(role: .destructive) {
                showRemoveConfirmation = true
            } label: {
                Label("Nur Verknüpfung entfernen", systemImage: "link.badge.minus")
            }
        } header: {
            Text("Datenbank")
        } footer: {
            Text("Dabei bleibt die Originaldatei auf dem Flipper erhalten.")
        }
    }

    private var dangerSection: some View {
        Section("Gefahrenbereich") {
            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label("Originaldatei endgültig löschen", systemImage: "trash")
            }
            .disabled(!metadata.exists)
        }
    }

    private var fileExtension: String {
        let value = (currentPath as NSString).pathExtension
        return value.isEmpty ? "Ohne Dateiendung" : ".\(value.lowercased())"
    }

    private var fileStatusTitle: String {
        metadata.exists ? "Datei vorhanden" : "Datei nicht gefunden"
    }

    private var fileStatusSymbol: String {
        metadata.exists ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private var automaticLauncherText: String {
        defaultLauncher(for: category) ?? "Keine Zuordnung"
    }

    private var manualPositionText: String {
        String(manualOrder + 1)
    }

    private var sizeText: String? {
        guard let size = metadata.size else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    private var modifiedText: String? {
        metadata.modifiedAt?.formatted(date: .abbreviated, time: .standard)
    }

    private var lastOpenedText: String {
        lastOpenedAt == 0 ? "Noch nie" : timestampText(lastOpenedAt)
    }

    private func moveEntry(down: Bool) {
        Task {
            await bluetooth.moveFavoriteEntry(
                path: currentPath,
                in: listCategory,
                down: down)
        }
    }

    private func openFile() {
        let entry = FileFavoriteEntry(
            favorite: favorite,
            category: category,
            addedAt: addedAt,
            lastOpenedAt: lastOpenedAt,
            manualOrder: manualOrder,
            name: name,
            launcherID: launcherID,
            path: currentPath)
        Task { await bluetooth.openFavorite(entry) }
    }

    private func calculateHash() async {
        do {
            calculatedHash = try await bluetooth.favoriteFileHash(at: currentPath)
            statusMessage = "Prüfsumme berechnet."
        } catch {
            statusMessage = "Prüfsumme fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    private func timestampText(_ timestamp: UInt32) -> String {
        Date(timeIntervalSince1970: TimeInterval(timestamp))
            .formatted(date: .abbreviated, time: .shortened)
    }
}

private struct FlipperFilePickerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var bluetooth: FlipperBluetoothManager
    let path: String
    let onSelect: (FlipperStorageItem) -> Void

    @State private var items: [FlipperStorageItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    init(
        path: String = "/",
        onSelect: @escaping (FlipperStorageItem) -> Void
    ) {
        self.path = path
        self.onSelect = onSelect
    }

    var body: some View {
        List {
            if let errorMessage {
                ContentUnavailableView(
                    "Ordner nicht lesbar",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage))
            } else {
                ForEach(items) { item in
                    if item.isDirectory {
                        NavigationLink {
                            FlipperFilePickerView(
                                path: item.path,
                                onSelect: onSelect)
                        } label: {
                            Label(item.name, systemImage: "folder.fill")
                                .foregroundStyle(.orange)
                        }
                    } else {
                        Button {
                            onSelect(item)
                            dismiss()
                        } label: {
                            HStack {
                                Label(item.name, systemImage: "doc")
                                    .foregroundStyle(.primary)
                                Spacer()
                                if let size = item.size {
                                    Text(ByteCountFormatter.string(
                                        fromByteCount: Int64(size),
                                        countStyle: .file))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .overlay {
            if isLoading {
                ProgressView()
            }
        }
        .navigationTitle(path == "/" ? "Datei auswählen" : (path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: path) {
            await load()
        }
    }

    private func load() async {
        if path == "/" {
            items = [
                FlipperStorageItem(name: "SD-Karte", path: "/ext", isDirectory: true, size: nil),
                FlipperStorageItem(name: "Interner Speicher", path: "/int", isDirectory: true, size: nil),
            ]
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            items = try await bluetooth.listDirectory(at: path)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct FileFavoritesFoldersView: View {
    @EnvironmentObject private var bluetooth: FlipperBluetoothManager
    @State private var folderToRemove: String?

    var body: some View {
        List {
            if bluetooth.favoritesDatabase.watchedFolders.isEmpty {
                ContentUnavailableView(
                    "Keine importierten Ordner",
                    systemImage: "folder",
                    description: Text("Importiere Ordner in der Flipper-FAP. Sie erscheinen anschließend auch hier."))
            } else {
                ForEach(bluetooth.favoritesDatabase.watchedFolders, id: \.self) { folder in
                    Button {
                        folderToRemove = folder
                    } label: {
                        HStack {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(folder.split(separator: "/").last.map(String.init) ?? folder)
                                    .foregroundStyle(.primary)
                                Text(folder)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
        }
        .navigationTitle("Importierte Ordner")
        .confirmationDialog(
            "Importierten Ordner entfernen?",
            isPresented: Binding(
                get: { folderToRemove != nil },
                set: { if !$0 { folderToRemove = nil } }),
            titleVisibility: .visible
        ) {
            Button("Ordner und Verknüpfungen entfernen", role: .destructive) {
                guard let folderToRemove else { return }
                Task { await bluetooth.removeWatchedFolder(folderToRemove) }
                self.folderToRemove = nil
            }
            Button("Abbrechen", role: .cancel) {
                folderToRemove = nil
            }
        } message: {
            Text("Die eigentlichen Dateien bleiben auf der SD-Karte erhalten.")
        }
    }
}

private func entries(
    for category: Int,
    in database: FileFavoritesDatabase
) -> [FileFavoriteEntry] {
    let result: [FileFavoriteEntry]
    switch category {
    case 0:
        result = database.entries
    case 1:
        result = database.entries.filter(\.favorite)
    case 2:
        result = database.entries
            .filter { $0.lastOpenedAt > 0 }
            .sorted { $0.lastOpenedAt > $1.lastOpenedAt }
            .prefix(20)
            .map { $0 }
    default:
        result = database.entries.filter { $0.category == category }
    }

    if category == 2 { return result }
    switch database.sortModes[category] ?? 0 {
    case 1:
        return result.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    case 2:
        return result.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending
        }
    case 3:
        return result.sorted { $0.addedAt > $1.addedAt }
    case 4:
        return result.sorted { $0.lastOpenedAt > $1.lastOpenedAt }
    case 5:
        return result.sorted {
            ($0.path as NSString).pathExtension.localizedCaseInsensitiveCompare(
                ($1.path as NSString).pathExtension) == .orderedAscending
        }
    default:
        return result.sorted { $0.manualOrder < $1.manualOrder }
    }
}

private func categoryTitle(_ category: Int, database: FileFavoritesDatabase) -> String {
    switch category {
    case 0: "Alle Dateien"
    case 1: "Favoriten"
    case 2: "Zuletzt verwendet"
    case 3: "Sub-GHz"
    case 4: "NFC"
    case 5: "125 kHz RFID"
    case 6: "Infrarot"
    case 7: "iButton"
    case 8: "Bad KB"
    case 9: "U2F"
    case 10: "JavaScript"
    case 11: "Apps"
    case 12: "Andere Dateien"
    case 13...16:
        database.customNames[category - 13]
    default: "Unbekannt"
    }
}

private func categorySymbol(_ category: Int) -> String {
    switch category {
    case 0: "doc.on.doc"
    case 1: "star.fill"
    case 2: "clock.arrow.circlepath"
    case 3: "antenna.radiowaves.left.and.right"
    case 4: "wave.3.right"
    case 5: "sensor.tag.radiowaves.forward"
    case 6: "light.beacon.max"
    case 7: "key.horizontal"
    case 8: "keyboard"
    case 9: "person.badge.key"
    case 10: "curlybraces"
    case 11: "app.badge"
    case 12: "doc"
    default: "folder"
    }
}

private func categoryColor(_ category: Int) -> Color {
    switch category {
    case 1: .yellow
    case 3: .green
    case 4: .blue
    case 5: .yellow
    case 6: .red
    case 7: .purple
    default: .orange
    }
}

private func sortModeTitle(_ mode: Int) -> String {
    switch mode {
    case 0: "Manuell"
    case 1: "Name A–Z"
    case 2: "Name Z–A"
    case 3: "Neueste zuerst"
    case 4: "Zuletzt geöffnet"
    case 5: "Dateityp"
    default: "Manuell"
    }
}

private func defaultLauncher(for category: Int) -> String? {
    switch category {
    case 3: "subghz"
    case 4: "nfc"
    case 5: "lfrfid"
    case 6: "infrared"
    case 7: "ibutton"
    case 8: "bad_kb"
    case 9: "u2f"
    case 10: "js_app"
    case 11: "Apps"
    default: nil
    }
}
