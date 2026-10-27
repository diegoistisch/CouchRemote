import Darwin
import Foundation
import RemoteKit

/// Schaltet den Sony-Fernseher übers Heimnetz ein und aus.
///
/// - Zustand abfragen: `getPowerStatus` der Sony-Web-API (braucht keine Anmeldung).
/// - Ausschalten: `setPowerStatus`, notfalls die IR-Taste „PowerOff“ über IRCC.
///   Beides braucht eine Anmeldung: PIN-Kopplung (Cookie) oder Pre-Shared Key.
/// - Einschalten: Wake-on-LAN an die MAC-Adresse des Fernsehers (TV-Einstellung „Remote Start“),
///   zusätzlich `setPowerStatus`, falls der Fernseher im Standby noch antwortet.
@MainActor
final class TVController: ObservableObject {
    static let hostKey = "tvHost"
    static let pskKey = "tvPSK"
    private static let macKey = "tvMAC"
    private static let cookieKey = "tvAuthCookie"
    private static let clientIDKey = "tvClientID"

    @Published var host: String {
        didSet { UserDefaults.standard.set(host, forKey: Self.hostKey) }
    }
    @Published var psk: String {
        didSet { UserDefaults.standard.set(psk, forKey: Self.pskKey) }
    }
    @Published private(set) var mac: [UInt8]? {
        didSet { UserDefaults.standard.set(mac.map(WakeOnLAN.format), forKey: Self.macKey) }
    }
    @Published private(set) var isPaired: Bool
    @Published private(set) var awaitingPIN = false
    @Published private(set) var status: String?
    @Published private(set) var isBusy = false

    private var cookie: String? {
        didSet {
            UserDefaults.standard.set(cookie, forKey: Self.cookieKey)
            isPaired = cookie != nil
        }
    }
    private let clientID: String
    private let session: URLSession

    private enum TVError: Error {
        case unauthorized
        case api(code: Int)
        case http(status: Int)
        case invalidResponse
    }

    init() {
        let defaults = UserDefaults.standard
        host = defaults.string(forKey: Self.hostKey) ?? ""
        psk = defaults.string(forKey: Self.pskKey) ?? ""
        mac = defaults.string(forKey: Self.macKey).flatMap(WakeOnLAN.parseMAC)
        cookie = defaults.string(forKey: Self.cookieKey)
        isPaired = defaults.string(forKey: Self.cookieKey) != nil
        if let id = defaults.string(forKey: Self.clientIDKey) {
            clientID = id
        } else {
            clientID = "CouchHost:\(UUID().uuidString)"
            defaults.set(clientID, forKey: Self.clientIDKey)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.httpShouldSetCookies = false // Cookie selbst verwalten
        session = URLSession(configuration: configuration)
    }

    private var trimmedHost: String { host.trimmingCharacters(in: .whitespaces) }
    var isConfigured: Bool { !trimmedHost.isEmpty }

    // MARK: - Ein/Aus

    /// Fragt den Zustand ab und schaltet um. Gibt einen kurzen Text fürs iPhone zurück.
    @discardableResult
    func togglePower() async -> String {
        isBusy = true
        defer { isBusy = false }

        guard isConfigured else {
            // Ohne IP-Adresse geht nur Einschalten per Wake-on-LAN (Broadcast an die MAC-Adresse).
            guard let mac else { return report("Fernseher nicht eingerichtet: IP-Adresse im CouchHost-Fenster eintragen") }
            sendWakeOnLAN(to: mac)
            return report("Fernseher wird eingeschaltet")
        }

        let state = try? await powerStatus()
        // Auch ein abgelehnter Verbindungsversuch füllt den ARP-Cache → MAC-Adresse lernen
        await learnMACIfNeeded()

        // Modelle ohne Sony-Web-API (z. B. KD-49XF7005) verraten ihren Zustand nicht zuverlässig
        // (DLNA antwortet auch im Standby) → unten immer das Weckpaket schicken, das stört nicht, wenn er schon an ist.

        if state == "active" {
            do {
                try await powerOff()
                return report("Fernseher aus")
            } catch TVError.unauthorized {
                return report("Fernseher lehnt ab: im CouchHost-Fenster neu koppeln")
            } catch {
                return report("Ausschalten fehlgeschlagen")
            }
        }

        // Standby (antwortet noch) oder gar nicht erreichbar → einschalten
        if let mac { sendWakeOnLAN(to: mac) }
        if state != nil { _ = try? await authorizedCall("system", "setPowerStatus", params: [["status": true]]) }
        if mac == nil && state == nil {
            return report("Fernseher nicht erreichbar, MAC-Adresse unbekannt")
        }
        return report("Fernseher wird eingeschaltet")
    }

    private func report(_ text: String) -> String {
        status = text
        return text
    }

    /// "active" oder "standby".
    private func powerStatus() async throws -> String? {
        let result = try await call("system", "getPowerStatus", params: [], auth: false)
        return (result.first as? [String: Any])?["status"] as? String
    }

    private func powerOff() async throws {
        do {
            try await authorizedCall("system", "setPowerStatus", params: [["status": false]])
        } catch TVError.api(_) {
            // Manche Modelle kennen setPowerStatus nicht → IR-Taste „PowerOff“ schicken
            try await sendIRCC("AAAAAQAAAAEAAAAvAw==")
        }
    }

    // MARK: - Kopplung per PIN

    /// Erster Schritt: der Fernseher zeigt eine 4-stellige PIN.
    func startPairing() async {
        guard isConfigured else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await register(pin: nil)
            awaitingPIN = false
            status = "Gekoppelt"
        } catch TVError.unauthorized {
            awaitingPIN = true
            status = "PIN vom Fernseher eingeben"
        } catch {
            status = "Fernseher nicht erreichbar. IP-Adresse und „Fernbedienungsgeräte“ am TV prüfen."
        }
    }

