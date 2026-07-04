import SwiftUI
import WidgetKit

private let appGroup = "group.de.lukasleipacher.DolphinDeck"

private struct DeckWidgetEntry: TimelineEntry {
    let date: Date
    let connected: Bool
    let name: String
    let battery: Int?
    let favorites: Int
}

private struct DeckWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> DeckWidgetEntry {
        DeckWidgetEntry(
            date: .now,
            connected: true,
            name: "Flipper Zero",
            battery: 86,
            favorites: 12)
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (DeckWidgetEntry) -> Void
    ) {
        completion(entry())
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<DeckWidgetEntry>) -> Void
    ) {
        let value = entry()
        completion(Timeline(
            entries: [value],
            policy: .after(Date().addingTimeInterval(15 * 60))))
    }

    private func entry() -> DeckWidgetEntry {
        let defaults = UserDefaults(suiteName: appGroup)
        let batteryValue = defaults?.object(forKey: "battery") as? Int
        return DeckWidgetEntry(
            date: .now,
            connected: defaults?.bool(forKey: "connected") ?? false,
            name: defaults?.string(forKey: "name") ?? "Flipper Zero",
            battery: batteryValue,
            favorites: defaults?.integer(forKey: "favorites") ?? 0)
    }
}

private struct DeckWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: DeckWidgetEntry

    var body: some View {
        switch family {
        case .accessoryRectangular:
            accessory
        default:
            standard
        }
    }

    private var standard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: entry.connected
                      ? "externaldrive.fill.badge.wifi"
                      : "externaldrive.badge.xmark")
                    .foregroundStyle(entry.connected ? .green : .secondary)
                Spacer()
                if let battery = entry.battery {
                    Text("\(battery)%")
                        .font(.caption.bold())
                }
            }
            Text(entry.name)
                .font(.headline)
                .lineLimit(1)
            Text(entry.connected ? "Verbunden" : "Nicht verbunden")
                .font(.caption)
                .foregroundStyle(.secondary)
            if family == .systemMedium {
                Label("\(entry.favorites) File Favorites", systemImage: "star.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .widgetURL(URL(string: "dolphindeck://favorites"))
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var accessory: some View {
        HStack {
            Image(systemName: entry.connected ? "link.circle.fill" : "link.badge.plus")
            VStack(alignment: .leading) {
                Text(entry.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(entry.battery.map { "\($0)% · \(entry.favorites) Favoriten" } ?? "\(entry.favorites) Favoriten")
                    .font(.caption)
            }
        }
        .widgetURL(URL(string: "dolphindeck://favorites"))
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

private struct DolphinDeckStatusWidget: Widget {
    let kind = "DolphinDeckStatus"

    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: kind,
            provider: DeckWidgetProvider()
        ) { entry in
            DeckWidgetView(entry: entry)
        }
        .configurationDisplayName("Dolphin Deck")
        .description("Flipper-Verbindung, Akku und File Favorites.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .accessoryRectangular,
        ])
    }
}

@main
struct DolphinDeckWidgetBundle: WidgetBundle {
    var body: some Widget {
        DolphinDeckStatusWidget()
    }
}
