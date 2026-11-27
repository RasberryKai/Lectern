import AppKit
import LecternCore
import SwiftUI

private enum SettingsSection: String, CaseIterable {
    case ai = "AI", rules = "Card rules", study = "Study", usage = "AI usage", library = "Library", shortcuts = "Shortcuts"

    var icon: String {
        switch self {
        case .ai: "sparkles"
        case .rules: "text.book.closed"
        case .study: "rectangle.on.rectangle"
        case .usage: "chart.bar"
        case .library: "books.vertical"
        case .shortcuts: "keyboard"
        }
    }
}

enum AppAppearance: String, CaseIterable {
    case system = "System", light = "Light", dark = "Dark"

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("lectern.appearance") private var appearance = AppAppearance.system
    @State private var selected = SettingsSection.ai
    @State private var visited: Set<SettingsSection> = [.ai]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button { model.showSettings = false } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                Spacer()
                ForEach(SettingsSection.allCases, id: \.self) { section in
                    Button {
                        visited.insert(section)
                        selected = section
                    } label: {
                        Label(section.rawValue, systemImage: section.icon)
                            .font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .foregroundStyle(selected == section ? Theme.accentText : Theme.quiet)
                            .background(selected == section ? Theme.goodWash : .clear, in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected == section ? .isSelected : [])
                }
                Spacer()
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.fixedSize()
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(Theme.surface)
            Divider()
            ZStack(alignment: .topLeading) {
                // Retain drafts, progress, and sign-in state when switching sections.
                ForEach(SettingsSection.allCases.filter(visited.contains), id: \.self) { section in
                    sectionView(section)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .opacity(selected == section ? 1 : 0)
                        .disabled(selected != section)
                        .allowsHitTesting(selected == section)
                        .accessibilityHidden(selected != section)
                }
            }
        }
        .background(Theme.canvasGrid)
        .foregroundStyle(Theme.ink)
        .tint(Theme.accentText)
        .navigationTitle(selected.rawValue)
        .onAppear { selectStudyIfRequested() }
        .onChange(of: model.showStudySettingsOnOpen) { _, _ in selectStudyIfRequested() }
    }

    private func selectStudyIfRequested() {
        guard model.showStudySettingsOnOpen else { return }
        visited.insert(.study)
        selected = .study
        model.showStudySettingsOnOpen = false
    }

    @ViewBuilder
    private func sectionView(_ section: SettingsSection) -> some View {
        switch section {
        case .ai: AISettingsTab()
        case .rules: RulesTab()
        case .study: StudySettingsTab()
        case .usage: UsageTab()
        case .library: LibraryTab()
        case .shortcuts: KeyboardShortcutsTab()
        }
    }
}

extension View {
    func settingsHeading() -> some View {
        font(.system(size: 28, weight: .bold)).tracking(-1.1)
            .accessibilityAddTraits(.isHeader)
    }

    func settingsField() -> some View {
        textFieldStyle(.plain).font(Theme.body).padding(.horizontal, 10).padding(.vertical, 7)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.borderStrong).allowsHitTesting(false))
    }
}

// MARK: - AI backends

private struct AISettingsTab: View {
    @Environment(AppModel.self) private var model
    @State private var draft = AISettings.default
    @State private var apiKey = ""
    @State private var message: String?
    @State private var error: String?
    @State private var loaded = false
    @State private var codexSignInTask: Task<Void, Never>?
    @State private var codexStatus: String?
    @State private var codexBusy = false

