import AppKit
import QuartzCore
import RemoteKit
import SwiftUI

/// Verwaltet die Startseite: App-Liste (gespeichert), Fokus fürs D-Pad, Suche und das Vollbildfenster.
@MainActor
final class HomeController: ObservableObject {
    /// Was gerade mit dem D-Pad ausgewählt ist.
    enum Focus: Equatable {
        case pill(Int)
        case app(Int)
        case shortcut(Int)
    }

    /// Kleine Schaltflächen oben rechts.
    enum Pill: CaseIterable {
        case search
        case desktop

        var title: String {
            switch self {
            case .search: "Suchen"
            case .desktop: "Schreibtisch"
            }
        }

        var systemImage: String {
            switch self {
            case .search: "magnifyingglass"
            case .desktop: "macwindow"
            }
        }
    }

    static let pills = Pill.allCases

    @Published private(set) var apps: [HomeApp] = []
    /// Animes für die Liste „Als Nächstes“ (kommen vom iPhone, gespeichert).
    @Published private(set) var anime: [AnimeEntry] = []
    @Published private(set) var focus: Focus = .app(0)
    /// Zuletzt ausgewählte App (für den Schnellzugriff darunter).
    @Published private(set) var currentAppIndex = 0
    @Published private(set) var isVisible = false
    @Published private(set) var wallpaper: NSImage?
    /// Hinweis „Tippe auf dem iPhone“, solange auf eine Suche gewartet wird. `nil` = kein Hinweis.
    @Published private(set) var searchPrompt: String?

    /// Startanimation: Kachel wächst zum Vollbild, dahinter öffnet sich der Browser.
    struct Launch: Equatable {
        let id = UUID()
        let app: HomeApp?
    }
    @Published private(set) var launch: Launch?
    /// Ändert sich bei jedem Einblenden (löst die Einblend-Animation der Inhalte aus).
    @Published private(set) var presentationID = UUID()

    /// Für die Netzwerk-Queue: Ist die Startseite gerade sichtbar?
    let visibility = Locked(false)

    /// Wird nach jeder Änderung der App-Liste aufgerufen (Server schickt sie an alle iPhones).
    var onAppsChanged: (([HomeApp]) -> Void)?
    /// Wird nach jeder Änderung der Anime-Liste aufgerufen (Server schickt sie an alle iPhones).
    var onAnimeChanged: (([AnimeEntry]) -> Void)?
    /// Wird aufgerufen, wenn am Fernseher „Suchen“ gewählt wurde (iPhone soll die Tastatur zeigen).
    var onKeyboardRequest: ((UUID?) -> Void)?

    private var window: NSWindow?
    nonisolated static let wallpaperPathKey = "wallpaperPath"

