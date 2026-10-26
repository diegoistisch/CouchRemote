import SwiftUI
import RemoteKit

/// Eine einzige Fernbedienungs-Ansicht: großes Trackpad, darunter Player, Navigation und Lautstärke.
struct RemoteView: View {
    @EnvironmentObject private var client: RemoteClient
    @State private var showsApps = false

    var body: some View {
        VStack(spacing: 14) {
            header
            if let notice = client.tvNotice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }

            VStack(spacing: 14) {
                TrackpadView()
                    .frame(maxHeight: .infinity)
                playerRow
                navigationRow
                volumeRow
            }
            // Nur die Bedienelemente sperren, der Header (Mac-Auswahl) bleibt aktiv.
            .disabled(!client.isConnected)
            .opacity(client.isConnected ? 1 : 0.5)
        }
        .padding()
        .sheet(isPresented: pairingSheetBinding) {
            PairingSheet().environmentObject(client)
        }
    }

    private var pairingSheetBinding: Binding<Bool> {
        Binding(
            get: { client.phase == .needsCode },
            set: { isPresented in
                if !isPresented, client.phase == .needsCode { client.cancelPairing() }
            }
        )
    }

    // MARK: - Kopfzeile

    private var header: some View {
        HStack {
            Circle()
                .fill(client.isConnected ? .green : .orange)
                .frame(width: 10, height: 10)
            Text(client.status)
                .font(.footnote)
                .lineLimit(1)
            if client.fastActive {
                // Trackpad läuft über den schnellen UDP-Kanal
                Image(systemName: "bolt.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
                    .accessibilityLabel("Schneller Kanal aktiv")
            }
            Spacer()
            Button {
                Haptics.tap()
                client.toggleTV()
            } label: {
                Image(systemName: "power")
                    .font(.title3)
            }
            .accessibilityLabel("Fernseher ein/aus")
            .disabled(!client.isConnected)
            .padding(.trailing, 8)
            Button {
                client.showKeyboard()
            } label: {
                Image(systemName: "keyboard")
                    .font(.title3)
            }
            .accessibilityLabel("Tastatur")
            .disabled(!client.isConnected)
            .padding(.trailing, 8)
            Button {
                showsApps = true
            } label: {
                Image(systemName: "square.grid.2x2")
                    .font(.title3)
            }
            .accessibilityLabel("Apps")
            .disabled(!client.isConnected)
            .padding(.trailing, 8)
            Menu {
                if client.macs.isEmpty {
                    Text("Kein Mac im Netzwerk gefunden")
                }
                ForEach(client.macs) { mac in
                    Button(mac.name) { client.connect(to: mac) }
                }
                if client.isConnected {
                    Divider()
                    Button("Trennen") { client.disconnect() }
                    Button("Kopplung vergessen", role: .destructive) { client.forgetCurrentMac() }
                }
            } label: {
                Image(systemName: "tv")
                    .font(.title3)
            }
        }
        .sheet(isPresented: $showsApps) {
            AppsSheet().environmentObject(client)
        }
        .sheet(item: $client.keyboardRequest) { request in
            KeyboardSheet(request: request).environmentObject(client)
        }
    }

    // MARK: - Bedienelemente

    /// Spulen (halten = wiederholen) und Play/Pause in der Mitte.
    private var playerRow: some View {
        HStack(spacing: 22) {
            RepeatingPress(label: "Zurückspulen") {
                client.send(.key(.seekBack))
            } content: {
                Image(systemName: "gobackward")
                    .font(.system(size: 24, weight: .semibold))
                    .frame(width: 62, height: 62)
                    .background(Circle().fill(.quaternary))
            }

            Button {
                Haptics.tap()
                client.send(.key(.playPause))
            } label: {
                Image(systemName: "playpause.fill")
                    .font(.system(size: 30, weight: .bold))
                    .frame(width: 84, height: 84)
                    .background(Circle().fill(.tint))
                    .foregroundStyle(.white)
            }
            .accessibilityLabel("Play/Pause")

            RepeatingPress(label: "Vorspulen") {
                client.send(.key(.seekForward))
            } content: {
                Image(systemName: "goforward")
                    .font(.system(size: 24, weight: .semibold))
                    .frame(width: 62, height: 62)
                    .background(Circle().fill(.quaternary))
            }
        }
    }

    private var navigationRow: some View {
        HStack(spacing: 12) {
            // Tippen = Escape (Menü/Vollbild verlassen), Halten = vorherige Seite im Browser.
            RemoteButton(systemImage: "chevron.backward", label: "Zurück",
                         longPressLabel: "Seite zurück",
                         longPressAction: { client.send(.key(.browserBack)) }) {
                client.send(.key(.back))
            }
            RemoteButton(systemImage: "house", label: "Home") { client.send(.key(.home)) }
            RemoteButton(systemImage: "arrow.up.left.and.arrow.down.right", label: "Vollbild") {
                client.send(.key(.fullscreen))
            }
        }
    }

    private var volumeRow: some View {
        HStack(spacing: 12) {
            RemoteButton(systemImage: "speaker.minus", label: "Leiser", repeats: true) { client.send(.key(.volumeDown)) }
            RemoteButton(systemImage: "speaker.slash", label: "Stumm") { client.send(.key(.mute)) }
            RemoteButton(systemImage: "speaker.plus", label: "Lauter", repeats: true) { client.send(.key(.volumeUp)) }
        }
    }
}

// MARK: - Kopplung

