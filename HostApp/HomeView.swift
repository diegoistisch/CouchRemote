import RemoteKit
import SwiftUI

/// Startseite: Vollbild-Hintergrund, große Uhr mit Begrüßung oben links, Schaltflächen oben rechts,
/// unten eine Leiste mit App-Kacheln und darüber der Schnellzugriff der gewählten App.
struct HomeView: View {
    @ObservedObject var home: HomeController

    /// Position jeder Kachel (für die Startanimation, die aus der Kachel heraus wächst).
    @State private var tileFrames: [UUID: CGRect] = [:]
    /// Einblend-Animation der Inhalte bei jedem Öffnen.
    @State private var appeared = true

    private static let space = "home"

    var body: some View {
        GeometryReader { geo in
            let metrics = Metrics(size: geo.size)

            ZStack(alignment: .topLeading) {
                background(size: geo.size)

                content(metrics)
                    // tvOS-Gefühl: beim Start einer App tritt die Startseite leicht zurück
                    .scaleEffect(home.launch != nil ? 0.96 : (appeared ? 1 : 1.03))
                    .opacity(appeared ? 1 : 0)
                    .blur(radius: home.launch != nil ? 6 : 0)

                if let prompt = home.searchPrompt {
                    searchOverlay(prompt, metrics)
                }

                if let launch = home.launch {
                    LaunchOverlay(
                        launch: launch,
                        source: launch.app.flatMap { tileFrames[$0.id] } ?? Self.centerRect(in: geo.size),
                        size: geo.size
                    )
                    .id(launch.id)
                }
            }
            .coordinateSpace(name: Self.space)
            .onPreferenceChange(TileFramesKey.self) { tileFrames = $0 }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: home.focus)
        .animation(.easeInOut(duration: 0.35), value: home.launch)
        .onChange(of: home.presentationID) { _, _ in
            appeared = false
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) { appeared = true }
            }
        }
    }

    private static func centerRect(in size: CGSize) -> CGRect {
        CGRect(x: size.width / 2 - 120, y: size.height / 2 - 70, width: 240, height: 140)
    }

    // MARK: - Maße

    struct Metrics {
        let size: CGSize
        let padding: CGFloat
        let gap: CGFloat
        let sectionGap: CGFloat
        let tileWidth: CGFloat
        let tileHeight: CGFloat
        let titleSize: CGFloat
        let barHeight: CGFloat
        let clockSize: CGFloat

        init(size: CGSize) {
            self.size = size
            padding = size.width * 0.045
            gap = size.width * 0.009
            sectionGap = size.height * 0.03
            // Etwa sieben Kacheln passen nebeneinander in die Leiste, weitere sind seitlich erreichbar
            tileWidth = max(size.width * 0.115, 110)
            tileHeight = tileWidth / 1.7
            titleSize = max(size.height * 0.026, 14)
            barHeight = max(size.height * 0.05, 32)
            clockSize = max(size.height * 0.17, 64)
        }
    }

    // MARK: - Inhalt

    private func content(_ m: Metrics) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                clock(m)
                Spacer(minLength: m.padding)
                pills(m)
            }

            Spacer(minLength: m.sectionGap)

            if let app = home.currentApp, !home.shortcuts.isEmpty {
                sectionTitle("\(app.name) · Schnellzugriff", m)
                shortcutRow(m)
                    .padding(.bottom, m.sectionGap)
            }

            dock(m)
        }
        .padding(.horizontal, m.padding)
        .padding(.top, m.padding * 0.7)
        .padding(.bottom, m.padding * 0.6)
        .frame(width: m.size.width, height: m.size.height, alignment: .topLeading)
    }

    // MARK: - Hintergrund

    private func background(size: CGSize) -> some View {
        ZStack {
            Color.black
            if let wallpaper = home.wallpaper {
                Image(nsImage: wallpaper)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipped()
            } else {
                LinearGradient(colors: [Color(red: 0.16, green: 0.24, blue: 0.3),
                                        Color(red: 0.1, green: 0.13, blue: 0.22), .black],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            // Das Bild soll wirken: nur oben links (Uhr) und unten (App-Leiste) abdunkeln
            LinearGradient(colors: [.black.opacity(0.4), .clear, .clear, .black.opacity(0.55)],
                           startPoint: .top, endPoint: .bottom)
            LinearGradient(colors: [.black.opacity(0.3), .clear],
                           startPoint: .leading, endPoint: .center)
        }
        .frame(width: size.width, height: size.height)
    }

    // MARK: - Uhr und Begrüßung

    private func clock(_ m: Metrics) -> some View {
        TimelineView(.everyMinute) { context in
            VStack(alignment: .leading, spacing: 0) {
                Text(Self.greeting(for: context.date))
                    .font(.system(size: m.titleSize * 1.05, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                Text(context.date, format: .dateTime.hour().minute())
                    .font(.system(size: m.clockSize, weight: .thin))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    // Ziffern stehen bei großer, dünner Schrift sonst sehr weit vom Text darüber ab
                    .padding(.vertical, -m.clockSize * 0.1)
                Text(context.date, format: .dateTime.weekday(.wide).day().month(.wide))
                    .font(.system(size: m.titleSize * 1.05, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .shadow(color: .black.opacity(0.35), radius: 12)
        }
        .environment(\.locale, Locale(identifier: "de_DE"))
    }

    static func greeting(for date: Date) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<11: "Guten Morgen"
        case 11..<17: "Guten Tag"
        case 17..<22: "Guten Abend"
        default: "Gute Nacht"
        }
    }

    // MARK: - Schaltflächen oben rechts

    private func pills(_ m: Metrics) -> some View {
        HStack(spacing: m.barHeight * 0.25) {
            ForEach(Array(HomeController.pills.enumerated()), id: \.offset) { index, pill in
                let focused = home.focus == .pill(index)
                Label(pill.title, systemImage: pill.systemImage)
                    .font(.system(size: m.barHeight * 0.36, weight: .semibold))
                    .padding(.horizontal, m.barHeight * 0.45)
                    .frame(height: m.barHeight)
                    .foregroundStyle(focused ? Color.black : Color.white)
                    .background(Capsule().fill(focused ? AnyShapeStyle(Color.white) : AnyShapeStyle(.ultraThinMaterial)))
                    .overlay(Capsule().strokeBorder(.white.opacity(focused ? 0 : 0.15), lineWidth: 1))
                    .scaleEffect(focused ? 1.08 : 1)
                    .shadow(color: focused ? .white.opacity(0.4) : .clear, radius: 12)
                    .onHover { if $0 { home.focusPill(index) } }
                    .onTapGesture { home.perform(pill) }
            }
        }
    }

    private func sectionTitle(_ text: String, _ m: Metrics) -> some View {
        Text(text)
            .font(.system(size: m.titleSize * 0.85, weight: .semibold))
            .foregroundStyle(.white.opacity(0.85))
            .shadow(color: .black.opacity(0.5), radius: 6)
            .padding(.bottom, m.gap * 1.4)
    }

    // MARK: - App-Leiste

    /// Eine Reihe abgerundeter App-Kacheln in einer halbtransparenten Leiste am unteren Rand.
    private func dock(_ m: Metrics) -> some View {
        let inset = m.gap * 1.6
        return Group {
            if home.apps.isEmpty {
                emptyState(m)
                    .padding(inset * 1.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: m.gap) {
                            ForEach(Array(home.apps.enumerated()), id: \.element.id) { index, app in
                                HomeTile(app: app, isFocused: home.focus == .app(index),
                                         width: m.tileWidth, height: m.tileHeight)
                                    .background(
                                        GeometryReader { geo in
                                            Color.clear.preference(key: TileFramesKey.self,
                                                                   value: [app.id: geo.frame(in: .named(Self.space))])
                                        }
                                    )
                                    .opacity(home.launch?.app?.id == app.id ? 0 : 1) // wächst gerade zum Vollbild
                                    .onHover { if $0 { home.focusApp(index) } }
                                    .onTapGesture { home.open(app) }
                                    .id(app.id)
                            }
                        }
                        // Platz für Vergrößerung und Schein der ausgewählten Kachel
                        .padding(inset)
                    }
                    .onChange(of: home.focus) { _, focus in
                        guard case .app(let index) = focus, home.apps.indices.contains(index) else { return }
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(home.apps[index].id, anchor: .center)
                        }
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: m.tileHeight * 0.3, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: m.tileHeight * 0.3, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                )
        )
    }

    private func emptyState(_ m: Metrics) -> some View {
        Text("Füge in der CouchRemote-App am iPhone unter „Apps“ deine Lieblingsseiten hinzu.")
            .font(.system(size: m.titleSize * 0.9))
            .foregroundStyle(.white.opacity(0.75))
    }

    // MARK: - Schnellzugriff

    private func shortcutRow(_ m: Metrics) -> some View {
        let cardWidth = m.tileWidth * 1.45
        let cardHeight = m.tileHeight * 0.62
        return HStack(spacing: m.gap) {
            ForEach(Array(home.shortcuts.enumerated()), id: \.element.id) { index, shortcut in
                let focused = home.focus == .shortcut(index)
                HStack(spacing: cardHeight * 0.25) {
                    Image(systemName: shortcut.systemImage)
                        .font(.system(size: cardHeight * 0.32, weight: .semibold))
                        .frame(width: cardHeight * 0.62, height: cardHeight * 0.62)
                        .background(Circle().fill(focused ? Color.black.opacity(0.08) : Color.white.opacity(0.15)))
                    Text(shortcut.title)
                        .font(.system(size: cardHeight * 0.26, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, cardHeight * 0.22)
                .frame(width: cardWidth, height: cardHeight)
                .foregroundStyle(focused ? Color.black : Color.white)
                .background(
                    RoundedRectangle(cornerRadius: cardHeight * 0.22, style: .continuous)
                        .fill(focused ? AnyShapeStyle(Color.white) : AnyShapeStyle(.ultraThinMaterial))
                )
                .scaleEffect(focused ? 1.06 : 1)
                .shadow(color: .black.opacity(focused ? 0.5 : 0.25), radius: focused ? 18 : 6, y: focused ? 10 : 3)
                .onHover { if $0 { home.focusShortcut(index) } }
                .onTapGesture { home.perform(shortcut) }
            }
        }
    }

    // MARK: - Suche

    private func searchOverlay(_ prompt: String, _ m: Metrics) -> some View {
        ZStack {
            Color.black.opacity(0.55)
            VStack(spacing: m.titleSize * 0.8) {
                Image(systemName: "keyboard")
                    .font(.system(size: m.titleSize * 2.4, weight: .regular))
                Text(prompt)
                    .font(.system(size: m.titleSize * 1.4, weight: .bold))
                Text("Tippe den Suchbegriff auf dem iPhone ein.")
                    .font(.system(size: m.titleSize * 0.9))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .foregroundStyle(.white)
            .padding(m.titleSize * 2)
            .background(RoundedRectangle(cornerRadius: m.titleSize, style: .continuous).fill(.ultraThinMaterial))
        }
        .transition(.opacity)
    }
}

private struct TileFramesKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

// MARK: - Startanimation

/// Die Kachel wächst aus ihrer Position zum Vollbild in der App-Farbe, das Logo vergrößert sich mit.
struct LaunchOverlay: View {
    let launch: HomeController.Launch
    let source: CGRect
    let size: CGSize

    @State private var expanded = false

    var body: some View {
        let hex = launch.app?.colorHex ?? "#1C1C28"
        let rgb = HexColor.rgb(hex)
        let color = Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
        let frame = expanded ? CGRect(origin: .zero, size: size) : source

        ZStack {
            RoundedRectangle(cornerRadius: expanded ? 0 : source.height * 0.14, style: .continuous)
                .fill(color)

            Group {
                if let app = launch.app {
                    TileContent(app: app, width: source.width, height: source.height)
                } else {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: source.height * 0.4, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .scaleEffect(expanded ? 1.7 : 1)

            ProgressView()
                .controlSize(.large)
                .tint(HexColor.isLight(hex) ? .black : .white)
                .opacity(expanded ? 0.8 : 0)
                .offset(y: size.height * 0.28)
        }
        .frame(width: frame.width, height: frame.height)
        .position(x: frame.midX, y: frame.midY)
        .shadow(color: .black.opacity(0.4), radius: expanded ? 0 : 20)
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.88)) { expanded = true }
        }
    }
}

// MARK: - Kacheln

/// Eine App-Kachel mit Rahmen und Fokus-Effekt. Ausgewählt: leicht vergrößert, weißer Rahmen, heller Schein.
struct HomeTile: View {
    let app: HomeApp
    let isFocused: Bool
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        let rgb = HexColor.rgb(app.colorHex)
        let color = Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
        let corner = height * 0.14

        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(LinearGradient(colors: [color, color.opacity(0.82)],
                                     startPoint: .top, endPoint: .bottom))
            TileContent(app: app, width: width, height: height)
            // Glanz oben, wie bei tvOS
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(LinearGradient(colors: [.white.opacity(isFocused ? 0.16 : 0.05), .clear],
                                     startPoint: .top, endPoint: .center))
                .allowsHitTesting(false)
        }
        .frame(width: width, height: height)
        .overlay(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(.white.opacity(isFocused ? 0.95 : 0.08), lineWidth: isFocused ? 3 : 1)
        )
        .shadow(color: isFocused ? Color(red: 0.55, green: 0.78, blue: 1).opacity(0.75) : .black.opacity(0.35),
                radius: isFocused ? 24 : 8, y: isFocused ? 0 : 4)
        .scaleEffect(isFocused ? 1.07 : 1)
        .zIndex(isFocused ? 1 : 0)
        .contentShape(Rectangle())
    }
}

/// Inhalt einer Kachel: eigenes Logo, sonst offizielles Icon + Name, sonst nur der Name.
struct TileContent: View {
    let app: HomeApp
    let width: CGFloat
    let height: CGFloat

    @State private var iconURL: URL?
    @State private var logo: (image: Image, aspect: CGFloat)?

    var body: some View {
        let textColor: Color = HexColor.isLight(app.colorHex) ? .black.opacity(0.85) : .white

        Group {
            if let logo {
                let wide = logo.aspect > 1.6
                logo.image
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: width * (wide ? 0.76 : 0.5), maxHeight: height * (wide ? 0.5 : 0.64))
            } else if let iconURL {
                HStack(spacing: height * 0.1) {
                    AsyncImage(url: iconURL) { phase in
                        if let image = phase.image {
                            image.resizable().interpolation(.high).scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: height * 0.1, style: .continuous))
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: height * 0.46, height: height * 0.46)
                    nameLabel(size: height * 0.17, color: textColor)
                }
                .padding(.horizontal, width * 0.08)
            } else {
                nameLabel(size: height * 0.22, color: textColor)
                    .padding(.horizontal, width * 0.08)
            }
        }
        .frame(width: width, height: height)
        .task(id: app.logo) {
            if let data = app.logo, let image = Image(logoData: data) {
                logo = (image, LogoData.aspectRatio(data) ?? 1)
            } else {
                logo = nil
                iconURL = await IconResolver.shared.iconURL(for: app.url)
            }
        }
    }

    private func nameLabel(size: CGFloat, color: Color) -> some View {
        Text(app.name)
            .font(.system(size: size, weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.45)
    }
}
