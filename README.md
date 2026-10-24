# CouchRemote

Ein altes MacBook am Fernseher wird zur TV-Box, das iPhone zur Fernbedienung.
Netflix und Crunchyroll laufen in Safari, gesteuert per D-Pad oder Trackpad vom iPhone.

## Aufbau

| Ordner | Inhalt |
| --- | --- |
| `RemoteKit/` | Gemeinsames Swift-Paket: Befehle (`RemoteCommand`) und JSON-Kodierung |
| `HostApp/` | Mac-App: WebSocket-Server mit Bonjour, setzt Befehle per `CGEvent` in Tasten und Maus um |
| `RemoteApp/` | iPhone-App: findet den Mac per Bonjour, D-Pad, Trackpad, Lautstärke |
| `project.yml` | XcodeGen-Konfiguration, daraus entsteht das Xcode-Projekt |

```
iPhone (CouchRemote) ──WebSocket/JSON──▶ Mac (CouchHost) ──CGEvent──▶ Safari (Netflix, Crunchyroll)
        ▲                                     │
        └──────────── Bonjour _couchremote._tcp
```

## Loslegen

```bash
brew install xcodegen
cd CouchRemote
xcodegen generate
open CouchRemote.xcodeproj
```

1. In Xcode bei beiden Targets unter *Signing & Capabilities* dein Team wählen.
2. **CouchHost** auf dem Mac starten. Beim ersten Start „Berechtigung anfragen“ klicken und
   CouchHost unter *Datenschutz & Sicherheit → Bedienungshilfen* erlauben.
   Hinweis: Nach einem neuen Build kann macOS die Berechtigung zurücksetzen. Dann CouchHost in der Liste
   entfernen und neu hinzufügen.
3. **CouchRemote** auf dem iPhone starten und „Lokales Netzwerk“ erlauben.
   Das iPhone verbindet sich automatisch, sobald genau ein Mac gefunden wird (sonst über das TV-Symbol wählen).

Tests für das Protokoll: `cd RemoteKit && swift test`

## Tastenbelegung (aktuell)

| iPhone | Mac |
| --- | --- |
| Pfeile (halten = wiederholen) | Pfeiltasten |
| OK | Return |
| Zurück tippen / halten | Escape / vorherige Seite (⌘[) |
| Play/Pause | Leertaste |
| Home | Startseite (Vollbild) öffnen |
| Auf der Startseite: Pfeile / OK | Kachel wählen / App in Safari öffnen |
| Lauter / Leiser / Stumm | Medientasten (Mac-Lautstärke) |
| Trackpad: 1 Finger wischen / tippen | Zeiger bewegen / Klick (2× schnell = Doppelklick) |
| Trackpad: 2 Finger wischen / tippen | Scrollen / Rechtsklick |
| Player: Spulen zurück / vor | Pfeil links / rechts |
| Player: Vollbild | F |
| Player: leiser / lauter | Pfeil runter / hoch (Lautstärke im Video) |

Hinweis: Bei Tonausgabe über HDMI ist die Mac-Lautstärke oft gesperrt. Dann im Player-Modus
die Video-Lautstärke nutzen oder die Fernbedienung des Fernsehers.

## Meilensteine

- [x] 1 Prototyp: iPhone sendet Befehle, Mac setzt sie um
- [x] 2a Bonjour-Erkennung (ohne IP-Eingabe)
- [x] 2b Kopplung per 4-stelligem Code und Token (Token im iPhone-Schlüsselbund, am Mac nur als Hash)
- [x] 3 Vollbild-Startseite mit Kacheln, Apps am iPhone verwalten (hinzufügen, sortieren, löschen, starten)
- [x] 4a Fernbedienungs-UI mit D-Pad und Trackpad
- [x] 4b Player-Modus, Tasten-Wiederholung, 2-Finger-Gesten, Latenz-Optimierung
- [ ] 4c Abnahme auf echten Seiten (Netflix, Crunchyroll)
- [ ] 5 Setup am Sony: Clamshell (Vorssaint), Auto-Start, Dauertest
- [ ] 6 Texteingabe, Wake-on-LAN

## Sicherheit

Neue iPhones müssen den Code eingeben, der im CouchHost-Fenster erscheint (5 Versuche, Verbindung
läuft nach 2 Minuten ohne Kopplung ab). Gekoppelte Geräte lassen sich im CouchHost-Fenster entfernen.
Die Verbindung ist im Heimnetz unverschlüsselt (kein TLS); für fremde Netze nicht gedacht.

## Startseite

- Öffnet sich mit der Home-Taste auf dem Bildschirm, auf dem der Mauszeiger ist (am Fernseher: dem einzigen)
- Escape auf der echten Mac-Tastatur schließt sie; „Beim Start zeigen“ im CouchHost-Fenster für den TV-Betrieb
- Apps werden am iPhone über das Raster-Symbol verwaltet und am Mac gespeichert (nur http(s)-Adressen)
- Icons liest der `IconResolver` aus dem HTML der Seite (apple-touch-icon/icon ≥ 96 px), sonst Anfangsbuchstabe

## Schneller Kanal (UDP)

Trackpad-Bewegungen, Scrollen und Klicks gehen über UDP statt WebSocket: Über TCP hält ein einziges
im WLAN verlorenes Paket alle folgenden Bewegungen zurück (Zeiger hängt, dann springt er). Jedes
UDP-Paket enthält die letzten 5 Eingaben (Redundanz), danach wird 3× nachgesendet. Pakete sind mit
HMAC-SHA256 signiert (Schlüssel pro Verbindung, nur für gekoppelte iPhones), Sequenznummern verhindern
Doppelungen. Erst wenn ein Probe-Paket bestätigt ist, schaltet das iPhone um (⚡ neben dem Status);
sonst bleibt alles auf WebSocket. Details: `RemoteKit/Sources/RemoteKit/FastChannel.swift`.

## Icons

Von Codex erzeugt (`make-icons.command`, Auftrag in `Design/icon-prompt.md`), Originale in `Design/Icons/`.

## Latenz

- Netzwerk und Eingaben am Mac auf eigener Queue mit höchster Priorität (nicht auf dem Main-Thread)
- App Nap aus (`NSAppSleepDisabled` + `latencyCritical`-Activity), sonst wird CouchHost im Hintergrund gedrosselt
- TCP ohne Nagle (`noDelay`), Keepalive (tote Verbindungen nach ~11 s weg), kein Peer-to-Peer-WLAN, WLAN-QoS „interactive voice“
- Trackpad-Bewegungen gehen sofort raus; höchstens eine ist unterwegs, der Rest wird gebündelt nachgeschickt
- UIKit-Touches mit koaleszierten Zwischenpunkten, Beschleunigung nach Geschwindigkeit
- Mac führt die Zeigerposition mit Nachkommastellen (keine Rundungsverluste)

## Bauen per Doppelklick

- `run-host.command`: CouchHost bauen (mit Entwicklerzertifikat signiert, damit die
  Bedienungshilfen-Berechtigung erhalten bleibt) und starten
- `run-iphone.command`: CouchRemote bauen, aufs gekoppelte iPhone installieren und starten
