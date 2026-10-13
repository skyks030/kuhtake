import AppKit
import SwiftUI

/// Click, press the key combination – done. ⎋ cancels, ⌫ removes the shortcut.
struct ShortcutRecorder: View {
    let action: ShortcutAction
    @ObservedObject private var settings = AppSettings.shared
    @State private var recording = false
    @State private var liveModifiers: NSEvent.ModifierFlags = []
    @State private var monitor: Any?
    @State private var problem: String?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            HStack(spacing: 4) {
                Button(action: toggleRecording) {
                    HStack(spacing: 6) {
                        if recording {
                            Circle().fill(Color.red).frame(width: 7, height: 7)
                                .opacity(0.9)
                            Text(liveModifiers.isEmpty ? "Tasten drücken …" : KeyCombo(keyCode: 0, modifiers: liveModifiers).modifierSymbols + " …")
                                .foregroundStyle(.secondary)
                        } else if let combo {
                            Text(combo.display)
                                .font(.system(.body, design: .rounded).weight(.medium))
                        } else {
                            Text("Kurzbefehl festlegen").foregroundStyle(.secondary)
                        }
                    }
                    .frame(minWidth: 150, minHeight: 22)
                    .padding(.horizontal, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(recording ? Color.accentColor.opacity(0.12) : Color.primary.opacity(hovering ? 0.09 : 0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(recording ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: recording ? 1.5 : 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .help(recording ? "⎋ abbrechen · ⌫ entfernen" : "Klicken und neue Tastenkombination drücken")

                Button {
                    stop()
                    settings.assign(nil, to: action)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .opacity(combo == nil || recording ? 0 : 1)
                .disabled(combo == nil || recording)
                .help("Kurzbefehl entfernen")
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.orange)
                    .transition(.opacity)
            }
        }
        .onDisappear(perform: stop)
    }

    private var combo: KeyCombo? { settings.shortcut(for: action).combo }

    private func toggleRecording() {
        recording ? stop() : start()
    }

    private func start() {
        problem = nil
        recording = true
        liveModifiers = []
        HotKeyCenter.shared.setSuspended(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .flagsChanged {
                liveModifiers = event.modifierFlags.intersection(KeyCombo.relevantModifiers)
                return nil
            }
            handle(event)
            return nil
        }
    }

    private func stop() {
        guard recording || monitor != nil else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        liveModifiers = []
        HotKeyCenter.shared.setSuspended(false)
    }

    private func handle(_ event: NSEvent) {
        let mods = event.modifierFlags.intersection(KeyCombo.relevantModifiers)
        if mods.isEmpty, event.keyCode == 53 { stop(); return }             // ⎋
        if mods.isEmpty, event.keyCode == 51 || event.keyCode == 117 {    // ⌫ ⌦
            settings.assign(nil, to: action)
            stop()
            return
        }
        guard let combo = KeyCombo(event: event) else { return }
        guard combo.isValidShortcut else {
            withAnimation { problem = "Bitte mit ⌘, ⌥ oder ⌃ kombinieren." }
            NSSound.beep()
            return
        }
        guard !KeyCombo.reserved.contains(combo) else {
            withAnimation { problem = "\(combo.display) ist von macOS belegt." }
            NSSound.beep()
            return
        }
        if let displaced = settings.assign(combo, to: action) {
            withAnimation { problem = "Von „\(displaced.title)“ übernommen." }
        } else {
            withAnimation { problem = nil }
        }
        stop()
    }
}