    var body: some View {
        @Bindable var model = model
        ScrollView {
            HStack(alignment: .top, spacing: 32) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Backend").settingsHeading().padding(.bottom, 8)
                    backendButton(.claudeCLI, "Claude CLI", "Your Claude subscription")
                    backendButton(.codexCLI, "Codex", "Your ChatGPT account")
                    backendButton(.messagesAPI, "Anthropic API", "API key, billed per token")
                    Text("Applies to new jobs. Running jobs keep their original backend and model. Lectern never switches backend on its own.")
                        .font(Theme.small).foregroundStyle(Theme.quiet).padding(.top, 8)
                    Divider().padding(.vertical, 8)
                    Toggle("ADHD mode", isOn: $model.adhdModeEnabled)
                        .toggleStyle(.switch)
                        .font(Theme.body.weight(.semibold))
                    Picker("Ask AI activity", selection: $model.adhdModeActivity) {
                        ForEach(AskWaitPreference.allCases, id: \.self) { preference in
                            Text(preference.title).tag(preference)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(!model.adhdModeEnabled)
                    Text("Random gives both activities an equal chance. Press Esc to return to chat.")
                        .font(Theme.small).foregroundStyle(Theme.quiet)
                    if let error { ErrorBanner(message: error) }
                }
                .frame(width: 340, alignment: .leading)
                VStack(alignment: .leading, spacing: 16) {
                    switch draft.backend {
                    case .claudeCLI:
                        cliFields(codex: false)
                    case .codexCLI:
                        cliFields(codex: true)
                    case .messagesAPI:
                        apiFields
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).panel(padding: 24)
            }
            .padding(.horizontal, 40).padding(.vertical, 32)
        }
        .disabled(!loaded)
        .onChange(of: model.settingsLoaded, initial: true) { _, ready in
            if ready, !loaded { draft = model.settings; loaded = true }
        }
        .task(id: draft) {
            guard loaded, draft != model.settings else { return }
            await save(draft)
        }
        .task(id: draft.backend) {
            if draft.backend == .codexCLI, !codexBusy,
               FileManager.default.isExecutableFile(atPath: CodexCLIProvider.resolveExecutable(configuredPath: draft.codexCLIPath).path) {
                await checkCodexStatus()
            }
        }
        .onDisappear { codexSignInTask?.cancel(); codexSignInTask = nil; codexBusy = false }
    }

    private func backendButton(_ backend: AIBackend, _ name: String, _ detail: String) -> some View {
        let selected = draft.backend == backend
        return Button { draft.backend = backend } label: {
            HStack(spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Theme.accentText : Theme.faint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(.system(size: 14, weight: .semibold))
                    Text(detail).font(Theme.small).foregroundStyle(Theme.quiet)
                }
                Spacer()
            }
            .padding(14)
            .background(selected ? Theme.goodWash : Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Theme.accentText : Theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private func cliFields(codex: Bool) -> some View {
        let configuredPath = codex ? $draft.codexCLIPath : $draft.claudeCLIPath
        let resolve = codex ? CodexCLIProvider.resolveExecutable(configuredPath:) : ClaudeCLIProvider.resolveExecutable(configuredPath:)
        let resolved = resolve(configuredPath.wrappedValue)
        let found = FileManager.default.isExecutableFile(atPath: resolved.path)
        Text(codex ? "Codex" : "Claude CLI").font(.system(size: 19, weight: .bold))
        VStack(alignment: .leading, spacing: 6) {
            Text("Model").font(Theme.small.weight(.medium))
            TextField("Model", text: codex ? $draft.codexModel : $draft.cliModel,
                      prompt: Text(codex ? AISettings.defaultCodexModel : AISettings.defaultCLIModel)).settingsField()
        }
        VStack(alignment: .leading, spacing: 6) {
            Text("CLI path").font(Theme.small.weight(.medium))
            HStack {
                TextField("CLI path", text: Binding(get: { configuredPath.wrappedValue ?? "" },
                                                    set: { configuredPath.wrappedValue = $0.isEmpty ? nil : $0 }),
                          prompt: Text(resolve(nil).path)).settingsField()
                Button("Choose…") { chooseCLI(codex: codex) }.buttonStyle(SecondaryButtonStyle())
            }
            Label(found ? "Found at \(resolved.path)" : "Not found at \(resolved.path)", systemImage: found ? "checkmark.circle" : "xmark.circle")
                .font(Theme.small).foregroundStyle(found ? Theme.good : Theme.bad)
        }
        Divider()
        if codex {
            Button(codexBusy ? "Waiting for ChatGPT sign-in…" : "Sign in with ChatGPT") { startCodexSignIn() }
                .buttonStyle(PrimaryButtonStyle()).disabled(codexBusy || !found)
            Button("Check sign-in") { Task { await checkCodexStatus() } }
                .buttonStyle(SecondaryButtonStyle()).disabled(codexBusy || !found)
            if let codexStatus { Text(codexStatus).font(Theme.small).foregroundStyle(codexStatusColor).textSelection(.enabled) }
            Text("Codex manages credentials in a separate Lectern account folder.")
                .font(Theme.small).foregroundStyle(Theme.quiet)
        } else {
            Text("Sign in once in Terminal with `claude auth login`. Lectern runs the unmodified CLI and never reads its login.")
                .font(Theme.small).foregroundStyle(Theme.quiet)
        }
    }

    @ViewBuilder private var apiFields: some View {
        Text("Anthropic API").font(.system(size: 19, weight: .bold))
        VStack(alignment: .leading, spacing: 6) {
            Text("Model").font(Theme.small.weight(.medium))
            TextField("Model", text: $draft.messagesAPIModel, prompt: Text(AISettings.defaultMessagesAPIModel)).settingsField()
        }
        VStack(alignment: .leading, spacing: 6) {
            Text("API version").font(Theme.small.weight(.medium))
            TextField("API version", text: $draft.messagesAPIVersion).settingsField()
        }
        Stepper("Max output tokens · \(draft.maxOutputTokens.formatted())", value: $draft.maxOutputTokens, in: 256...128_000, step: 1024)
        Divider()
        SecureField(model.apiKeySaved ? "Paste a replacement API key" : "Paste an API key", text: $apiKey).settingsField()
        HStack {
            Button("Save key") { saveKey() }.buttonStyle(PrimaryButtonStyle()).disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
            if model.apiKeySaved { Button("Remove key", role: .destructive) { removeKey() }.buttonStyle(SecondaryButtonStyle(foreground: Theme.bad)) }
        }
        Text("The API key is stored in your macOS Keychain.").font(Theme.small).foregroundStyle(Theme.quiet)
        if let message { Text(message).font(Theme.small).foregroundStyle(Theme.good) }
    }

    private func save(_ settings: AISettings) async {
        do {
            try await model.updateSettings(settings)
            error = nil
        } catch is CancellationError {
            // A newer draft owns saving and status reporting.
        } catch { self.error = error.localizedDescription }
    }

    private func chooseCLI(codex: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.message = codex ? "Choose the codex executable" : "Choose the claude executable"
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            if codex { draft.codexCLIPath = url.path } else { draft.claudeCLIPath = url.path }
        }
    }

    private func startCodexSignIn() {
        codexSignInTask?.cancel()
        let executable = CodexCLIProvider.resolveExecutable(configuredPath: draft.codexCLIPath)
        codexBusy = true
        codexStatus = "Waiting for the Codex sign-in link…"
        codexSignInTask = Task { @MainActor in
            defer { codexBusy = false; codexSignInTask = nil }
            do {
                try await CodexCLIProvider.signIn(executableURL: executable) { url in
                    Task { @MainActor in NSWorkspace.shared.open(url) }
                }
                codexStatus = "Signed in with ChatGPT."
            } catch is CancellationError {
                codexStatus = "Sign-in cancelled."
            } catch {
                codexStatus = "Sign-in failed: \(error.localizedDescription)"
            }
        }
    }

    private func checkCodexStatus() async {
        let executable = CodexCLIProvider.resolveExecutable(configuredPath: draft.codexCLIPath)
        codexBusy = true
        defer { codexBusy = false }
        do { codexStatus = try await CodexCLIProvider.accountStatus(executableURL: executable) }
        catch { codexStatus = "Could not check sign-in: \(error.localizedDescription)" }
    }

    private var codexStatusColor: Color {
        let status = codexStatus?.lowercased() ?? ""
        if status.contains("failed") || status.contains("could not") { return Theme.bad }
        if status.hasPrefix("signed in") { return Theme.good }
        return Theme.quiet
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
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Global card rules").settingsHeading()
                Text("version \(String(PromptBuilder.hash(saved).prefix(8)))").font(Theme.caption.monospaced()).foregroundStyle(Theme.faint)
                Spacer()
            }
            Text("Sent with every Generate and revision. Module instructions come after these, and slide notes win over both.")
                .font(Theme.small).foregroundStyle(Theme.quiet)
            TextEditor(text: $draft)
                .font(.system(size: 13, design: .monospaced))
                .accessibilityLabel("Global card rules")
                .scrollContentBackground(.hidden)
                .padding(14)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border).allowsHitTesting(false))
            if let error { Text(error).font(Theme.small).foregroundStyle(Theme.bad) }
            HStack {
                Text("Stored at \(model.store.rootURL.appendingPathComponent("rules.md").path)").font(Theme.caption).foregroundStyle(Theme.faint).lineLimit(1)
                Spacer()
                Button("Revert") { draft = saved }.buttonStyle(SecondaryButtonStyle()).disabled(draft == saved)
                Button("Save rules") { Task { await save() } }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut("s", modifiers: .command).disabled(draft == saved)
            }
        }
        .padding(.horizontal, 40).padding(.vertical, 32)
        .task { await load() }
    }

    private func load() async {
        do { saved = try await model.store.loadRules(); draft = saved }
        catch { self.error = error.localizedDescription }
    }

    private func save() async {
        do {
            let content = draft
            try await model.store.saveRules(content)
            saved = content
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: - API usage

private struct UsageTab: View {
    @Environment(AppModel.self) private var model
    @State private var jobs: [Job] = []
    @State private var records: [AIUsageAttempt] = []
    @State private var loading = true
    @State private var learningPointsOnly = false
    @State private var error: String?

    private var summary: AIUsageSummary {
        AIUsageSummary.summarize(records: records, legacyJobs: jobs, learningPointsOnly: learningPointsOnly)
    }
    private var apiCost: APICostSummary {
        if learningPointsOnly {
            return APIPricing.summarize([], records: records.filter { $0.context["feature"] == "learningPointsV2" })
        }
        return APIPricing.summarize(jobs, records: records)
    }

    var body: some View {
        let totals = summary
        let cost = apiCost
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("AI usage").settingsHeading()
                    Spacer()
                    SegmentedControl(options: [(false, "All AI"), (true, "Learning points v2")], selection: $learningPointsOnly)
                    Button("Refresh") { Task { await load() } }.buttonStyle(SecondaryButtonStyle()).disabled(loading)
                }
                if loading { ProgressView().controlSize(.small) }
                if let error { ErrorBanner(message: error) }
                HStack(spacing: 10) {
                    metric("Provider calls", totals.providerCalls.formatted())
                    metric("Input tokens", totals.inputTokens.formatted(.number.notation(.compactName)))
                    metric("Output tokens", totals.outputTokens.formatted(.number.notation(.compactName)))
                    metric("Anthropic API spend", Format.usd(cost.totalUSD))
                }
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Details").font(.headline)
                        row("Execution attempts", totals.attempts)
                        row("Skipped checks", totals.skipped)
                        row("Failed or cancelled", totals.failed)
                        row("Cache read tokens", totals.cacheReadTokens)
                        row("Cache write tokens", totals.cacheWriteTokens)
                        row("Unknown usage", totals.missingUsage)
                        if learningPointsOnly {
                            row("Learning points added", totals.pointsAdded)
                            row("Learning points merged", totals.pointsMerged)
                            row("Learning points rejected", totals.pointsRejected)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).panel()
                    VStack(alignment: .leading, spacing: 12) {
                        Text("By backend").font(.headline)
                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                            GridRow {
                                Text("Backend"); Text("Calls"); Text("Input"); Text("Output")
                            }.eyebrow()
                            ForEach(AIBackend.allCases, id: \.self) { backend in
                                let value = AIUsageSummary.summarize(records: records, legacyJobs: jobs, learningPointsOnly: learningPointsOnly, backend: backend)
                                GridRow {
                                    Text(backendLabel(backend))
                                    Text(value.providerCalls.formatted())
                                    Text(value.inputTokens.formatted(.number.notation(.compactName)))
                                    Text(value.outputTokens.formatted(.number.notation(.compactName)))
                                }
                            }
                        }
                        .font(Theme.small).monospacedDigit()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).panel()
                }
                if learningPointsOnly {
                    DisclosureGroup("What triggered the checks") {
                        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                            GridRow { Text("Trigger"); Text("Calls"); Text("Skipped") }
                            ForEach(["answer", "clicked", "newChat", "switchChat", "idle", "chatEnded"], id: \.self) { trigger in
                                let matching = records.filter { $0.context["feature"] == "learningPointsV2" && $0.context["trigger"] == trigger }
                                GridRow {
                                    Text(triggerLabel(trigger))
                                    Text(matching.reduce(0) { $0 + $1.providerCalls }.formatted())
                                    Text(matching.filter { $0.status == "skipped" }.count.formatted())
                                }
                            }
                        }.padding(.top, 6).font(Theme.small)
                    }.panel()
                }
                if cost.unpricedJobs > 0 {
                    Text("\(cost.unpricedJobs) API attempts have no price.").font(Theme.small).foregroundStyle(Theme.amber)
                }
                Text("Totals include failed attempts and retries. Unknown usage is left out of token totals. CLI subscription cost and quota aren't available.")
                    .font(Theme.small).foregroundStyle(Theme.quiet)
            }
            .padding(.horizontal, 40).padding(.vertical, 32)
        }
        .task { await load() }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value).font(.system(size: 27, weight: .bold)).tracking(-1).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.65)
            Text(title).font(Theme.small).foregroundStyle(Theme.quiet)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: 16)
        .accessibilityElement(children: .combine)
    }

    private func row(_ label: String, _ value: Int) -> some View {
        HStack {
            Text(label).foregroundStyle(Theme.quiet)
            Spacer()
            Text(value.formatted()).monospacedDigit()
        }.font(Theme.body)
    }

    private func backendLabel(_ backend: AIBackend) -> String {
        switch backend { case .claudeCLI: "Claude CLI"; case .codexCLI: "Codex CLI"; case .messagesAPI: "Messages API" }
    }
    private func triggerLabel(_ trigger: String) -> String {
        switch trigger {
        case "answer": "Answer"; case "clicked": "Clicked"; case "newChat": "New chat"
        case "switchChat": "Switch chat"; case "idle": "Idle reopen"; default: "Chat ended"
        }
    }
    private func load() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            var allJobs: [Job] = [], allRecords: [AIUsageAttempt] = []
            for module in try await model.store.modules() {
                for lecture in try await model.store.lectures(in: module.id) {
                    allJobs += lecture.jobs
                    allRecords += try await model.store.usageRecords(moduleID: module.id, lectureID: lecture.id)
                }
            }
            jobs = allJobs; records = allRecords
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: - Library

