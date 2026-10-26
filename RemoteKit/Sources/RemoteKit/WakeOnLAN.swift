import Foundation

/// Wake-on-LAN: „Magic Packet“ (6 × 0xFF, dann 16 × die MAC-Adresse), schaltet den Fernseher
/// aus dem Standby ein (beim Sony: Einstellung „Remote Start“).
public enum WakeOnLAN {
    /// Liest eine MAC-Adresse wie `ac:9b:0a:12:3d:4f` oder `ac-9b-a-12-3d-4f`
    /// (macOS-`arp` lässt führende Nullen weg).
    public static func parseMAC(_ text: String) -> [UInt8]? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0 == ":" || $0 == "-" })
        guard parts.count == 6 else { return nil }
        var bytes: [UInt8] = []
        for part in parts {
            guard (1...2).contains(part.count), let byte = UInt8(part, radix: 16) else { return nil }
            bytes.append(byte)
        }
        return bytes
    }

    /// Formatiert eine MAC-Adresse als `AC:9B:0A:12:3D:4F`.
    public static func format(_ mac: [UInt8]) -> String {
        mac.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    /// MAC-Adresse aus der Ausgabe von `arp -n <IP>`, z. B. `? (192.168.1.40) at ac:9b:a:12:3d:4f on en0`.
    public static func macFromArp(_ output: String) -> [UInt8]? {
        guard let range = output.range(of: " at ") else { return nil }
        let rest = output[range.upperBound...]
        let token = rest.prefix { !$0.isWhitespace }
        return parseMAC(String(token))
    }

    public static func magicPacket(mac: [UInt8]) -> Data {
        var packet = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet.append(contentsOf: mac) }
        return packet
    }
}
