import AppKit
import SwiftUI

/// Opens SwiftUI views in regular windows. While any of them is open, Kuhtake behaves like a normal app
/// (Dock icon and its own menus in the menu bar, ⌘, etc.); with all closed it lives in the status bar only.
final class WindowPresenter: NSObject, NSWindowDelegate {
    static let shared = WindowPresenter()
    private var windows: [String: NSWindow] = [:]
    private var onClose: [String: () -> Void] = [:]

    func show<V: View>(id: String, title: String, size: CGSize, resizable: Bool = false,
                       onClose: (() -> Void)? = nil, @ViewBuilder content: () -> V) {
        if bringToFront(id) { return }
        let hosting = NSHostingController(rootView: content())
        // Don't let SwiftUI resize the window on every content update (live preview).
        hosting.sizingOptions = resizable ? [.minSize] : [.preferredContentSize]
        present(id: id, title: title, size: size, resizable: resizable, controller: hosting, onClose: onClose)
    }

    /// Shows an existing window again; false if it isn't open.
    @discardableResult
    func bringToFront(_ id: String) -> Bool {
        guard let existing = windows[id] else { return false }
        updateActivationPolicy(opening: true)
        NSApp.activate(ignoringOtherApps: true)
        existing.makeKeyAndOrderFront(nil)
        return true
    }

    func window(_ id: String) -> NSWindow? { windows[id] }

    func present(id: String, title: String, size: CGSize, resizable: Bool, controller: NSViewController,
                 styleMask extra: NSWindow.StyleMask = [], autosaveName: String? = nil, onClose: (() -> Void)? = nil) {
        if bringToFront(id) { return }
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        style.formUnion(extra)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.title = title
        window.contentViewController = controller
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.identifier = NSUserInterfaceItemIdentifier(id)
        window.center()
        if let autosaveName { window.setFrameAutosaveName(autosaveName) }
        windows[id] = window
        if let onClose { self.onClose[id] = onClose }
        updateActivationPolicy(opening: true)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close(id: String) {
        windows[id]?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let id = window.identifier?.rawValue else { return }
        windows[id] = nil
        onClose.removeValue(forKey: id)?()
        DispatchQueue.main.async { self.updateActivationPolicy(opening: false) }
    }

    private func updateActivationPolicy(opening: Bool) {
        let wantsRegular = opening || !windows.isEmpty
        let policy: NSApplication.ActivationPolicy = wantsRegular ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if wantsRegular { MainMenu.rebuild() }
    }
}
