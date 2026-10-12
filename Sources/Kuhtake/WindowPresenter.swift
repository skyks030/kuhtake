import AppKit
import SwiftUI

/// Opens SwiftUI views in regular windows (the app itself has no Dock icon).
final class WindowPresenter: NSObject, NSWindowDelegate {
    static let shared = WindowPresenter()
    private var windows: [String: NSWindow] = [:]
    private var onClose: [String: () -> Void] = [:]

    func show<V: View>(id: String, title: String, size: CGSize, resizable: Bool = false,
                       onClose: (() -> Void)? = nil, @ViewBuilder content: () -> V) {
        NSApp.activate(ignoringOtherApps: true)
        if let existing = windows[id] {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.title = title
        window.contentViewController = NSHostingController(rootView: content())
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.identifier = NSUserInterfaceItemIdentifier(id)
        window.center()
        window.makeKeyAndOrderFront(nil)
        windows[id] = window
        if let onClose { self.onClose[id] = onClose }
    }

    func close(id: String) {
        windows[id]?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let id = window.identifier?.rawValue else { return }
        windows[id] = nil
        onClose.removeValue(forKey: id)?()
    }
}
