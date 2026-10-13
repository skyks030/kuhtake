# Kuhtake

macOS-Menüleisten-App fürs Filmset: filmt den Live-Feed eines Fensters (z. B. Teradek-Viewer) oder eines ganzen Bildschirms ab, nimmt per Knopfdruck oder automatisch auf und legt die Clips sauber benannt nach Szene / Shot / Take ab.

## Funktionen

- **Vorschaufenster**: öffnet sich bei jedem Start und zeigt live, was gerade aufgenommen würde (volle Bildrate, Pegelanzeige, Verbindungsstatus). Solange ein Kuhtake-Fenster offen ist, hat die App ein Dock-Icon und eigene Menüs; sind alle zu, lebt sie nur in der Menüleiste.
- **Blackmagic DeckLink / UltraStudio**: Hardware-Eingänge nativ über das DeckLink SDK (nicht als Webcam) – Bild und Ton, automatische Formaterkennung. Die Verbindung wird jede Sekunde geprüft; Abstecken, Signalverlust, belegter Eingang oder hängender Stream führen zu automatischem Neuverbinden. Voraussetzung: Blackmagic Desktop Video.
- **Source Browser (⌘F)**: indexiert den Arbeitsordner im Hintergrund, zeigt Szenen → Einstellungen → Takes, optional nur den letzten Take je Einstellung („Nur letzte Takes“). Takes lassen sich per Kontextmenü umbenennen, per Drag & Drop (oder „Verschieben nach“) in eine andere Einstellung bzw. Szene verschieben und mit ⌫ / ⌘⌫ in den Papierkorb legen – Dateien und Ordner werden dabei nach dem Namensschema umbenannt. Take auswählen und **1** / **2** drücken lädt ihn in Monitor 1 / 2, **Leertaste** spielt beide gemeinsam ab bzw. stoppt sie, die Playheads sind einzeln verschiebbar. Monitor 2 lässt sich mit dem X schließen. **⌘R** zurück zum Live-Bild.
- **Teradek Serv Pro / VUER**: Quelle „Teradek Vuer HDR“ – Kuhtake findet das Fenster der VUER-App selbst (auch nach einem Neustart von Vuer), nimmt es in voller Auflösung auf und schneidet den Videobereich automatisch heraus (anpassbar über „Bildausschnitt festlegen …“). Teradek-Encoder im Netzwerk werden per Bonjour angezeigt. Hintergrund: Serv Pro & Co. senden nur über Teradeks eigenes, undokumentiertes Protokoll (`_tdstream._tcp`, SRT-basiert) an VUER – RTSP/HLS bietet der Serv Pro nicht an.
- **Timecode**: Oben in der Live-Vorschau läuft der Timecode (HH:MM:SS:FF). Über das Stift-Symbol, die Einstellungen oder das Menü einen Rahmen über die Timecode-Einblendung der Kamera ziehen (z. B. Alexa-35-SDI-Overlay); Kuhtake liest ihn per Texterkennung, lässt ihn bildgenau weiterlaufen, filtert Fehllesungen und schreibt ihn als QuickTime-Timecode-Spur in jede neue .mov-Datei. Ohne erkannten Timecode: 00:00:00:00.
- **Einstellungen (⌘,)**: Allgemein, Quelle, Aufnahme, Auto-Aufnahme, Timecode, Benennung, Tastenkürzel – alle Kürzel frei belegbar (Klicken, Kombination drücken), wahlweise systemweit.
- **Quelle wählen**: Blackmagic-Eingänge, Fenster oder Bildschirme mit Vorschaubild. Die gewählte Quelle wird dauerhaft im Hintergrund mitgeschnitten (Vorschau), aber erst bei „Aufnahme“ gespeichert. Wird das Fenster geschlossen (z. B. Viewer neu gestartet), verbindet sich Kuhtake automatisch wieder.
- **Aufnahme starten/stoppen**: im Menü, per **⌘-Klick** (oder ⌥-Klick) auf das Menüleisten-Symbol oder global mit **⌃⌥⌘R**.
- **Kuh in der Menüleiste**: im Ruhezustand eine kleine Kuh, während der Aufnahme eine rote, pulsierende Kuh mit „REC“.
- **Auto-Aufnahme**: In der Live-Vorschau ein Rechteck oder einen Kreis (z. B. über die REC-Anzeige der Kamera) ziehen und skalieren. Weicht der Bereich deutlich vom gespeicherten Ruhezustand ab, startet die Aufnahme; kehrt er zurück, stoppt sie. Mit fein einstellbarem Regler für die Empfindlichkeit, Start-/Stopp-Verzögerung (gegen blinkende Anzeigen) und Live-Pegel.
- **Benennung**: Nach jedem Clip erscheint (abschaltbar) ein Dialog für Szene (frei), Shot und Take. Der Take zählt automatisch hoch; wird Shot oder Szene geändert, beginnt der Take wieder bei 01. Ist der Dialog aus, wird automatisch weitergezählt.
  Das **Namensschema** ist frei – direkt im Benennungsdialog oder in den Einstellungen, z. B. `SC{szene}/SC{szene}_SH{shot}_TK{take}` (Standard), `{datum}/S{szene}_E{shot}_T{take:3}` oder `{szene}-{shot}-{take}`. `/` trennt Ordner, `{take:3}` setzt die Stellenzahl. Der Source Browser erkennt vorhandene Dateien anhand desselben Schemas – eine ältere Ablage mit anderen Namen wird gefunden, sobald das Schema sie beschreibt (passt nur der Dateiname, reicht das auch).
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

## Website

Die Landingpage (Next.js) liegt im Hauptverzeichnis (`app/`, `components/`, `lib/`, `public/`). In Vercel einfach das Repo mit Branch `main` importieren – siehe [WEBSITE.md](WEBSITE.md).

## Aufbau

| Datei | Aufgabe |
|---|---|
| `CaptureEngine.swift` | ScreenCaptureKit-Stream der gewählten Quelle (Video + Audio) |
| `KuhtakeDeckLink/` | DeckLink-SDK-Anbindung (ObjC++): Geräteerkennung, Formaterkennung, Watchdog |
| `DeckLinkEngine.swift` | DeckLink-Eingang → Bild/Ton für Vorschau und Aufnahme |
| `FrameHub.swift` | Verteilt Bilder/Ton jeder Quelle an Recorder, Vorschau, Pegel |
| `PreviewWindow.swift`, `SourceBrowserView.swift`, `PlayerMonitor.swift` | Vorschaufenster, Source Browser, Monitore |
| `ClipIndex.swift` | Hintergrund-Index der Takes im Arbeitsordner |
| `SettingsWindow.swift`, `Shortcuts.swift`, `ShortcutRecorder.swift`, `MainMenu.swift` | Einstellungen, Tastenkürzel, App-Menüs |
| `Recorder.swift` | AVAssetWriter, Letterboxing, konstante Bildrate |
| `MotionDetector.swift` | Bereichsüberwachung für die Auto-Aufnahme |
| `AppController.swift` | Koordination: Quelle, Aufnahme, Auto-Trigger, Ablage |
| `StatusMenuController.swift` | Menüleisten-Symbol und Menü |
| `ClipNaming.swift`, `NamingPanel.swift` | Szene/Shot/Take-Logik und Dialog |
| `Updater.swift` | GitHub-Release-Check und Selbst-Update |
| `CowArt.swift` | Die Kuh: App-Icon, Menüleisten-Symbol, Illustrationen |
