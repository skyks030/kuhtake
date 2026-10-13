import AppKit
import Carbon
import Combine

// MARK: - Key combination

/// A key plus modifiers, stored layout-independently as virtual key code.
struct KeyCombo: Codable, Hashable {
    var keyCode: UInt16
    /// `NSEvent.ModifierFlags` raw value (only ⌘ ⌥ ⌃ ⇧).
    var modifiers: UInt

    static let relevantModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    init(keyCode: Int, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = UInt16(keyCode)
        self.modifiers = modifiers.intersection(Self.relevantModifiers).rawValue
    }

    init?(event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        self.init(keyCode: Int(event.keyCode), modifiers: event.modifierFlags)
    }

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var carbonModifiers: UInt32 {
        var m = 0
        if flags.contains(.command) { m |= cmdKey }
        if flags.contains(.option) { m |= optionKey }
        if flags.contains(.control) { m |= controlKey }
        if flags.contains(.shift) { m |= shiftKey }
        return UInt32(m)
    }

    var isFunctionKey: Bool { KeyNames.functionKeys[Int(keyCode)] != nil }

    /// Plain letters would collide with typing – a shortcut needs ⌘, ⌥ or ⌃ (or is an F-key).
    var isValidShortcut: Bool {
        isFunctionKey || !flags.intersection([.command, .option, .control]).isEmpty
    }

    var modifierSymbols: String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s
    }

    var keyName: String { KeyNames.name(for: Int(keyCode)) }
    var display: String { modifierSymbols + keyName }

    /// For `NSMenuItem.keyEquivalent` (lowercase character or function-key character).
    var menuKeyEquivalent: String { KeyNames.menuEquivalent(for: Int(keyCode)) }

    /// Combinations the system or every Mac app already uses.
    static let reserved: Set<KeyCombo> = [
        KeyCombo(keyCode: kVK_ANSI_Q, modifiers: .command), KeyCombo(keyCode: kVK_ANSI_W, modifiers: .command),
        KeyCombo(keyCode: kVK_ANSI_H, modifiers: .command), KeyCombo(keyCode: kVK_ANSI_M, modifiers: .command),
        KeyCombo(keyCode: kVK_ANSI_C, modifiers: .command), KeyCombo(keyCode: kVK_ANSI_V, modifiers: .command),
        KeyCombo(keyCode: kVK_ANSI_X, modifiers: .command), KeyCombo(keyCode: kVK_ANSI_A, modifiers: .command),
        KeyCombo(keyCode: kVK_ANSI_Z, modifiers: .command), KeyCombo(keyCode: kVK_ANSI_Comma, modifiers: .command),
        KeyCombo(keyCode: kVK_Tab, modifiers: .command), KeyCombo(keyCode: kVK_Space, modifiers: .command),
    ]
}

enum KeyNames {
    static let functionKeys: [Int: (String, Int)] = [
        kVK_F1: ("F1", NSF1FunctionKey), kVK_F2: ("F2", NSF2FunctionKey), kVK_F3: ("F3", NSF3FunctionKey),
        kVK_F4: ("F4", NSF4FunctionKey), kVK_F5: ("F5", NSF5FunctionKey), kVK_F6: ("F6", NSF6FunctionKey),
        kVK_F7: ("F7", NSF7FunctionKey), kVK_F8: ("F8", NSF8FunctionKey), kVK_F9: ("F9", NSF9FunctionKey),
        kVK_F10: ("F10", NSF10FunctionKey), kVK_F11: ("F11", NSF11FunctionKey), kVK_F12: ("F12", NSF12FunctionKey),
        kVK_F13: ("F13", NSF13FunctionKey), kVK_F14: ("F14", NSF14FunctionKey), kVK_F15: ("F15", NSF15FunctionKey),
        kVK_F16: ("F16", NSF16FunctionKey), kVK_F17: ("F17", NSF17FunctionKey), kVK_F18: ("F18", NSF18FunctionKey),
        kVK_F19: ("F19", NSF19FunctionKey), kVK_F20: ("F20", NSF20FunctionKey),
    ]

