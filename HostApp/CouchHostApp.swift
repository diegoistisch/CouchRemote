import SwiftUI

@main
struct CouchHostApp: App {
    @StateObject private var home: HomeController
    @StateObject private var server: RemoteServer
    @StateObject private var tv: TVController
    @AppStorage("showHomeOnLaunch") private var showHomeOnLaunch = false

    /// Verhindert App Nap: Ohne das drosselt macOS CouchHost, sobald Safari vorne ist,
    /// und Mausbefehle bleiben kurz hängen.
    private static var latencyActivity: NSObjectProtocol?

    init() {
        let home = HomeController()
        let tv = TVController()
        _home = StateObject(wrappedValue: home)
        _tv = StateObject(wrappedValue: tv)
        _server = StateObject(wrappedValue: RemoteServer(home: home, tv: tv))

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
                .environmentObject(tv)
                .onAppear {
                    server.start()
                    if showHomeOnLaunch { home.show() }
                }
        }
        .windowResizability(.contentSize)
    }
}
