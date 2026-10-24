# Auftrag: App-Icons für CouchHost und CouchRemote

Erstelle zwei App-Icons als PNG für ein privates Projekt. Arbeite nur im aktuellen Ordner.

## Die Apps
- **CouchHost** (macOS): verwandelt ein MacBook am Fernseher in eine TV-Box mit Startseite (ähnlich Apple TV).
- **CouchRemote** (iOS): das iPhone als Fernbedienung mit großem Trackpad für diesen Mac.

Die beiden Icons sollen klar als Paar erkennbar sein (gleiche Farbwelt, gleiche Formsprache).

## Gestaltung
- Modern, ruhig, hochwertig, im Stil aktueller Apple-App-Icons (weiche Verläufe, dezente Tiefe, keine Comic-Optik).
- Farbwelt: tiefes Nachtblau bis Violett als Hintergrund, mit einem warmen Akzent (Orange/Koralle) wie Licht vom Fernseher.
- **CouchHost**: ein stilisierter Fernseher/Bildschirm, davor angedeutet die Silhouette eines Sofas, auf dem Bildschirm ein leuchtendes Raster aus kleinen abgerundeten Kacheln.
- **CouchRemote**: eine schlanke Fernbedienung bzw. ein Trackpad-Rechteck mit einem leuchtenden Punkt (Finger/Cursor), dazu dieselbe Sofa- oder Kachel-Andeutung, damit die Verbindung klar ist.
- Keine Schrift, keine Buchstaben, keine fremden Marken oder Logos (kein Apple-Logo, kein Netflix etc.), keine Fotos realer Produkte.
- Gut erkennbar auch klein (32 px): wenige, klare Formen.

## Technische Vorgaben
1. `Design/Icons/CouchHost-1024.png`: 1024×1024 px, macOS-Stil: abgerundetes Quadrat („Squircle“, Eckradius ca. 185 px) mit ca. 824×824 px Fläche zentriert, **transparenter Rand** rundherum, leichter Schatten unter der Form erlaubt.
2. `Design/Icons/CouchRemote-1024.png`: 1024×1024 px, iOS-Stil: **randlos, quadratisch, komplett deckend** (keine Transparenz, keine eigenen abgerundeten Ecken, iOS rundet selbst ab).

## Vorgehen
- Wenn du ein Werkzeug zur Bilderzeugung hast, nutze es und speichere die Ergebnisse an den Pfaden oben (bei Bedarf mit `sips` auf 1024×1024 bringen; für CouchHost den transparenten Rand und die Squircle-Maske sicherstellen).
- Sonst zeichne die Icons mit Code: ein Swift-Skript mit AppKit/CoreGraphics (`swift Design/make-icons.swift`), keine Downloads, keine zusätzlichen Pakete. Lege das Skript unter `Design/make-icons.swift` ab, damit man es später anpassen kann.
- Prüfe am Ende mit `sips -g pixelWidth -g pixelHeight -g hasAlpha`, dass beide Dateien existieren und die Vorgaben erfüllen.
- Ändere keine anderen Dateien im Projekt.