    /// Zweiter Schritt: PIN bestätigen, der Fernseher gibt ein Anmelde-Cookie zurück.
    func finishPairing(pin: String) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await register(pin: pin.trimmingCharacters(in: .whitespaces))
            awaitingPIN = false
            status = "Gekoppelt"
            await learnMACIfNeeded()
        } catch TVError.unauthorized {
            status = "Falsche PIN, bitte neu koppeln"
            awaitingPIN = false
        } catch {
            status = "Kopplung fehlgeschlagen"
            awaitingPIN = false
        }
    }

    func unpair() {
        cookie = nil
        awaitingPIN = false
        status = nil
    }

    /// `actRegister`: ohne PIN → 401 und der Fernseher zeigt eine PIN; mit PIN (oder gültigem Cookie)
    /// → neues Cookie. Das Cookie läuft nach einigen Tagen ab und wird dann über `renew` erneuert.
    private func register(pin: String?, renewWith existing: String? = nil) async throws {
        let params: [Any] = [
            ["clientid": clientID, "nickname": "CouchHost", "level": "private"],
            [["value": "yes", "function": "WOL"]]
        ]
        var headers: [String: String] = [:]
        if let pin {
            headers["Authorization"] = "Basic " + Data(":\(pin)".utf8).base64EncodedString()
        } else if let existing {
            headers["Cookie"] = existing
        }
        let (_, response) = try await post(path: "/sony/accessControl",
                                           body: try jsonBody("actRegister", params: params, version: "1.0"),
                                           headers: headers)
        guard let setCookie = response.value(forHTTPHeaderField: "Set-Cookie"),
              let auth = setCookie.split(separator: ";").first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("auth=") })
        else { throw TVError.invalidResponse }
        cookie = auth.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Web-API

    /// Aufruf mit Anmeldung; ein abgelaufenes Cookie wird einmal erneuert.
    @discardableResult
    private func authorizedCall(_ service: String, _ method: String, params: [Any]) async throws -> [Any] {
        do {
            return try await call(service, method, params: params, auth: true)
        } catch TVError.unauthorized where psk.isEmpty && cookie != nil {
            try await register(pin: nil, renewWith: cookie)
            return try await call(service, method, params: params, auth: true)
        }
    }

    private var authHeaders: [String: String] {
        if !psk.isEmpty { return ["X-Auth-PSK": psk] }
        if let cookie { return ["Cookie": cookie] }
        return [:]
    }

    private func call(_ service: String, _ method: String, params: [Any], auth: Bool) async throws -> [Any] {
        let (data, _) = try await post(path: "/sony/\(service)",
                                       body: try jsonBody(method, params: params, version: "1.0"),
                                       headers: auth ? authHeaders : [:])
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TVError.invalidResponse
        }
        if let error = json["error"] as? [Any], let code = error.first as? Int {
            // 401/403 kommen bei Sony auch als API-Fehler statt als HTTP-Status
            if code == 401 || code == 403 { throw TVError.unauthorized }
            throw TVError.api(code: code)
        }
        return json["result"] as? [Any] ?? []
    }

    private func jsonBody(_ method: String, params: [Any], version: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "method": method, "params": params, "id": 1, "version": version
        ] as [String: Any])
    }

    /// IR-Taste über IRCC (SOAP).
    private func sendIRCC(_ code: String) async throws {
        let body = """
        <?xml version="1.0"?>\
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">\
        <s:Body><u:X_SendIRCC xmlns:u="urn:schemas-sony-com:service:IRCC:1"><IRCCCode>\(code)</IRCCCode></u:X_SendIRCC></s:Body>\
        </s:Envelope>
        """
        var headers = authHeaders
        headers["Content-Type"] = "text/xml; charset=UTF-8"
        headers["SOAPACTION"] = "\"urn:schemas-sony-com:service:IRCC:1#X_SendIRCC\""
        _ = try await post(path: "/sony/IRCC", body: Data(body.utf8), headers: headers)
    }

    private func post(path: String, body: Data, headers: [String: String]) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: "http://\(trimmedHost)\(path)") else { throw TVError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TVError.invalidResponse }
        switch http.statusCode {
        case 200: return (data, http)
        case 401, 403: throw TVError.unauthorized
        default: throw TVError.http(status: http.statusCode)
        }
    }

    // MARK: - Wake-on-LAN

    /// MAC-Adresse von Hand setzen (Feld im CouchHost-Fenster). Leer = wieder automatisch lernen.
    func setMAC(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            mac = nil
        } else if let parsed = WakeOnLAN.parseMAC(trimmed) {
            mac = parsed
        }
    }

    /// MAC-Adresse aus dem ARP-Cache lernen, solange der Fernseher erreichbar ist.
    private func learnMACIfNeeded() async {
        guard mac == nil else { return }
        let host = trimmedHost
        let output = await Task.detached { () -> String in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
            process.arguments = ["-n", host]
            let pipe = Pipe()
            process.standardOutput = pipe
            guard (try? process.run()) != nil else { return "" }
            process.waitUntilExit()
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        }.value
        if let found = WakeOnLAN.macFromArp(output) { mac = found }
    }

    /// Magic Packet an Broadcast und direkt an den Fernseher, je dreimal (UDP kann verloren gehen).
    private func sendWakeOnLAN(to mac: [UInt8]) {
        let packet = WakeOnLAN.magicPacket(mac: mac)
        var targets = [in_addr_t(0xFFFF_FFFF)] // 255.255.255.255
        var direct = in_addr()
        if inet_pton(AF_INET, trimmedHost, &direct) == 1 {
            targets.append(direct.s_addr)
            // Broadcast des eigenen /24-Netzes (z. B. 192.168.0.255), s_addr ist in Netzwerk-Byte-Reihenfolge
            targets.append((UInt32(bigEndian: direct.s_addr) | 0xFF).bigEndian)
        }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var enable: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &enable, socklen_t(MemoryLayout<Int32>.size))

        for _ in 0..<3 {
            for target in targets {
                var address = sockaddr_in()
                address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                address.sin_family = sa_family_t(AF_INET)
                address.sin_port = in_port_t(9).bigEndian
                address.sin_addr.s_addr = target
                packet.withUnsafeBytes { bytes in
                    withUnsafePointer(to: &address) { pointer in
                        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            _ = sendto(fd, bytes.baseAddress, bytes.count, 0, $0,
                                       socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
            }
        }
    }
}
