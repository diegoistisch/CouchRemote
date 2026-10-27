import AppKit
import ApplicationServices

/// Drückt im Browser den Knopf „Opening überspringen“ (Crunchyroll), „Skip Intro“ usw.
///
/// 1. In Chrome und Safari per JavaScript (AppleScript). Nötig, weil Crunchyroll den Knopf mit
///    `aria-hidden` vor den Bedienungshilfen versteckt. Braucht im Browser einmal
///    „JavaScript von Apple Events erlauben“ (Chrome: Darstellen → Entwickler).
/// 2. Sonst über die Bedienungshilfen: kurzer Text mit „überspringen“ bzw. „skip“ in der Webseite.
/// Läuft nicht auf dem Main-Thread.
enum SkipButtonPresser {
    /// Wörter, an denen der Knopf erkannt wird (kleingeschrieben).
    private static let keywords = ["überspringen", "skip"]
    /// Bevorzugt, falls mehrere Knöpfe da sind (z. B. Opening statt Rückblick).
    private static let preferred = ["opening", "intro", "vorspann"]
    /// Längere Texte sind keine Knöpfe, sondern z. B. Episodenbeschreibungen.
    private static let maxTextLength = 40
    /// Obergrenze pro Fenster, damit eine riesige Seite die Suche nicht ewig aufhält.
    private static let maxElements = 30_000
    private static let timeBudget: TimeInterval = 3

