import AppKit
import SwiftUI

/// Lays out the editable source at its full height inside the review stage.
struct CardSourceEditor: NSViewRepresentable {
    @Binding var text: String
    let label: String
    let size: CGFloat
    let emphasized: Bool
    let onBlur: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> SourceTextView {
        let editor = SourceTextView(frame: .zero)
        editor.delegate = context.coordinator
        editor.isRichText = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isVerticallyResizable = false
        editor.isHorizontallyResizable = false
        editor.textContainerInset = NSSize(width: 0, height: 4)
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = false
        editor.textContainer?.heightTracksTextView = false
        editor.setAccessibilityLabel(label)

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        editor.font = .systemFont(ofSize: size, weight: emphasized ? .semibold : .regular)
        editor.textColor = NSColor(Theme.ink)
        editor.defaultParagraphStyle = paragraph
        editor.typingAttributes[.paragraphStyle] = paragraph
        editor.onBlur = { [weak coordinator = context.coordinator] in coordinator?.parent.onBlur() }
        return editor
    }

    func updateNSView(_ editor: SourceTextView, context: Context) {
        context.coordinator.parent = self
        if editor.string != text { editor.string = text }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView editor: SourceTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite,
              let container = editor.textContainer, let layout = editor.layoutManager else { return nil }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        // TextKit lays out the insertion point after a trailing newline in a separate fragment.
        let height = max(layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY)
        return CGSize(width: width, height: ceil(max(height, size) + 2 * editor.textContainerInset.height))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CardSourceEditor

        init(_ parent: CardSourceEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }
    }

    final class SourceTextView: NSTextView {
        var onBlur: (() -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window else { return }
                window.makeFirstResponder(self)
            }
        }

        override func resignFirstResponder() -> Bool {
            guard super.resignFirstResponder() else { return false }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window?.firstResponder !== self else { return }
                self.onBlur?()
            }
            return true
        }
    }
}
