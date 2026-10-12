# Kuhtake Website

Kleine Landingpage (Next.js, Node.js) mit Infos und Download-Button. Der Button zeigt immer auf die DMG des neuesten GitHub-Releases (wird alle 5 Minuten neu abgefragt) – nach `scripts/release.sh` ist die Seite also automatisch aktuell.

## Lokal

```bash
npm install
npm run dev     # http://localhost:3000
```

## Auf Vercel

1. In Vercel *Add New → Project* → Repository `skyks030/kuhtake` importieren (Branch `main`).
2. Alles auf Standard lassen – Next.js wird im Repo-Hauptverzeichnis erkannt.
3. Deploy. Keine Umgebungsvariablen nötig.

Die Website-Dateien (`app/`, `components/`, `lib/`, `public/`, `package.json`, `next.config.ts`) liegen bewusst im Hauptverzeichnis neben dem Swift-Paket, damit Vercel ohne Root-Directory-Einstellung baut.

Das App-Icon (`public/kuhtake-icon.png`, `app/icon.png`) wird aus `Sources/Kuhtake/CowArt.swift` erzeugt.
