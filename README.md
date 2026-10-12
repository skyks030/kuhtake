# Kuhtake

macOS-Menüleisten-App fürs Filmset: filmt den Live-Feed eines Fensters (z. B. Teradek-Viewer) oder eines ganzen Bildschirms ab, nimmt per Knopfdruck oder automatisch auf und legt die Clips sauber benannt nach Szene / Shot / Take ab.

## Funktionen

- **Lebt nur in der Menüleiste** – kein Dock-Icon.
- **Quelle wählen**: Fenster oder Bildschirme mit Vorschaubild. Die gewählte Quelle wird dauerhaft im Hintergrund mitgeschnitten (Vorschau), aber erst bei „Aufnahme“ gespeichert. Wird das Fenster geschlossen (z. B. Viewer neu gestartet), verbindet sich Kuhtake automatisch wieder.
- **Aufnahme starten/stoppen**: im Menü, per **⌘-Klick** (oder ⌥-Klick) auf das Menüleisten-Symbol oder global mit **⌃⌥⌘R**.
- **Kuh in der Menüleiste**: im Ruhezustand eine kleine Kuh, während der Aufnahme eine rote, pulsierende Kuh mit „REC“.
- **Auto-Aufnahme**: In der Live-Vorschau ein Rechteck oder einen Kreis (z. B. über die REC-Anzeige der Kamera) ziehen und skalieren. Weicht der Bereich deutlich vom gespeicherten Ruhezustand ab, startet die Aufnahme; kehrt er zurück, stoppt sie. Mit fein einstellbarem Regler für die Empfindlichkeit, Start-/Stopp-Verzögerung (gegen blinkende Anzeigen) und Live-Pegel.
- **Benennung**: Nach jedem Clip erscheint (abschaltbar) ein Dialog für Szene (frei), Shot und Take (zweistellig). Der Take zählt automatisch hoch; wird Shot oder Szene geändert, beginnt der Take wieder bei 01. Ist der Dialog aus, wird automatisch weitergezählt.
  Ablage: `<Arbeitsordner>/SC<Szene>/SC<Szene>_SH<Shot>_TK<Take>.mov`
- **Dateiformat**: H.264, HEVC, ProRes 422 Proxy/LT/422/HQ · MOV oder MP4 · native Auflösung oder 720p/1080p/2160p mit schwarzen Balken · 23.976–60 fps · Datenrate. Dateien haben eine konstante Bildrate.
- **Ton der Quelle** wird direkt aus der App abgegriffen (ScreenCaptureKit), auch wenn der Mac stumm ist.
- **Auto-Update**: Beim Start wird auf GitHub nach einer neuen Version gesucht. „Jetzt installieren“ lädt sie, ersetzt die App und startet sie neu.

## Installation

1. Neueste `Kuhtake-x.y.z.dmg` unter [Releases](../../releases) laden, `Kuhtake.app` nach *Programme* ziehen.
2. Beim ersten Start fragt Kuhtake nach der Berechtigung **Bildschirm- & Systemaudioaufnahme** → erlauben, danach Kuhtake neu starten (macOS verlangt das).

> Die App ist nicht notarisiert. Falls macOS den Start blockiert: Rechtsklick → *Öffnen*, oder `xattr -dr com.apple.quarantine /Applications/Kuhtake.app`.

Voraussetzung: macOS 14 Sonoma oder neuer.

## Entwicklung

```bash
swift build                 # Debug-Build
scripts/build-app.sh        # build/Kuhtake.app (universal, signiert)
open build/Kuhtake.app
```

Signiert wird automatisch mit der ersten „Apple Development“-Identität im Schlüsselbund (sonst ad-hoc), überschreibbar mit `SIGN_IDENTITY=…`. Eine stabile Signatur sorgt dafür, dass die Bildschirmaufnahme-Berechtigung nach Updates erhalten bleibt.

### Neue Version veröffentlichen

```bash
scripts/release.sh 1.1.0 "Was ist neu"
```

Das Skript setzt `VERSION`, baut die App, erstellt `Kuhtake-1.1.0-macOS.zip` (für den Updater) und `Kuhtake-1.1.0.dmg`, taggt `v1.1.0` und legt das GitHub-Release an. Alle installierten Kuhtake-Apps bieten das Update beim nächsten Start an.

## Aufbau

| Datei | Aufgabe |
|---|---|
| `CaptureEngine.swift` | ScreenCaptureKit-Stream der gewählten Quelle (Video + Audio) |
| `Recorder.swift` | AVAssetWriter, Letterboxing, konstante Bildrate |
| `MotionDetector.swift` | Bereichsüberwachung für die Auto-Aufnahme |
| `AppController.swift` | Koordination: Quelle, Aufnahme, Auto-Trigger, Ablage |
| `StatusMenuController.swift` | Menüleisten-Symbol und Menü |
| `ClipNaming.swift`, `NamingPanel.swift` | Szene/Shot/Take-Logik und Dialog |
| `Updater.swift` | GitHub-Release-Check und Selbst-Update |
| `CowArt.swift` | Die Kuh: App-Icon, Menüleisten-Symbol, Illustrationen |
