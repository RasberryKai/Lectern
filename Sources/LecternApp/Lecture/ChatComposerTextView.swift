import AppKit
import SwiftUI

/// NSTextView keeps normal editing/selection while giving Return one unambiguous meaning.
struct ChatComposerTextView: NSViewRepresentable {
    static func owns(_ responder: NSResponder?) -> Bool { responder is ComposerEditor }
    @Binding var text: String
    @Binding var height: CGFloat
    var focused: Bool
    var editable: Bool
    var maximumHeight: CGFloat
    var onFocus: (Bool) -> Void
    var onSend: () -> Void
    var onMenuKey: (UInt16) -> Bool
    var onImages: ([ChatImageInput]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        let editor = ComposerEditor()
        editor.delegate = context.coordinator
        editor.font = .systemFont(ofSize: 13.5)
        editor.textColor = .labelColor
        editor.backgroundColor = .clear
        editor.drawsBackground = false
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.textContainerInset = NSSize(width: 5, height: 7)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        scroll.documentView = editor
        // The enclosing right pane owns image drops, including over this editor.
        editor.unregisterDraggedTypes()
        editor.registerForDraggedTypes([.string])
        editor.receiveImages = { [weak coordinator = context.coordinator] images in
            coordinator?.parent.onImages(images)
        }
        editor.focusChanged = { [weak coordinator = context.coordinator] focused in
            coordinator?.parent.onFocus(focused)
        }
        editor.command = { [weak coordinator = context.coordinator, weak editor] event in
            guard let coordinator else { return false }
            if (event.keyCode == 36 || event.keyCode == 76), event.modifierFlags.contains(.shift) { return false }
            if coordinator.parent.onMenuKey(event.keyCode) { return true }
            if event.keyCode == 36 || event.keyCode == 76 {
                coordinator.parent.onSend(); return true
            }
            if event.keyCode == 53 { editor?.window?.makeFirstResponder(nil); coordinator.parent.onFocus(false); return true }
            return false
        }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? ComposerEditor else { return }
        if editor.string != text { editor.string = text }
        editor.isEditable = editable
        editor.unregisterDraggedTypes()
        editor.registerForDraggedTypes([.string])
        editor.wantsFocus = focused
        editor.focusIfNeeded()
        context.coordinator.resize(editor)
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatComposerTextView
        init(_ parent: ChatComposerTextView) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string; resize(editor)
        }
        func resize(_ editor: NSTextView) {
            guard let container = editor.textContainer, let layout = editor.layoutManager else { return }
            layout.ensureLayout(for: container)
            let next = min(parent.maximumHeight, max(76, layout.usedRect(for: container).height + 18))
            if abs(parent.height - next) > 1 { DispatchQueue.main.async { self.parent.height = next } }
        }
    }
}
private final class ComposerEditor: NSTextView {
    var wantsFocus = false
    var command: ((NSEvent) -> Bool)?
    var focusChanged: ((Bool) -> Void)?
    var receiveImages: (([ChatImageInput]) -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusIfNeeded()
    }
    func focusIfNeeded() {
        guard wantsFocus, isEditable else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.wantsFocus, self.isEditable,
                  let window = self.window, window.firstResponder !== self else { return }
            window.makeFirstResponder(self)
        }
    }
    override func paste(_ sender: Any?) {
        let images = ChatImageInput.images(on: .general)
        if isEditable, !images.isEmpty { receiveImages?(images); return }
        super.paste(sender)
    }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { focusChanged?(true) }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { focusChanged?(false) }
        return accepted
    }
    override func keyDown(with event: NSEvent) {
        if command?(event) == true { return }
        super.keyDown(with: event)
    }
}
