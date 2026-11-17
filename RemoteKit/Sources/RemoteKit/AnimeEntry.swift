import Foundation

/// Ein Anime, der gerade läuft: jede Woche zur selben Zeit erscheint eine neue Folge.
///
/// Gespeichert wird nur der Stand beim Eintragen (`currentEpisode` zum Zeitpunkt `updatedAt`).
/// Jeder Erscheinungstermin danach zählt automatisch eine Folge weiter, bis `totalEpisodes`
/// erreicht ist. Man muss die Folge also nicht jede Woche von Hand hochzählen.
///
/// Wochentag und Uhrzeit gelten in der Zeitzone des Geräts (iPhone und Mac stehen im selben Haushalt).
public struct AnimeEntry: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    /// Zuletzt erschienene Folge, Stand `updatedAt` (0 = noch keine Folge draußen).
    public var currentEpisode: Int
    public var totalEpisodes: Int
    /// 1 = Sonntag … 7 = Samstag (wie `Calendar.component(.weekday, …)`).
    public var weekday: Int
    public var hour: Int
    public var minute: Int
    /// Wann `currentEpisode` eingetragen wurde.
    public var updatedAt: Date

    public init(id: UUID = UUID(), title: String, currentEpisode: Int, totalEpisodes: Int,
                weekday: Int, hour: Int, minute: Int, updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.currentEpisode = currentEpisode
        self.totalEpisodes = totalEpisodes
        self.weekday = weekday
        self.hour = hour
        self.minute = minute
        self.updatedAt = updatedAt
    }

    public static let maxCount = 50
    public static let maxEpisodes = 2000

    public var isValid: Bool {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && title.count <= 80
            && (1...Self.maxEpisodes).contains(totalEpisodes)
            && (0...totalEpisodes).contains(currentEpisode)
            && (1...7).contains(weekday)
            && (0...23).contains(hour)
            && (0...59).contains(minute)
    }

    // MARK: - Termine

    /// Nächster Erscheinungstermin echt nach `date`.
    public func releaseDate(after date: Date, calendar: Calendar = .current) -> Date? {
        let components = DateComponents(hour: hour, minute: minute, second: 0, weekday: weekday)
        return calendar.nextDate(after: date, matching: components, matchingPolicy: .nextTime)
    }

    /// Zuletzt erschienene Folge zum Zeitpunkt `now` (zählt seit `updatedAt` mit).
    public func airedEpisode(at now: Date = Date(), calendar: Calendar = .current) -> Int {
        var episode = currentEpisode
        var cursor = updatedAt
        while episode < totalEpisodes, let next = releaseDate(after: cursor, calendar: calendar), next <= now {
            episode += 1
            cursor = next
        }
        return min(episode, totalEpisodes)
    }

    /// Alle Folgen draußen?
    public func isFinished(at now: Date = Date(), calendar: Calendar = .current) -> Bool {
        airedEpisode(at: now, calendar: calendar) >= totalEpisodes
    }

    /// Nächste Folge und wann sie erscheint. `nil`, wenn der Anime durch ist.
    public func nextRelease(at now: Date = Date(), calendar: Calendar = .current) -> (episode: Int, date: Date)? {
        let aired = airedEpisode(at: now, calendar: calendar)
        guard aired < totalEpisodes, let date = releaseDate(after: now, calendar: calendar) else { return nil }
        return (aired + 1, date)
    }

    /// Gleicher Anime mit dem heutigen Stand als neuem Ausgangspunkt (z. B. vor dem Bearbeiten).
    public func rebased(at now: Date = Date(), calendar: Calendar = .current) -> AnimeEntry {
        var copy = self
        copy.currentEpisode = airedEpisode(at: now, calendar: calendar)
        copy.updatedAt = now
        return copy
    }

    // MARK: - Liste

    /// Noch laufende Animes, nach dem nächsten Termin sortiert (was zuerst erscheint, steht oben).
    public static func upcoming(_ entries: [AnimeEntry], at now: Date = Date(),
                                calendar: Calendar = .current) -> [UpcomingRelease] {
        entries
            .compactMap { entry -> UpcomingRelease? in
                guard let next = entry.nextRelease(at: now, calendar: calendar) else { return nil }
                return UpcomingRelease(entry: entry, episode: next.episode, date: next.date)
            }
            .sorted { $0.date == $1.date ? $0.entry.title < $1.entry.title : $0.date < $1.date }
    }

    // MARK: - Texte

    private static let germanLocale = Locale(identifier: "de_DE")

    /// Wochentagsnamen in der Reihenfolge Montag … Sonntag, mit dem passenden `weekday`-Wert.
    public static var weekdaysMondayFirst: [(weekday: Int, name: String)] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = germanLocale
        let names = calendar.weekdaySymbols // [Sonntag, Montag, …]
        return [2, 3, 4, 5, 6, 7, 1].map { ($0, names[$0 - 1]) }
    }

    public static func weekdayName(_ weekday: Int, short: Bool = false) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = germanLocale
        let names = short ? calendar.shortWeekdaySymbols : calendar.weekdaySymbols
        return names.indices.contains(weekday - 1) ? names[weekday - 1] : "?"
    }

    /// „Sonntag, 17:00“
    public var scheduleText: String {
        "\(Self.weekdayName(weekday)), \(String(format: "%02d:%02d", hour, minute))"
    }

    /// Kurze Angabe für einen Termin: „Heute“, „Morgen“ oder der Wochentag.
    public static func dayLabel(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case 0: return "Heute"
        case 1: return "Morgen"
        case 7: return "Nächsten \(weekdayName(calendar.component(.weekday, from: date)))"
        default: return weekdayName(calendar.component(.weekday, from: date))
        }
    }

    /// „Heute, 17:00“
    public static func releaseLabel(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = calendar.dateComponents([.hour, .minute], from: date)
        return "\(dayLabel(for: date, now: now, calendar: calendar)), "
            + String(format: "%02d:%02d", time.hour ?? 0, time.minute ?? 0)
    }

    /// „in 45 Min.“, „in 3 Std.“ – nur für Termine in den nächsten 24 Stunden, sonst `nil`.
    public static func countdown(to date: Date, now: Date = Date()) -> String? {
        let minutes = Int((date.timeIntervalSince(now) / 60).rounded(.up))
        switch minutes {
        case ..<1: return "jetzt"
        case 1..<60: return "in \(minutes) Min."
        case 60..<(24 * 60): return "in \(minutes / 60) Std."
        default: return nil
        }
    }
}

/// Nächste Folge eines Animes (für die Liste „Als Nächstes“).
public struct UpcomingRelease: Identifiable, Equatable, Sendable {
    public let entry: AnimeEntry
    public let episode: Int
    public let date: Date

    public var id: UUID { entry.id }
}
