import SwiftUI

struct KeyboardShortcutsTab: View {
    var body: some View {
        Form {
            Section("App") {
                shortcut("Settings", "⌘,")
                shortcut("Overview", "⌘0")
                shortcut("New module", "⌘⇧N")
            }
            Section {
                shortcut("Toggle AI chat", "⌘⇧A")
                shortcut("New chat", "⌘N")
                shortcut("Toggle Cards in Prepare / Source in Review", "⌘⇧S")
                Text("These work while typing in a lecture. Press the shortcut again to hide the active pane. Switching tabs keeps the pane open. ⌘A keeps its usual Select All behavior.")
                    .font(Theme.small).foregroundStyle(Theme.quiet)
                shortcut("Prepare / Coverage / Review", "⌘1 / ⌘2 / ⌘3")
                shortcut("Generate cards", "⌘G")
                shortcut("Toggle right pane", "⌘⌥B")
            } header: { Text("Lecture workspace") }
            Section("Prepare · outside text fields") {
                shortcut("Previous / next slide", "← ↑ / → ↓")
                shortcut("Use slide for cards", "Space")
                shortcut("Toggle thumbnails", "⌘B")
                shortcut("Toggle notes", "⌘J")
                shortcut("Open AI chat", "A")
            }
            Section("Review · outside text fields") {
                shortcut("Previous / next card", "← ↑ J / → ↓ K")
                shortcut("Good / Bad / Needs work", "1 / 2 / 3")
                shortcut("Accept proposal", "Return")
                shortcut("Accept and mark Good", "⇧Return")
                shortcut("Discard proposal", "X")
                shortcut("Undo last verdict or edit", "U")
                shortcut("Open source / cycle source slides", "S")
                shortcut("Enlarge source slide", "Space")
                shortcut("Switch Browse / Test", "T")
                shortcut("Show answer (Test)", "Space")
                shortcut("Open source in Prepare", "G")
                shortcut("Edit card front", "E")
                shortcut("Open AI chat", "A")
            }
            Section("Chat and feedback") {
                shortcut("Send", "Return / ⌘Return")
                shortcut("New line", "⇧Return")
                shortcut("Attach context in chat", "@")
                shortcut("Navigate / select context", "↑ ↓ / Return")
                shortcut("Paste an image into chat", "⌘V")
                shortcut("Dismiss context picker / leave text field", "Esc")
            }
            Section("Pane dividers") {
                shortcut("Resize focused divider", "← / →")
                Text("Drag to resize; drag past the minimum to hide. Double-click to reset the width.")
                    .font(Theme.small).foregroundStyle(Theme.quiet)
            }
        }
        .formStyle(.grouped)
    }

    private func shortcut(_ title: String, _ keys: String) -> some View {
        LabeledContent(title) {
            Text(keys).font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Theme.inset, in: RoundedRectangle(cornerRadius: 4))
        }
    }
}
