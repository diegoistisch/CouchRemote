import XCTest
@testable import RemoteKit

final class RemoteCommandTests: XCTestCase {
    func testRoundTripClientMessages() throws {
        let commands: [RemoteCommand] = RemoteKey.allCases.map { .key($0) } + [
            .mouseMove(dx: 12.5, dy: -3),
            .click(.left),
            .click(.right),
            .scroll(dx: 0, dy: 40)
        ]
        let messages: [ClientMessage] = commands.map { .command($0) } + [
            .hello(deviceName: "iPhone", token: nil),
            .hello(deviceName: "iPhone", token: "abc"),
            .pair(code: "0420"),
            .openApp(id: UUID()),
            .setApps(HomeApp.defaults),
            .tvPower
        ]
        for message in messages {
            let data = try RemoteProtocol.encode(message)
            XCTAssertEqual(try RemoteProtocol.decode(ClientMessage.self, from: data), message)
        }
    }

    func testRoundTripServerMessages() throws {
        let messages: [ServerMessage] = [
            .welcome, .pairingRequired, .pairingFailed(attemptsLeft: 3), .paired(token: "t0k3n"),
            .apps(HomeApp.defaults), .notice("Fernseher aus")
        ]
        for message in messages {
            let data = try RemoteProtocol.encode(message)
            XCTAssertEqual(try RemoteProtocol.decode(ServerMessage.self, from: data), message)
        }
    }

    func testMACParsing() {
        XCTAssertEqual(WakeOnLAN.parseMAC("AC:9B:0A:12:3D:4F"), [0xAC, 0x9B, 0x0A, 0x12, 0x3D, 0x4F])
        // arp unter macOS lässt führende Nullen weg
        XCTAssertEqual(WakeOnLAN.parseMAC("ac:9b:a:12:3d:4f"), [0xAC, 0x9B, 0x0A, 0x12, 0x3D, 0x4F])
        XCTAssertEqual(WakeOnLAN.parseMAC("ac-9b-0a-12-3d-4f"), [0xAC, 0x9B, 0x0A, 0x12, 0x3D, 0x4F])
        XCTAssertNil(WakeOnLAN.parseMAC("ac:9b:0a:12:3d"))
        XCTAssertNil(WakeOnLAN.parseMAC("(incomplete)"))
        XCTAssertNil(WakeOnLAN.parseMAC("ac:9b:0a:12:3d:4g"))
    }

    func testMagicPacket() {
        let mac: [UInt8] = [0xAC, 0x9B, 0x0A, 0x12, 0x3D, 0x4F]
        let packet = [UInt8](WakeOnLAN.magicPacket(mac: mac))
        XCTAssertEqual(packet.count, 6 + 16 * 6)
        XCTAssertEqual(Array(packet[0..<6]), [UInt8](repeating: 0xFF, count: 6))
        XCTAssertEqual(Array(packet[6..<12]), mac)
        XCTAssertEqual(Array(packet[96..<102]), mac)
    }

    func testMACFromArpOutput() {
        let output = "? (192.168.1.40) at ac:9b:a:12:3d:4f on en0 ifscope [ethernet]\n"
        XCTAssertEqual(WakeOnLAN.macFromArp(output), [0xAC, 0x9B, 0x0A, 0x12, 0x3D, 0x4F])
        XCTAssertNil(WakeOnLAN.macFromArp("? (192.168.1.40) at (incomplete) on en0 ifscope [ethernet]"))
    }

    func testHomeAppValidation() {
        XCTAssertTrue(HomeApp.defaults.allSatisfy(\.isValid))
        XCTAssertFalse(HomeApp(name: "Datei", url: URL(string: "file:///etc/passwd")!, colorHex: "#000000").isValid)
        XCTAssertFalse(HomeApp(name: "App", url: URL(string: "ssh://example.com")!, colorHex: "#000000").isValid)
        XCTAssertFalse(HomeApp(name: "  ", url: URL(string: "https://example.com")!, colorHex: "#000000").isValid)
    }

    func testHexColor() {
        let rgb = HexColor.rgb("#FF8000")
        XCTAssertEqual(rgb.red, 1, accuracy: 0.001)
        XCTAssertEqual(rgb.green, 128.0 / 255, accuracy: 0.001)
        XCTAssertEqual(rgb.blue, 0, accuracy: 0.001)
    }