    private static let special: [Int: (String, String)] = [
        kVK_Return: ("↩", "\r"), kVK_ANSI_KeypadEnter: ("⌤", "\u{3}"), kVK_Tab: ("⇥", "\t"), kVK_Space: ("Leertaste", " "),
        kVK_Delete: ("⌫", "\u{8}"), kVK_ForwardDelete: ("⌦", "\u{7f}"), kVK_Escape: ("⎋", "\u{1b}"),
        kVK_LeftArrow: ("←", String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))),
        kVK_RightArrow: ("→", String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))),
        kVK_UpArrow: ("↑", String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))),
        kVK_DownArrow: ("↓", String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))),
        kVK_Home: ("↖", String(Character(UnicodeScalar(NSHomeFunctionKey)!))),
        kVK_End: ("↘", String(Character(UnicodeScalar(NSEndFunctionKey)!))),
        kVK_PageUp: ("⇞", String(Character(UnicodeScalar(NSPageUpFunctionKey)!))),
        kVK_PageDown: ("⇟", String(Character(UnicodeScalar(NSPageDownFunctionKey)!))),
    ]

    static func name(for keyCode: Int) -> String {
        if let f = functionKeys[keyCode] { return f.0 }
        if let s = special[keyCode] { return s.0 }
        return character(for: keyCode)?.uppercased() ?? "#\(keyCode)"
    }

    static func menuEquivalent(for keyCode: Int) -> String {
        if let f = functionKeys[keyCode] { return String(Character(UnicodeScalar(f.1)!)) }
        if let s = special[keyCode] { return s.1 }
        return character(for: keyCode)?.lowercased() ?? ""
    }

    /// What the key types on the current keyboard layout (so ⌘Z shows as ⌘Z on a German keyboard, too).
    static func character(for keyCode: Int) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
                ?? TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> String? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeys: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            let s = String(utf16CodeUnits: chars, count: length)
            return s.trimmingCharacters(in: .controlCharacters).isEmpty ? nil : s
        }
    }
}

// MARK: - Actions

enum ShortcutAction: String, CaseIterable, Codable, CodingKeyRepresentable, Identifiable {
    case toggleRecording, startRecording, stopRecording, toggleAutoRecord
    case showPreview, sourceBrowser, liveView, chooseSource, nameNextClip

    var id: String { rawValue }

    var title: String {
        switch self {
        case .toggleRecording: return "Aufnahme starten / stoppen"
        case .startRecording: return "Aufnahme starten"
        case .stopRecording: return "Aufnahme stoppen"
        case .toggleAutoRecord: return "Auto-Aufnahme ein / aus"
        case .showPreview: return "Vorschaufenster zeigen"
        case .sourceBrowser: return "Source Browser öffnen"
        case .liveView: return "Zurück zum Live-Bild"
        case .chooseSource: return "Quelle wählen …"
        case .nameNextClip: return "Szene / Shot / Take festlegen …"
        }
    }

    var symbol: String {
        switch self {
        case .toggleRecording: return "record.circle"
        case .startRecording: return "play.circle"
        case .stopRecording: return "stop.circle"
        case .toggleAutoRecord: return "wand.and.rays"
        case .showPreview: return "rectangle.inset.filled"
        case .sourceBrowser: return "rectangle.split.3x1"
        case .liveView: return "dot.radiowaves.left.and.right"
        case .chooseSource: return "video.badge.plus"
        case .nameNextClip: return "number"
        }
    }

    enum Group: String, CaseIterable { case recording = "Aufnahme", view = "Vorschau & Browser", other = "Sonstiges" }

    var group: Group {
        switch self {
        case .toggleRecording, .startRecording, .stopRecording, .toggleAutoRecord: return .recording
        case .showPreview, .sourceBrowser, .liveView: return .view
        case .chooseSource, .nameNextClip: return .other
        }
    }

    /// ⌘F / ⌘R only make sense while a Kuhtake window is in front – globally they would steal "Find"/"Reload" everywhere.
    var allowsGlobal: Bool {
        switch self {
        case .sourceBrowser, .liveView: return false
        default: return true
        }
    }

