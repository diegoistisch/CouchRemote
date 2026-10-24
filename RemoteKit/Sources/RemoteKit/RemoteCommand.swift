import Foundation

/// Ein Eingabebefehl, den das iPhone an den Mac schickt.
public enum RemoteCommand: Codable, Equatable, Sendable {
    /// Eine Taste der Fernbedienung (D-Pad, OK, Zurück, …).
    case key(RemoteKey)
    /// Relative Mausbewegung in Bildschirmpunkten (Trackpad-Modus).
    case mouseMove(dx: Double, dy: Double)
    /// Mausklick an der aktuellen Zeigerposition.
    case click(MouseButton)
    /// Scrollen in Pixeln. Positives `dy` scrollt nach oben.
    case scroll(dx: Double, dy: Double)
    /// Text an der aktuellen Cursorposition eintippen (beliebige Unicode-Zeichen).
    case text(String)
}

public enum RemoteKey: String, Codable, Sendable, CaseIterable {
    case up, down, left, right
    case select
    case back
    case home
    case playPause
    case volumeUp, volumeDown, mute
    /// Player: zurück- bzw. vorspulen (Pfeil links/rechts im Video).
    case seekBack, seekForward
    /// Player: Vollbild umschalten (Taste F bei Netflix, Crunchyroll, YouTube).
    case fullscreen
    /// Browser: vorherige Seite (⌘[).
    case browserBack
    /// Tastatur: Zeichen links vom Cursor löschen.
    case deleteBackward
}

public enum MouseButton: String, Codable, Sendable {
    case left, right
}

/// Nachrichten iPhone → Mac.
///
/// Ablauf: Nach dem Verbinden schickt das iPhone `hello`. Kennt der Mac das Token,
/// antwortet er `welcome`. Sonst zeigt er einen 4-stelligen Code und antwortet
/// `pairingRequired`; das iPhone schickt den Code mit `pair` und bekommt `paired(token)`.
/// Erst danach nimmt der Mac `command`-Nachrichten an.
public enum ClientMessage: Codable, Equatable, Sendable {
    case hello(deviceName: String, token: String?)
    case pair(code: String)
    case command(RemoteCommand)
    /// Startseite: eine App öffnen.
    case openApp(id: UUID)
    /// Startseite: komplette App-Liste ersetzen (hinzufügen, löschen, sortieren).
    case setApps([HomeApp])
    /// In einer App suchen (öffnet deren Suchseite mit dem Begriff).
    case search(appID: UUID, query: String)
}

/// Nachrichten Mac → iPhone.
public enum ServerMessage: Codable, Equatable, Sendable {
    case welcome
    case pairingRequired
    case pairingFailed(attemptsLeft: Int)
    case paired(token: String)
    /// Aktuelle App-Liste der Startseite (nach dem Anmelden und bei jeder Änderung).
    case apps([HomeApp])
    /// Am Fernseher wurde „Suchen“ gewählt: iPhone soll die Tastatur zeigen (optional für eine App).
    case showKeyboard(appID: UUID?)
    /// Zugangsdaten für den schnellen UDP-Kanal (siehe `FastChannel`). `session` < 2^53 (JSON-sicher).
    case fastChannel(port: UInt16, session: UInt64, key: Data)
    /// Das erste gültige UDP-Paket ist angekommen: ab jetzt Trackpad über UDP.
    case fastChannelConfirmed
}

public enum RemoteProtocol {
    /// Bonjour-Diensttyp, unter dem der Mac im Heimnetz sichtbar ist.
    /// Muss auch in `NSBonjourServices` beider Info.plists stehen.
    public static let bonjourType = "_couchremote._tcp"

    /// Länge des Kopplungscodes.
    public static let pairingCodeLength = 4

    /// Größte WebSocket-Nachricht (App-Liste mit Logos).
    public static let maximumMessageSize = 32 * 1024 * 1024

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
