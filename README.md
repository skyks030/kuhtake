# Kuhtake

macOS-Menüleisten-App fürs Filmset: filmt den Live-Feed eines Fensters (z. B. Teradek-Viewer) oder eines ganzen Bildschirms ab, nimmt per Knopfdruck oder automatisch auf und legt die Clips sauber benannt nach Szene / Shot / Take ab.

## Funktionen

- **Vorschaufenster**: öffnet sich bei jedem Start und zeigt live, was gerade aufgenommen würde (volle Bildrate, Pegelanzeige, Verbindungsstatus). Solange ein Kuhtake-Fenster offen ist, hat die App ein Dock-Icon und eigene Menüs; sind alle zu, lebt sie nur in der Menüleiste.
- **Blackmagic DeckLink / UltraStudio**: Hardware-Eingänge nativ über das DeckLink SDK (nicht als Webcam) – Bild und Ton, automatische Formaterkennung. Die Verbindung wird jede Sekunde geprüft; Abstecken, Signalverlust, belegter Eingang oder hängender Stream führen zu automatischem Neuverbinden. Voraussetzung: Blackmagic Desktop Video.
- **File Browser (⌘F)**: indexiert den Arbeitsordner im Hintergrund, zeigt Szenen → Einstellungen → Takes, optional nur den letzten Take je Einstellung („Nur letzte Takes“). Takes lassen sich per Kontextmenü umbenennen, per Drag & Drop (oder „Verschieben nach“) in eine andere Einstellung bzw. Szene verschieben und mit ⌫ / ⌘⌫ in den Papierkorb legen – Dateien und Ordner werden dabei nach dem Namensschema umbenannt. Take auswählen und **1** / **2** drücken lädt ihn in Monitor 1 / 2, **Leertaste** spielt beide gemeinsam ab bzw. stoppt sie, **J / K / L** spielen rückwärts / stoppen / vorwärts (mehrmals drücken: 2×, 4×, 8×, angezeigt unten links im Monitor), die Playheads sind einzeln verschiebbar. Monitor 1 ist grün, Monitor 2 gelb umrandet; Takes, die gerade in einem Monitor laufen, sind in der Liste in derselben Farbe hinterlegt. Auf-/zugeklappte Ordner, Breite der Seitenleiste und Scroll-Position bleiben beim Wechsel ins Live-Bild erhalten. Monitor 2 lässt sich mit dem X schließen. **⌘R** zurück zum Live-Bild.
- **Take-Suche (⇧Leertaste)**: Suchleiste im Stil von Raycast – findet Takes nach Szene, Shot, Take, Name, Timecode (auch innerhalb eines Clips), Uhrzeit oder Länge (`90s`, `>2m`). Der beste Treffer ist vorausgewählt, **↩** springt im File Browser dorthin, **⌘1 / ⌘2** lädt ihn in einen Monitor.
- **Auto-Aufnahme-Knopf** neben REC schaltet die Auto-Aufnahme direkt ein und aus (Rechtsklick: einrichten).
- **Teradek Serv Pro / VUER**: Quelle „Teradek Vuer HDR“ – Kuhtake findet das Fenster der VUER-App selbst (auch nach einem Neustart von Vuer), nimmt es in voller Auflösung auf und schneidet den Videobereich automatisch heraus (anpassbar über „Bildausschnitt festlegen …“). Teradek-Encoder im Netzwerk werden per Bonjour angezeigt. Hintergrund: Serv Pro & Co. senden nur über Teradeks eigenes, undokumentiertes Protokoll (`_tdstream._tcp`, SRT-basiert) an VUER – RTSP/HLS bietet der Serv Pro nicht an.
- **Teradek-Netzwerkstream**: für Encoder mit RTSP-, MPEG-TS- oder HLS-Ausgang (Cube, Bond, Prism …) – Bild (H.264/HEVC) und Ton (AAC) werden nativ empfangen und mit VideoToolbox dekodiert. Eingabe als Encoder-IP (Kuhtake sucht den RTSP-Stream auf Port 554/8554 selbst), `rtsp://benutzer:passwort@IP/stream1`, `rtspu://…` (RTP über UDP), `udp://@:5000` (MPEG-TS an diesen Mac, auch Multicast), `tcp://IP:Port` oder `http://…/index.m3u8` (HLS, nur Bild). Verbindungsabbrüche werden automatisch neu verbunden; „Diagnose kopieren“ in den Einstellungen liefert das komplette Protokoll. Ein eingebauter Test-Encoder (`simulator://rtsp`, `simulator://rtsp-udp`, `simulator://ts`) erlaubt das Ausprobieren ohne Hardware.
- **Timecode**: Oben in der Live-Vorschau läuft der Timecode (HH:MM:SS:FF). Über das Stift-Symbol, die Einstellungen oder das Menü einen Rahmen über die Timecode-Einblendung der Kamera ziehen (z. B. Alexa-35-SDI-Overlay); Kuhtake liest ihn per Texterkennung, lässt ihn bildgenau weiterlaufen, filtert Fehllesungen und schreibt ihn als QuickTime-Timecode-Spur in jede neue .mov-Datei. Ohne erkannten Timecode: 00:00:00:00.
- **Einstellungen (⌘,)**: Allgemein, Quelle, Aufnahme, Auto-Aufnahme, Timecode, Benennung, Tastenkürzel – alle Kürzel frei belegbar (Klicken, Kombination drücken), wahlweise systemweit.
- **Quelle wählen**: Blackmagic-Eingänge, Fenster oder Bildschirme mit Vorschaubild. Die gewählte Quelle wird dauerhaft im Hintergrund mitgeschnitten (Vorschau), aber erst bei „Aufnahme“ gespeichert. Wird das Fenster geschlossen (z. B. Viewer neu gestartet), verbindet sich Kuhtake automatisch wieder.
- **Aufnahme starten/stoppen**: im Menü, per **⌘-Klick** (oder ⌥-Klick) auf das Menüleisten-Symbol oder global mit **⌃⌥⌘R**.
- **Kuh in der Menüleiste**: im Ruhezustand eine kleine Kuh, während der Aufnahme eine rote, pulsierende Kuh mit „REC“.
- **Auto-Aufnahme**: In der Live-Vorschau ein Rechteck oder einen Kreis (z. B. über die REC-Anzeige der Kamera) ziehen und skalieren. Weicht der Bereich deutlich vom gespeicherten Ruhezustand ab, startet die Aufnahme; kehrt er zurück, stoppt sie. Mit fein einstellbarem Regler für die Empfindlichkeit, Start-/Stopp-Verzögerung (gegen blinkende Anzeigen) und Live-Pegel.
- **Benennung**: Nach jedem Clip erscheint (abschaltbar) ein Dialog für Szene (frei), Shot und Take. Der Take zählt automatisch hoch; wird Shot oder Szene geändert, beginnt der Take wieder bei 01. Ist der Dialog aus, wird automatisch weitergezählt.
  Den nächsten Clip stellst du im Hauptfenster oben rechts ein (Klick auf den Namen). Unter Einstellungen → Benennung legst du die **Bezeichnungen** fest, die vor Szene, Shot und Take stehen (Standard `SC`, `SH`, `TK`), und das **Namensschema**, z. B. `{szene}/{szene}_{shot}_{take}` → `SC12A/SC12A_SH03_TK07.mov` (Standard), `{datum}/{szene}_{shot}_{take:3}` oder `{szene}_{shot}_{take}`. `/` trennt Ordner, `{take:3}` setzt die Stellenzahl. Der Source Browser erkennt vorhandene Dateien anhand derselben Bezeichnungen und desselben Schemas (Shot/Take ein- bis dreistellig) – eine ältere Ablage mit anderen Namen wird gefunden, sobald Bezeichnungen und Schema sie beschreiben.
