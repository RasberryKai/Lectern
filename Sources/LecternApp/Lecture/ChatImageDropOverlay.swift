import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A native drop destination above the pane's WebKit and selectable text views.
/// AppKit routes drags by registered types independently of mouse hit testing.
struct ChatImageDropOverlay: NSViewRepresentable {
    let enabled: Bool
    @Binding var isTargeted: Bool
    let onImages: ([ChatImageInput]) -> Bool

    func makeNSView(context: Context) -> ChatImageDropView {
        let view = ChatImageDropView()
        view.registerForDraggedTypes([.fileURL, .png, .tiff, NSPasteboard.PasteboardType(UTType.image.identifier)])
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: ChatImageDropView, context: Context) {
        view.enabled = enabled
        view.onTargeted = { isTargeted = $0 }
        view.onImages = onImages
    }
}

final class ChatImageDropView: NSView {
    var enabled = false
    var onTargeted: (Bool) -> Void = { _ in }
    var onImages: ([ChatImageInput]) -> Bool = { _ in false }

    // Keep clicking, text selection, scrolling, and dragging text/images out intact.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateTarget(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateTarget(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { onTargeted(false) }
    override func draggingEnded(_ sender: any NSDraggingInfo) { onTargeted(false) }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        accepts(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        onTargeted(false)
        guard accepts(sender) else { return false }
        let images = ChatImageInput.images(on: sender.draggingPasteboard)
        return !images.isEmpty && onImages(images)
    }

    private func updateTarget(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let accepted = accepts(sender)
        onTargeted(accepted)
        return accepted ? .copy : []
    }

    private func accepts(_ sender: any NSDraggingInfo) -> Bool {
        guard enabled, sender.draggingSourceOperationMask.contains(.copy) else { return false }
        let pasteboard = sender.draggingPasteboard
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return files.contains { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
            || (pasteboard.types ?? []).contains { UTType($0.rawValue)?.conforms(to: .image) == true }
    }
}
