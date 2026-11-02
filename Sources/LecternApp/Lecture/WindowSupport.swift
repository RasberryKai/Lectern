import AppKit
import SwiftUI

/// Keeps a SwiftUI window open until an async save succeeds (FRONTEND_HANDOFF: close must
/// await `closeAndFlush()` and keep the window open if saving fails).
///
/// SwiftUI owns the window delegate, so this wraps it: `windowShouldClose` is answered here and
/// every other delegate message is forwarded to SwiftUI's original delegate.
struct WindowCloseGuard: NSViewRepresentable {
    let shouldClose: () async -> Bool

    func makeNSView(context: Context) -> CloseGuardView {
        let view = CloseGuardView()
        view.shouldClose = shouldClose
        return view
    }

    func updateNSView(_ view: CloseGuardView, context: Context) {
        view.shouldClose = shouldClose
        view.installIfNeeded()
    }
}

final class CloseGuardView: NSView {
    var shouldClose: (() async -> Bool)?
    private var proxy: WindowDelegateProxy?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installIfNeeded()
    }

    func installIfNeeded() {
        guard let window else { return }
        if let proxy, window.delegate === proxy { return }
        let next = WindowDelegateProxy(original: window.delegate)
        next.shouldClose = { [weak self] in await self?.shouldClose?() ?? true }
        proxy = next
        window.delegate = next
    }
}

final class WindowDelegateProxy: NSObject, NSWindowDelegate {
    /// Strong: NSWindow.delegate is weak and SwiftUI may only reference its delegate through the window.
    private let original: NSWindowDelegate?
    var shouldClose: (() async -> Bool)?
    private var allowClose = false
    private var saving = false

    init(original: NSWindowDelegate?) { self.original = original }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if allowClose { return original?.windowShouldClose?(sender) ?? true }
        guard !saving else { return false }
        saving = true
        Task { @MainActor [weak self, weak sender] in
            let ok = await self?.shouldClose?() ?? true
            guard let self else { return }
            self.saving = false
            if ok {
                self.allowClose = true
                sender?.performClose(nil)
            }
        }
        return false
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let original, original.responds(to: aSelector) { return original }
        return super.forwardingTarget(for: aSelector)
    }
}

/// One local key monitor per lecture window. Text editors keep normal typing, Space and arrows;
/// command shortcuts and Escape are seen first.
struct KeyMonitor: NSViewRepresentable {
    /// Return true when handled. `editingText` tells whether a text view has focus.
    let handler: (_ event: NSEvent, _ editingText: Bool) -> Bool

    func makeNSView(context: Context) -> KeyMonitorView {
        let view = KeyMonitorView()
        view.handler = handler
        return view
    }

    func updateNSView(_ view: KeyMonitorView, context: Context) { view.handler = handler }

    static func dismantleNSView(_ view: KeyMonitorView, coordinator: ()) { view.removeMonitor() }
}

final class KeyMonitorView: NSView {
    var handler: ((NSEvent, Bool) -> Bool)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { removeMonitor(); return }
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, let window = self.window, event.window === window,
                      window.attachedSheet == nil, NSApp.modalWindow == nil else { return false }
                let editing = Self.isEditingText(window.firstResponder)
                return self.handler?(event, editing) == true
            }
            return handled ? nil : event
        }
    }

    func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private static func isEditingText(_ responder: NSResponder?) -> Bool {
        var current = responder
        while let item = current {
            if item is NSTextView || item is NSTextField { return true }
            current = item.nextResponder
        }
        return false
    }
}

enum Key {
    static let returnKey: UInt16 = 36
    static let enter: UInt16 = 76
    static let escape: UInt16 = 53
    static let space: UInt16 = 49
    static let left: UInt16 = 123
    static let right: UInt16 = 124
    static let down: UInt16 = 125
    static let up: UInt16 = 126

    static func modifiers(_ event: NSEvent) -> NSEvent.ModifierFlags {
        event.modifierFlags.intersection([.command, .control, .option, .shift])
    }
    static func letter(_ event: NSEvent) -> String { event.charactersIgnoringModifiers?.lowercased() ?? "" }
    static func isReturn(_ event: NSEvent) -> Bool { event.keyCode == returnKey || event.keyCode == enter }

    /// Printable text without command/control, for "typing on a slide opens its note".
    static func printable(_ event: NSEvent) -> String? {
        guard event.modifierFlags.intersection([.command, .control]).isEmpty,
              let text = event.characters, !text.isEmpty,
              text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value) })
        else { return nil }
        return text
    }
}
