# Auftrag: App-Icons für CouchHost und CouchRemote (Version 2, flach)

Erstelle zwei App-Icons als PNG für ein privates Projekt. Arbeite nur im aktuellen Ordner.
Die erste Version (weiche Verläufe, Leuchten, 3D-Optik) wirkte generisch und „KI-generiert“.
Diese Version soll das Gegenteil sein: ein klares, flaches, handwerklich gestaltetes Icon-Paar.

## Die Apps
- **CouchHost** (macOS): verwandelt ein MacBook am Fernseher in eine TV-Box mit Startseite aus App-Kacheln.
- **CouchRemote** (iOS): das iPhone als Fernbedienung mit großem Trackpad für diesen Mac.

Die beiden Icons müssen klar als Paar erkennbar sein: gleiche Farben, gleiche Strichstärken, gleiche Eckradien.

## Stilregeln (verbindlich)
- **Flach.** Keine Verläufe, kein Glühen, keine Schatten, keine Spiegelungen, keine Texturen, kein 3D.
- **Höchstens drei Volltonfarben** pro Icon, in beiden Icons dieselben:
  - Hintergrund: ein tiefes, leicht warmes Dunkelblau, z. B. `#1E2235`
  - Hauptfarbe: warmes Off-White, z. B. `#F3EEE4`
  - Akzent: ein kräftiges Korall/Orange, z. B. `#FF6A3D` (sparsam, nur ein Element)
- Geometrische Grundformen (Rechtecke mit einheitlichem Eckradius, Kreise), wie ein gut gezeichnetes
  Piktogramm. Einheitliche Strichstärke, falls Konturen verwendet werden.
- Viel Luft: das Motiv nimmt etwa 55–65 % der Fläche ein, optisch zentriert.
- Keine Schrift, keine Buchstaben, keine fremden Marken oder Logos, keine Fotos.
- Muss auch bei 32 px und 16 px noch klar lesbar sein: wenige, große Formen.

## Motive
- **CouchHost**: ein Fernseher in Off-White (abgerundetes Rechteck mit kurzem Standfuß), auf dem
  Bildschirm ein Raster aus 2×3 kleinen abgerundeten Kacheln im Hintergrund-Blau. Genau eine Kachel
  (z. B. oben links) ist im Korall-Akzent – die „ausgewählte App“.
- **CouchRemote**: eine schlanke, hochkant stehende Fernbedienung in Off-White (abgerundetes Rechteck).
  Oben eine große Trackpad-Fläche im Hintergrund-Blau, darauf ein Kreis im Korall-Akzent (Finger/Cursor).
  Darunter zwei bis drei kleine runde Tasten im Hintergrund-Blau. Gleiche Eckradien und Proportionen
  wie der Fernseher bei CouchHost.

## Technische Vorgaben
1. `Design/Icons/CouchHost-1024.png`: 1024×1024 px, macOS-Stil: abgerundetes Quadrat („Squircle“,
   Eckradius ca. 185 px) mit 824×824 px Fläche zentriert, **transparenter Rand** rundherum, kein Schatten.
2. `Design/Icons/CouchRemote-1024.png`: 1024×1024 px, iOS-Stil: **randlos, quadratisch, komplett deckend**
   (keine Transparenz, keine eigenen abgerundeten Ecken, iOS rundet selbst ab).

## Vorgehen
- **Zeichne die Icons mit Code, nicht mit einem Bildgenerator**: ein Swift-Skript mit AppKit/CoreGraphics
  unter `Design/make-icons.swift`, ausgeführt mit `swift Design/make-icons.swift`. Keine Downloads,
  keine zusätzlichen Pakete. Alle Maße als benannte Konstanten oben im Skript, damit man später leicht
  nachjustieren kann.
- Kantenglättung an, exakte Geometrie, Pixel-Ausrichtung wo sinnvoll.
- Prüfe am Ende mit `sips -g pixelWidth -g pixelHeight -g hasAlpha`, dass beide Dateien existieren und
  die Vorgaben erfüllen. Sieh dir die Ergebnisse an, falls du Bilder ansehen kannst, und korrigiere
  Proportionen, bis sie ausgewogen wirken.
- Ändere keine anderen Dateien im Projekt außer `Design/make-icons.swift` und den beiden PNGs.