    func testIconParsingPrefersLargeTouchIcon() {
        let html = """
        <head>
          <link rel="icon" href="/favicon-32.png" sizes="32x32">
          <link rel="icon" type="image/svg+xml" href="/logo.svg">
          <link rel="icon" href="/icon-192.png" sizes="192x192">
          <link rel='apple-touch-icon' sizes='180x180' href='https://cdn.example.com/touch.png?v=1&amp;x=2'>
        </head>
        """
        let base = URL(string: "https://www.example.com/browse")!
        XCTAssertEqual(IconResolver.bestIcon(in: html, base: base)?.absoluteString,
                       "https://cdn.example.com/touch.png?v=1&x=2")
    }

    func testIconParsingResolvesRelativeAndSkipsTiny() {
        let html = "<link rel=\"shortcut icon\" href=\"/fav.ico\"><link rel=\"icon\" sizes=\"144x144\" href=\"img/i144.png\">"
        let base = URL(string: "https://site.com/de/")!
        XCTAssertEqual(IconResolver.bestIcon(in: html, base: base)?.absoluteString, "https://site.com/de/img/i144.png")
        XCTAssertNil(IconResolver.bestIcon(in: "<link rel=\"icon\" href=\"/fav.ico\">", base: base))
    }

    func testManifestIconPrefersLargeAnyPurpose() throws {
        let manifest = """
        {"icons": [
          {"src": "/i192.png", "sizes": "192x192", "type": "image/png"},
          {"src": "/i512-mask.png", "sizes": "512x512", "purpose": "maskable"},
          {"src": "/i512.png", "sizes": "512x512", "purpose": "any"},
          {"src": "/logo.svg", "sizes": "any", "type": "image/svg+xml"}
        ]}
        """
        let base = URL(string: "https://www.example.com/manifest.json")!
        XCTAssertEqual(IconResolver.bestIcon(inManifest: Data(manifest.utf8), base: base)?.absoluteString,
                       "https://www.example.com/i512.png")
    }

    func testSearchURLs() {
        let youtube = HomeApp(name: "YouTube", url: URL(string: "https://www.youtube.com")!, colorHex: "#FFFFFF")
        XCTAssertEqual(KnownServices.searchURL(for: youtube, query: "lofi & chill")?.absoluteString,
                       "https://www.youtube.com/results?search_query=lofi%20%26%20chill")
        let crunchy = HomeApp(name: "CR", url: URL(string: "https://crunchyroll.com/de")!, colorHex: "#F47521")
        XCTAssertEqual(KnownServices.searchURL(for: crunchy, query: "Frieren")?.absoluteString,
                       "https://www.crunchyroll.com/search?q=Frieren")
        XCTAssertEqual(KnownServices.shortcuts(for: crunchy).first?.id, "search")
        let other = HomeApp(name: "ORF", url: URL(string: "https://on.orf.at")!, colorHex: "#000000")
        XCTAssertFalse(KnownServices.supportsSearch(other))
        XCTAssertTrue(KnownServices.shortcuts(for: other).isEmpty)
    }

    func testFastChannelRoundTripAndTamperDetection() {
        let key = FastChannel.makeKey()
        let entries = [
            FastInputEntry(seq: 41, input: .move(dx: 3.5, dy: -1.25)),
            FastInputEntry(seq: 42, input: .scroll(dx: 0, dy: 12)),
            FastInputEntry(seq: 43, input: .click(.right))
        ]
        let packet = FastChannel.encode(session: 7, entries: entries, key: key)

        let decoded = FastChannel.decode(packet) { $0 == 7 ? key : nil }
        XCTAssertEqual(decoded?.session, 7)
        XCTAssertEqual(decoded?.entries, entries)

        // Falscher Schlüssel, unbekannte Sitzung, verändertes Byte → abgelehnt
        XCTAssertNil(FastChannel.decode(packet) { _ in FastChannel.makeKey() })
        XCTAssertNil(FastChannel.decode(packet) { _ in nil })
        var tampered = packet
        tampered[14] ^= 0x01
        XCTAssertNil(FastChannel.decode(tampered) { _ in key })
        XCTAssertNil(FastChannel.decode(Data("CR".utf8)) { _ in key })
    }

    func testFastChannelKeepsOnlyNewestEntries() {
        let key = FastChannel.makeKey()
        let entries = (1...10).map { FastInputEntry(seq: UInt32($0), input: .move(dx: 1, dy: 1)) }
        let decoded = FastChannel.decode(FastChannel.encode(session: 1, entries: entries, key: key)) { _ in key }
        XCTAssertEqual(decoded?.entries.map(\.seq), [5, 6, 7, 8, 9, 10])
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try RemoteProtocol.decode(ClientMessage.self, from: Data("nope".utf8)))
    }
}
