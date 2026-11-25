import Foundation

/// Live-Daten eines Animes von AniList, wie sie in einem `AnimeEntry` gespeichert werden.
///
/// Der Mac holt sie regelmäßig neu (`AniListClient.media(ids:)`), das iPhone bekommt sie mit der Anime-Liste.
public struct AniListInfo: Codable, Equatable, Hashable, Sendable {
    public var id: Int
    /// `FINISHED`, `RELEASING`, `NOT_YET_RELEASED`, `CANCELLED` oder `HIATUS`.
    public var status: String
    /// Folgen insgesamt, `nil`, solange AniList es nicht weiß (z. B. bei langen Serien).
    public var episodes: Int?
    public var nextEpisode: Int?
    public var nextAiringAt: Date?
    /// Zuletzt ausgestrahlte Folge (nur, wenn sie in den letzten Wochen kam).
    public var lastEpisode: Int?
    public var lastAiredAt: Date?
    public var coverURL: URL?
    public var siteURL: URL?
    /// Wann der Mac die Daten zuletzt geholt hat.
    public var syncedAt: Date

    public init(id: Int, status: String, episodes: Int? = nil, nextEpisode: Int? = nil, nextAiringAt: Date? = nil,
                lastEpisode: Int? = nil, lastAiredAt: Date? = nil, coverURL: URL? = nil, siteURL: URL? = nil,
                syncedAt: Date = Date()) {
        self.id = id
        self.status = status
        self.episodes = episodes
        self.nextEpisode = nextEpisode
        self.nextAiringAt = nextAiringAt
        self.lastEpisode = lastEpisode
        self.lastAiredAt = lastAiredAt
        self.coverURL = coverURL
        self.siteURL = siteURL
        self.syncedAt = syncedAt
    }

    /// Fertig ausgestrahlt (oder abgebrochen): Es kommt nichts mehr.
    public var isOver: Bool { status == "FINISHED" || status == "CANCELLED" }

    /// „Läuft“, „Abgeschlossen“, …
    public var statusText: String { AniListMedia.statusText(status) }
}

/// Ein Anime, wie ihn die AniList-API liefert (Suchtreffer oder Aktualisierung).
public struct AniListMedia: Identifiable, Equatable, Sendable {
    public var id: Int
    public var title: String
    public var status: String
    public var episodes: Int?
    public var nextEpisode: Int?
    public var nextAiringAt: Date?
    public var lastEpisode: Int?
    public var lastAiredAt: Date?
    public var coverURL: URL?
    public var siteURL: URL?
    /// „TV“, „MOVIE“, „ONA“, …
    public var format: String?
    public var year: Int?

    public init(id: Int, title: String, status: String, episodes: Int? = nil, nextEpisode: Int? = nil,
                nextAiringAt: Date? = nil, lastEpisode: Int? = nil, lastAiredAt: Date? = nil,
                coverURL: URL? = nil, siteURL: URL? = nil, format: String? = nil, year: Int? = nil) {
        self.id = id
        self.title = title
        self.status = status
        self.episodes = episodes
        self.nextEpisode = nextEpisode
        self.nextAiringAt = nextAiringAt
        self.lastEpisode = lastEpisode
        self.lastAiredAt = lastAiredAt
        self.coverURL = coverURL
        self.siteURL = siteURL
        self.format = format
        self.year = year
    }

    public func info(syncedAt: Date = Date()) -> AniListInfo {
        AniListInfo(id: id, status: status, episodes: episodes, nextEpisode: nextEpisode, nextAiringAt: nextAiringAt,
                    lastEpisode: lastEpisode, lastAiredAt: lastAiredAt, coverURL: coverURL, siteURL: siteURL,
                    syncedAt: syncedAt)
    }

    public static func statusText(_ status: String) -> String {
        switch status {
        case "FINISHED": "Abgeschlossen"
        case "RELEASING": "Läuft"
        case "NOT_YET_RELEASED": "Noch nicht gestartet"
        case "CANCELLED": "Abgebrochen"
        case "HIATUS": "Pause"
        default: status.capitalized
        }
    }

    /// Live-Stand für die Suchtreffer: „Läuft · Folge 6: Heute, 17:00“, „Abgeschlossen · 24 Folgen“ …
    public func liveText(now: Date = Date(), calendar: Calendar = .current) -> String {
        if let next = nextEpisode, let date = nextAiringAt {
            return "\(Self.statusText(status)) · Folge \(next): \(Self.whenText(date, now: now, calendar: calendar))"
        }
        if status == "FINISHED", let episodes {
            return episodes == 1 ? "Abgeschlossen · 1 Folge" : "Abgeschlossen · \(episodes) Folgen"
        }
        return Self.statusText(status)
    }

