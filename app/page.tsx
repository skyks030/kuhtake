import Image from "next/image";
import { MenuBarDemo } from "@/components/MenuBarDemo";
import { getLatestRelease, REPO_URL, RELEASES_URL } from "@/lib/release";

const features = [
  { emoji: "🪟", title: "Fenster oder Bildschirm", text: "Teradek-Viewer, Monitor-App oder ganzer Desktop – mit Vorschaubild auswählen." },
  { emoji: "⏺️", title: "Ein Klick, ein Take", text: "Aufnahme im Menü, per ⌘-Klick auf die Kuh oder mit ⌃⌥⌘R starten." },
  { emoji: "👀", title: "Auto-Aufnahme", text: "Bereich über die REC-Anzeige der Kamera ziehen – Kuhtake startet und stoppt mit." },
  { emoji: "🏷️", title: "Szene · Shot · Take", text: "Nach jedem Clip kurz benennen oder einfach automatisch weiterzählen lassen." },
  { emoji: "🎞️", title: "Dein Format", text: "H.264, HEVC oder ProRes, native Auflösung oder 1080p mit Balken, 23.976–60 fps." },
  { emoji: "🔊", title: "Mit Ton", text: "Der Ton der Quelle wird direkt mitgeschnitten – auch wenn der Mac stumm ist." },
];

const steps = [
  { title: "Laden & reinziehen", text: "DMG öffnen, Kuhtake in den Programme-Ordner ziehen." },
  { title: "Erlauben", text: "Beim ersten Start die Bildschirmaufnahme erlauben und Kuhtake neu starten." },
  { title: "Quelle wählen", text: "Auf die Kuh in der Menüleiste klicken, Fenster wählen – fertig zum Drehen." },
];

function formatDate(iso: string | null) {
  if (!iso) return null;
  return new Date(iso).toLocaleDateString("de-DE", { day: "numeric", month: "long", year: "numeric" });
}

export default async function Home() {
  const release = await getLatestRelease();
  const date = formatDate(release.publishedAt);

  return (
    <main>
      <nav className="nav">
        <a href="#" className="nav-brand">
          <Image src="/kuhtake-icon.png" alt="" width={36} height={36} />
          Kuhtake
        </a>
        <a href={REPO_URL} className="nav-link">GitHub</a>
      </nav>

      <section className="hero">
        <div className="spots" aria-hidden />
        <div className="hero-inner">
          <Image src="/kuhtake-icon.png" alt="Kuhtake App-Icon: eine Kuh mit Aufnahmepunkt" width={200} height={200} priority className="hero-icon" />
          <h1>
            Muuh-tiviert
            <br />
            <span>jeden Take sichern.</span>
          </h1>
          <p className="lead">
            Kuhtake lebt in deiner Menüleiste, filmt den Live-Feed vom Set mit und legt jeden Clip sauber nach Szene, Shot
            und Take ab.
          </p>
          <div className="cta">
            <a className="button" href={release.dmgUrl}>
              <span aria-hidden>⬇</span> Für macOS laden
              {release.version && <span className="button-version">v{release.version}</span>}
            </a>
            <p className="cta-note">
              Kostenlos · macOS 14 oder neuer · Apple Silicon & Intel
              {date && <> · {date}</>}
            </p>
          </div>
          <MenuBarDemo />
        </div>
        <svg className="meadow" viewBox="0 0 1440 120" preserveAspectRatio="none" aria-hidden>
          <path d="M0 70 C 360 0, 720 130, 1080 50 S 1440 60, 1440 60 V120 H0 Z" />
        </svg>
      </section>

      <section className="section features">
        <h2>Alles, was die Herde braucht</h2>
        <div className="grid">
          {features.map((f) => (
            <article key={f.title} className="card">
              <span className="card-emoji" aria-hidden>{f.emoji}</span>
              <h3>{f.title}</h3>
              <p>{f.text}</p>
            </article>
          ))}
        </div>
      </section>

      <section className="section steps">
        <h2>In drei Schritten auf der Weide</h2>
        <ol>
          {steps.map((s, i) => (
            <li key={s.title}>
              <span className="step-number">{i + 1}</span>
              <div>
                <h3>{s.title}</h3>
                <p>{s.text}</p>
              </div>
            </li>
          ))}
        </ol>
        <p className="hint">
          Startet Kuhtake beim ersten Mal nicht? Rechtsklick auf die App → <em>Öffnen</em>. Updates holt sich Kuhtake danach
          von selbst.
        </p>
      </section>

      <footer className="footer">
        <p>
          Mit 🐄 gemacht · <a href={REPO_URL}>Quellcode auf GitHub</a> · <a href={RELEASES_URL}>Alle Versionen</a>
        </p>
      </footer>
    </main>
  );
}
