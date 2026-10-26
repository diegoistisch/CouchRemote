import CryptoKit
import Foundation
import Network
import RemoteKit
import UIKit

/// Findet CouchHost-Macs per Bonjour, koppelt sich per Code und schickt Befehle über WebSocket.
@MainActor
final class RemoteClient: ObservableObject {
    /// Eine Instanz für App und Sperrbildschirm-Knöpfe (siehe `LockScreenRemote`).
    static let shared = RemoteClient()

    struct DiscoveredMac: Identifiable, Hashable {
        let name: String
        let endpoint: NWEndpoint
        var id: String { name }
    }

    enum Phase: Equatable {
        case idle
        case connecting
        case needsCode
        case connected
    }

    /// Tastatur-Sheet anzeigen: vom Fernseher angefordert (Suche) oder über den Tastatur-Knopf.
    struct KeyboardRequest: Identifiable, Equatable {
        let id = UUID()
        /// App, in der gesucht werden soll (nil = frei wählbar).
        var appID: UUID?
        /// true = Such-Modus vorauswählen, false = Eintippen.
        var preferSearch: Bool
    }

    @Published private(set) var macs: [DiscoveredMac] = []
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var currentMac: String?
    @Published private(set) var status = "Suche Mac …"
    @Published private(set) var codeError: String?
    /// Apps der Startseite (kommen vom Mac).
    @Published private(set) var apps: [HomeApp] = []
    /// Gesetzt = Tastatur-Sheet ist offen.
    @Published var keyboardRequest: KeyboardRequest?
    /// Trackpad läuft über den schnellen UDP-Kanal.
    @Published private(set) var fastActive = false
    /// Kurze Rückmeldung zum Fernseher-Ein/Aus, z. B. „Fernseher aus“.
    @Published private(set) var tvNotice: String?
    private var tvNoticeTask: Task<Void, Never>?

    var isConnected: Bool { phase == .connected }

    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var autoConnect = true
    private let lastMacKey = "lastConnectedMac"

    // Trackpad: Bewegungen gehen sofort raus. Ist die vorige noch unterwegs,
    // werden neue gesammelt und direkt danach als eine Nachricht verschickt.
    private var pendingMove = (dx: 0.0, dy: 0.0)
    private var pendingScroll = (dx: 0.0, dy: 0.0)
    private var moveInFlight = false

    // Schneller UDP-Kanal (siehe `FastChannel`)
    private var fastConnection: NWConnection?
    private var fastSession: UInt64 = 0
    private var fastKey: SymmetricKey?
    private var fastSeq: UInt32 = 0
    private var fastRecent: [FastInputEntry] = []
    private var fastResendsLeft = 0
    private var fastResendTimer: Timer?
    private var fastProbeTimer: Timer?
    private var fastProbeAttempts = 0

