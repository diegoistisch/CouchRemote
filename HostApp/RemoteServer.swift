import AppKit
import CryptoKit
import Foundation
import Network
import RemoteKit

/// WebSocket-Server, der sich per Bonjour im Heimnetz anmeldet.
///
/// Threading:
/// - Verbindungen laufen auf `networkQueue` (höchste Priorität). Eingabebefehle gekoppelter
///   iPhones werden direkt dort ausgeführt, ohne Umweg über den Main-Thread. So können
///   Oberfläche, Animationen oder App Nap die Mausbewegungen nicht ausbremsen.
/// - Kopplung, Geräteliste und Startseite laufen auf dem Main-Thread.
@MainActor
final class RemoteServer: ObservableObject {
    struct PairingRequest: Identifiable {
        let id: ObjectIdentifier
        let deviceName: String
        let code: String
    }

    @Published private(set) var status = "Gestoppt"
    @Published private(set) var connectedNames: [String] = []
    @Published private(set) var pairingRequests: [PairingRequest] = []
    @Published private(set) var pairedDevices: [PairingStore.Device] = []
    /// Wie gleichmäßig Trackpad-Pakete ankommen (letzte Messung), z. B. „Ø 8 ms · max 30 ms“.
    @Published private(set) var trackpadTiming: String?
    @Published private(set) var trackpadTimingDate: Date?

    private enum Phase {
        case awaitingHello
        case awaitingCode(code: String, attemptsLeft: Int)
        case authenticated(deviceID: UUID)
    }

    private final class Client {
        let connection: NWConnection
        var phase: Phase = .awaitingHello
        var name = "iPhone"
        var timeout: DispatchWorkItem?
        /// Sitzung des schnellen UDP-Kanals (siehe `FastChannel`).
        var fastSession: UInt64?

        init(_ connection: NWConnection) { self.connection = connection }

        var isAuthenticated: Bool {
            if case .authenticated = phase { return true }
            return false
        }
    }

    private static let maxAttempts = 5
    /// Nicht gekoppelte Verbindungen werden nach dieser Zeit getrennt.
    private static let unauthenticatedTimeout: TimeInterval = 120

