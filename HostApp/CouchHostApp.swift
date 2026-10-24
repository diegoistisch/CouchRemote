import SwiftUI

@main
struct CouchHostApp: App {
    @StateObject private var home: HomeController
    @StateObject private var server: RemoteServer
    @AppStorage("showHomeOnLaunch") private var showHomeOnLaunch = false

    /// Verhindert App Nap: Ohne das drosselt macOS CouchHost, sobald Safari vorne ist,
    /// und Mausbefehle bleiben kurz hängen.
    private static var latencyActivity: NSObjectProtocol?

    init() {
        let home = HomeController()
        _home = StateObject(wrappedValue: home)
        _server = StateObject(wrappedValue: RemoteServer(home: home))

        Self.latencyActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Fernbedienungsbefehle müssen sofort umgesetzt werden"
        )
    }

    var body: some Scene {
        WindowGroup("CouchHost") {
            HostStatusView()
                .environmentObject(server)
                .environmentObject(home)
                .onAppear {
                    server.start()
                    if showHomeOnLaunch { home.show() }
                }
        }
        .windowResizability(.contentSize)
    }
}