    private static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("CouchHost", isDirectory: true)
    }

    private static var storeURL: URL { supportDirectory.appendingPathComponent("apps.json") }
    private static var animeURL: URL { supportDirectory.appendingPathComponent("anime.json") }

    init() {
        apps = Self.loadApps()
        anime = Self.loadAnime()
        startAniListSync()
    }

    var currentApp: HomeApp? {
        apps.indices.contains(currentAppIndex) ? apps[currentAppIndex] : nil
    }

    var shortcuts: [AppShortcut] {
        currentApp.map(KnownServices.shortcuts(for:)) ?? []
    }

    // MARK: - Speichern

    private static func loadApps() -> [HomeApp] {
        if let data = try? Data(contentsOf: storeURL),
           let saved = try? JSONDecoder().decode([HomeApp].self, from: data) {
            return saved
        }
        // Übernahme aus der Vorversion (UserDefaults)
        if let data = UserDefaults.standard.data(forKey: "homeApps"),
           let saved = try? JSONDecoder().decode([HomeApp].self, from: data) {
            return saved
        }
        return HomeApp.defaults
    }

    private func saveApps() {
        do {
            try FileManager.default.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)
            try JSONEncoder().encode(apps).write(to: Self.storeURL, options: .atomic)
        } catch {
            NSLog("CouchHost: Apps konnten nicht gespeichert werden: \(error)")
        }
    }

    /// Übernimmt eine neue Liste vom iPhone. Ungültige Einträge (z. B. keine http(s)-Adresse) fallen raus.
    func setApps(_ newApps: [HomeApp]) {
        var seen = Set<UUID>()
        apps = Array(newApps.filter { $0.isValid && seen.insert($0.id).inserted }.prefix(HomeApp.maxCount))
        currentAppIndex = min(currentAppIndex, max(apps.count - 1, 0))
        if case .app = focus { focus = .app(currentAppIndex) }
        if case .shortcut = focus { focus = .app(currentAppIndex) }
        saveApps()
        onAppsChanged?(apps)
    }

    // MARK: - Anime

    private static func loadAnime() -> [AnimeEntry] {
        guard let data = try? Data(contentsOf: animeURL),
              let saved = try? JSONDecoder().decode([AnimeEntry].self, from: data) else { return [] }
        return saved
    }

    private func saveAnime() {
        do {
            try FileManager.default.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)
            try JSONEncoder().encode(anime).write(to: Self.animeURL, options: .atomic)
        } catch {
            NSLog("CouchHost: Animes konnten nicht gespeichert werden: \(error)")
        }
    }

    /// Übernimmt eine neue Anime-Liste vom iPhone. Ungültige Einträge fallen raus.
    func setAnime(_ newAnime: [AnimeEntry]) {
        var seen = Set<UUID>()
        let previous = Dictionary(anime.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let oldIDs = Set(anime.compactMap { $0.aniList?.id })
        anime = Array(newAnime.filter { $0.isValid && seen.insert($0.id).inserted }.prefix(AnimeEntry.maxCount))
            .map { entry in
                // Das iPhone schickt die Liste so, wie es sie kennt. Hat der Mac inzwischen frischere
                // AniList-Daten geholt, bleiben die stehen.
                guard let incoming = entry.aniList, let known = previous[entry.id],
                      let knownInfo = known.aniList, knownInfo.id == incoming.id,
                      knownInfo.syncedAt > incoming.syncedAt else { return entry }
                var merged = known
                merged.title = entry.title
                return merged
            }
        saveAnime()
        onAnimeChanged?(anime)
        // Neu verknüpfte Animes sofort mit Live-Daten füllen.
        if !Set(anime.compactMap { $0.aniList?.id }).subtracting(oldIDs).isEmpty {
            startAniListSync()
        }
    }

    // MARK: - AniList

    private let aniList = AniListClient()
    private var aniListTask: Task<Void, Never>?

    /// Holt die Live-Daten für alle verknüpften Animes jetzt und danach regelmäßig neu:
    /// alle 30 Minuten und kurz nach jeder angekündigten Folge.
    func startAniListSync() {
        aniListTask?.cancel()
        aniListTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let delay = await self?.syncAniList() else { return }
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    /// Ein Durchgang. Gibt zurück, in wie vielen Sekunden der nächste fällig ist.
    private func syncAniList() async -> TimeInterval {
        let ids = Array(Set(anime.compactMap { $0.aniList?.id }))
        guard !ids.isEmpty else { return 30 * 60 }
        let media: [AniListMedia]
        do {
            media = try await aniList.media(ids: ids)
        } catch {
            NSLog("CouchHost: AniList-Daten konnten nicht geholt werden: \(error.localizedDescription)")
            return 5 * 60
        }
        guard !Task.isCancelled else { return 0 }

        let byID = Dictionary(media.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let now = Date()
        let updated = anime.map { entry in
            guard let id = entry.aniList?.id, let fresh = byID[id] else { return entry }
            return entry.synced(with: fresh, at: now)
        }
        if updated != anime {
            anime = updated
            saveAnime()
            onAnimeChanged?(anime)
        }

        var delay: TimeInterval = 30 * 60
        if let soonest = anime.compactMap({ $0.aniList?.nextAiringAt }).filter({ $0 > now }).min() {
            // Zwei Minuten nach der Ausstrahlung nachsehen, dann steht die nächste Folge schon fest.
            delay = min(delay, soonest.timeIntervalSince(now) + 120)
        }
        return max(delay, 60)
    }

    // MARK: - Öffnen und Suchen

    func open(_ app: HomeApp) {
        guard app.isValid else { return }
        startLaunch(app: app, url: app.url)
    }

    func perform(_ shortcut: AppShortcut) {
        switch shortcut.action {
        case .open(let url): startLaunch(app: currentApp, url: url)
        case .search: requestSearch(for: currentApp)
        }
    }

    /// Zeigt den Such-Hinweis und bittet die iPhones, die Tastatur zu öffnen.
    func requestSearch(for app: HomeApp?) {
        searchPrompt = app.map { "In \($0.name) suchen" } ?? "Suchen"
        onKeyboardRequest?(app?.id)
    }

    func search(appID: UUID, query: String) {
        guard let app = apps.first(where: { $0.id == appID }),
              let url = KnownServices.searchURL(for: app, query: query) else { return }
        startLaunch(app: app, url: url)
    }

    /// Öffnet eine Adresse mit Startanimation (falls die Startseite sichtbar ist).
    ///
    /// Ablauf: Kachel wächst zum Vollbild (0,5 s) → Browser öffnet sich dahinter →
    /// Startseite blendet aus. Das Fenster liegt solange eine Ebene höher, damit der
    /// Browser die Animation nicht vorzeitig verdeckt.
    private func startLaunch(app: HomeApp?, url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return }
        guard launch == nil else { return }
        guard isVisible, let window else {
            openInBrowser(url)
            return
        }

        searchPrompt = nil
        window.level = .floating
        launch = Launch(app: app)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) { [weak self] in
            MainActor.assumeIsolated { self?.openInBrowser(url) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.05) { [weak self] in
            MainActor.assumeIsolated {
                self?.fadeOut { self?.launch = nil }
            }
        }
    }

    /// Öffnet im Standardbrowser des Macs (nicht fest in Safari).
    private func openInBrowser(_ url: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(url, configuration: configuration, completionHandler: nil)
    }

    // MARK: - D-Pad

    /// Tasten, die die Startseite selbst verarbeitet (statt sie als Tastendruck weiterzugeben).
    nonisolated static func handles(_ key: RemoteKey) -> Bool {
        switch key {
        case .up, .down, .left, .right, .select, .back: true
        default: false
        }
    }

    func focusApp(_ index: Int) {
        guard apps.indices.contains(index) else { return }
        currentAppIndex = index
        focus = .app(index)
    }

    func focusPill(_ index: Int) {
        guard Self.pills.indices.contains(index) else { return }
        focus = .pill(index)
    }

    func perform(_ pill: Pill) {
        switch pill {
        case .search: requestSearch(for: nil)
        case .desktop: fadeOut()
        }
    }

    func focusShortcut(_ index: Int) {
        guard shortcuts.indices.contains(index) else { return }
        focus = .shortcut(index)
    }

    func handle(_ key: RemoteKey) {
        NSCursor.setHiddenUntilMouseMoves(true) // Zeiger stört bei D-Pad-Bedienung
        if searchPrompt != nil {
            searchPrompt = nil // jede Taste schließt den Such-Hinweis
            if key == .back || key == .select { return }
        }
        let pills = Self.pills

        // Aufbau von oben nach unten: Schaltflächen → Schnellzugriff → App-Leiste
        switch focus {
        case .pill(let index):
            switch key {
            case .left: focus = .pill(max(index - 1, 0))
            case .right: focus = .pill(min(index + 1, pills.count - 1))
            case .down:
                if !shortcuts.isEmpty {
                    focus = .shortcut(0)
                } else if !apps.isEmpty {
                    focusApp(currentAppIndex)
                }
            case .select: perform(pills[index])
            default: break
            }

        case .app(let index):
            switch key {
            case .left where index > 0: focusApp(index - 1)
            case .right where index + 1 < apps.count: focusApp(index + 1)
            case .up:
                if !shortcuts.isEmpty {
                    focus = .shortcut(0)
                } else {
                    focus = .pill(0)
                }
            case .select: if apps.indices.contains(index) { open(apps[index]) }
            default: break
            }

        case .shortcut(let index):
            switch key {
            case .left: focus = .shortcut(max(index - 1, 0))
            case .right: focus = .shortcut(min(index + 1, shortcuts.count - 1))
            case .up: focus = .pill(0)
            case .down: focusApp(currentAppIndex)
            case .select: if shortcuts.indices.contains(index) { perform(shortcuts[index]) }
            default: break
            }
        }
    }

    // MARK: - Fenster

    /// Home-Taste: Startseite öffnen bzw. wieder schließen.
    func toggle() {
        guard launch == nil else { return }
        if isVisible {
            fadeOut()
        } else {
            show()
        }
    }

    /// Blendet das Fenster weich aus und versteckt es danach.
    private func fadeOut(completion: (() -> Void)? = nil) {
        guard let window, isVisible else {
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.hide()
                window.alphaValue = 1
                window.level = .normal
                completion?()
            }
        })
    }

    func show() {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        guard let screen else { return }

        loadWallpaper(for: screen)
        searchPrompt = nil
        focus = apps.isEmpty ? .pill(0) : .app(min(currentAppIndex, apps.count - 1))

        let window = self.window ?? makeWindow()
        window.setFrame(screen.frame, display: true)
        // Über allen anderen Fenstern, auch über Browsern im Vollbild
        window.level = .floating
        window.alphaValue = 0
        // CouchHost läuft im Hintergrund; das kooperative `activate()` würde hier oft ignoriert
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]

        isVisible = true
        visibility.set(true)
        presentationID = UUID()

        // Weich einblenden
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
    }

    func hide() {
        window?.orderOut(nil)
        NSApp.presentationOptions = []
        searchPrompt = nil
        isVisible = false
        visibility.set(false)
    }

    /// Eigenes Bild (im CouchHost-Fenster gewählt) oder das Schreibtischbild dieses Bildschirms.
    private func loadWallpaper(for screen: NSScreen) {
        let customPath = UserDefaults.standard.string(forKey: Self.wallpaperPathKey)
        let url = customPath.map(URL.init(fileURLWithPath:)) ?? NSWorkspace.shared.desktopImageURL(for: screen)
        wallpaper = url.flatMap(NSImage.init(contentsOf:))
    }

    private func makeWindow() -> NSWindow {
        let window = HomeWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.onEscape = { [weak self] in self?.hide() }
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: HomeView(home: self))
        self.window = window
        return window
    }
}

/// Randloses Fenster, das trotzdem Tastatureingaben annehmen darf.
/// Escape auf der echten Mac-Tastatur schließt die Startseite (Escape vom iPhone wird vorher abgefangen).
private final class HomeWindow: NSWindow {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onEscape?()
        } else {
            super.keyDown(with: event)
        }
    }
}
