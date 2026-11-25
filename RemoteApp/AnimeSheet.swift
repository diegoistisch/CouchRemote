import RemoteKit
import SwiftUI

/// Animes, die gerade laufen: was als Nächstes erscheint und wann. Dieselbe Liste steht am Fernseher
/// auf der Startseite unter „Als Nächstes“. Hinzufügen per Suche (Live-Daten von AniList) oder von Hand.
/// Antippen zeigt Details oder bearbeitet, wischen löscht.
struct AnimeSheet: View {
    @EnvironmentObject private var client: RemoteClient
    @Environment(\.dismiss) private var dismiss

    @State private var editing: AnimeEntry?
    @State private var showing: AnimeEntry?
    @State private var isAdding = false
    @State private var isSearching = false
    /// Eingetragener Anime, der mit AniList verknüpft werden soll.
    @State private var linking: AnimeEntry?

    var body: some View {
        NavigationStack {
            TimelineView(.everyMinute) { context in
                content(now: context.date)
            }
            .navigationTitle("Anime")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fertig") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isSearching = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Anime hinzufügen")
                    .disabled(client.anime.count >= AnimeEntry.maxCount)
                }
            }
            .sheet(isPresented: $isSearching) {
                AnimeSearchView(initialQuery: "", addedIDs: linkedIDs) { media in
                    client.setAnime(client.anime + [AnimeEntry(media: media)])
                } onManual: {
                    isSearching = false
                    Task {
                        try? await Task.sleep(for: .milliseconds(450))
                        isAdding = true
                    }
                }
            }
            .sheet(isPresented: $isAdding) {
                AnimeEditor(entry: nil) { newEntry in
                    client.setAnime(client.anime + [newEntry])
                }
            }
            .sheet(item: $editing) { entry in
                AnimeEditor(entry: entry) { updated in
                    client.setAnime(client.anime.map { $0.id == updated.id ? updated : $0 })
                } onLink: {
                    editing = nil
                    Task {
                        try? await Task.sleep(for: .milliseconds(450))
                        linking = entry
                    }
                }
            }
            .sheet(item: $linking) { entry in
                AnimeSearchView(initialQuery: entry.title, addedIDs: linkedIDs) { media in
                    // Gleicher Eintrag (gleiche ID), ab jetzt mit Live-Daten
                    var linked = AnimeEntry(media: media)
                    linked.id = entry.id
                    client.setAnime(client.anime.map { $0.id == entry.id ? linked : $0 })
                }
            }
            .sheet(item: $showing) { entry in
                AnimeDetailView(entryID: entry.id)
                    .environmentObject(client)
            }
        }
    }

    private var linkedIDs: Set<Int> {
        Set(client.anime.compactMap { $0.aniList?.id })
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        if client.anime.isEmpty {
            ContentUnavailableView {
                Label("Keine Animes", systemImage: "calendar.badge.clock")
            } description: {
                Text("Such nach einem Anime: Welche Folge draußen ist und wann die nächste kommt, kommt live von AniList. Die Liste erscheint am Fernseher auf der Startseite unter „Als Nächstes“.")
            } actions: {
                Button("Anime suchen") { isSearching = true }
                    .buttonStyle(.borderedProminent)
                Button("Von Hand eintragen") { isAdding = true }
            }
        } else {
            let today = AnimeEntry.today(client.anime, at: now)
            let todayIDs = Set(today.map(\.id))
            let upcoming = AnimeEntry.upcoming(client.anime, at: now).filter { !todayIDs.contains($0.id) }
            let finished = client.anime
                .filter { $0.isFinished(at: now) && !todayIDs.contains($0.id) }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            let waiting = client.anime
                .filter { $0.isWaitingForDate(at: now) && !todayIDs.contains($0.id) }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

            List {
                if !today.isEmpty {
                    Section {
                        ForEach(today) { release in
                            let isOut = release.isOut(at: now)
                            row(release.entry, now: now) {
                                VStack(alignment: .trailing, spacing: 2) {
                                    if isOut {
                                        Text("NEU")
                                            .font(.caption.weight(.heavy))
                                            .foregroundStyle(.black)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 2)
                                            .background(Capsule().fill(Color.orange))
                                        Text("seit \(String(format: "%02d:%02d", release.entry.hour, release.entry.minute))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Text(String(format: "%02d:%02d", release.entry.hour, release.entry.minute))
                                            .font(.headline)
                                            .foregroundStyle(.orange)
                                        if let countdown = AnimeEntry.countdown(to: release.date, now: now) {
                                            Text(countdown)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            } subtitle: {
                                Text(release.entry.episodeText(release.episode))
                            }
                            .listRowBackground(Color.orange.opacity(isOut ? 0.12 : 0.2))
                        }
                        .onDelete { offsets in
                            delete(offsets.map { today[$0].entry.id })
                        }
                    } header: {
                        Label(today.count == 1 ? "Heute · 1 neue Folge" : "Heute · \(today.count) neue Folgen",
                              systemImage: "sparkles")
                            .foregroundStyle(.orange)
                    }
                }

                if !upcoming.isEmpty {
                    Section {
                        ForEach(upcoming) { release in
                            row(release.entry, now: now) {
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(AnimeEntry.releaseLabel(for: release.date, now: now))
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    if let countdown = AnimeEntry.countdown(to: release.date, now: now) {
                                        Text(countdown)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            } subtitle: {
                                Text(release.entry.episodeText(release.episode))
                            }
                        }
                        .onDelete { offsets in
                            delete(offsets.map { upcoming[$0].entry.id })
                        }
                    } header: {
                        Text("Als Nächstes")
                    } footer: {
                        Text(linkedIDs.isEmpty
                             ? "Nach jedem Termin zählt die Folge automatisch eine weiter."
                             : "Gesuchte Animes holt der Mac laufend live von AniList.")
                    }
                }

                if !waiting.isEmpty {
                    Section("Noch kein Termin") {
                        ForEach(waiting) { entry in
                            row(entry, now: now) {
                                Image(systemName: "hourglass")
                                    .foregroundStyle(.secondary)
                            } subtitle: {
                                let aired = entry.airedEpisode(at: now)
                                Text(aired == 0 ? "Noch keine Folge draußen" : "Zuletzt \(entry.episodeText(aired))")
                            }
                        }
                        .onDelete { offsets in
                            delete(offsets.map { waiting[$0].id })
                        }
                    }
                }

                if !finished.isEmpty {
                    Section("Abgeschlossen") {
                        ForEach(finished) { entry in
                            row(entry, now: now) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            } subtitle: {
                                Text("Alle \(entry.totalEpisodes) Folgen draußen")
                            }
                        }
                        .onDelete { offsets in
                            delete(offsets.map { finished[$0].id })
                        }
                    }
                }
            }
        }
    }

    private func row<Trailing: View, Subtitle: View>(
        _ entry: AnimeEntry, now: Date,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder subtitle: () -> Subtitle
    ) -> some View {
        Button {
            if entry.aniList != nil {
                showing = entry
            } else {
                editing = entry.rebased(at: now)
            }
        } label: {
            HStack(spacing: 12) {
                if let aniList = entry.aniList {
                    AnimeCover(url: aniList.coverURL, width: 40)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    subtitle()
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(scheduleText(entry, now: now))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
                trailing()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// „Dienstag, 17:00“, bei AniList mit Status davor („Läuft · Dienstag, 17:00“).
    private func scheduleText(_ entry: AnimeEntry, now: Date) -> String {
        guard let aniList = entry.aniList else { return entry.scheduleText }
        if entry.isFinished(at: now) || entry.nextRelease(at: now) == nil { return "AniList · \(aniList.statusText)" }
        return "AniList · \(entry.scheduleText)"
    }

    private func delete(_ ids: [UUID]) {
        let removed = Set(ids)
        client.setAnime(client.anime.filter { !removed.contains($0.id) })
    }
}

/// Formular zum Anlegen oder Ändern eines Animes.
struct AnimeEditor: View {
    let entry: AnimeEntry?
    let onSave: (AnimeEntry) -> Void
    /// Eingetragenen Anime mit AniList verknüpfen (nur beim Bearbeiten).
    var onLink: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var currentEpisode: Int
    @State private var totalEpisodes: Int
    @State private var weekday: Int
    @State private var time: Date

    init(entry: AnimeEntry?, onSave: @escaping (AnimeEntry) -> Void, onLink: (() -> Void)? = nil) {
        self.entry = entry
        self.onSave = onSave
        self.onLink = onLink
        let calendar = Calendar.current
        let now = Date()
        _title = State(initialValue: entry?.title ?? "")
        _currentEpisode = State(initialValue: entry?.currentEpisode ?? 0)
        _totalEpisodes = State(initialValue: entry?.totalEpisodes ?? 12)
        _weekday = State(initialValue: entry?.weekday ?? calendar.component(.weekday, from: now))
        let hour = entry?.hour ?? 17
        let minute = entry?.minute ?? 0
        _time = State(initialValue: calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now)
    }

    private var draft: AnimeEntry? {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        let candidate = AnimeEntry(
            id: entry?.id ?? UUID(),
            title: title.trimmingCharacters(in: .whitespaces),
            currentEpisode: currentEpisode,
            totalEpisodes: totalEpisodes,
            weekday: weekday,
            hour: parts.hour ?? 0,
            minute: parts.minute ?? 0,
            updatedAt: Date()
        )
        return candidate.isValid ? candidate : nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Titel") {
                    TextField("z. B. Frieren", text: $title)
                        .textInputAutocapitalization(.words)
                }

                Section {
                    Stepper(value: $currentEpisode, in: 0...totalEpisodes) {
                        LabeledContent("Aktuelle Folge", value: currentEpisode == 0 ? "noch keine" : "\(currentEpisode)")
                    }
                    Stepper(value: $totalEpisodes, in: max(currentEpisode, 1)...AnimeEntry.maxEpisodes) {
                        LabeledContent("Folgen insgesamt", value: "\(totalEpisodes)")
                    }
                } header: {
                    Text("Folgen")
                } footer: {
                    Text("„Aktuelle Folge“ ist die zuletzt erschienene. Danach zählt die App bei jedem Termin selbst weiter.")
                }

                Section {
                    Picker("Wochentag", selection: $weekday) {
                        ForEach(AnimeEntry.weekdaysMondayFirst, id: \.weekday) { day in
                            Text(day.name).tag(day.weekday)
                        }
                    }
                    DatePicker("Uhrzeit", selection: $time, displayedComponents: .hourAndMinute)
                } header: {
                    Text("Neue Folge erscheint")
                }

                if let draft, let next = draft.nextRelease() {
                    Section {
                        LabeledContent("Folge \(next.episode)", value: AnimeEntry.releaseLabel(for: next.date))
                    } header: {
                        Text("Als Nächstes")
                    }
                }

                if let onLink {
                    Section {
                        Button {
                            onLink()
                        } label: {
                            Label("Live-Daten von AniList holen", systemImage: "antenna.radiowaves.left.and.right")
                        }
                    } footer: {
                        Text("Sucht den Anime auf AniList. Folge und Termin kommen dann automatisch, du musst nichts mehr eintragen.")
                    }
                }
            }
            .navigationTitle(entry == nil ? "Anime hinzufügen" : "Anime bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        if let draft {
                            onSave(draft)
                            dismiss()
                        }
                    }
                    .disabled(draft == nil)
                }
            }
        }
        .environment(\.locale, Locale(identifier: "de_DE"))
    }
}