struct PairingSheet: View {
    @EnvironmentObject private var client: RemoteClient
    @State private var code = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "tv")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
                Text("Gib den \(RemoteProtocol.pairingCodeLength)-stelligen Code ein, der auf dem Mac bzw. Fernseher angezeigt wird.")
                    .multilineTextAlignment(.center)

                TextField("0000", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .font(.system(size: 44, weight: .bold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .focused($isFocused)
                    .onChange(of: code) { _, newValue in
                        let digits = String(newValue.filter(\.isNumber).prefix(RemoteProtocol.pairingCodeLength))
                        if digits != newValue {
                            code = digits
                            return
                        }
                        if digits.count == RemoteProtocol.pairingCodeLength {
                            client.submit(code: digits)
                            code = ""
                        }
                    }

                if let error = client.codeError {
                    Text(error)
                        .foregroundStyle(.red)
                }
                Spacer()
            }
            .padding(24)
            .navigationTitle("Mit Mac koppeln")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { client.cancelPairing() }
                }
            }
            .onAppear { isFocused = true }
        }
        .interactiveDismissDisabled()
    }
}

// MARK: - Trackpad

struct TrackpadView: View {
    @EnvironmentObject private var client: RemoteClient
    @AppStorage("trackpadSensitivity") private var sensitivity = 1.0
    /// Letzte Fingerposition in der Scroll-Leiste (nil = kein Finger drauf).
    @State private var scrollStripLast: CGFloat?

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                trackpad
                scrollStrip
            }

            HStack {
                Image(systemName: "tortoise")
                Slider(value: $sensitivity, in: 0.4...2.5)
                Image(systemName: "hare")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var trackpad: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24)
                .fill(.quaternary)
            Text("1 Finger: Zeiger · Tippen: Klick\n2 Finger: Scrollen · Tippen: Rechtsklick")
                .multilineTextAlignment(.center)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .allowsHitTesting(false)
            TrackpadSurface(
                onMove: move,
                onScroll: { dx, dy in client.queueScroll(dx: dx * 2, dy: dy * 2) },
                onTap: {
                    Haptics.tap()
                    client.send(.click(.left))
                },
                onTwoFingerTap: {
                    Haptics.tap()
                    client.send(.click(.right))
                }
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .accessibilityLabel("Trackpad")
    }

    /// Schmale Leiste rechts: 1 Finger hoch/runter = senkrecht scrollen.
    private var scrollStrip: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18)
                .fill(.quaternary)
            Image(systemName: "arrow.up.and.down")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(width: 44)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let dy = value.translation.height - (scrollStripLast ?? 0)
                    scrollStripLast = value.translation.height
                    if dy != 0 { client.queueScroll(dx: 0, dy: dy * 3) }
                }
                .onEnded { _ in scrollStripLast = nil }
        )
        .accessibilityLabel("Scrollen")
    }

    /// Zeigerbeschleunigung nach Geschwindigkeit wie beim Mac-Trackpad:
    /// langsam = feiner als 1:1 (präzise), schnell = bis zu 3,5-fach (weite Strecken).
    private func move(dx: Double, dy: Double, dt: Double) {
        let speed = (dx * dx + dy * dy).squareRoot() / dt // Punkte pro Sekunde
        let acceleration = min(max(pow(speed / 300, 0.6), 0.5), 3.5)
        let gain = 1.6 * sensitivity * acceleration
        client.queueMove(dx: dx * gain, dy: dy * gain)
    }
}

// MARK: - Bausteine

/// Knopf, der beim Halten seine Aktion wiederholt (nach 0,4 s alle 0,11 s).
struct RepeatingPress<Content: View>: View {
    let label: String
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var repeatTask: Task<Void, Never>?
    @State private var isPressed = false

    var body: some View {
        content()
            .contentShape(Rectangle())
            .scaleEffect(isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.1), value: isPressed)
            .onLongPressGesture(minimumDuration: .infinity, maximumDistance: 40, perform: {}) { pressing in
                isPressed = pressing
                repeatTask?.cancel()
                repeatTask = nil
                guard pressing else { return }
                fire()
                repeatTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    while !Task.isCancelled {
                        fire()
                        try? await Task.sleep(for: .milliseconds(110))
                    }
                }
            }
            .onDisappear { repeatTask?.cancel() }
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { fire() }
    }

    private func fire() {
        Haptics.tap()
        action()
    }
}

/// Runder Rechteck-Knopf. Optional: Wiederholen beim Halten oder eine zweite Aktion beim langen Drücken.
struct RemoteButton: View {
    let systemImage: String
    let label: String
    var repeats = false
    var longPressLabel: String?
    var longPressAction: (() -> Void)?
    let action: () -> Void

    var body: some View {
        if repeats {
            RepeatingPress(label: label, action: action) { face }
        } else if let longPressAction {
            face
                .contentShape(Rectangle())
                .onTapGesture {
                    Haptics.tap()
                    action()
                }
                .onLongPressGesture(minimumDuration: 0.5) {
                    Haptics.longPress()
                    longPressAction()
                }
                .accessibilityElement()
                .accessibilityLabel(label)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { action() }
                .accessibilityAction(named: Text(longPressLabel ?? label)) { longPressAction() }
        } else {
            Button {
                Haptics.tap()
                action()
            } label: {
                face
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
        }
    }

    private var face: some View {
        Image(systemName: systemImage)
            .font(.title3)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(RoundedRectangle(cornerRadius: 14).fill(.quaternary))
    }
}

enum Haptics {
    @MainActor static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    @MainActor static func longPress() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}
