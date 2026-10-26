import Combine
import RemoteKit
import SwiftUI
import UniformTypeIdentifiers

/// Statusfenster des Mac-Hosts: Verbindung, Kopplungscodes, gekoppelte Geräte, Berechtigung.
/// Die Vollbild-Startseite mit Kacheln kommt in Meilenstein 3.
struct HostStatusView: View {
    @EnvironmentObject private var server: RemoteServer
    @EnvironmentObject private var home: HomeController
    @EnvironmentObject private var tv: TVController
    @AppStorage("showHomeOnLaunch") private var showHomeOnLaunch = false
    @AppStorage(HomeController.wallpaperPathKey) private var wallpaperPath: String?
    @AppStorage(PointerSmoother.defaultsKey) private var smoothingMs = PointerSmoother.defaultMilliseconds
    @State private var tvPIN = ""
    @State private var tvMAC = ""
    @State private var isTrusted = InputInjector.hasAccessibility(prompt: false)

    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("CouchHost").font(.title2.bold())

            Label(server.status, systemImage: "antenna.radiowaves.left.and.right")
            Label(connectedText, systemImage: "iphone")

            ForEach(server.pairingRequests) { request in
                pairingCard(request)
            }

            Divider()
            trackpadSection
            Divider()
            homeSection
            Divider()
            tvSection
            Divider()
            pairedDevicesSection
            Divider()
            accessibilitySection
        }
        .padding(24)
        .frame(minWidth: 420, alignment: .leading)
        .onReceive(refresh) { _ in
            isTrusted = InputInjector.hasAccessibility(prompt: false)
        }
    }

    private var connectedText: String {
        switch server.connectedNames.count {
        case 0: "Kein iPhone verbunden"
        case 1: "Verbunden: \(server.connectedNames[0])"
        default: "\(server.connectedNames.count) iPhones verbunden"
        }
    }

    // MARK: - Teile

    private func pairingCard(_ request: RemoteServer.PairingRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("„\(request.deviceName)“ möchte sich koppeln")
                .font(.headline)
            Text(request.code)
                .font(.system(size: 64, weight: .bold, design: .monospaced))
                .kerning(16)
                .textSelection(.disabled)
            Text("Gib diesen Code auf dem iPhone ein.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.tint.opacity(0.15)))
    }

    private var trackpadSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Trackpad").font(.headline)
            Picker("Glättung", selection: $smoothingMs) {
                ForEach(PointerSmoother.options, id: \.milliseconds) { option in
                    Text(option.title).tag(option.milliseconds)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)
            Text("Glättet ungleichmäßig ankommende WLAN-Pakete. Stärker = ruhiger, aber etwas träger.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let timing = server.trackpadTiming {
                Label(timing, systemImage: "waveform.path.ecg")
                    .font(.callout.monospacedDigit())
                if let date = server.trackpadTimingDate {
                    Text("Paketabstände während der letzten Bewegung, gemessen \(date.formatted(date: .omitted, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Bewege das Trackpad am iPhone, um die Verbindung zu messen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var homeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Startseite").font(.headline)
            Text("\(home.apps.count) Apps · öffnet sich mit der Home-Taste am iPhone auf dem Bildschirm mit dem Mauszeiger.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button("Startseite zeigen") { home.show() }
                Toggle("Beim Start zeigen", isOn: $showHomeOnLaunch)
            }
            HStack {
                Button("Hintergrundbild wählen …") { chooseWallpaper() }
                if wallpaperPath != nil {
                    Button("Schreibtischbild verwenden") {
                        UserDefaults.standard.removeObject(forKey: HomeController.wallpaperPathKey)
                        wallpaperPath = nil
                    }
                }
            }
            Text(wallpaperPath.map { "Hintergrund: \(URL(fileURLWithPath: $0).lastPathComponent)" }
                 ?? "Hintergrund: aktuelles Schreibtischbild")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var tvSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Fernseher").font(.headline)
            Text("Ein/Aus übers Heimnetz (Sony Bravia). Am TV „Remote Start“ einschalten. Die IP-Adresse steht unter Einstellungen → Netzwerk → Netzwerkstatus, am besten im Router fest vergeben.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("IP-Adresse, z. B. 192.168.1.40", text: $tv.host)
                    .frame(maxWidth: 220)
                if tv.isPaired || !tv.psk.isEmpty {
                    Label("Gekoppelt", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            if tv.awaitingPIN {
                HStack {
                    TextField("PIN vom Fernseher", text: $tvPIN)
                        .frame(maxWidth: 140)
                        .onSubmit(submitTVPIN)
                    Button("Bestätigen", action: submitTVPIN)
                        .disabled(tvPIN.isEmpty || tv.isBusy)
                }
            }
            HStack {
                Button(tv.isPaired ? "Neu koppeln" : "Mit Fernseher koppeln") {
                    Task { await tv.startPairing() }
                }
                .disabled(!tv.isConfigured || tv.isBusy)
                Button("Ein/Aus testen") {
                    Task { await tv.togglePower() }
                }
                .disabled(!tv.isConfigured || tv.isBusy)
                if tv.isPaired {
                    Button("Kopplung lösen", role: .destructive) { tv.unpair() }
                }
            }
            SecureField("Pre-Shared Key (optional, statt PIN)", text: $tv.psk)
                .frame(maxWidth: 260)
            HStack {
                TextField("MAC-Adresse fürs Einschalten", text: $tvMAC)
                    .frame(maxWidth: 220)
                    .onSubmit { tv.setMAC(tvMAC) }
                Button("Übernehmen") { tv.setMAC(tvMAC) }
            }
            Text(tv.mac.map { "MAC-Adresse: \(WakeOnLAN.format($0))" }
                 ?? "MAC-Adresse wird gelernt, sobald der Fernseher einmal erreichbar war, oder oben eintragen.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let status = tv.status {
                Text(status)
                    .font(.caption)
            }
        }
    }

    private func submitTVPIN() {
        let pin = tvPIN
        tvPIN = ""
        Task { await tv.finishPairing(pin: pin) }
    }

    private func chooseWallpaper() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Bild für den Hintergrund der Startseite"
        if panel.runModal() == .OK, let url = panel.url {
            UserDefaults.standard.set(url.path, forKey: HomeController.wallpaperPathKey)
            wallpaperPath = url.path
        }
    }

    private var pairedDevicesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Gekoppelte Geräte").font(.headline)
            if server.pairedDevices.isEmpty {
                Text("Noch keine. Öffne CouchRemote auf dem iPhone.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(server.pairedDevices) { device in
                HStack {
                    Image(systemName: "iphone")
                    VStack(alignment: .leading) {
                        Text(device.name)
                        Text("gekoppelt am \(device.pairedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Entfernen", role: .destructive) { server.forget(device) }
                }
            }
        }
    }

    @ViewBuilder
    private var accessibilitySection: some View {
        if isTrusted {
            Label("Bedienungshilfen erlaubt", systemImage: "checkmark.shield.fill")
                .foregroundStyle(.green)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label("Bedienungshilfen fehlen", systemImage: "exclamationmark.shield.fill")
                    .foregroundStyle(.orange)
                Text("Ohne diese Berechtigung kann CouchHost keine Tasten oder Mausbewegungen senden.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Berechtigung anfragen") {
                        isTrusted = InputInjector.hasAccessibility(prompt: true)
                    }
                    Button("Einstellungen öffnen") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        }
    }
}
