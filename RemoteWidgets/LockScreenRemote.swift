import RemoteKit

/// Gegenstück zu `RemoteApp/LockScreenRemote.swift`. `RemoteKeyIntent` läuft als
/// `LiveActivityIntent` immer im App-Prozess, in der Widget-Erweiterung passiert nichts.
enum LockScreenRemote {
    static func press(_ key: RemoteKey) async {}
    static func toggleTV() async {}
}