- **Absturzsichere Aufnahme**: Jede Aufnahme wird während des Drehs unter `~/Movies/Kuhtake/Temp/Aufnahme_<Datum>.tmp` geschrieben, als fragmentierter Film (Fragment je Sekunde). Bricht sie ab (Absturz, Strom weg), reicht es, die Endung `.tmp` in `.mov` bzw. `.mp4` zu ändern; die Datei spielt dann bis etwa eine Sekunde vor dem Abbruch. Nach dem Benennen wird der Take in den Projektordner kopiert und dort geprüft (Größe, abspielbar, gleiche Länge). Die Temp-Datei bleibt mit dem Zusatz „(gesichert als …)“ liegen, bis die nächste Aufnahme startet. Nie gesicherte Aufnahmen werden nie automatisch gelöscht; beim Start weist Kuhtake auf sie hin. ⌘Q wartet, bis laufende Aufnahmen und Kopien fertig sind.
- **Dateiformat**: H.264, HEVC, ProRes 422 Proxy/LT/422/HQ · MOV oder MP4 · native Auflösung oder 720p/1080p/2160p mit schwarzen Balken · 23.976–60 fps · Datenrate. Dateien haben eine konstante Bildrate – auch bei Fenstern oder Bildschirmen, auf denen sich nichts bewegt (ScreenCaptureKit liefert dann keine neuen Bilder; Kuhtake wiederholt das letzte).
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

# Netzwerkstream ohne UI testen (ohne Adresse: eingebauter Test-Encoder), Exit-Code 0 = Bilder dekodiert
.build/debug/Kuhtake --stream-selftest [simulator://ts | rtsp://… | udp://@:5000] [Sekunden]
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
| `TeradekStream.swift` | Netzwerkstream-Eingang: Verbindungsaufbau, Stream-Suche, Neuverbinden, Dekodierung → Bild/Ton |
| `RTSPClient.swift`, `MPEGTS.swift`, `StreamCodecs.swift`, `StreamLog.swift` | RTSP/RTP/SDP, MPEG-TS-Demuxer, H.264/HEVC- und AAC-Decoder, Protokoll und Adressformat |
| `TeradekSimulator.swift` | Test-Encoder (RTSP-Server / MPEG-TS über UDP) und `--stream-selftest` |
| `FrameHub.swift` | Verteilt Bilder/Ton jeder Quelle an Recorder, Vorschau, Pegel |
| `PreviewWindow.swift`, `SourceBrowserView.swift`, `PlayerMonitor.swift` | Vorschaufenster, File Browser, Monitore |
| `ClipIndex.swift` | Hintergrund-Index der Takes im Arbeitsordner |
| `SettingsWindow.swift`, `Shortcuts.swift`, `ShortcutRecorder.swift`, `MainMenu.swift` | Einstellungen, Tastenkürzel, App-Menüs |
| `Recorder.swift` | AVAssetWriter, Letterboxing, konstante Bildrate |
| `MotionDetector.swift` | Bereichsüberwachung für die Auto-Aufnahme |
| `AppController.swift` | Koordination: Quelle, Aufnahme, Auto-Trigger, Ablage |
| `StatusMenuController.swift` | Menüleisten-Symbol und Menü |
| `ClipNaming.swift`, `NamingPanel.swift` | Szene/Shot/Take-Logik und Dialog |
| `Updater.swift` | GitHub-Release-Check und Selbst-Update |
| `CowArt.swift` | Die Kuh: App-Icon, Menüleisten-Symbol, Illustrationen |
