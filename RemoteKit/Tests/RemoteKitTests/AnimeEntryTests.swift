import XCTest
@testable import RemoteKit

final class AnimeEntryTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Vienna")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    /// Dienstag, 17. 11. 2026, 15:00. Neue Folgen jeden Dienstag um 17:00.
    private func tuesdayAnime(current: Int = 5, total: Int = 12) -> AnimeEntry {
        AnimeEntry(title: "Test", currentEpisode: current, totalEpisodes: total,
                   weekday: 3, hour: 17, minute: 0, updatedAt: date(2026, 11, 17, 15))
    }

    func testNextReleaseSameDay() {
        let next = tuesdayAnime().nextRelease(at: date(2026, 11, 17, 15), calendar: calendar)
        XCTAssertEqual(next?.episode, 6)
        XCTAssertEqual(next?.date, date(2026, 11, 17, 17))
    }

    func testAutoIncrementAfterRelease() {
        let anime = tuesdayAnime()
        // Kurz nach der Ausstrahlung: Folge 6 ist draußen, Folge 7 kommt nächste Woche
        XCTAssertEqual(anime.airedEpisode(at: date(2026, 11, 17, 17, 1), calendar: calendar), 6)
        let next = anime.nextRelease(at: date(2026, 11, 17, 17, 1), calendar: calendar)
        XCTAssertEqual(next?.episode, 7)
        XCTAssertEqual(next?.date, date(2026, 11, 24, 17))
        // Drei Wochen später
        XCTAssertEqual(anime.airedEpisode(at: date(2026, 12, 8, 18), calendar: calendar), 9)
    }

    func testFinishedAnimeHasNoNextRelease() {
        let anime = tuesdayAnime(current: 11, total: 12)
        XCTAssertNotNil(anime.nextRelease(at: date(2026, 11, 17, 16), calendar: calendar))
        XCTAssertNil(anime.nextRelease(at: date(2026, 11, 17, 18), calendar: calendar))
        XCTAssertTrue(anime.isFinished(at: date(2027, 3, 1, 12), calendar: calendar))
        XCTAssertEqual(anime.airedEpisode(at: date(2027, 3, 1, 12), calendar: calendar), 12)
    }

    func testUpcomingSortedByDate() {
        let tuesday = tuesdayAnime()
        var wednesday = tuesdayAnime()
        wednesday.id = UUID()
        wednesday.title = "Mittwoch"
        wednesday.weekday = 4
        let done = tuesdayAnime(current: 12, total: 12)
        let list = AnimeEntry.upcoming([wednesday, done, tuesday], at: date(2026, 11, 17, 15), calendar: calendar)
        XCTAssertEqual(list.map(\.entry.id), [tuesday.id, wednesday.id])
    }

    func testToday() {
        let anime = tuesdayAnime()
        var wednesday = tuesdayAnime()
        wednesday.id = UUID()
        wednesday.weekday = 4
        // Vor der Ausstrahlung: Folge 6 kommt heute
        let before = AnimeEntry.today([anime, wednesday], at: date(2026, 11, 17, 16), calendar: calendar)
        XCTAssertEqual(before.map(\.entry.id), [anime.id])
        XCTAssertEqual(before.first?.episode, 6)
        XCTAssertEqual(before.first?.isOut(at: date(2026, 11, 17, 16)), false)
        // Danach: Folge 6 ist heute erschienen
        let after = AnimeEntry.today([anime], at: date(2026, 11, 17, 20), calendar: calendar)
        XCTAssertEqual(after.first?.episode, 6)
        XCTAssertEqual(after.first?.isOut(at: date(2026, 11, 17, 20)), true)
        // Erst nach dem Termin eingetragen (Folge 6 ist die von heute): bleibt trotzdem bis Mitternacht stehen
        var late = anime
        late.currentEpisode = 6
        late.updatedAt = date(2026, 11, 17, 18)
        let lateToday = AnimeEntry.today([late], at: date(2026, 11, 17, 20), calendar: calendar)
        XCTAssertEqual(lateToday.first?.episode, 6)
        XCTAssertEqual(lateToday.first?.isOut(at: date(2026, 11, 17, 20)), true)
        // Am nächsten Tag ist sie aus „Heute“ verschwunden
        XCTAssertTrue(AnimeEntry.today([late], at: date(2026, 11, 18, 10), calendar: calendar).isEmpty)
        // Letzte Folge heute erschienen: bleibt auch stehen
        let finale = tuesdayAnime(current: 11, total: 12)
        XCTAssertEqual(AnimeEntry.today([finale], at: date(2026, 11, 17, 23), calendar: calendar).first?.episode, 12)
    }

    func testLabels() {
        let now = date(2026, 11, 17, 15)
        XCTAssertEqual(AnimeEntry.releaseLabel(for: date(2026, 11, 17, 17), now: now, calendar: calendar), "Heute, 17:00")
        XCTAssertEqual(AnimeEntry.releaseLabel(for: date(2026, 11, 18, 9, 5), now: now, calendar: calendar), "Morgen, 09:05")
        XCTAssertEqual(AnimeEntry.dayLabel(for: date(2026, 11, 20, 9), now: now, calendar: calendar), "Freitag")
        XCTAssertEqual(AnimeEntry.countdown(to: date(2026, 11, 17, 15, 45), now: now), "in 45 Min.")
        XCTAssertEqual(AnimeEntry.countdown(to: date(2026, 11, 17, 17), now: now), "in 2 Std.")
        XCTAssertNil(AnimeEntry.countdown(to: date(2026, 11, 20, 17), now: now))
    }

    func testValidation() {
        XCTAssertTrue(tuesdayAnime().isValid)
        XCTAssertFalse(tuesdayAnime(current: 13, total: 12).isValid)
        XCTAssertFalse(AnimeEntry(title: " ", currentEpisode: 0, totalEpisodes: 12, weekday: 1, hour: 0, minute: 0).isValid)
    }
}