private struct LibraryTab: View {
    @Environment(AppModel.self) private var model
    @State private var result: String?
    @State private var working = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Library").settingsHeading()
                VStack(alignment: .leading, spacing: 12) {
                    Text("Library folder").font(.headline)
                    HStack {
                        Text((model.store.rootURL.path as NSString).abbreviatingWithTildeInPath)
                            .font(Theme.small.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).settingsField()
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.store.rootURL]) }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                    Text("PDFs are private copies inside this folder, so lectures keep working after the originals move.")
                        .font(Theme.small).foregroundStyle(Theme.quiet)
                }
                .panel()
                VStack(alignment: .leading, spacing: 12) {
                    Text("Backup").font(.headline)
                    Text("Save your entire library, study history, and app preferences in one ZIP file. AI sign-ins and API keys stay in their credential stores.")
                        .font(Theme.small).foregroundStyle(Theme.quiet)
                    HStack(spacing: 10) {
                        Button("Download backup…") { saveBackup() }
                            .buttonStyle(PrimaryButtonStyle()).disabled(model.backupStatus == .saving)
                        if model.backupStatus == .saving {
                            ProgressView().controlSize(.small)
                            Text("Creating backup…").font(Theme.small).foregroundStyle(Theme.quiet)
                        }
                    }
                    if case .saved(let url) = model.backupStatus {
                        HStack {
                            Label("Saved \(url.lastPathComponent)", systemImage: "checkmark.circle")
                                .font(Theme.small).foregroundStyle(Theme.good).textSelection(.enabled)
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                .buttonStyle(LinkButtonStyle())
                        }
                    }
                    if case .failed(let message) = model.backupStatus {
                        ErrorBanner(message: message)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).panel()
                VStack(alignment: .leading, spacing: 12) {
                    Text("Import from the earlier apps").font(.headline)
                    Text("Import a Slide Learning folder or Flashcard Reviewer backup. Lectern reads the originals and skips items already imported from the same path.")
                        .font(Theme.small).foregroundStyle(Theme.quiet)
                    HStack {
                        Button("Import Slide Learning folder…") { Task { await importSlides() } }
                        Button("Import reviewer sessions.json…") { Task { await importReviewer() } }
                    }
                    .buttonStyle(SecondaryButtonStyle()).disabled(working)
                    if working { ProgressView().controlSize(.small) }
                    if let result { Text(result).font(Theme.small).textSelection(.enabled) }
                }
                .frame(maxWidth: .infinity, alignment: .leading).panel()
            }
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 40).padding(.vertical, 32)
        }
    }

    private func saveBackup() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        let date = Date.now.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
        panel.nameFieldStringValue = "Lectern Backup \(date).zip"
        panel.prompt = "Save Backup"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.exportLibraryBackup(to: url) }
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
