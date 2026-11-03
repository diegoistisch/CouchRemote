import SwiftUI
import RemoteKit

/// Fernbedienung im Stil der Apple-Remote-App (Liquid Glass): oben Einstellungen, Mac-Auswahl und
/// Power, in der Mitte das große Trackpad, unten Player, Navigation sowie Apps und Tastatur.
struct RemoteView: View {
    @EnvironmentObject private var client: RemoteClient
    @State private var showsApps = false
    @State private var showsSettings = false
    @AppStorage(LockScreenRemote.enabledKey) private var lockScreenRemote = true

    var body: some View {
        VStack(spacing: 16) {
            header
            if let notice = client.notice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }

            VStack(spacing: 18) {
                TrackpadView()
                    .frame(maxHeight: .infinity)
                playerRow
                navigationRow
                appsKeyboardRow
            }
            // Nur die Bedienelemente sperren, der Header (Mac-Auswahl, Einstellungen) bleibt aktiv.
            .disabled(!client.isConnected)
            .opacity(client.isConnected ? 1 : 0.5)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .sheet(isPresented: pairingSheetBinding) {
            PairingSheet().environmentObject(client)
        }
        .sheet(isPresented: $showsApps) {
            AppsSheet().environmentObject(client)
        }
        .sheet(isPresented: $showsSettings) {
            SettingsSheet().environmentObject(client)
        }
        .sheet(item: $client.keyboardRequest) { request in
            KeyboardSheet(request: request).environmentObject(client)
        }
        .onChange(of: lockScreenRemote) { _, enabled in
            if !enabled {
                LockScreenRemote.stop()
            } else if client.isConnected, let mac = client.currentMac {
                LockScreenRemote.start(macName: mac)
            }
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

    /// Wie bei Apple: runder Knopf links, Auswahl-Pille in der Mitte, Power rechts.
    private var header: some View {
        HStack(spacing: 14) {
            Button {
                Haptics.tap()
                showsSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 22, weight: .medium))
                    .frame(width: 58, height: 58)
                    .glass(in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Einstellungen")

            macPicker

            Button {
                Haptics.tap()
                client.toggleTV()
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 22, weight: .medium))
                    .frame(width: 58, height: 58)
                    .glass(in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Fernseher ein/aus")
            .disabled(!client.isConnected)
            .opacity(client.isConnected ? 1 : 0.5)
        }
    }

    private var macPicker: some View {
        Menu {
            if client.macs.isEmpty {
                Text("Kein Mac im Netzwerk gefunden")
            }
            ForEach(client.macs) { mac in
                Button(mac.name) { client.connect(to: mac) }
            }
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(client.isConnected ? .green : .orange)
                    .frame(width: 8, height: 8)
                Text(client.currentMac ?? "Mac auswählen")
                    .font(.headline)
                    .lineLimit(1)
                if client.fastActive {
                    // Trackpad läuft über den schnellen UDP-Kanal
                    Image(systemName: "bolt.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                        .accessibilityLabel("Schneller Kanal aktiv")
                }
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 58)
            .glass(in: Capsule())
        }
        .accessibilityLabel("Mac auswählen")
    }

    // MARK: - Bedienelemente

    /// Spulen (halten = wiederholen) und Play/Pause in der Mitte.
    private var playerRow: some View {
        HStack(spacing: 0) {
            RepeatingPress(label: "Zurückspulen") {
                client.send(.key(.seekBack))
            } content: {
                Image(systemName: "gobackward")
                    .font(.system(size: 24, weight: .medium))
                    .frame(width: 72, height: 72)
                    .glass(in: Circle())
            }
            Spacer()
            Button {
                Haptics.tap()
                client.send(.key(.playPause))
            } label: {
                Image(systemName: "playpause")
                    .font(.system(size: 32, weight: .medium))
                    .frame(width: 104, height: 104)
                    .glass(in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play/Pause")
            Spacer()
            RepeatingPress(label: "Vorspulen") {
                client.send(.key(.seekForward))
            } content: {
                Image(systemName: "goforward")
                    .font(.system(size: 24, weight: .medium))
                    .frame(width: 72, height: 72)
                    .glass(in: Circle())
            }
        }
    }

    private var navigationRow: some View {
        HStack(spacing: 12) {
            RemoteButton(systemImage: "house", label: "Home") { client.send(.key(.home)) }
            RemoteButton(systemImage: "arrow.up.left.and.arrow.down.right", label: "Vollbild") {
                client.send(.key(.fullscreen))
            }
            // Drückt am Mac „Opening überspringen“ (Crunchyroll) bzw. „Skip Intro“, falls er gerade da ist.
            RemoteButton(systemImage: "forward.end", label: "Opening überspringen") {
                client.send(.key(.skip))
            }
        }
    }

    /// Apps und Tastatur sitzen dort, wo früher die Lautstärke war.
    private var appsKeyboardRow: some View {
        HStack(spacing: 12) {
            RemoteButton(systemImage: "square.grid.2x2", label: "Apps", title: "Apps") {
                showsApps = true
            }
            RemoteButton(systemImage: "keyboard", label: "Tastatur", title: "Tastatur") {
                client.showKeyboard()
            }
        }
    }
}

// MARK: - Einstellungen

struct SettingsSheet: View {
    @EnvironmentObject private var client: RemoteClient
    @Environment(\.dismiss) private var dismiss
    @AppStorage("trackpadSensitivity") private var sensitivity = 1.0
    @AppStorage(LockScreenRemote.enabledKey) private var lockScreenRemote = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Circle()
                            .fill(client.isConnected ? .green : .orange)
                            .frame(width: 10, height: 10)
                        Text(client.status)
                    }
                    if client.macs.isEmpty {
                        Text("Kein Mac im Netzwerk gefunden")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(client.macs) { mac in
                        Button {
                            client.connect(to: mac)
                        } label: {
                            HStack {
                                Text(mac.name).foregroundStyle(.primary)
                                Spacer()
                                if mac.name == client.currentMac {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } header: {
                    Text("Mac")
                }

                Section {
                    HStack {
                        Image(systemName: "tortoise")
                        Slider(value: $sensitivity, in: 0.4...2.5)
                        Image(systemName: "hare")
                    }
                    .foregroundStyle(.secondary)
                } header: {
                    Text("Trackpad-Geschwindigkeit")
                }

                Section {
                    Toggle(isOn: $lockScreenRemote) {
                        Label("Auf dem Sperrbildschirm", systemImage: "lock.iphone")
                    }
                } footer: {
                    Text("Zeigt die Fernbedienung als Live-Aktivität auf dem Sperrbildschirm.")
                }

                if client.isConnected {
                    Section {
                        Button("Trennen") { client.disconnect() }
                        Button("Kopplung vergessen", role: .destructive) { client.forgetCurrentMac() }
                    }
                }
            }
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
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
        HStack(spacing: 10) {
            trackpad
            scrollStrip
        }
    }

    private var trackpad: some View {
        ZStack {
            Color.clear
            if client.isConnected {
                Text("1 Finger: Zeiger · Tippen: Klick\n2 Finger: Scrollen · Tippen: Rechtsklick")
                    .multilineTextAlignment(.center)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .allowsHitTesting(false)
            } else {
                // Wie „Suchen …“ bei Apple: solange kein Mac verbunden ist, steht der Status mittig.
                VStack(spacing: 12) {
                    ProgressView()
                    Text(client.status.uppercased())
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .allowsHitTesting(false)
            }
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
        .glass(in: RoundedRectangle(cornerRadius: 40, style: .continuous), interactive: false)
        .clipShape(RoundedRectangle(cornerRadius: 40, style: .continuous))
        .accessibilityLabel("Trackpad")
    }

    /// Schmale Leiste rechts: 1 Finger hoch/runter = senkrecht scrollen.
    private var scrollStrip: some View {
        ZStack {
            Color.clear
            Image(systemName: "arrow.up.and.down")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(width: 44)
        .glass(in: Capsule(), interactive: false)
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
    /// Optionaler Text neben dem Symbol (z. B. „Apps“).
    var title: String? = nil
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
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.title3)
            if let title {
                Text(title).font(.headline)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 56)
        .contentShape(Capsule())
        .glass(in: Capsule())
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

// MARK: - Liquid Glass

extension View {
    /// Liquid Glass ab iOS 26, sonst ein Material-Hintergrund in derselben Form.
    @ViewBuilder
    func glass<S: Shape>(in shape: S, interactive: Bool = true) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
        #else
        self.background(.ultraThinMaterial, in: shape)
        #endif
    }
}
