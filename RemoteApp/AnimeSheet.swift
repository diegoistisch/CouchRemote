import RemoteKit
import SwiftUI

/// Animes, die gerade laufen: was als Nächstes erscheint und wann. Dieselbe Liste steht am Fernseher
/// auf der Startseite unter „Als Nächstes“. Antippen bearbeitet, wischen löscht.
struct AnimeSheet: View {
    @EnvironmentObject private var client: RemoteClient
    @Environment(\.dismiss) private var dismiss

    @State private var editing: AnimeEntry?
    @State private var isAdding = false

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
                        isAdding = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Anime hinzufügen")
                    .disabled(client.anime.count >= AnimeEntry.maxCount)
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
                }
            }
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        if client.anime.isEmpty {
            ContentUnavailableView {
                Label("Keine Animes", systemImage: "calendar.badge.clock")
            } description: {
                Text("Trag ein, welche Folge gerade draußen ist und wann die nächste kommt. Die Liste erscheint am Fernseher auf der Startseite unter „Als Nächstes“.")
            } actions: {
                Button("Anime hinzufügen") { isAdding = true }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            let upcoming = AnimeEntry.upcoming(client.anime, at: now)
            let finished = client.anime
                .filter { $0.isFinished(at: now) }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

            List {
                if !upcoming.isEmpty {
                    Section {
                        ForEach(upcoming) { release in
                            row(release.entry, now: now) {
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(AnimeEntry.releaseLabel(for: release.date, now: now))
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Calendar.current.isDate(release.date, inSameDayAs: now)
                                                         ? Color.orange : .primary)
                                    if let countdown = AnimeEntry.countdown(to: release.date, now: now) {
                                        Text(countdown)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            } subtitle: {
                                Text("Folge \(release.episode) von \(release.entry.totalEpisodes)")
                            }
                        }
                        .onDelete { offsets in
                            delete(offsets.map { upcoming[$0].entry.id })
                        }
                    } header: {
                        Text("Als Nächstes")
                    } footer: {
                        Text("Nach jedem Termin zählt die Folge automatisch eine weiter.")
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
            editing = entry.rebased(at: now)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    subtitle()
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(entry.scheduleText)
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

    private func delete(_ ids: [UUID]) {
        let removed = Set(ids)
        client.setAnime(client.anime.filter { !removed.contains($0.id) })
    }
}

/// Formular zum Anlegen oder Ändern eines Animes.
struct AnimeEditor: View {
    let entry: AnimeEntry?
    let onSave: (AnimeEntry) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var currentEpisode: Int
    @State private var totalEpisodes: Int
    @State private var weekday: Int
    @State private var time: Date

    init(entry: AnimeEntry?, onSave: @escaping (AnimeEntry) -> Void) {
        self.entry = entry
        self.onSave = onSave
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
