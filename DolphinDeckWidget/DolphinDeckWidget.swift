import Foundation
import SwiftUI
import WidgetKit

private let appGroup = "group.de.lukasleipacher.DolphinDeck"

private struct DeckWidgetFavorite: Identifiable, Hashable {
    let name: String
    let path: String

    var id: String { path }

    var launchURL: URL {
        var components = URLComponents()
        components.scheme = "dolphindeck"
        components.host = "run-favorite"
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        return components.url ?? URL(string: "dolphindeck://favorites")!
    }
}

private struct DeckWidgetEntry: TimelineEntry {
    let date: Date
    let connected: Bool
    let name: String
    let battery: Int?
    let favorites: Int
    let quickFavorites: [DeckWidgetFavorite]
}

private struct DeckWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> DeckWidgetEntry {
        DeckWidgetEntry(
            date: .now,
            connected: true,
            name: "Flipper Zero",
            battery: 86,
            favorites: 12,
            quickFavorites: [
                DeckWidgetFavorite(
                    name: "Garagentor",
                    path: "/ext/subghz/Garagentor.sub"),
            ])
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
        let names = defaults?.stringArray(forKey: "quickFavoriteNames") ?? []
        let paths = defaults?.stringArray(forKey: "quickFavoritePaths") ?? []
        let quickFavorites = zip(names, paths).map {
            DeckWidgetFavorite(name: $0.0, path: $0.1)
        }
        return DeckWidgetEntry(
            date: .now,
            connected: defaults?.bool(forKey: "connected") ?? false,
            name: defaults?.string(forKey: "name") ?? "Flipper Zero",
            battery: batteryValue,
            favorites: defaults?.integer(forKey: "favorites") ?? 0,
            quickFavorites: quickFavorites)
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
            if let favorite = entry.quickFavorites.first {
                Link(destination: favorite.launchURL) {
                    HStack(spacing: 6) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                        Text(favorite.name)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "play.fill")
                    }
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 7)
                    .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }
            } else if family == .systemMedium {
                Label("\(entry.favorites) File Favorites", systemImage: "star.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .widgetURL(entry.quickFavorites.first?.launchURL ?? URL(string: "dolphindeck://favorites"))
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var accessory: some View {
        HStack {
            Image(systemName: entry.connected ? "link.circle.fill" : "link.badge.plus")
            VStack(alignment: .leading) {
                Text(entry.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(entry.quickFavorites.first?.name
                     ?? entry.battery.map { "\($0)% · \(entry.favorites) Favoriten" }
                     ?? "\(entry.favorites) Favoriten")
                    .font(.caption)
            }
        }
        .widgetURL(entry.quickFavorites.first?.launchURL ?? URL(string: "dolphindeck://favorites"))
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
        .description("Flipper-Verbindung, Akku und einen File Favorite direkt ausführen.")
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
