import AppKit
import ApplicationServices

/// Drückt im Browser den Knopf „Opening überspringen“ (Crunchyroll), „Skip Intro“ usw.
///
/// Sucht über die Bedienungshilfen im vordersten Fenster nach einem kurzen Text mit
/// „überspringen“ bzw. „skip“ innerhalb der Webseite. Das reicht auch in den Iframe des
/// Players hinein und braucht keine Einstellung im Browser (anders als JavaScript per AppleScript).
/// Läuft nicht auf dem Main-Thread.
enum SkipButtonPresser {
    /// Wörter, an denen der Knopf erkannt wird (kleingeschrieben).
    private static let keywords = ["überspringen", "skip"]
    /// Bevorzugt, falls mehrere Knöpfe da sind (z. B. Opening statt Rückblick).
    private static let preferred = ["opening", "intro", "vorspann"]
    /// Längere Texte sind keine Knöpfe, sondern z. B. Episodenbeschreibungen.
    private static let maxTextLength = 40
    private static let maxElements = 6000

    private struct Candidate {
        let element: AXUIElement
        let text: String
        let frame: CGRect
        let isButton: Bool
    }

    /// Gibt eine kurze Rückmeldung fürs iPhone zurück.
    static func press() -> String {
        guard InputInjector.hasAccessibility(prompt: false) else { return "Bedienungshilfen fehlen am Mac" }
        guard let app = NSWorkspace.shared.frontmostApplication else { return "Kein Überspringen-Knopf zu sehen" }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.5)
        // Chrome und Electron bauen den Baum der Webseite erst auf, wenn jemand danach fragt.
        let wasEnabled = (value(appElement, "AXManualAccessibility") as? Bool) == true
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        var candidate = find(in: appElement)
        if candidate == nil, !wasEnabled {
            Thread.sleep(forTimeInterval: 0.4) // Baum braucht beim ersten Mal einen Moment
            candidate = find(in: appElement)
        }
        guard let candidate else { return "Kein Überspringen-Knopf zu sehen" }

        if !candidate.isButton || AXUIElementPerformAction(candidate.element, kAXPressAction as CFString) != .success {
            click(at: CGPoint(x: candidate.frame.midX, y: candidate.frame.midY))
        }
        return "„\(candidate.text)“ gedrückt"
    }

    // MARK: - Suchen

    private static func find(in appElement: AXUIElement) -> Candidate? {
        guard let window = value(appElement, kAXFocusedWindowAttribute).map({ $0 as! AXUIElement }),
              let windowFrame = frame(of: window) else { return nil }

        // Breitensuche; Treffer zählen nur innerhalb der Webseite (nicht Tabs, Lesezeichen …).
        var queue: [(element: AXUIElement, inWebArea: Bool)] = [(window, false)]
        var index = 0
        var found: [Candidate] = []

        while index < queue.count, index < maxElements {
            let (element, parentInWebArea) = queue[index]
            index += 1
            let role = value(element, kAXRoleAttribute) as? String ?? ""
            let inWebArea = parentInWebArea || role == "AXWebArea"

            if inWebArea, let text = text(of: element), let elementFrame = frame(of: element),
               elementFrame.width > 4, elementFrame.height > 4, windowFrame.intersects(elementFrame) {
                found.append(Candidate(element: element, text: text, frame: elementFrame,
                                       isButton: role == kAXButtonRole || role == kAXLinkRole))
                continue // Kinder (Beschriftung des Knopfs) nicht nochmal prüfen
            }
            if let children = value(element, kAXChildrenAttribute) as? [AXUIElement] {
                queue.append(contentsOf: children.map { ($0, inWebArea) })
            }
        }

        return found.first { candidate in
            let lower = candidate.text.lowercased()
            return preferred.contains { lower.contains($0) }
        } ?? found.first
    }

    /// Beschriftung, falls sie wie ein Überspringen-Knopf aussieht.
    private static func text(of element: AXUIElement) -> String? {
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            guard let text = (value(element, attribute) as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !text.isEmpty, text.count <= maxTextLength else { continue }
            let lower = text.lowercased()
            if keywords.contains(where: { lower.contains($0) }) { return text }
        }
        return nil
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var result: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }

    /// Rahmen in Bildschirmkoordinaten (Ursprung oben links, wie bei CGEvent).
    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue = value(element, kAXPositionAttribute),
              let sizeValue = value(element, kAXSizeAttribute) else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGRect(origin: position, size: size)
    }

    // MARK: - Klicken

    /// Echter Mausklick, falls der Knopf kein „Drücken“ anbietet. Der Zeiger springt danach zurück.
    private static func click(at point: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        let original = CGEvent(source: nil)?.location ?? point
        for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: original, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }
}