    var defaultBinding: ShortcutBinding {
        switch self {
        case .toggleRecording: return .init(combo: KeyCombo(keyCode: kVK_ANSI_R, modifiers: [.control, .option, .command]), global: true)
        case .startRecording: return .init(combo: nil, global: true)
        case .stopRecording: return .init(combo: nil, global: true)
        case .toggleAutoRecord: return .init(combo: KeyCombo(keyCode: kVK_ANSI_A, modifiers: [.control, .option, .command]), global: true)
        case .showPreview: return .init(combo: KeyCombo(keyCode: kVK_ANSI_V, modifiers: [.control, .option, .command]), global: true)
        case .sourceBrowser: return .init(combo: KeyCombo(keyCode: kVK_ANSI_F, modifiers: .command), global: false)
        case .liveView: return .init(combo: KeyCombo(keyCode: kVK_ANSI_R, modifiers: .command), global: false)
        case .chooseSource: return .init(combo: KeyCombo(keyCode: kVK_ANSI_I, modifiers: [.command, .shift]), global: false)
        case .nameNextClip: return .init(combo: KeyCombo(keyCode: kVK_ANSI_N, modifiers: [.command, .shift]), global: false)
        }
    }

    @MainActor
    func perform() {
        let c = AppController.shared
        switch self {
        case .toggleRecording: c.toggleRecording()
        case .startRecording: c.startRecording()
        case .stopRecording: c.stopRecording()
        case .toggleAutoRecord: c.setAutoRecord(!c.settings.autoRecordEnabled)
        case .showPreview: PreviewWindow.show()
        case .sourceBrowser: PreviewWindow.show(mode: .browser)
        case .liveView: PreviewWindow.show(mode: .live)
        case .chooseSource: SourcePickerWindow.show()
        case .nameNextClip: NamingPanelController.shared.editNext()
        }
    }
}

struct ShortcutBinding: Codable, Equatable {
    var combo: KeyCombo?
    /// Works system-wide (also when another app is in front), not only in Kuhtake's windows.
    var global: Bool
}

extension AppSettings {
    /// Assigns `combo` to `action`; another action that had the same combination loses it (returned).
    @discardableResult
    func assign(_ combo: KeyCombo?, to action: ShortcutAction) -> ShortcutAction? {
        var displaced: ShortcutAction?
        var all = shortcuts
        if let combo {
            for other in ShortcutAction.allCases where other != action && shortcut(for: other).combo == combo {
                var b = shortcut(for: other)
                b.combo = nil
                all[other] = b
                displaced = other
            }
        }
        var b = shortcut(for: action)
        b.combo = combo
        all[action] = b
        shortcuts = all
        return displaced
    }

    func setGlobal(_ global: Bool, for action: ShortcutAction) {
        var b = shortcut(for: action)
        b.global = global && action.allowsGlobal
        shortcuts[action] = b
    }

    func resetShortcuts() {
        shortcuts = [:]
    }
}

// MARK: - System-wide shortcuts

/// Registers the global shortcuts with the system (Carbon hot keys – no Accessibility permission needed).
/// Re-registers automatically when the settings change.
final class HotKeyCenter: ObservableObject {
    static let shared = HotKeyCenter()

    /// Actions whose combination another app already registered.
    @Published private(set) var conflicts: Set<ShortcutAction> = []

    private var refs: [EventHotKeyRef] = []
    private var actionsByID: [UInt32: ShortcutAction] = [:]
    private var handler: EventHandlerRef?
    private var cancellable: AnyCancellable?
    private var suspended = false
    private static let signature = OSType(0x4B544B45) // 'KTKE'

    func start() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            DispatchQueue.main.async {
                guard let action = HotKeyCenter.shared.actionsByID[id.id] else { return }
                MainActor.assumeIsolated { action.perform() }
            }
            return noErr
        }, 1, &spec, nil, &handler)

        cancellable = AppSettings.shared.$shortcuts
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.register() }
    }

    /// While a shortcut is being recorded, the existing ones must not fire.
    func setSuspended(_ s: Bool) {
        suspended = s
        register()
    }

    private func register() {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs = []
        actionsByID = [:]
        guard !suspended else { return }

        var failed = Set<ShortcutAction>()
        let settings = AppSettings.shared
        for (index, action) in ShortcutAction.allCases.enumerated() {
            let b = settings.shortcut(for: action)
            guard b.global, action.allowsGlobal, let combo = b.combo else { continue }
            let id = UInt32(index + 1)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(combo.keyCode), combo.carbonModifiers,
                                             EventHotKeyID(signature: Self.signature, id: id),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
                actionsByID[id] = action
            } else {
                failed.insert(action)
            }
        }
        // Updated after the current SwiftUI update pass.
        DispatchQueue.main.async { self.conflicts = failed }
        MainMenu.rebuild()
    }
}
