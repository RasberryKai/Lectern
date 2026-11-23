import SwiftUI

struct KeyboardShortcutsTab: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Shortcuts").settingsHeading()
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 12) {
                        section("App", [
                            ("Settings", "⌘ ,"),
                            ("Overview", "⌘ 0"),
                            ("New module", "⌘ ⇧ N")
                        ])
                        section("Lecture workspace", [
                            ("Prepare / Coverage / Review", "⌘1  ⌘2  ⌘3"),
                            ("Generate cards", "⌘ G"),
                            ("Toggle AI chat", "⌘ ⇧ A"),
                            ("New chat", "⌘ N"),
                            ("Cards (Prepare) / Source (Review)", "⌘ ⇧ S"),
                            ("Toggle right pane", "⌘ ⌥ B")
                        ])
                        section("Prepare", [
                            ("Previous / next slide", "←  →"),
                            ("Use slide for cards", "Space"),
                            ("Toggle thumbnails", "⌘ B"),
                            ("Toggle notes", "⌘ J"),
                            ("Open AI chat", "A")
                        ])
                    }
                    VStack(spacing: 12) {
                        section("Review", [
                            ("Previous / next card", "←  →  or  J  K"),
                            ("Good / Bad", "1  2"),
                            ("Accept proposal", "↩"),
                            ("Accept and mark Good", "⇧ ↩"),
                            ("Discard proposal", "X"),
                            ("Undo", "U"),
                            ("Source slides", "S"),
                            ("Browse / Test", "T"),
                            ("Show answer (Test)", "Space"),
                            ("Edit card front", "E")
                        ])
                        section("Chat", [
                            ("Send", "↩"),
                            ("New line", "⇧ ↩"),
                            ("Attach context", "@"),
                            ("Paste an image", "⌘ V")
                        ])
                        section("Study", [
                            ("Show answer / enlarge source", "Space"),
                            ("Got it / Missed", "1  2"),
                            ("Open or cycle source slides", "S"),
                            ("Jump to slide in Prepare", "G"),
                            ("Open Ask AI", "A"),
                            ("Edit front / Disable / Undo", "E  D  U"),
                            ("End session", "Esc"),
                            ("Toggle AI chat / source", "⌘ ⇧ A  /  ⌘ ⇧ S"),
                            ("Toggle right pane", "⌘ ⌥ B")
                        ])
                    }
                }
            }
            .padding(.horizontal, 40).padding(.vertical, 32)
        }
    }

    private func section(_ title: String, _ shortcuts: [(action: String, keys: String)]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).eyebrow().accessibilityAddTraits(.isHeader)
            ForEach(shortcuts, id: \.action) { shortcut in
                HStack(alignment: .firstTextBaseline) {
                    Text(shortcut.action).font(Theme.small)
                    Spacer(minLength: 4)
                    Text(shortcut.keys)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.quiet)
                        .fixedSize()
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: 16)
    }
}
