import ActivityKit
import AppIntents
import RemoteKit

/// Live Activity „Fernbedienung auf dem Sperrbildschirm“.
/// Liegt in App und Widget-Erweiterung, damit beide denselben Typ kennen.
struct RemoteActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Name des Macs, mit dem die Fernbedienung zuletzt verbunden war.
        var macName: String
    }
}

/// Taste der Live Activity. Als `LiveActivityIntent` läuft `perform()` im Prozess der App
/// (iOS weckt sie dafür im Hintergrund), auch wenn das iPhone gesperrt ist.
struct RemoteKeyIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Fernbedienungstaste"
    static var isDiscoverable = false

    @Parameter(title: "Taste")
    var key: String

    init() {}

    init(_ key: RemoteKey) {
        self.key = key.rawValue
    }

    func perform() async throws -> some IntentResult {
        if let key = RemoteKey(rawValue: key) {
            await LockScreenRemote.press(key)
        }
        return .result()
    }
}