    let home: HomeController
    let tv: TVController
    private let pairings = PairingStore()
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: Client] = [:] // nur Main-Thread

    // Von der Netzwerk-Queue genutzt:
    private let networkQueue: DispatchQueue
    /// „Opening überspringen“ suchen und drücken (siehe `SkipButtonPresser`).
    private let skipQueue = DispatchQueue(label: "at.diego.couchremote.skip", qos: .userInitiated)
    private let injector: InputInjector
    /// Zeigerbewegungen gleichmäßig abspielen (gegen WLAN-Ruckeln).
    private let smoother: PointerSmoother
    private let packetTiming = Locked(PacketTiming())
    private var timingTimer: Timer?
    /// Verbindungen, die Eingabebefehle schicken dürfen.
    private let authorized = Locked(Set<ObjectIdentifier>())

    // Schneller UDP-Kanal fürs Trackpad
    private struct FastSession {
        let key: SymmetricKey
        var lastSeq: UInt32
        let connectionID: ObjectIdentifier
        var confirmed: Bool
    }
    private var udpListener: NWListener?
    private let udpPort = Locked<UInt16?>(nil)
    private let fastSessions = Locked([UInt64: FastSession]())

    init(home: HomeController, tv: TVController) {
        let queue = DispatchQueue(label: "at.diego.couchremote.network", qos: .userInteractive)
        let injector = InputInjector()
        networkQueue = queue
        self.injector = injector
        smoother = PointerSmoother(queue: queue) { dx, dy in
            injector.perform(.mouseMove(dx: dx, dy: dy))
        }
        self.home = home
        self.tv = tv
        pairedDevices = pairings.devices
        home.onAppsChanged = { [weak self] apps in
            self?.broadcast(.apps(apps))
        }
        home.onKeyboardRequest = { [weak self] appID in
            self?.broadcast(.showKeyboard(appID: appID))
        }
    }

    /// TCP ohne Nagle-Algorithmus: kleine Nachrichten (Mausbewegungen) gehen sofort raus,
    /// statt bis zu ~200 ms gesammelt zu werden.
    nonisolated static func makeParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        // Keepalive: tote Verbindungen (iPhone weg, App beendet) nach ~11 s erkennen.
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
        return parameters
    }

    // MARK: - Start

    func start() {
        guard listener == nil else { return }
        do {
            let listener = try NWListener(using: Self.makeParameters())
            // name: nil → der Computername wird als Bonjour-Name verwendet.
            listener.service = NWListener.Service(name: nil, type: RemoteProtocol.bonjourType)
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated { self?.handle(listenerState: state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            listener.start(queue: .main)
            self.listener = listener
            status = "Starte …"
        } catch {
            status = "Fehler beim Start: \(error.localizedDescription)"
        }
        startFastChannel()

        // Messwerte einmal pro Sekunde ins Fenster übernehmen
        timingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let summary = self.packetTiming.mutate({ $0.takeSummary() }) else { return }
                self.trackpadTiming = summary
                self.trackpadTimingDate = Date()
            }
        }
    }

    /// Läuft auf der Netzwerk-Queue. Bewegungen gehen durch die Glättung; Klicks und Scrollen
    /// erst nach dem Rest der Bewegung, damit sie an der richtigen Stelle landen.
    nonisolated private func inject(_ command: RemoteCommand) {
        switch command {
        case let .mouseMove(dx, dy):
            packetTiming.mutate { $0.record(at: ProcessInfo.processInfo.systemUptime) }
            smoother.add(dx: dx, dy: dy)
        case .click, .scroll:
            smoother.flush()
            injector.perform(command)
        default:
            injector.perform(command)
        }
    }

    // MARK: - Schneller UDP-Kanal

    private func startFastChannel() {
        guard udpListener == nil else { return }
        let parameters = NWParameters.udp
        parameters.serviceClass = .interactiveVoice
        guard let listener = try? NWListener(using: parameters) else { return }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            if case .ready = state, let port = listener?.port {
                self?.udpPort.set(port.rawValue)
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.acceptFast(connection)
        }
        listener.start(queue: networkQueue)
        udpListener = listener
    }

    /// Läuft auf der Netzwerk-Queue.
    nonisolated private func acceptFast(_ connection: NWConnection) {
        connection.start(queue: networkQueue)
        receiveFast(on: connection)
    }

    nonisolated private func receiveFast(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data { self.handleFastPacket(data) }
            if error == nil {
                self.receiveFast(on: connection)
            } else {
                connection.cancel()
            }
        }
    }

    /// Läuft auf der Netzwerk-Queue: Signatur prüfen, nur neue Einträge (Sequenznummer) ausführen.
    nonisolated private func handleFastPacket(_ data: Data) {
        let sessions = fastSessions.get()
        guard let (sessionID, entries) = FastChannel.decode(data, keyFor: { sessions[$0]?.key }) else { return }

        var fresh: [FastInputEntry] = []
        var confirmConnection: ObjectIdentifier?
        fastSessions.mutate { sessions in
            guard var session = sessions[sessionID] else { return }
            if !session.confirmed {
                session.confirmed = true
                confirmConnection = session.connectionID
            }
            fresh = entries.filter { $0.seq > session.lastSeq }.sorted { $0.seq < $1.seq }
            if let last = fresh.last { session.lastSeq = last.seq }
            sessions[sessionID] = session
        }

        // Ein Paket kann mehrere neue Bewegungen enthalten (nach einem Verlust) → zusammenfassen,
        // damit die Messung pro Paket zählt und nicht pro Eintrag.
        var moveX = 0.0, moveY = 0.0
        for entry in fresh {
            switch entry.input {
            case let .move(dx, dy):
                moveX += Double(dx)
                moveY += Double(dy)
            case let .scroll(dx, dy):
                if moveX != 0 || moveY != 0 { inject(.mouseMove(dx: moveX, dy: moveY)); moveX = 0; moveY = 0 }
                inject(.scroll(dx: Double(dx), dy: Double(dy)))
            case let .click(button):
                if moveX != 0 || moveY != 0 { inject(.mouseMove(dx: moveX, dy: moveY)); moveX = 0; moveY = 0 }
                inject(.click(button))
            }
        }
        if moveX != 0 || moveY != 0 { inject(.mouseMove(dx: moveX, dy: moveY)) }

        if let confirmConnection {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.confirmFast(confirmConnection) }
            }
        }
    }

    /// Nach dem Anmelden: Schlüssel für den UDP-Kanal erzeugen und über die WebSocket-Verbindung schicken.
    private func setUpFastChannel(for client: Client, id: ObjectIdentifier) {
        guard let port = udpPort.get() else { return }
        let sessionID = UInt64.random(in: 1...(1 << 53))
        let key = FastChannel.makeKey()
        fastSessions.mutate {
            $0[sessionID] = FastSession(key: key, lastSeq: 0, connectionID: id, confirmed: false)
        }
        client.fastSession = sessionID
        let keyData = key.withUnsafeBytes { Data($0) }
        send(.fastChannel(port: port, session: sessionID, key: keyData), to: client)
    }

    private func confirmFast(_ id: ObjectIdentifier) {
        guard let client = clients[id] else { return }
        send(.fastChannelConfirmed, to: client)
    }

    private func handle(listenerState state: NWListener.State) {
        switch state {
        case .ready:
            let name = Host.current().localizedName ?? "Mac"
            let port = listener?.port.map { " (Port \($0.rawValue))" } ?? ""
            status = "Bereit, sichtbar als „\(name)“\(port)"
        case .waiting(let error):
            status = "Warte auf Netzwerk: \(error.localizedDescription)"
        case .failed(let error):
            status = "Fehler: \(error.localizedDescription)"
            listener?.cancel()
            listener = nil
        case .cancelled:
            status = "Gestoppt"
        default:
            break
        }
    }

    // MARK: - Verbindungen

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        let client = Client(connection)
        clients[id] = client

        let timeout = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let client = self.clients[id], !client.isAuthenticated else { return }
                self.drop(id)
            }
        }
        client.timeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.unauthenticatedTimeout, execute: timeout)

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.drop(id) } }
            default:
                break
            }
        }
        connection.start(queue: networkQueue)
        receive(on: connection, id: id)
    }

    /// Läuft auf der Netzwerk-Queue.
    nonisolated private func receive(on connection: NWConnection, id: ObjectIdentifier) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata
            if metadata?.opcode == .close || error != nil {
                connection.cancel() // → stateUpdateHandler räumt auf
                return
            }
            if let data, !data.isEmpty,
               let message = try? RemoteProtocol.decode(ClientMessage.self, from: data) {
                self.route(message, from: id)
            }
            self.receive(on: connection, id: id)
        }
    }

    /// Läuft auf der Netzwerk-Queue. Eingaben direkt ausführen, alles andere an den Main-Thread.
    nonisolated private func route(_ message: ClientMessage, from id: ObjectIdentifier) {
        guard case let .command(command) = message else {
            DispatchQueue.main.async { MainActor.assumeIsolated { self.handle(message, from: id) } }
            return
        }
        guard authorized.get().contains(id) else { return }

        if case let .key(key) = command {
            if key == .home {
                // Home öffnet die Startseite bzw. schließt sie wieder.
                DispatchQueue.main.async { MainActor.assumeIsolated { self.home.toggle() } }
                return
            }
            if key == .skip {
                // Eigene Queue: Die Suche im Bedienungshilfen-Baum kann kurz dauern.
                skipQueue.async {
                    let result = SkipButtonPresser.press()
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            if let client = self.clients[id] { self.send(.notice(result), to: client) }
                        }
                    }
                }
                return
            }
            if home.visibility.get(), HomeController.handles(key) {
                DispatchQueue.main.async { MainActor.assumeIsolated { self.home.handle(key) } }
                return
            }
        }
        inject(command)
    }

    /// Main-Thread: Kopplung und Startseite.
    private func handle(_ message: ClientMessage, from id: ObjectIdentifier) {
        guard let client = clients[id] else { return }

        switch (message, client.phase) {
        case let (.hello(deviceName, token), .awaitingHello):
            client.name = String(deviceName.prefix(60))
            if let token, let device = pairings.device(forToken: token) {
                authenticate(client, id: id, deviceID: device.id)
                send(.welcome, to: client)
                send(.apps(home.apps), to: client)
                setUpFastChannel(for: client, id: id)
            } else {
                let code = String(format: "%04d", Int.random(in: 0...9999))
                client.phase = .awaitingCode(code: code, attemptsLeft: Self.maxAttempts)
                refreshLists()
                send(.pairingRequired, to: client)
                NSApp.activate() // Fenster mit dem Code nach vorne holen
            }

        case let (.pair(code), .awaitingCode(expected, attemptsLeft)):
            if code == expected {
                let (device, token) = pairings.add(name: client.name)
                pairedDevices = pairings.devices
                authenticate(client, id: id, deviceID: device.id)
                send(.paired(token: token), to: client)
                send(.apps(home.apps), to: client)
                setUpFastChannel(for: client, id: id)
            } else if attemptsLeft > 1 {
                client.phase = .awaitingCode(code: expected, attemptsLeft: attemptsLeft - 1)
                send(.pairingFailed(attemptsLeft: attemptsLeft - 1), to: client)
            } else {
                send(.pairingFailed(attemptsLeft: 0), to: client)
                drop(id)
            }

        case let (.openApp(appID), .authenticated):
            if let app = home.apps.first(where: { $0.id == appID }) {
                home.open(app)
            }

        case let (.setApps(apps), .authenticated):
            home.setApps(apps) // → onAppsChanged → broadcast an alle iPhones

        case let (.search(appID, query), .authenticated):
            home.search(appID: appID, query: String(query.prefix(200)))

        case (.tvPower, .authenticated):
            Task {
                let result = await tv.togglePower()
                if let client = clients[id] { send(.notice(result), to: client) }
            }

        default:
            break // Nachricht passt nicht zum Zustand (z. B. vor der Kopplung) → ignorieren
        }
    }

    private func authenticate(_ client: Client, id: ObjectIdentifier, deviceID: UUID) {
        client.phase = .authenticated(deviceID: deviceID)
        client.timeout?.cancel()
        client.timeout = nil
        authorized.mutate { $0.insert(id) }
        refreshLists()
    }

    private func send(_ message: ServerMessage, to client: Client) {
        guard let data = try? RemoteProtocol.encode(message) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "message", metadata: [metadata])
        client.connection.send(content: data, contentContext: context, isComplete: true,
                               completion: .contentProcessed { _ in })
    }

    private func broadcast(_ message: ServerMessage) {
        for client in clients.values where client.isAuthenticated {
            send(message, to: client)
        }
    }

    private func drop(_ id: ObjectIdentifier) {
        authorized.mutate { $0.remove(id) }
        guard let client = clients.removeValue(forKey: id) else { return }
        if let session = client.fastSession {
            fastSessions.mutate { $0[session] = nil }
        }
        client.timeout?.cancel()
        client.connection.cancel()
        refreshLists()
    }

    private func refreshLists() {
        pairingRequests = clients.compactMap { id, client in
            guard case let .awaitingCode(code, _) = client.phase else { return nil }
            return PairingRequest(id: id, deviceName: client.name, code: code)
        }
        connectedNames = clients.values.filter(\.isAuthenticated).map(\.name).sorted()
    }

    // MARK: - Geräte verwalten

    /// Entfernt die Kopplung und trennt das Gerät sofort.
    func forget(_ device: PairingStore.Device) {
        pairings.remove(device.id)
        pairedDevices = pairings.devices
        for (id, client) in Array(clients) {
            if case let .authenticated(deviceID) = client.phase, deviceID == device.id {
                drop(id)
            }
        }
    }
}
