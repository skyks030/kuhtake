# Kuhtake Website

Kleine Landingpage (Next.js, Node.js) mit Infos und Download-Button. Der Button zeigt immer auf die DMG des neuesten GitHub-Releases (wird alle 5 Minuten neu abgefragt) – nach `scripts/release.sh` ist die Seite also automatisch aktuell.

## Lokal

```bash
cd website
npm install
npm run dev     # http://localhost:3000
```

## Auf Vercel

1. In Vercel *Add New → Project* → Repository `skyks030/kuhtake` importieren.
2. **Root Directory** auf `website` setzen (Framework „Next.js“ wird erkannt).
3. Deploy. Keine Umgebungsvariablen nötig.

Das App-Icon (`public/kuhtake-icon.png`, `app/icon.png`) wird aus `Sources/Kuhtake/CowArt.swift` erzeugt.
