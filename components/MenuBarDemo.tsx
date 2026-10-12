import { CowMark } from "./CowMark";

/** A fake macOS menu bar: the cow idles, then turns red and pulses while "recording". Pure CSS. */
export function MenuBarDemo() {
  return (
    <div className="menubar" aria-label="Kuhtake in der Menüleiste: Kuh im Ruhezustand, rote Kuh während der Aufnahme">
      <span className="menubar-app">Viewer</span>
      <span className="menubar-item">Ablage</span>
      <span className="menubar-item">Darstellung</span>
      <span className="menubar-spacer" />
      <span className="menubar-cow">
        <CowMark className="cow-idle" />
        <span className="cow-rec">
          <CowMark className="cow-rec-icon" />
          <span className="cow-rec-label">REC</span>
        </span>
      </span>
      <span className="menubar-item menubar-clock">Drehtag 3 · 14:07</span>
    </div>
  );
}
