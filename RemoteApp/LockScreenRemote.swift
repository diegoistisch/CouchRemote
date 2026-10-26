import ActivityKit
import Foundation
import RemoteKit

/// Fernbedienung als Live Activity auf dem Sperrbildschirm und in der Dynamic Island.
///
/// Die Live Activity startet, sobald die App mit einem Mac verbunden ist (nur im Vordergrund
/// möglich). Ihre Knöpfe lösen `RemoteKeyIntent` aus; iOS führt den im App-Prozess aus und
/// landet hier in `press(_:)`.
@MainActor
enum LockScreenRemote {
    nonisolated static let enabledKey = "lockScreenRemoteEnabled"

    /// Einstellung im TV-Menü, standardmäßig an.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Live Activity starten oder auf den aktuellen Mac aktualisieren.
    static func start(macName: String) {
        guard isEnabled, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = RemoteActivityAttributes.ContentState(macName: macName)
        let running = Activity<RemoteActivityAttributes>.activities
            .filter { $0.activityState == .active || $0.activityState == .stale }

        if let activity = running.first {
            if activity.content.state != state {
                Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
            }
            return
        }
        // iOS beendet Live Activities nach spätestens 8 Stunden; beim nächsten Öffnen
        // der App startet hier eine neue.
        _ = try? Activity.request(attributes: RemoteActivityAttributes(),
                                  content: ActivityContent(state: state, staleDate: nil),
                                  pushType: nil)
    }

    static func stop() {
        for activity in Activity<RemoteActivityAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// Taste von der Live Activity: an den Mac schicken, vorher bei Bedarf neu verbinden.
    static func press(_ key: RemoteKey) async {
        await RemoteClient.shared.sendInBackground(.key(key))
    }
}