    /// „Heute, 17:00“ für die nächsten Tage, sonst mit Datum: „Sa., 10. Jan., 17:00“.
    public static func whenText(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: date)).day ?? 0
        if (0...6).contains(days) {
            return AnimeEntry.releaseLabel(for: date, now: now, calendar: calendar)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEE, d. MMM, HH:mm"
        return formatter.string(from: date)
    }

    /// „TV · 2023“
    public var detailText: String {
        let formatText: String? = switch format {
        case "TV": "TV"
        case "TV_SHORT": "TV (kurz)"
        case "MOVIE": "Film"
        case "SPECIAL": "Special"
        case "OVA": "OVA"
        case "ONA": "ONA"
        case "MUSIC": "Musik"
        case nil: nil
        case let other?: other
        }
        return [formatText, year.map(String.init)].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Fehler beim Abfragen von AniList.
public enum AniListError: LocalizedError, Equatable {
    case http(Int)
    case api(String)

    public var errorDescription: String? {
        switch self {
        case .http(429): "AniList: zu viele Anfragen, bitte kurz warten."
        case .http(let code): "AniList antwortet nicht (HTTP \(code))."
        case .api(let message): "AniList: \(message)"
        }
    }
}

/// Kleiner Client für die öffentliche AniList-GraphQL-API (https://graphql.anilist.co, ohne Anmeldung).
public struct AniListClient: Sendable {
    public static let endpoint = URL(string: "https://graphql.anilist.co")!

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    private static let mediaFields = """
    id
    title { romaji english }
    status
    episodes
    format
    seasonYear
    siteUrl
    coverImage { medium }
    nextAiringEpisode { episode airingAt }
    """

    /// Animes nach Titel suchen (beste Treffer zuerst, ohne Ü18-Titel).
    public func search(_ text: String) async throws -> [AniListMedia] {
        let query = """
        query ($search: String) {
          Page(perPage: 20) {
            media(search: $search, type: ANIME, isAdult: false, sort: [SEARCH_MATCH]) { \(Self.mediaFields) }
          }
        }
        """
        let data = try await post(query: query, variables: ["search": .string(text)])
        return try Self.parseMedia(data)
    }

    /// Aktuelle Daten für bekannte Animes, inklusive der zuletzt ausgestrahlten Folge.
    public func media(ids: [Int], now: Date = Date()) async throws -> [AniListMedia] {
        guard !ids.isEmpty else { return [] }
        // Zuletzt ausgestrahlte Folgen der letzten drei Wochen (neueste zuerst). Reicht für wöchentliche
        // Serien und für „heute erschienen“; ältere Folgen ergeben sich aus `nextAiringEpisode`.
        let since = Int(now.timeIntervalSince1970) - 21 * 24 * 3600
        let query = """
        query ($ids: [Int], $since: Int) {
          Page(perPage: 50) {
            media(id_in: $ids, type: ANIME) { \(Self.mediaFields) }
          }
          aired: Page(perPage: 50) {
            airingSchedules(mediaId_in: $ids, notYetAired: false, airingAt_greater: $since, sort: TIME_DESC) {
              mediaId episode airingAt
            }
          }
        }
        """
        let data = try await post(query: query,
                                  variables: ["ids": .ints(ids), "since": .int(since)])
        return try Self.parseMedia(data)
    }

    // MARK: - HTTP

    enum Variable: Encodable {
        case string(String)
        case int(Int)
        case ints([Int])

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let value): try container.encode(value)
            case .int(let value): try container.encode(value)
            case .ints(let value): try container.encode(value)
            }
        }
    }

    private struct Body: Encodable {
        let query: String
        let variables: [String: Variable]
    }

    private func post(query: String, variables: [String: Variable]) async throws -> Data {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(Body(query: query, variables: variables))
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        if !(200..<300).contains(status) {
            if let message = Self.errorMessage(data) { throw AniListError.api(message) }
            throw AniListError.http(status)
        }
        return data
    }

    // MARK: - Antwort lesen

    private struct Response: Decodable {
        struct Title: Decodable { let romaji: String?; let english: String? }
        struct Cover: Decodable { let medium: String? }
        struct NextAiring: Decodable { let episode: Int; let airingAt: Int }
        struct Media: Decodable {
            let id: Int
            let title: Title?
            let status: String?
            let episodes: Int?
            let format: String?
            let seasonYear: Int?
            let siteUrl: String?
            let coverImage: Cover?
            let nextAiringEpisode: NextAiring?
        }
        struct Schedule: Decodable { let mediaId: Int; let episode: Int; let airingAt: Int }
        struct MediaPage: Decodable { let media: [Media]? }
        struct SchedulePage: Decodable { let airingSchedules: [Schedule]? }
        struct DataBody: Decodable {
            let Page: MediaPage?
            let aired: SchedulePage?
        }
        struct APIError: Decodable { let message: String }
        let data: DataBody?
        let errors: [APIError]?
    }

    static func errorMessage(_ data: Data) -> String? {
        (try? JSONDecoder().decode(Response.self, from: data))?.errors?.first?.message
    }

    /// Zeitstempel auf die volle Minute abgerundet (Wochentag und Uhrzeit werden minutengenau gespeichert).
    static func date(_ timestamp: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(timestamp - timestamp % 60))
    }

    /// Liest eine Antwort von `search` oder `media(ids:)`.
    static func parseMedia(_ data: Data) throws -> [AniListMedia] {
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard let body = response.data, let media = body.Page?.media else {
            throw AniListError.api(response.errors?.first?.message ?? "Unerwartete Antwort")
        }
        // Neueste ausgestrahlte Folge je Anime (Liste ist nach Zeit absteigend sortiert).
        var lastAired: [Int: Response.Schedule] = [:]
        for schedule in body.aired?.airingSchedules ?? [] {
            if let known = lastAired[schedule.mediaId], known.airingAt >= schedule.airingAt { continue }
            lastAired[schedule.mediaId] = schedule
        }
        return media.map { item in
            let title = item.title?.english?.nilIfBlank ?? item.title?.romaji?.nilIfBlank ?? "Anime \(item.id)"
            let last = lastAired[item.id]
            return AniListMedia(
                id: item.id,
                title: String(title.prefix(80)),
                status: item.status ?? "RELEASING",
                episodes: item.episodes.flatMap { $0 > 0 ? $0 : nil },
                nextEpisode: item.nextAiringEpisode?.episode,
                nextAiringAt: item.nextAiringEpisode.map { Self.date($0.airingAt) },
                lastEpisode: last?.episode,
                lastAiredAt: last.map { Self.date($0.airingAt) },
                coverURL: item.coverImage?.medium.flatMap(URL.init(string:)),
                siteURL: item.siteUrl.flatMap(URL.init(string:)),
                format: item.format,
                year: item.seasonYear
            )
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
