import CryptoKit
import Foundation

/// Merkt sich gekoppelte iPhones. Gespeichert wird nur ein SHA-256-Hash des Tokens,
/// das Token selbst liegt ausschließlich im Schlüsselbund des iPhones.
@MainActor
final class PairingStore {
    struct Device: Codable, Identifiable, Hashable {
        let id: UUID
        let name: String
        let tokenHash: String
        let pairedAt: Date
    }

    private(set) var devices: [Device] = []
    private let defaultsKey = "pairedDevices"

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([Device].self, from: data) {
            devices = decoded
        }
    }

    func device(forToken token: String) -> Device? {
        let hash = Self.hash(token)
        return devices.first { $0.tokenHash == hash }
    }

    /// Legt ein neues Gerät an und gibt das (nur jetzt sichtbare) Token zurück.
    func add(name: String) -> (device: Device, token: String) {
        var generator = SystemRandomNumberGenerator() // kryptografisch sicher auf Apple-Plattformen
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        let token = Data(bytes).base64EncodedString()

        let device = Device(id: UUID(), name: name, tokenHash: Self.hash(token), pairedAt: Date())
        devices.append(device)
        save()
        return (device, token)
    }

    func remove(_ id: UUID) {
        devices.removeAll { $0.id == id }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(devices) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    private static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