    /// Browser, die auch durchsucht werden, wenn gerade etwas anderes vorne ist (z. B. CouchHost).
    private static let browsers: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "com.microsoft.edgemac",
        "com.brave.Browser", "org.mozilla.firefox", "com.operasoftware.Opera", "com.vivaldi.Vivaldi"
    ]

    private struct Candidate {
        let element: AXUIElement
        let text: String
        let frame: CGRect
        let isButton: Bool
        let app: NSRunningApplication
    }

    /// Gibt eine kurze Rückmeldung fürs iPhone zurück.
    static func press() -> String {
        guard InputInjector.hasAccessibility(prompt: false) else { return "Bedienungshilfen fehlen am Mac" }

        let script = pressViaJavaScript()
        if case .pressed(let label) = script { return "„\(label)“ gedrückt" }

        let deadline = Date().addingTimeInterval(timeBudget)
        var candidate: Candidate?
        for app in candidateApps() {
            candidate = find(in: app, deadline: deadline)
            if candidate != nil || Date() > deadline { break }
        }
        guard let candidate else {
            if case .failed(let hint) = script { return hint }
            return "Kein Überspringen-Knopf zu sehen"
        }

        if !candidate.isButton || AXUIElementPerformAction(candidate.element, kAXPressAction as CFString) != .success {
            // Echter Klick trifft nur, wenn das Fenster vorne liegt.
            if !candidate.app.isActive {
                candidate.app.activate()
                Thread.sleep(forTimeInterval: 0.3)
            }
            click(at: CGPoint(x: candidate.frame.midX, y: candidate.frame.midY))
        }
        return "„\(candidate.text)“ gedrückt"
    }

    /// Vorderste App zuerst, danach alle laufenden Browser.
    private static func candidateApps() -> [NSRunningApplication] {
        let front = NSWorkspace.shared.frontmostApplication
        let running = NSWorkspace.shared.runningApplications.filter {
            browsers.contains($0.bundleIdentifier ?? "") && $0 != front
        }
        return (front.map { [$0] } ?? []) + running
    }

    // MARK: - Suchen

    private static func find(in app: NSRunningApplication, deadline: Date) -> Candidate? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.5)
        // Chrome und Electron bauen den Baum der Webseite erst auf, wenn jemand danach fragt.
        let wasEnabled = (value(appElement, "AXManualAccessibility") as? Bool) == true
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        if let found = search(appElement, app: app, deadline: deadline) { return found }
        if !wasEnabled, app.bundleIdentifier != Bundle.main.bundleIdentifier, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.4) // Baum braucht beim ersten Mal einen Moment
            return search(appElement, app: app, deadline: deadline)
        }
        return nil
    }

    private static func search(_ appElement: AXUIElement, app: NSRunningApplication, deadline: Date) -> Candidate? {
        var windows = value(appElement, kAXWindowsAttribute) as? [AXUIElement] ?? []
        // Fokussiertes Fenster zuerst
        if let focused = value(appElement, kAXFocusedWindowAttribute).map({ $0 as! AXUIElement }) {
            windows.removeAll { CFEqual($0, focused) }
            windows.insert(focused, at: 0)
        }

        var found: [Candidate] = []
        for window in windows where found.isEmpty && Date() < deadline {
            guard let windowFrame = frame(of: window) else { continue }
            collect(in: window, windowFrame: windowFrame, app: app, deadline: deadline, into: &found)
        }

        if found.isEmpty {
            NSLog("CouchHost: Kein Überspringen-Knopf in \(app.localizedName ?? "?") (\(windows.count) Fenster)")
        }
        return found.first { candidate in
            let lower = candidate.text.lowercased()
            return preferred.contains { lower.contains($0) }
        } ?? found.first
    }

    private static let searchAttributes = [
        kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXChildrenAttribute
    ] as CFArray

    /// Breitensuche; Treffer zählen nur innerhalb der Webseite (nicht Tabs, Lesezeichen …).
    private static func collect(in window: AXUIElement, windowFrame: CGRect, app: NSRunningApplication,
                                deadline: Date, into found: inout [Candidate]) {
        var queue: [(element: AXUIElement, inWebArea: Bool)] = [(window, false)]
        var index = 0

        while index < queue.count, index < maxElements {
            if index % 500 == 0, Date() > deadline { break }
            let (element, parentInWebArea) = queue[index]
            index += 1

            // Alle Werte mit einem Aufruf holen (deutlich schneller als einzeln).
            var valuesRef: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element, searchAttributes, [], &valuesRef) == .success,
                  let values = valuesRef as? [AnyObject], values.count == 5 else { continue }
            let role = values[0] as? String ?? ""
            let inWebArea = parentInWebArea || role == "AXWebArea"

            if inWebArea, let text = matchingText(values[1], values[2], values[3]),
               let elementFrame = frame(of: element),
               elementFrame.width > 4, elementFrame.height > 4, windowFrame.intersects(elementFrame) {
                found.append(Candidate(element: element, text: text, frame: elementFrame,
                                       isButton: role == kAXButtonRole || role == "AXLink", app: app))
                continue // Kinder (Beschriftung des Knopfs) nicht nochmal prüfen
            }
            if let children = values[4] as? [AXUIElement] {
                queue.append(contentsOf: children.map { ($0, inWebArea) })
            }
        }
    }

    /// Beschriftung, falls sie wie ein Überspringen-Knopf aussieht.
    private static func matchingText(_ candidates: AnyObject...) -> String? {
        for candidate in candidates {
            guard let text = (candidate as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
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

    // MARK: - JavaScript

    private enum ScriptResult {
        case pressed(String)
        case notFound
        case failed(String)
    }

    /// Sucht den Knopf in allen Dokumenten (auch gleich-originigen Iframes), klickt ihn und gibt
    /// seine Beschriftung zurück (leer = nicht gefunden). Ohne doppelte Anführungszeichen und
    /// Backslashes, damit es unverändert in einen AppleScript-String passt.
    private static let javaScript = """
    (() => {
      const words = ['überspringen', 'skip'], preferred = ['opening', 'intro', 'vorspann'];
      const docs = [document];
      for (const frame of document.querySelectorAll('iframe')) {
        try { if (frame.contentDocument) docs.push(frame.contentDocument); } catch (e) {}
      }
      const found = [];
      for (const doc of docs) {
        for (const button of doc.querySelectorAll('button, [role=button]')) {
          const text = (button.getAttribute('aria-label') || button.textContent || '').trim();
          const lower = text.toLowerCase();
          if (!text || text.length > 40 || !words.some(w => lower.includes(w))) continue;
          const rect = button.getBoundingClientRect();
          if (rect.width < 4 || rect.height < 4) continue;
          found.push([button, text]);
        }
      }
      const hit = found.find(([, t]) => preferred.some(p => t.toLowerCase().includes(p))) || found[0];
      if (!hit) return '';
      hit[0].click();
      return hit[1];
    })()
    """

    /// Aktiver Tab jedes Fensters der laufenden Browser (Browser werden nicht gestartet).
    private static func pressViaJavaScript() -> ScriptResult {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        var failure: String?

        for (bundleID, name, command) in [
            ("com.google.Chrome", "Chrome", "execute (active tab of w) javascript js"),
            ("com.apple.Safari", "Safari", "do JavaScript js in (current tab of w)")
        ] where running.contains(bundleID) {
            let source = """
            set js to "\(javaScript)"
            tell application id "\(bundleID)"
              repeat with w in windows
                set r to \(command)
                if r is not missing value and r is not "" then return r
              end repeat
            end tell
            return ""
            """
            // NSAppleScript nur auf dem Main-Thread benutzen.
            let (label, error) = DispatchQueue.main.sync { () -> (String?, (number: Int, message: String)?) in
                var info: NSDictionary?
                let result = NSAppleScript(source: source)?.executeAndReturnError(&info)
                let error = info.map {
                    ($0[NSAppleScript.errorNumber] as? Int ?? 0, $0[NSAppleScript.errorMessage] as? String ?? "")
                }
                return (result?.stringValue, error)
            }
            if let label, !label.isEmpty { return .pressed(label) }
            if let error {
                NSLog("CouchHost: JavaScript in \(name) fehlgeschlagen (\(error.number)): \(error.message)")
                failure = error.number == -1743
                    ? "CouchHost darf \(name) nicht steuern (Systemeinstellungen → Datenschutz → Automation)"
                    : "In \(name) „JavaScript von Apple Events erlauben“ einschalten"
            }
        }
        return failure.map(ScriptResult.failed) ?? .notFound
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
