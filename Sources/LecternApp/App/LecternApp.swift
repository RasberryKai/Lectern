import AppKit
import LecternCore
import SwiftUI

@main
struct LecternApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("Lectern", id: "library") {
            LibraryWindow()
                .environment(model)
                .frame(minWidth: 1100, minHeight: 700)
                .task { await model.start() }
        }
        .defaultSize(width: 1320, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Module…") { model.showNewModule = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandGroup(after: .sidebar) {
                Button("Overview") { Task { await model.returnToLibrary(destination: .overview) } }
                    .keyboardShortcut("0", modifiers: [.command])
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .frame(width: 720, height: 620)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Running from `swift run` has no bundle; make it a regular foreground app with an icon.
        NSApp.setActivationPolicy(.regular)
        if Bundle.main.bundleIdentifier == nil, let icon = Self.fallbackIcon() { NSApp.applicationIconImage = icon }
        NSApp.activate()
        // Lecture windows restored without the library window still need the library opened.
        Task { await AppModel.shared.start() }
    }

    /// Lecture windows hold staged edits. Quit waits until every one has saved.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = AppModel.shared
        guard model.hasOpenLectureWindows else { return .terminateNow }
        Task { @MainActor in
            let saved = await model.closeAllLectureWindows()
            NSApp.reply(toApplicationShouldTerminate: saved)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private static func fallbackIcon() -> NSImage? {
        let size = NSSize(width: 512, height: 512)
        return NSImage(size: size, flipped: true) { rect in
            let inset = rect.insetBy(dx: rect.width * 0.098, dy: rect.height * 0.098)
            NSColor(hex: 0x3E5C41).setFill()
            NSBezierPath(roundedRect: inset, xRadius: inset.width * 0.225, yRadius: inset.width * 0.225).fill()
            let points: [CGPoint] = [.init(x: 50, y: 32), .init(x: 94, y: 32), .init(x: 94, y: 146.4),
                                     .init(x: 184.5, y: 94.2), .init(x: 206.5, y: 132.3), .init(x: 50, y: 222.6)]
            let k = rect.width / 1024 * 2.2
            let path = NSBezierPath()
            for (index, point) in points.enumerated() {
                let mapped = CGPoint(x: rect.width / 2 + (point.x - 128) * k, y: rect.height / 2 + (point.y - 127) * k)
                if index == 0 { path.move(to: mapped) } else { path.line(to: mapped) }
            }
            path.close()
            NSColor(hex: 0xF7F5EF).setFill()
            path.fill()
            return true
        }
    }
}