    /// TCP ohne Nagle-Algorithmus, damit kleine Nachrichten sofort rausgehen.
    private static func makeParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.serviceClass = .interactiveVoice // niedrige Latenz bevorzugen (WLAN-QoS)
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        webSocket.maximumMessageSize = RemoteProtocol.maximumMessageSize // App-Liste mit Logos
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        // Kein Peer-to-Peer-WLAN (AWDL): das normale WLAN hat stabilere Latenz.
        parameters.includePeerToPeer = false
        return parameters
    }

    // MARK: - Suche

    func startBrowsing() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: RemoteProtocol.bonjourType, domain: nil),
                                using: NWParameters())
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found: [DiscoveredMac] = results.compactMap { result in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                return DiscoveredMac(name: name, endpoint: result.endpoint)
            }
            MainActor.assumeIsolated { self?.update(found) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                if case .failed(let error) = state {
                    self?.status = "Suche fehlgeschlagen: \(error.localizedDescription)"
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func update(_ found: [DiscoveredMac]) {
        macs = found.sorted { $0.name < $1.name }
        if macs.isEmpty, phase == .idle { status = "Kein Mac gefunden" }
        autoConnectIfPossible()
    }

    /// Beim Zurückkehren in die App: Verbindung wiederherstellen, falls sie im Hintergrund abgerissen ist.
    func reconnectIfNeeded() {
        autoConnectIfPossible()
    }

    private func autoConnectIfPossible() {
        // Automatisch verbinden: zuletzt genutzter Mac, sonst der einzige gefundene.
        guard autoConnect, connection == nil else { return }
        let lastName = UserDefaults.standard.string(forKey: lastMacKey)
        if let mac = macs.first(where: { $0.name == lastName }) ?? (macs.count == 1 ? macs.first : nil) {
            connect(to: mac)
        }
    }

    // MARK: - Verbindung und Kopplung

    func connect(to mac: DiscoveredMac) {
        connection?.cancel()
        reset()
        autoConnect = true
        phase = .connecting
        currentMac = mac.name
        codeError = nil
        status = "Verbinde mit \(mac.name) …"

        let connection = NWConnection(to: mac.endpoint, using: Self.makeParameters())
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            MainActor.assumeIsolated {
                guard let self, let connection, connection === self.connection else { return }
                switch state {
                case .ready:
                    self.status = "Melde an …"
                    self.receive(on: connection)
                    self.sendMessage(.hello(deviceName: UIDevice.current.name,
                                            token: TokenStore.token(for: mac.name)))
                case .waiting(let error):
                    self.status = "Warte: \(error.localizedDescription)"
                case .failed(let error):
                    self.status = "Verbindung verloren: \(error.localizedDescription)"
                    self.reset()
                case .cancelled:
                    self.reset()
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
        self.connection = connection
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, context, _, error in
            MainActor.assumeIsolated {
                guard let self, let connection, connection === self.connection, error == nil else { return }
                let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                    as? NWProtocolWebSocket.Metadata
                if metadata?.opcode == .close {
                    connection.cancel()
                    return
                }
                if let data, let message = try? RemoteProtocol.decode(ServerMessage.self, from: data) {
                    self.handle(message)
                }
                self.receive(on: connection)
            }
        }
    }

    private func handle(_ message: ServerMessage) {
        guard let mac = currentMac else { return }
        switch message {
        case .welcome:
            markConnected(mac)
        case .pairingRequired:
            TokenStore.delete(for: mac) // altes Token ist ungültig (z. B. am Mac entfernt)
            phase = .needsCode
            status = "Code vom Fernseher eingeben"
            codeError = nil
        case .pairingFailed(let attemptsLeft):
            if attemptsLeft > 0 {
                codeError = "Falscher Code, noch \(attemptsLeft) \(attemptsLeft == 1 ? "Versuch" : "Versuche")"
            } else {
                autoConnect = false
                status = "Zu viele Fehlversuche. Über das TV-Symbol neu verbinden."
            }
        case .paired(let token):
            TokenStore.save(token, for: mac)
            markConnected(mac)
        case .apps(let apps):
            self.apps = apps
        case .showKeyboard(let appID):
            keyboardRequest = KeyboardRequest(appID: appID, preferSearch: true)
        case let .fastChannel(port, session, key):
            setUpFastChannel(port: port, session: session, key: key)
        case .fastChannelConfirmed:
            fastProbeTimer?.invalidate()
            fastProbeTimer = nil
            fastActive = fastConnection != nil
        case .tvStatus(let text):
            showTVNotice(text)
        }
    }

    private func markConnected(_ mac: String) {
        phase = .connected
        codeError = nil
        status = "Verbunden mit \(mac)"
        UserDefaults.standard.set(mac, forKey: lastMacKey)
        LockScreenRemote.start(macName: mac)
    }

    func submit(code: String) {
        codeError = nil
        sendMessage(.pair(code: code))
    }

    func cancelPairing() {
        disconnect()
        status = "Kopplung abgebrochen"
    }

    /// Löscht das Token für den aktuellen Mac und trennt; beim nächsten Verbinden wird neu gekoppelt.
    func forgetCurrentMac() {
        if let mac = currentMac { TokenStore.delete(for: mac) }
        disconnect()
        status = "Kopplung gelöscht"
    }

    func disconnect() {
        autoConnect = false
        connection?.cancel()
        reset()
        status = "Getrennt"
    }

    private func reset() {
        connection = nil
        phase = .idle
        moveInFlight = false
        pendingMove = (0, 0)
        pendingScroll = (0, 0)
        tearDownFastChannel()
    }

    // MARK: - Schneller UDP-Kanal

    private func setUpFastChannel(port: UInt16, session: UInt64, key: Data) {
        tearDownFastChannel()
        // Gleiche Adresse wie die WebSocket-Verbindung, anderer Port.
        guard let endpoint = connection?.currentPath?.remoteEndpoint,
              case let .hostPort(host, _) = endpoint,
              let udpPort = NWEndpoint.Port(rawValue: port) else { return }

        let parameters = NWParameters.udp
        parameters.serviceClass = .interactiveVoice
        parameters.includePeerToPeer = false
        let udp = NWConnection(host: host, port: udpPort, using: parameters)
        fastSession = session
        fastKey = SymmetricKey(data: key)
        fastSeq = 0
        fastRecent = []
        udp.stateUpdateHandler = { [weak self, weak udp] state in
            MainActor.assumeIsolated {
                guard let self, let udp, udp === self.fastConnection else { return }
                switch state {
                case .ready: self.startFastProbe()
                case .failed, .cancelled: self.tearDownFastChannel()
                default: break
                }
            }
        }
        udp.start(queue: .main)
        fastConnection = udp
    }

    /// Leere Pakete schicken, bis der Mac bestätigt, dass UDP ankommt (Firewall, WLAN …).
    /// Bis dahin läuft das Trackpad weiter über WebSocket.
    private func startFastProbe() {
        fastProbeAttempts = 0
        transmitFast([])
        fastProbeTimer?.invalidate()
        fastProbeTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, !self.fastActive, self.fastProbeAttempts < 15 else {
                    timer.invalidate()
                    return
                }
                self.fastProbeAttempts += 1
                self.transmitFast([])
            }
        }
    }

    private func tearDownFastChannel() {
        fastConnection?.cancel()
        fastConnection = nil
        fastKey = nil
        fastActive = false
        fastProbeTimer?.invalidate()
        fastProbeTimer = nil
        fastResendTimer?.invalidate()
        fastResendTimer = nil
    }

    private func transmitFast(_ entries: [FastInputEntry]) {
        guard let udp = fastConnection, let key = fastKey else { return }
        let packet = FastChannel.encode(session: fastSession, entries: entries, key: key)
        udp.send(content: packet, completion: .idempotent)
    }

    /// Jedes Paket enthält die letzten 5 Eingaben: Geht eines verloren, bringt das nächste sie mit.
    /// Danach wird 3× im Abstand von 25 ms nachgesendet, damit auch die letzte Eingabe sicher ankommt.
    private func sendFast(_ input: FastInput) {
        fastSeq &+= 1
        fastRecent.append(FastInputEntry(seq: fastSeq, input: input))
        if fastRecent.count > 5 { fastRecent.removeFirst(fastRecent.count - 5) }
        transmitFast(fastRecent)

        fastResendsLeft = 3
        guard fastResendTimer == nil else { return }
        fastResendTimer = Timer.scheduledTimer(withTimeInterval: 0.025, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.fastResendsLeft > 0 else {
                    timer.invalidate()
                    self?.fastResendTimer = nil
                    return
                }
                self.fastResendsLeft -= 1
                self.transmitFast(self.fastRecent)
            }
        }
    }

    // MARK: - Sperrbildschirm

    /// Befehl von der Live Activity. Die App läuft dann meist im Hintergrund und ihre
    /// Verbindung ist eingeschlafen oder abgerissen: erst prüfen (WebSocket-Ping), sonst
    /// direkt zum zuletzt genutzten Mac neu verbinden (ohne auf die Bonjour-Suche zu warten).
    func sendInBackground(_ command: RemoteCommand) async {
        await sendInBackground(.command(command))
    }

    func sendInBackground(_ message: ClientMessage) async {
        if !(await isAlive()) {
            guard await reconnectToLastMac() else { return }
        }
        await withCheckedContinuation { continuation in
            sendMessage(message) { continuation.resume() }
        }
    }

    private func reconnectToLastMac() async -> Bool {
        if phase != .connecting {
            guard let name = currentMac ?? UserDefaults.standard.string(forKey: lastMacKey),
                  TokenStore.token(for: name) != nil else { return false } // Kopplung geht nur in der App
            let endpoint = macs.first(where: { $0.name == name })?.endpoint
                ?? .service(name: name, type: RemoteProtocol.bonjourType, domain: "local.", interface: nil)
            connect(to: DiscoveredMac(name: name, endpoint: endpoint))
        }
        // Bis zu 5 s auf `welcome` warten.
        for _ in 0..<100 where phase == .connecting {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return isConnected
    }

    /// Antwortet der Mac innerhalb einer Sekunde auf einen WebSocket-Ping?
    private func isAlive() async -> Bool {
        guard isConnected, let connection else { return false }
        final class Once { var done = false }
        let once = Once()
        return await withCheckedContinuation { continuation in
            let finish: (Bool) -> Void = { alive in
                guard !once.done else { return }
                once.done = true
                continuation.resume(returning: alive)
            }
            let metadata = NWProtocolWebSocket.Metadata(opcode: .ping)
            metadata.setPongHandler(.main) { error in
                MainActor.assumeIsolated { finish(error == nil) }
            }
            let context = NWConnection.ContentContext(identifier: "ping", metadata: [metadata])
            connection.send(content: Data(), contentContext: context, isComplete: true,
                            completion: .contentProcessed { error in
                                guard error != nil else { return }
                                MainActor.assumeIsolated { finish(false) }
                            })
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                MainActor.assumeIsolated { finish(false) }
            }
        }
    }

    // MARK: - Startseite

    func openApp(_ app: HomeApp) {
        guard isConnected else { return }
        sendMessage(.openApp(id: app.id))
    }

    /// Öffnet die Suchseite der App am Fernseher.
    func search(appID: UUID, query: String) {
        guard isConnected, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        sendMessage(.search(appID: appID, query: query))
    }

    // MARK: - Fernseher

    func toggleTV() {
        guard isConnected else { return }
        showTVNotice("Fernseher …")
        sendMessage(.tvPower)
    }

    private func showTVNotice(_ text: String) {
        tvNotice = text
        tvNoticeTask?.cancel()
        tvNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.tvNotice = nil
        }
    }

    // MARK: - Tastatur

    func showKeyboard() {
        keyboardRequest = KeyboardRequest(appID: nil, preferSearch: false)
    }

    /// Live-Tippen: schickt nur den Unterschied zwischen altem und neuem Text
    /// (Löschen bis zum gemeinsamen Anfang, dann die neuen Zeichen). So funktionieren
    /// auch Autokorrektur und Diktat.
    func sendTextChange(from old: String, to new: String) {
        guard isConnected, old != new else { return }
        let oldCharacters = Array(old)
        let newCharacters = Array(new)
        var common = 0
        while common < oldCharacters.count, common < newCharacters.count,
              oldCharacters[common] == newCharacters[common] {
            common += 1
        }
        for _ in 0..<(oldCharacters.count - common) {
            sendMessage(.command(.key(.deleteBackward)))
        }
        let insertion = String(newCharacters[common...])
        if !insertion.isEmpty {
            sendMessage(.command(.text(insertion)))
        }
    }

    /// Neue App-Liste an den Mac schicken. Lokal sofort übernehmen, der Mac bestätigt mit `.apps`.
    func setApps(_ newApps: [HomeApp]) {
        guard isConnected else { return }
        apps = newApps
        sendMessage(.setApps(newApps))
    }

    /// Tasten und Klicks: sofort senden.
    func send(_ command: RemoteCommand) {
        guard isConnected else { return }
        // Klicks über UDP, damit sie in der richtigen Reihenfolge zu den Bewegungen ankommen.
        if fastActive, case let .click(button) = command {
            sendFast(.click(button))
            return
        }
        sendMessage(.command(command))
    }

    /// Trackpad-Bewegung: sofort senden, außer die vorige ist noch unterwegs.
    func queueMove(dx: Double, dy: Double) {
        guard isConnected else { return }
        if fastActive {
            sendFast(.move(dx: Float(dx), dy: Float(dy)))
            return
        }
        pendingMove.dx += dx
        pendingMove.dy += dy
        flushPending()
    }

    func queueScroll(dx: Double, dy: Double) {
        guard isConnected else { return }
        if fastActive {
            sendFast(.scroll(dx: Float(dx), dy: Float(dy)))
            return
        }
        pendingScroll.dx += dx
        pendingScroll.dy += dy
        flushPending()
    }

    private func flushPending() {
        // Rückstau vermeiden: höchstens eine Bewegung gleichzeitig unterwegs.
        guard !moveInFlight else { return }

        var commands: [RemoteCommand] = []
        if pendingMove.dx != 0 || pendingMove.dy != 0 {
            commands.append(.mouseMove(dx: pendingMove.dx, dy: pendingMove.dy))
            pendingMove = (0, 0)
        }
        if pendingScroll.dx != 0 || pendingScroll.dy != 0 {
            commands.append(.scroll(dx: pendingScroll.dx, dy: pendingScroll.dy))
            pendingScroll = (0, 0)
        }
        guard !commands.isEmpty else { return }

        moveInFlight = true
        for (index, command) in commands.enumerated() {
            let isLast = index == commands.count - 1
            sendMessage(.command(command)) { [weak self] in
                guard isLast, let self else { return }
                self.moveInFlight = false
                self.flushPending() // inzwischen Gesammeltes direkt hinterherschicken
            }
        }
    }

    private func sendMessage(_ message: ClientMessage, completion: (() -> Void)? = nil) {
        guard let connection, let data = try? RemoteProtocol.encode(message) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "message", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true,
                        completion: .contentProcessed { _ in
                            MainActor.assumeIsolated { completion?() }
                        })
    }
}

