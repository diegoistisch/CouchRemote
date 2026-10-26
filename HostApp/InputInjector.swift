import AppKit
import ApplicationServices
import RemoteKit

/// Setzt Fernbedienungsbefehle in echte Tastatur-, Maus- und Medientasten-Events um.
/// Braucht die Bedienungshilfen-Berechtigung (Systemeinstellungen → Datenschutz & Sicherheit).
///
/// Läuft bewusst NICHT auf dem Main-Thread, sondern nur auf der Netzwerk-Queue des Servers:
/// So kann die Oberfläche (Startseite, Animationen) die Mausbewegungen nie ausbremsen.
/// Nicht von mehreren Threads gleichzeitig benutzen.
final class InputInjector: @unchecked Sendable {
    private let source = CGEventSource(stateID: .hidSystemState)

    /// Eigene Zeigerposition mit Nachkommastellen: langsame Bewegungen gehen nicht durch Rundung verloren.
    private var virtualCursor: CGPoint?

    /// Für Doppelklicks (z. B. Vollbild per Doppelklick aufs Video).
    private var lastClick: (time: TimeInterval, button: MouseButton, count: Int64)?
    private static let doubleClickInterval: TimeInterval = 0.4

    static func hasAccessibility(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    func perform(_ command: RemoteCommand) {
        switch command {
        case .key(let key): press(key)
        case .mouseMove(let dx, let dy): moveMouse(dx: dx, dy: dy)
        case .click(let button): click(button)
        case .scroll(let dx, let dy): scroll(dx: dx, dy: dy)
        case .text(let string): type(string)
        }
    }

    // MARK: - Text

    /// Tippt beliebigen Text (Umlaute, Emoji …) als Unicode-Tastenereignisse,
    /// unabhängig vom Tastaturlayout des Macs.
    private func type(_ string: String) {
        for character in string.prefix(500) {
            let units = Array(String(character).utf16)
            for isDown in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: isDown)
                units.withUnsafeBufferPointer { buffer in
                    event?.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                }
                event?.post(tap: .cghidEventTap)
            }
        }
    }

    // MARK: - Tasten

    private enum KeyCode {
        static let returnKey: CGKeyCode = 36
        static let space: CGKeyCode = 49
        static let escape: CGKeyCode = 53
        static let left: CGKeyCode = 123
        static let right: CGKeyCode = 124
        static let down: CGKeyCode = 125
        static let up: CGKeyCode = 126
        static let f: CGKeyCode = 3
        static let leftBracket: CGKeyCode = 33
        static let delete: CGKeyCode = 51
    }

    /// NX_KEYTYPE_* aus IOKit/hidsystem/ev_keymap.h
    private enum MediaKey {
        static let soundUp: Int = 0
        static let soundDown: Int = 1
        static let mute: Int = 7
    }

    private func press(_ key: RemoteKey) {
        switch key {
        case .up: tap(KeyCode.up)
        case .down: tap(KeyCode.down)
        case .left, .seekBack: tap(KeyCode.left)
        case .right, .seekForward: tap(KeyCode.right)
        case .select: tap(KeyCode.returnKey)
        case .back: tap(KeyCode.escape)
        case .playPause: tap(KeyCode.space)
        case .fullscreen: tap(KeyCode.f)
        case .browserBack: tap(KeyCode.leftBracket, flags: .maskCommand)
        case .deleteBackward: tap(KeyCode.delete)
        case .home, .skip: break // wird vom Server abgefangen (Startseite bzw. SkipButtonPresser)
        case .volumeUp: mediaKey(MediaKey.soundUp)
        case .volumeDown: mediaKey(MediaKey.soundDown)
        case .mute: mediaKey(MediaKey.mute)
        }
    }

    private func tap(_ code: CGKeyCode, flags: CGEventFlags = []) {
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: isDown)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }

    private func mediaKey(_ key: Int) {
        // NSEvent sicherheitshalber auf dem Main-Thread erzeugen (selten, nicht zeitkritisch).
        DispatchQueue.main.async {
            Self.postMediaKey(key)
        }
    }

    private static func postMediaKey(_ key: Int) {
        for isDown in [true, false] {
            let state = isDown ? 0xA : 0xB
            let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: (key << 16) | (state << 8),
                data2: -1
            )
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Maus

    private var systemCursor: CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    private func moveMouse(dx: Double, dy: Double) {
        let actual = systemCursor
        var point = virtualCursor ?? actual
        // Wurde die echte Maus bewegt? Dann von dort aus weitermachen.
        if abs(point.x - actual.x) > 2 || abs(point.y - actual.y) > 2 {
            point = actual
        }
        point.x += dx
        point.y += dy
        point = clampToDisplays(point)
        virtualCursor = point

        let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                            mouseCursorPosition: point, mouseButton: .left)
        // Relative Werte mitschicken, manche Web-Player werten nur diese aus.
        event?.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx.rounded()))
        event?.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy.rounded()))
        event?.post(tap: .cghidEventTap)
    }

    private func click(_ button: MouseButton) {
        let point = systemCursor
        let now = ProcessInfo.processInfo.systemUptime

        var clickCount: Int64 = 1
        if let last = lastClick, last.button == button, now - last.time < Self.doubleClickInterval {
            clickCount = min(last.count + 1, 3)
        }
        lastClick = (now, button, clickCount)

        let (downType, upType, cgButton): (CGEventType, CGEventType, CGMouseButton) =
            button == .left
                ? (.leftMouseDown, .leftMouseUp, .left)
                : (.rightMouseDown, .rightMouseUp, .right)
        for type in [downType, upType] {
            let event = CGEvent(mouseEventSource: source, mouseType: type,
                                mouseCursorPosition: point, mouseButton: cgButton)
            event?.setIntegerValueField(.mouseEventClickState, value: clickCount)
            event?.post(tap: .cghidEventTap)
        }
    }

    private func scroll(dx: Double, dy: Double) {
        CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0)?
            .post(tap: .cghidEventTap)
    }

    /// Hält den Zeiger innerhalb aller angeschlossenen Bildschirme.
    private func clampToDisplays(_ point: CGPoint) -> CGPoint {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &displays, &count)

        let bounds = displays.map(CGDisplayBounds).reduce(CGRect.null) { $0.union($1) }
        guard !bounds.isNull else { return point }
        return CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX - 1),
            y: min(max(point.y, bounds.minY), bounds.maxY - 1)
        )
    }
}
