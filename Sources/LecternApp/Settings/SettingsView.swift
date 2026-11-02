import AppKit
import LecternCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            AISettingsTab().tabItem { Label("Claude", systemImage: "sparkles") }
            RulesTab().tabItem { Label("Card rules", systemImage: "text.book.closed") }
            UsageTab().tabItem { Label("API usage", systemImage: "dollarsign.circle") }
            LibraryTab().tabItem { Label("Library", systemImage: "books.vertical") }
        }
        .scenePadding()
    }
}

// MARK: - Claude backend

private struct AISettingsTab: View {
    @Environment(AppModel.self) private var model
    @State private var draft = AISettings.default
    @State private var apiKey = ""
    @State private var message: String?
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                Picker("Backend", selection: $draft.backend) {
                    Text("Claude CLI (your subscription)").tag(AIBackend.claudeCLI)
                    Text("Anthropic API (API key, billed per token)").tag(AIBackend.messagesAPI)
                }
                .pickerStyle(.radioGroup)
                Text("Every job records the backend and model it used. Lectern never falls back to another backend on its own.")
                    .font(Theme.small).foregroundStyle(Theme.quiet)
            }
            Section("Claude CLI") {
                TextField("Model", text: $draft.cliModel, prompt: Text(AISettings.defaultCLIModel))
                HStack {
                    TextField("CLI path", text: Binding(get: { draft.claudeCLIPath ?? "" }, set: { draft.claudeCLIPath = $0.isEmpty ? nil : $0 }),
                              prompt: Text(ClaudeCLIProvider.resolveExecutable(configuredPath: nil).path))
                    Button("Choose…") { chooseCLI() }
                }
                let resolved = ClaudeCLIProvider.resolveExecutable(configuredPath: draft.claudeCLIPath)
                let found = FileManager.default.isExecutableFile(atPath: resolved.path)
                Label(found ? "Found at \(resolved.path)" : "Not found at \(resolved.path)", systemImage: found ? "checkmark.circle" : "xmark.circle")
                    .font(Theme.small).foregroundStyle(found ? Theme.good : Theme.bad)
                Text("Sign in once in Terminal with `claude auth login` using an ordinary Claude Pro/Max/Team/Enterprise account. Lectern runs the unmodified CLI and never reads its login. Extra-usage credits on your account can still be charged after included limits.")
                    .font(Theme.small).foregroundStyle(Theme.quiet).fixedSize(horizontal: false, vertical: true)
            }
            Section("Anthropic API") {
                TextField("Model", text: $draft.messagesAPIModel, prompt: Text(AISettings.defaultMessagesAPIModel))
                TextField("API version", text: $draft.messagesAPIVersion)
                Stepper("Max output tokens: \(draft.maxOutputTokens)", value: $draft.maxOutputTokens, in: 256...128_000, step: 1024)
                HStack {
                    SecureField(model.apiKeySaved ? "Key saved in Keychain. Paste to replace." : "Paste an API key", text: $apiKey)
                    Button("Save key") { saveKey() }.disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    if model.apiKeySaved { Button("Remove", role: .destructive) { removeKey() } }
                }
                Text("The key is stored only in your macOS Keychain, never in Lectern's files.")
                    .font(Theme.small).foregroundStyle(Theme.quiet)
            }
            if let message { Text(message).font(Theme.small).foregroundStyle(Theme.good) }
            if let error { Text(error).font(Theme.small).foregroundStyle(Theme.bad) }
            HStack {
                Spacer()
                Button("Revert") { draft = model.settings; message = nil }.disabled(draft == model.settings)
                Button("Save") { Task { await save() } }.keyboardShortcut(.defaultAction).disabled(draft == model.settings)
            }
        }
        .formStyle(.grouped)
        .onAppear { if !loaded { draft = model.settings; loaded = true } }
    }

    private func save() async {
        do {
            try await model.updateSettings(draft)
            message = "Saved. New jobs use these settings; running jobs keep theirs."
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func chooseCLI() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.message = "Choose the claude executable"
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url { draft.claudeCLIPath = url.path }
    }

    private func saveKey() {
        do {
            try model.keychain.saveAPIKey(apiKey)
            apiKey = ""
            model.refreshAPIKeyState()
            message = "API key saved in Keychain."
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func removeKey() {
        do {
            try model.keychain.deleteAPIKey()
            model.refreshAPIKeyState()
            message = "API key removed."
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: - Rules

private struct RulesTab: View {
    @Environment(AppModel.self) private var model
    @State private var saved = ""
    @State private var draft = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Global card rules").font(.system(size: 14, weight: .semibold))
                Text("version \(String(PromptBuilder.hash(saved).prefix(8)))").font(Theme.caption.monospaced()).foregroundStyle(Theme.faint)
                Spacer()
            }
            Text("Sent with every Generate and revision. Module instructions come after these, and slide notes win over both. Every job records the rules version it used.")
                .font(Theme.small).foregroundStyle(Theme.quiet)
            TextEditor(text: $draft)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.borderStrong))
            if let error { Text(error).font(Theme.small).foregroundStyle(Theme.bad) }
            HStack {
                Text("Stored at \(model.store.rootURL.appendingPathComponent("rules.md").path)").font(Theme.caption).foregroundStyle(Theme.faint).lineLimit(1)
                Spacer()
                Button("Revert") { draft = saved }.disabled(draft == saved)
                Button("Save rules") { Task { await save() } }.keyboardShortcut("s", modifiers: .command).disabled(draft == saved)
            }
        }
        .task { await load() }
    }

    private func load() async {
        do { saved = try await model.store.loadRules(); draft = saved }
        catch { self.error = error.localizedDescription }
    }

    private func save() async {
        do {
            try await model.store.saveRules(draft)
            saved = draft
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: - API usage

private struct UsageTab: View {
    @Environment(AppModel.self) private var model
    @State private var summary: APICostSummary?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Anthropic API spend").font(.system(size: 14, weight: .semibold))
            if let summary {
                Text(Format.usd(summary.totalUSD)).font(Theme.serif(34))
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                    GridRow { Text("Reported by the API"); Text(Format.usd(summary.reportedUSD)).monospacedDigit() }
                    GridRow { Text("Estimated from tokens"); Text(Format.usd(summary.estimatedUSD)).monospacedDigit() }
                    GridRow { Text("Jobs without a price"); Text("\(summary.unpricedJobs)").monospacedDigit() }
                    GridRow { Text("Input tokens"); Text(summary.inputTokens.formatted()).monospacedDigit() }
                    GridRow { Text("Output tokens"); Text(summary.outputTokens.formatted()).monospacedDigit() }
                }
                .font(Theme.body)
                Text("Covers API-key jobs only. Claude CLI jobs run on your subscription and aren't counted. Estimates use published prices current on 2 Nov 2026 and are not an invoice; failed or cancelled requests can still be charged without usage data.")
                    .font(Theme.small).foregroundStyle(Theme.quiet).fixedSize(horizontal: false, vertical: true)
            } else if let error {
                Text(error).foregroundStyle(Theme.bad)
            } else {
                ProgressView()
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await load() }
    }

    private func load() async {
        do {
            var jobs: [Job] = []
            for module in try await model.store.modules() {
                for lecture in try await model.store.lectures(in: module.id) { jobs += lecture.jobs }
            }
            summary = APIPricing.summarize(jobs)
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: - Library

private struct LibraryTab: View {
    @Environment(AppModel.self) private var model
    @State private var result: String?
    @State private var working = false

    var body: some View {
        Form {
            Section("Library folder") {
                Text(model.store.rootURL.path).font(Theme.small.monospaced()).textSelection(.enabled)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.store.rootURL]) }
                Text("PDFs are private copies inside this folder, so lectures keep working after the originals move.")
                    .font(Theme.small).foregroundStyle(Theme.quiet)
            }
            Section("Import from the earlier apps") {
                Text("Your own Slide Learning and Flashcard Reviewer data was imported when Lectern first opened. Use these for a friend's exported folders or a backup. Originals are read, never changed; importing the same path twice skips what's already there.")
                    .font(Theme.small).foregroundStyle(Theme.quiet).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Import Slide Learning folder…") { Task { await importSlides() } }
                    Button("Import reviewer sessions.json…") { Task { await importReviewer() } }
                }
                .disabled(working)
                if working { ProgressView().controlSize(.small) }
                if let result { Text(result).font(Theme.small).textSelection(.enabled) }
            }
        }
        .formStyle(.grouped)
    }

    private func importSlides() async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose the Slide Learning folder that contains Projects"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        working = true; defer { working = false }
        // Keep security-scoped access alive for the whole import.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        report(await LegacyImporter(store: model.store).importProjects(from: url))
    }

    private func importReviewer() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Choose a Flashcard Reviewer sessions.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        working = true; defer { working = false }
        report(await LegacyImporter(store: model.store).importReviewer(from: url))
    }

    private func report(_ report: MigrationReport) {
        var lines = ["Imported \(report.imported.count), already imported \(report.skipped.count), failed \(report.failures.count)."]
        lines += report.failures.map { "\($0.source): \($0.message)" }
        result = lines.joined(separator: "\n")
        model.scheduleReload()
    }
}
