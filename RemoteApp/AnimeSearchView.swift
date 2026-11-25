import RemoteKit
import SwiftUI

/// Anime auf AniList suchen und mit einem Tipp in die Liste übernehmen.
/// Jeder Treffer zeigt gleich den Live-Stand: läuft noch (mit nächster Folge) oder schon abgeschlossen.
struct AnimeSearchView: View {
    let initialQuery: String
    /// Schon in der Liste (bekommen ein Häkchen).
    let addedIDs: Set<Int>
    let onPick: (AniListMedia) -> Void
    /// „Von Hand eintragen“ anbieten.
    var onManual: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var query: String
    @State private var results: [AniListMedia] = []
    @State private var isLoading = false
    @State private var errorText: String?

    private let client = AniListClient()

    init(initialQuery: String, addedIDs: Set<Int>, onPick: @escaping (AniListMedia) -> Void,
         onManual: (() -> Void)? = nil) {
        self.initialQuery = initialQuery
        self.addedIDs = addedIDs
        self.onPick = onPick
        self.onManual = onManual
        _query = State(initialValue: initialQuery)
    }

    var body: some View {
        NavigationStack {
            List {
                if let errorText {
                    Section {
                        Label(errorText, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                }

                if !results.isEmpty {
                    Section {
                        ForEach(results) { media in
                            resultRow(media)
                        }
                    } footer: {
                        Text("Daten von AniList.")
                    }
                } else if !isLoading, errorText == nil, trimmedQuery.count >= 2 {
                    Section {
                        Text("Nichts gefunden.")
                            .foregroundStyle(.secondary)
                    }
                }

                if let onManual {
                    Section {
                        Button {
                            onManual()
                        } label: {
                            Label("Von Hand eintragen", systemImage: "square.and.pencil")
                        }
                    } footer: {
                        Text("Für Animes, die AniList nicht kennt. Dann trägst du Folge und Termin selbst ein.")
                    }
                }
            }
            .overlay {
                if isLoading && results.isEmpty {
                    ProgressView()
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Anime suchen, z. B. Frieren")
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .task(id: trimmedQuery) {
                await search(trimmedQuery)
            }
            .navigationTitle("Anime suchen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
            }
        }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resultRow(_ media: AniListMedia) -> some View {
        let isAdded = addedIDs.contains(media.id)
        return Button {
            onPick(media)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                AnimeCover(url: media.coverURL, width: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text(media.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(media.liveText())
                        .font(.caption)
                        .foregroundStyle(media.status == "RELEASING" ? Color.orange : .secondary)
                    if !media.detailText.isEmpty {
                        Text(media.detailText)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: isAdded ? "checkmark.circle.fill" : "plus.circle")
                    .font(.title3)
                    .foregroundStyle(isAdded ? Color.green : Color.accentColor)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isAdded)
    }

    private func search(_ text: String) async {
        guard text.count >= 2 else {
            results = []
            errorText = nil
            return
        }
        // Kurz warten, bis fertig getippt ist (die Aufgabe wird bei jedem Tastendruck neu gestartet).
        try? await Task.sleep(for: .milliseconds(text == initialQuery ? 0 : 350))
        guard !Task.isCancelled else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let found = try await client.search(text)
            guard !Task.isCancelled else { return }
            results = found
            errorText = nil
        } catch {
            guard !Task.isCancelled, (error as? URLError)?.code != .cancelled else { return }
            errorText = (error as? LocalizedError)?.errorDescription ?? "Suche fehlgeschlagen. Bist du online?"
        }
    }
}

/// Details zu einem Anime mit Live-Daten: Status, nächste Folge, Link zu AniList, Entfernen.
struct AnimeDetailView: View {
    let entryID: UUID

    @EnvironmentObject private var client: RemoteClient
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TimelineView(.everyMinute) { context in
                if let entry = client.anime.first(where: { $0.id == entryID }) {
                    content(entry, now: context.date)
                } else {
                    ContentUnavailableView("Nicht mehr in der Liste", systemImage: "trash")
                }
            }
            .navigationTitle("Anime")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
    }

    private func content(_ entry: AnimeEntry, now: Date) -> some View {
        let aired = entry.airedEpisode(at: now)
        let next = entry.nextRelease(at: now)
        return List {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    AnimeCover(url: entry.aniList?.coverURL, width: 72)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.title)
                            .font(.title3.weight(.semibold))
                        if let aniList = entry.aniList {
                            Text(aniList.statusText)
                                .font(.subheadline)
                                .foregroundStyle(aniList.status == "RELEASING" ? Color.orange : .secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Folgen") {
                if let next {
                    LabeledContent("Nächste Folge", value: "Folge \(next.episode)")
                    LabeledContent("Erscheint", value: AniListMedia.whenText(next.date, now: now))
                    if let countdown = AnimeEntry.countdown(to: next.date, now: now) {
                        LabeledContent("Noch", value: countdown)
                    }
                } else if !entry.isFinished(at: now) {
                    LabeledContent("Nächste Folge", value: "noch kein Termin")
                }
                LabeledContent("Draußen", value: aired == 0 ? "noch keine" : "\(aired)")
                LabeledContent("Insgesamt", value: entry.knowsTotalEpisodes ? "\(entry.totalEpisodes)" : "noch offen")
            }

            if let aniList = entry.aniList {
                Section {
                    if let url = aniList.siteURL {
                        Link(destination: url) {
                            Label("Auf AniList ansehen", systemImage: "safari")
                        }
                    }
                } footer: {
                    Text("Aktualisiert \(aniList.syncedAt.formatted(.relative(presentation: .named, unitsStyle: .wide))). Der Mac holt die Daten laufend neu.")
                }
            }

            Section {
                Button("Aus der Liste entfernen", role: .destructive) {
                    client.setAnime(client.anime.filter { $0.id != entryID })
                    dismiss()
                }
            }
        }
        .environment(\.locale, Locale(identifier: "de_DE"))
    }
}

/// Cover-Bild (AniList), mit Platzhalter beim Laden oder ohne Bild.
struct AnimeCover: View {
    let url: URL?
    let width: CGFloat

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                Rectangle()
                    .fill(Color.secondary.opacity(0.15))
                    .overlay(Image(systemName: "film").foregroundStyle(.tertiary))
            }
        }
        .frame(width: width, height: width * 1.42)
        .clipShape(RoundedRectangle(cornerRadius: width * 0.14, style: .continuous))
    }
}
