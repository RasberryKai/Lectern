import AppKit
import SwiftUI

/// Keep native popup selection and keyboard behavior without macOS replacing our label.
struct SolveOptionPicker<Label: View>: View {
    @Binding var selection: String
    let options: [String]
    let label: String
    @ViewBuilder var content: () -> Label
    @State private var focused = false

    var body: some View {
        content()
            .accessibilityHidden(true)
            .overlay {
                NativePopup(selection: $selection, options: options, label: label, focused: $focused)
            }
            .overlay {
                if focused {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 2)
                        .padding(-3)
                        .allowsHitTesting(false)
                }
            }
    }

    private struct NativePopup: NSViewRepresentable {
        @Binding var selection: String
        let options: [String]
        let label: String
        @Binding var focused: Bool
        @Environment(\.isEnabled) private var isEnabled

        func makeNSView(context: Context) -> Popup {
            let popup = Popup(frame: .zero, pullsDown: false)
            popup.isBordered = false
            popup.isTransparent = true
            (popup.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
            popup.focusRingType = .none
            popup.font = .systemFont(ofSize: 17, weight: .medium)
            popup.target = context.coordinator
            popup.action = #selector(Coordinator.select(_:))
            popup.setContentHuggingPriority(.defaultLow, for: .horizontal)
            popup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return popup
        }

        func updateNSView(_ popup: Popup, context: Context) {
            context.coordinator.selection = $selection
            let titles = ["Choose…"] + options
            if popup.itemTitles != titles {
                popup.removeAllItems()
                popup.addItems(withTitles: titles)
            }
            popup.selectItem(at: options.firstIndex(of: selection).map { $0 + 1 } ?? 0)
            popup.isEnabled = isEnabled
            popup.setAccessibilityLabel(label)
            popup.onFocus = { focused = $0 }
        }

        func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

        final class Coordinator: NSObject {
            var selection: Binding<String>
            init(selection: Binding<String>) { self.selection = selection }

            @objc func select(_ sender: NSPopUpButton) {
                selection.wrappedValue = sender.indexOfSelectedItem == 0 ? "" : sender.titleOfSelectedItem ?? ""
            }
        }

        final class Popup: NSPopUpButton {
            var onFocus: ((Bool) -> Void)?
            override var acceptsFirstResponder: Bool { true }

            override func becomeFirstResponder() -> Bool {
                let accepted = super.becomeFirstResponder()
                if accepted { onFocus?(true) }
                return accepted
            }

            override func resignFirstResponder() -> Bool {
                let accepted = super.resignFirstResponder()
                if accepted { onFocus?(false) }
                return accepted
            }
        }
    }
}

/// Use the same columns for every row; long situations wrap within their column.
struct SolveMatchingRowLayout: Layout {
    private let gap: CGFloat = 32

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = max(180, proposal.width ?? 640)
        let sizes = sizes(width: width, subviews: subviews)
        return CGSize(width: width, height: width >= 420
            ? max(sizes[0].height, sizes[1].height)
            : sizes[0].height + 8 + sizes[1].height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = sizes(width: bounds.width, subviews: subviews)
        let horizontal = bounds.width >= 420
        subviews[0].place(at: CGPoint(x: bounds.minX, y: horizontal ? bounds.midY - sizes[0].height / 2 : bounds.minY),
                          proposal: ProposedViewSize(sizes[0]))
        subviews[1].place(at: CGPoint(x: horizontal ? bounds.maxX - sizes[1].width : bounds.minX,
                                     y: horizontal ? bounds.midY - sizes[1].height / 2 : bounds.minY + sizes[0].height + 8),
                          proposal: ProposedViewSize(sizes[1]))
    }

    private func sizes(width: CGFloat, subviews: Subviews) -> [CGSize] {
        let horizontal = width >= 420
        let pickerWidth = horizontal ? (width - gap) * 0.4 : width
        let labelWidth = horizontal ? width - gap - pickerWidth : width
        return [subviews[0].sizeThatFits(ProposedViewSize(width: labelWidth, height: nil)),
                subviews[1].sizeThatFits(ProposedViewSize(width: pickerWidth, height: nil))]
    }
}
