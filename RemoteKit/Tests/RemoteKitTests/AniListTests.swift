import XCTest
@testable import RemoteKit

final class AniListTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Vienna")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    // MARK: - Antwort lesen

    func testParseResponse() throws {
        let json = """
        {"data":{
          "Page":{"media":[
            {"id":1,"title":{"romaji":"Sousou no Frieren","english":"Frieren: Beyond Journey's End"},
             "status":"RELEASING","episodes":28,"format":"TV","seasonYear":2026,
             "siteUrl":"https://anilist.co/anime/1","coverImage":{"medium":"https://img/1.jpg"},
             "nextAiringEpisode":{"episode":6,"airingAt":1795453230}},
            {"id":2,"title":{"romaji":"One Piece","english":null},"status":"RELEASING","episodes":null,
             "format":"TV","seasonYear":1999,"siteUrl":null,"coverImage":null,"nextAiringEpisode":null}
          ]},
          "aired":{"airingSchedules":[
            {"mediaId":1,"episode":5,"airingAt":1794848400},
            {"mediaId":1,"episode":4,"airingAt":1794243600}
          ]}
        }}
        """
        let media = try AniListClient.parseMedia(Data(json.utf8))
        XCTAssertEqual(media.count, 2)
        XCTAssertEqual(media[0].title, "Frieren: Beyond Journey's End")
        XCTAssertEqual(media[0].nextEpisode, 6)
        // Auf die volle Minute abgerundet
        XCTAssertEqual(media[0].nextAiringAt, Date(timeIntervalSince1970: 1795453200))
        XCTAssertEqual(media[0].lastEpisode, 5)
        XCTAssertEqual(media[0].lastAiredAt, Date(timeIntervalSince1970: 1794848400))
        XCTAssertEqual(media[0].coverURL, URL(string: "https://img/1.jpg"))
        XCTAssertEqual(media[0].detailText, "TV · 2026")
        XCTAssertEqual(media[1].title, "One Piece")
        XCTAssertNil(media[1].episodes)
        XCTAssertNil(media[1].lastEpisode)
    }

    func testParseError() {
        let json = #"{"data":null,"errors":[{"message":"Too Many Requests.","status":429}]}"#
        XCTAssertThrowsError(try AniListClient.parseMedia(Data(json.utf8))) { error in
            XCTAssertEqual(error as? AniListError, .api("Too Many Requests."))
        }
    }

    // MARK: - Übernehmen

    /// Läuft, Folge 5 kam Dienstag 17. 11. um 17:00, Folge 6 kommt Dienstag 24. 11. um 17:00.
    private func releasing(next: Date? = nil, total: Int? = 12) -> AniListMedia {
        AniListMedia(id: 1, title: "Frieren", status: "RELEASING", episodes: total, nextEpisode: 6,
                     nextAiringAt: next ?? date(2026, 11, 24, 17), lastEpisode: 5,
                     lastAiredAt: date(2026, 11, 17, 17))
    }

    func testSyncedReleasing() {
        let now = date(2026, 11, 18, 10)
        let entry = AnimeEntry(media: releasing(), at: now, calendar: calendar)
        XCTAssertTrue(entry.isValid)
        XCTAssertEqual(entry.currentEpisode, 5)
        XCTAssertEqual(entry.totalEpisodes, 12)
        XCTAssertEqual(entry.weekday, 3)
        XCTAssertEqual(entry.hour, 17)
        XCTAssertEqual(entry.aniList?.id, 1)
        let next = entry.nextRelease(at: now, calendar: calendar)
        XCTAssertEqual(next?.episode, 6)
        XCTAssertEqual(next?.date, date(2026, 11, 24, 17))
        XCTAssertEqual(entry.episodeText(6), "Folge 6 von 12")
        // Bis der Mac neue Daten holt, zählt es im Wochenrhythmus weiter
        XCTAssertEqual(entry.airedEpisode(at: date(2026, 12, 2, 10), calendar: calendar), 7)
    }

    func testBreakWeekUsesAnnouncedDate() {
        // Eine Woche Pause: Folge 6 erst am 1. 12.
        let now = date(2026, 11, 18, 10)
        let entry = AnimeEntry(media: releasing(next: date(2026, 12, 1, 17)), at: now, calendar: calendar)
        XCTAssertEqual(entry.nextRelease(at: now, calendar: calendar)?.date, date(2026, 12, 1, 17))
        // Am 24. 11. kommt nichts, also auch nichts unter „Heute“
        XCTAssertEqual(entry.airedEpisode(at: date(2026, 11, 24, 20), calendar: calendar), 5)
        XCTAssertTrue(AnimeEntry.today([entry], at: date(2026, 11, 24, 16), calendar: calendar).isEmpty)
        XCTAssertEqual(AnimeEntry.today([entry], at: date(2026, 12, 1, 16), calendar: calendar).first?.episode, 6)
    }

    func testTodaysEpisodeStaysAfterSync() {
        // Mac holt um 18:00 neue Daten: Folge 5 kam heute um 17:00
        let now = date(2026, 11, 17, 18)
        let entry = AnimeEntry(media: releasing(), at: now, calendar: calendar)
        let today = AnimeEntry.today([entry], at: now, calendar: calendar)
        XCTAssertEqual(today.first?.episode, 5)
        XCTAssertEqual(today.first?.isOut(at: now), true)
        XCTAssertTrue(AnimeEntry.today([entry], at: date(2026, 11, 18, 9), calendar: calendar).isEmpty)
    }

    func testFinishedShow() {
        let media = AniListMedia(id: 2, title: "Alt", status: "FINISHED", episodes: 24)
        let now = date(2026, 11, 17, 18)
        let entry = AnimeEntry(media: media, at: now, calendar: calendar)
        XCTAssertTrue(entry.isValid)
        XCTAssertTrue(entry.isFinished(at: now, calendar: calendar))
        XCTAssertEqual(entry.currentEpisode, 24)
        XCTAssertNil(entry.nextRelease(at: now, calendar: calendar))
        // Ein alter, fertiger Anime taucht nie unter „Heute“ auf
        for day in 17...23 {
            XCTAssertTrue(AnimeEntry.today([entry], at: date(2026, 11, day, 23), calendar: calendar).isEmpty)
        }
    }

    func testFinaleAiredToday() {
        let media = AniListMedia(id: 3, title: "Finale", status: "FINISHED", episodes: 12, lastEpisode: 12,
                                 lastAiredAt: date(2026, 11, 17, 17))
        let now = date(2026, 11, 17, 20)
        let entry = AnimeEntry(media: media, at: now, calendar: calendar)
        XCTAssertEqual(AnimeEntry.today([entry], at: now, calendar: calendar).first?.episode, 12)
        XCTAssertTrue(AnimeEntry.today([entry], at: date(2026, 11, 24, 20), calendar: calendar).isEmpty)
    }

    func testUnknownTotalAndNoDate() {
        let long = AnimeEntry(media: releasing(total: nil), at: date(2026, 11, 18, 10), calendar: calendar)
        XCTAssertTrue(long.isValid)
        XCTAssertFalse(long.knowsTotalEpisodes)
        XCTAssertEqual(long.episodeText(6), "Folge 6")

        // Angekündigt, aber noch ohne Termin: kein erfundener Wochentermin
        let upcoming = AniListMedia(id: 4, title: "Bald", status: "NOT_YET_RELEASED", episodes: nil)
        let entry = AnimeEntry(media: upcoming, at: date(2026, 11, 18, 10), calendar: calendar)
        XCTAssertTrue(entry.isValid)
        XCTAssertEqual(entry.currentEpisode, 0)
        XCTAssertNil(entry.nextRelease(at: date(2026, 11, 18, 10), calendar: calendar))
        XCTAssertTrue(entry.isWaitingForDate(at: date(2026, 11, 18, 10), calendar: calendar))
        XCTAssertTrue(AnimeEntry.upcoming([entry], at: date(2026, 11, 18, 10), calendar: calendar).isEmpty)
    }

    func testOldEntriesStillDecode() throws {
        // anime.json aus der Vorversion (ohne `aniList`)
        let json = """
        [{"id":"6B1E3C9A-2D4F-4F7E-9A51-3C2B1D0E9F11","title":"Frieren","currentEpisode":3,"totalEpisodes":28,
          "weekday":6,"hour":17,"minute":0,"updatedAt":785000000}]
        """
        let entries = try JSONDecoder().decode([AnimeEntry].self, from: Data(json.utf8))
        XCTAssertNil(entries.first?.aniList)
        XCTAssertTrue(entries.first?.knowsTotalEpisodes ?? false)
        XCTAssertEqual(entries.first?.episodeText(4), "Folge 4 von 28")
    }
}
