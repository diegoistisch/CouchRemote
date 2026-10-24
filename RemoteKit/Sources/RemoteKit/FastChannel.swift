import CryptoKit
import Foundation

/// Zeitkritische Trackpad-Eingaben, die über den schnellen UDP-Kanal gehen.
public enum FastInput: Equatable, Sendable {
    case move(dx: Float, dy: Float)
    case scroll(dx: Float, dy: Float)
    case click(MouseButton)
}

public struct FastInputEntry: Equatable, Sendable {
    public let seq: UInt32
    public let input: FastInput

    public init(seq: UInt32, input: FastInput) {
        self.seq = seq
        self.input = input
    }
}

/// Schneller Eingabekanal über UDP.
///
/// Warum: Über TCP (WebSocket) hält ein einziges im WLAN verlorenes Paket alle folgenden
/// Mausbewegungen zurück, bis es neu gesendet wurde (oft 100–200 ms) – der Zeiger „hängt“
/// und springt dann. Über UDP geht ein verlorenes Paket einfach unter; weil jedes Paket die
/// letzten Eingaben noch einmal enthält, wird es vom nächsten ersetzt.
///
/// Sicherheit: Jedes Paket trägt eine HMAC-SHA256-Signatur (16 Byte) mit einem Schlüssel,
/// den nur gekoppelte iPhones über die angemeldete WebSocket-Verbindung bekommen.
/// Sequenznummern verhindern doppelte oder wiederholte Eingaben.
///
/// Paketaufbau (Little Endian):
/// `"CR"` · Version (1) · Sitzung (8) · Anzahl (1) · Einträge (je 13: seq u32, Art u8, a f32, b f32) · HMAC (16)
public enum FastChannel {
    public static let maxEntries = 6
    private static let magic: [UInt8] = [0x43, 0x52] // "CR"
    private static let version: UInt8 = 1
    private static let macLength = 16
    private static let entryLength = 13
    private static let headerLength = 2 + 1 + 8 + 1

    private enum Kind: UInt8 {
        case move = 0, scroll = 1, leftClick = 2, rightClick = 3
    }

    public static func makeKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    public static func encode(session: UInt64, entries: [FastInputEntry], key: SymmetricKey) -> Data {
        var body = Data(magic)
        body.append(version)
        appendLE(session, to: &body)
        let entries = entries.suffix(maxEntries)
        body.append(UInt8(entries.count))
        for entry in entries {
            appendLE(entry.seq, to: &body)
            let (kind, a, b): (Kind, Float, Float)
            switch entry.input {
            case let .move(dx, dy): (kind, a, b) = (.move, dx, dy)
            case let .scroll(dx, dy): (kind, a, b) = (.scroll, dx, dy)
            case .click(.left): (kind, a, b) = (.leftClick, 0, 0)
            case .click(.right): (kind, a, b) = (.rightClick, 0, 0)
            }
            body.append(kind.rawValue)
            appendLE(a.bitPattern, to: &body)
            appendLE(b.bitPattern, to: &body)
        }
        let mac = HMAC<SHA256>.authenticationCode(for: body, using: key)
        body.append(contentsOf: Data(mac).prefix(macLength))
        return body
    }

    /// Prüft Signatur und Aufbau. `keyFor` liefert den Schlüssel einer Sitzung (oder nil, wenn unbekannt).
    public static func decode(_ data: Data, keyFor: (UInt64) -> SymmetricKey?) -> (session: UInt64, entries: [FastInputEntry])? {
        let bytes = [UInt8](data)
        guard bytes.count >= headerLength + macLength,
              Array(bytes[0..<2]) == magic, bytes[2] == version else { return nil }

        let session: UInt64 = readLE(bytes, at: 3)
        let count = Int(bytes[11])
        guard count <= maxEntries,
              bytes.count == headerLength + count * entryLength + macLength,
              let key = keyFor(session) else { return nil }

        let bodyEnd = bytes.count - macLength
        let expected = [UInt8](Data(HMAC<SHA256>.authenticationCode(for: bytes[0..<bodyEnd], using: key)).prefix(macLength))
        guard constantTimeEqual(expected, Array(bytes[bodyEnd...])) else { return nil }

        var entries: [FastInputEntry] = []
        var offset = headerLength
        for _ in 0..<count {
            let seq: UInt32 = readLE(bytes, at: offset)
            let rawKind = bytes[offset + 4]
            let a = Float(bitPattern: readLE(bytes, at: offset + 5))
            let b = Float(bitPattern: readLE(bytes, at: offset + 9))
            offset += entryLength
            guard a.isFinite, b.isFinite, let kind = Kind(rawValue: rawKind) else { return nil }
            let input: FastInput
            switch kind {
            case .move: input = .move(dx: a, dy: b)
            case .scroll: input = .scroll(dx: a, dy: b)
            case .leftClick: input = .click(.left)
            case .rightClick: input = .click(.right)
            }
            entries.append(FastInputEntry(seq: seq, input: input))
        }
        return (session, entries)
    }

    // MARK: - Bytes

    private static func appendLE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func readLE<T: FixedWidthInteger>(_ bytes: [UInt8], at offset: Int) -> T {
        var value: T = 0
        for index in 0..<MemoryLayout<T>.size {
            value |= T(bytes[offset + index]) << (8 * index)
        }
        return value
    }

    private static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }
}
