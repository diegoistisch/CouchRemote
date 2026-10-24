import Foundation

/// Ein Direktsprung in eine App, z. B. „Watchlist“ bei Crunchyroll.
public struct AppShortcut: Identifiable, Hashable, Sendable {
    public enum Action: Hashable, Sendable {
        case open(URL)
        /// Suche in dieser App (Text kommt von der iPhone-Tastatur).
        case search
    }

    public let id: String
    public let title: String
    public let systemImage: String
    public let action: Action
}

/// Bekannte Dienste: Such-Adressen und Direktlinks.
///
/// Stand der Recherche (Okt. 2026):
/// - YouTube: `/results?search_query=` ist die Adresse der normalen Suchseite; `/feed/subscriptions`,
///   `/feed/history`, `/playlist?list=WL` (Später ansehen) sind Standardseiten.
/// - Crunchyroll: `/watchlist` und `/history` existieren. `/search?q=` ist NICHT bestätigt
///   (Crunchyroll blockiert automatische Abrufe) und muss im Browser getestet werden.
/// - Netflix: `/search?q=` und `/browse/my-list`.
public enum KnownServices {
    private struct Service {
        let hostSuffix: String
        /// Such-Adresse ohne Parameter + Name des Parameters.
        let search: (base: String, parameter: String)?
        let links: [(id: String, title: String, systemImage: String, url: String)]
    }

    private static let services: [Service] = [
        Service(
            hostSuffix: "youtube.com",
            search: ("https://www.youtube.com/results", "search_query"),
            links: [
                ("subscriptions", "Abos", "play.square.stack", "https://www.youtube.com/feed/subscriptions"),
                ("watchLater", "Später ansehen", "clock", "https://www.youtube.com/playlist?list=WL"),
                ("history", "Verlauf", "clock.arrow.circlepath", "https://www.youtube.com/feed/history")
            ]
        ),
        Service(
            hostSuffix: "crunchyroll.com",
            search: ("https://www.crunchyroll.com/search", "q"),
            links: [
                ("watchlist", "Watchlist", "bookmark", "https://www.crunchyroll.com/watchlist"),
                ("history", "Verlauf", "clock.arrow.circlepath", "https://www.crunchyroll.com/history")
            ]
        ),
        Service(
            hostSuffix: "netflix.com",
            search: ("https://www.netflix.com/search", "q"),
            links: [
                ("myList", "Meine Liste", "plus.rectangle.on.rectangle", "https://www.netflix.com/browse/my-list")
            ]
        )
    ]

    private static func service(for app: HomeApp) -> Service? {
        guard let host = app.url.host?.lowercased() else { return nil }
        return services.first { host == $0.hostSuffix || host.hasSuffix("." + $0.hostSuffix) }
    }

    public static func supportsSearch(_ app: HomeApp) -> Bool {
        service(for: app)?.search != nil
    }

    public static func searchURL(for app: HomeApp, query: String) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let search = service(for: app)?.search,
              var components = URLComponents(string: search.base) else { return nil }
        // URLComponents lässt „&“ und „+“ in Werten stehen → selbst kodieren.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        components.percentEncodedQueryItems = [URLQueryItem(name: search.parameter, value: encoded)]
        return components.url
    }

    /// Schnellzugriffe für die Startseite: zuerst „Suchen“ (falls möglich), dann Direktlinks.
    public static func shortcuts(for app: HomeApp) -> [AppShortcut] {
        guard let service = service(for: app) else { return [] }
        var result: [AppShortcut] = []
        if service.search != nil {
            result.append(AppShortcut(id: "search", title: "Suchen", systemImage: "magnifyingglass", action: .search))
        }
        for link in service.links {
            if let url = URL(string: link.url) {
                result.append(AppShortcut(id: link.id, title: link.title, systemImage: link.systemImage, action: .open(url)))
            }
        }
        return result
    }
}
