import SwiftUI

@main
struct CouchRemoteApp: App {
    @StateObject private var client = RemoteClient.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RemoteView()
                .environmentObject(client)
                .onAppear { client.startBrowsing() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { client.reconnectIfNeeded() }
                }
        }
    }
}
