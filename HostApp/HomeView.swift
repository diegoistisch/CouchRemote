import RemoteKit
import SwiftUI

/// Startseite im Stil von tvOS: Hintergrundbild, obere Leiste (Start, Suche, Uhrzeit),
/// „Deine Apps“ als Logo-Kacheln und darunter der Schnellzugriff der gewählten App.
struct HomeView: View {
    @ObservedObject var home: HomeController

    /// Position jeder Kachel (für die Startanimation, die aus der Kachel heraus wächst).
    @State private var tileFrames: [UUID: CGRect] = [:]
    /// Einblend-Animation der Inhalte bei jedem Öffnen.
    @State private var appeared = true

    private static let space = "home"

    var body: some View {
        GeometryReader { geo in
            let metrics = Metrics(size: geo.size, appCount: home.apps.count)

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

        init(size: CGSize, appCount: Int) {
            self.size = size
            padding = size.width * 0.045
            gap = size.width * 0.011
            sectionGap = size.height * 0.035
            let columns = CGFloat(HomeController.columns)
            let rows = CGFloat(max(1, (appCount + HomeController.columns - 1) / HomeController.columns))
            let byWidth = (size.width - 2 * padding - (columns - 1) * gap) / columns
            let byHeight = (size.height * 0.42 - (rows - 1) * gap) / rows * 1.7
            tileWidth = max(min(byWidth, byHeight), 90)
            tileHeight = tileWidth / 1.7
            titleSize = max(size.height * 0.028, 14)
            barHeight = max(size.height * 0.055, 34)
        }
    }

    // MARK: - Inhalt

    private func content(_ m: Metrics) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            topBar(m)
                .padding(.bottom, m.sectionGap)

            sectionTitle("Deine Apps", m)

            if home.apps.isEmpty {
                emptyState(m)
            } else {
                appGrid(m)
            }

            if let app = home.currentApp, !home.shortcuts.isEmpty {
                sectionTitle("\(app.name) · Schnellzugriff", m)
                    .padding(.top, m.sectionGap)
                shortcutRow(m)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, m.padding)
        .padding(.top, m.padding * 0.6)
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
                    .blur(radius: 2)
            } else {
                LinearGradient(colors: [Color(red: 0.1, green: 0.13, blue: 0.22), .black],
                               startPoint: .top, endPoint: .bottom)
            }
            // Abdunkeln für Lesbarkeit: oben leicht, unten stärker
            LinearGradient(colors: [.black.opacity(0.45), .black.opacity(0.2), .black.opacity(0.7)],
                           startPoint: .top, endPoint: .bottom)
        }
        .frame(width: size.width, height: size.height)
    }

    // MARK: - Obere Leiste

    private func topBar(_ m: Metrics) -> some View {
        HStack(spacing: m.barHeight * 0.5) {
            Text("Start")
                .font(.system(size: m.barHeight * 0.4, weight: .semibold))
                .padding(.horizontal, m.barHeight * 0.6)
                .frame(height: m.barHeight * 0.8)
                .background(Capsule().fill(.white.opacity(0.2)))
                .padding(m.barHeight * 0.1)
                .background(Capsule().fill(.ultraThinMaterial))

            Spacer()

            let searchFocused = home.focus == .search
            Image(systemName: "magnifyingglass")
                .font(.system(size: m.barHeight * 0.42, weight: .semibold))
                .foregroundStyle(searchFocused ? Color.black : Color.white)
                .frame(width: m.barHeight, height: m.barHeight)
                .background(Circle().fill(searchFocused ? AnyShapeStyle(Color.white) : AnyShapeStyle(.ultraThinMaterial)))
                .scaleEffect(searchFocused ? 1.12 : 1)
                .shadow(color: searchFocused ? .white.opacity(0.5) : .clear, radius: 12)
                .onHover { if $0 { home.focusSearch() } }
                .onTapGesture { home.requestSearch(for: nil) }

            TimelineView(.everyMinute) { context in
                Text(context.date, format: .dateTime.hour().minute())
                    .font(.system(size: m.barHeight * 0.5, weight: .medium, design: .rounded))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(.white)
    }

    private func sectionTitle(_ text: String, _ m: Metrics) -> some View {
        Text(text)
            .font(.system(size: m.titleSize, weight: .semibold))
            .foregroundStyle(.white.opacity(0.92))
            .shadow(color: .black.opacity(0.5), radius: 6)
            .padding(.bottom, m.gap * 1.6)
    }

    // MARK: - Apps

    private func appGrid(_ m: Metrics) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(m.tileWidth), spacing: m.gap), count: HomeController.columns),
            alignment: .leading,
            spacing: m.gap * 1.3
        ) {
            ForEach(Array(home.apps.enumerated()), id: \.element.id) { index, app in
                HomeTile(app: app, isFocused: home.focus == .app(index),
                         width: m.tileWidth, height: m.tileHeight)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(key: TileFramesKey.self,
                                                   value: [app.id: proxy.frame(in: .named(Self.space))])
                        }
                    )
                    .opacity(home.launch?.app?.id == app.id ? 0 : 1) // wächst gerade zum Vollbild
                    .onHover { if $0 { home.focusApp(index) } }
                    .onTapGesture { home.open(app) }
            }
        }
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
