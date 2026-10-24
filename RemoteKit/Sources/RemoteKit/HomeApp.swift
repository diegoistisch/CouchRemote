import Foundation

/// Eine Kachel auf der Startseite: eine Webseite, die im Standardbrowser des Macs geöffnet wird.
public struct HomeApp: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var url: URL
    /// Kachelfarbe als Hex, z. B. "#F47521".
    public var colorHex: String
    /// Eigenes Logo (PNG/JPEG, vom iPhone gewählt). Ohne Logo wird das Icon der Seite geladen.
    public var logo: Data?

    public init(id: UUID = UUID(), name: String, url: URL, colorHex: String, logo: Data? = nil) {
        self.id = id
        self.name = name
        self.url = url
        self.colorHex = colorHex
        self.logo = logo
    }

    /// Nur http(s) ist erlaubt, damit das iPhone keine beliebigen Programme oder Dateien öffnen kann.
    public var isValid: Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host?.isEmpty == false else { return false }
        guard (logo?.count ?? 0) <= Self.maxLogoBytes else { return false }
        return !name.trimmingCharacters(in: .whitespaces).isEmpty && name.count <= 40
    }

    public static let maxCount = 30
    public static let maxLogoBytes = 600_000

    public static let defaults: [HomeApp] = [
        HomeApp(name: "Netflix", url: URL(string: "https://www.netflix.com/browse")!, colorHex: "#141414"),
        HomeApp(name: "Crunchyroll", url: URL(string: "https://www.crunchyroll.com")!, colorHex: "#F47521"),
        HomeApp(name: "YouTube", url: URL(string: "https://www.youtube.com")!, colorHex: "#F2F2F2")
    ]

    /// Farbauswahl für den Editor am iPhone.
    public static let palette: [String] = [
        "#141414", "#F2F2F2", "#E50914", "#F47521", "#FF0033",
        "#F5C518", "#1DB954", "#00A8E1", "#113CCF", "#6E3BFF",
        "#9146FF", "#5F6368"
    ]
}

/// Hex-String → RGB-Werte 0…1 (plattformunabhängig, für SwiftUI-`Color` auf beiden Seiten).
public enum HexColor {
    public static func rgb(_ hex: String) -> (red: Double, green: Double, blue: Double) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else { return (0.35, 0.35, 0.4) }
        return (
            Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255
        )
    }

    /// Helle Kachel (z. B. YouTube-Weiß)? Dann dunkle Schrift.
    public static func isLight(_ hex: String) -> Bool {
        let c = rgb(hex)
        return 0.299 * c.red + 0.587 * c.green + 0.114 * c.blue > 0.65
    }
}
