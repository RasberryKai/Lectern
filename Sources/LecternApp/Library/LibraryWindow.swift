import LecternCore
import SwiftUI

struct LibraryWindow: View {
    static let sidebarWidth: CGFloat = 212
    @Environment(AppModel.self) private var model

    @Environment(\.launchPhase) private var launchPhase

    var body: some View {
        @Bindable var model = model
        Group {
            if model.showNewModule {
                ModuleCreationForm(onClose: { model.showNewModule = false })
            } else if let moduleID = model.settingsModuleID {
                ModuleSettingsSheet(moduleID: moduleID) { model.settingsModuleID = nil }
                    .background(Theme.canvasGrid.ignoresSafeArea(edges: .top))
            } else if let ref = model.activeLecture {
                LectureWindow(ref: ref).id(ref)
            } else if case .ready = model.phase, model.modules.isEmpty {
                ModuleCreationForm()
            } else {
                HStack(spacing: 0) {
                    Sidebar()
                        .frame(width: Self.sidebarWidth)
                        .background(Theme.sidebar.ignoresSafeArea(edges: .top))
                    Rectangle().fill(Theme.border).frame(width: 1).ignoresSafeArea(edges: .top)
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .launchEntrance()
                        .background(Theme.canvasGrid.ignoresSafeArea(edges: .top))
                }
            }
        }
        .disabled(model.showSettings)
        .accessibilityHidden(model.showSettings)
        .overlay {
            if model.showSettings {
                SettingsView().background(Theme.canvasGrid.ignoresSafeArea(edges: .top))
            }
        }
        .background(WindowCloseGuard { await model.closeAllLectureWindows() })
        .foregroundStyle(Theme.ink)
        .sheet(item: $model.renamingLecture) { ref in RenameLectureSheet(ref: ref) }
        .sheet(item: $model.movingLecture) { ref in MoveLectureSheet(ref: ref) }
        .sheet(isPresented: Binding(get: { launchPhase != .covered && model.showBootstrapReport },
                                    set: { model.showBootstrapReport = $0 })) { BootstrapReportSheet() }
        .sheet(item: $model.pendingImport) { pending in ImportPDFsSheet(pending: pending) }
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ViewBuilder private var detail: some View {
        switch model.phase {
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("Opening your library…").font(Theme.body).foregroundStyle(Theme.quiet)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 12) {
                Text("Lectern couldn't open its library").font(Theme.heading(26))
                Text(message).font(Theme.body).foregroundStyle(Theme.quiet).textSelection(.enabled)
                Text(model.store.rootURL.path).font(Theme.caption.monospaced()).foregroundStyle(Theme.faint).textSelection(.enabled)
            }
            .frame(maxWidth: 560)
        case .ready:
            switch model.selection {
            case .overview: OverviewView()
            case .module(let id): ModuleView(moduleID: id).id(id)
            case .export(let id, let lectureID): ExportView(moduleID: id, initialLectureID: lectureID).id(model.selection)
            }
        }
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.launchPhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduced
    @State private var archivedExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Wordmark(size: 23)
                .anchorPreference(key: LaunchDestination.self, value: .bounds) { $0 }
                .opacity(phase == .finished || reduced ? 1 : 0)
                .padding(.horizontal, 22).padding(.top, 22).padding(.bottom, 20)
            SidebarRow(title: "Overview", detail: nil, isSelected: model.selection == .overview) { model.selection = .overview }
                .launchEntrance(row: 0)
            VStack(alignment: .leading, spacing: 0) {
                Text("Study").eyebrow()
                    .padding(.horizontal, 22).padding(.bottom, 6)
                upcomingStudyRow("Flashcards", icon: "rectangle.on.rectangle")
                upcomingStudyRow("Mock exams", icon: "checkmark.square")
            }
            .padding(.top, 22).launchEntrance(row: 1)
            Text("Modules").eyebrow()
                .padding(.horizontal, 22).padding(.top, 22).padding(.bottom, 6).launchEntrance(row: 2)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array((model.dashboard?.modules ?? []).enumerated()), id: \.element.id) { index, progress in
                        SidebarRow(title: progress.module.name,
                                   detail: "\(progress.totals.doneLectureCount) / \(progress.totals.plannedLectureCount)",
                                   isSelected: isSelected(progress.module.id)) {
                            model.selection = .module(progress.module.id)
                        }
                        .launchEntrance(row: 3 + index)
                    }
                    Button { model.showNewModule = true } label: {
                        Text("+ New module").font(Theme.body).foregroundStyle(Theme.accentText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.borderStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12).padding(.top, 10)
                    .launchEntrance(row: 5)
                    archived.padding(.top, 18).launchEntrance(row: 6)
                }
            }
            Spacer(minLength: 12)
            let status = model.backendStatus
            HStack(spacing: 8) {
                Circle().fill(status.ready ? Theme.good : Theme.amber).frame(width: 7, height: 7)
                Text(status.text).font(Theme.small).foregroundStyle(Theme.quiet)
            }
            .launchEntrance(row: 6)
            .help(backendHelp)
            .padding(.horizontal, 22).padding(.bottom, 12)
            Button { model.showSettings = true } label: {
                HStack { Label("Settings", systemImage: "gearshape"); Spacer(); Text("⌘ ,").foregroundStyle(Theme.quiet) }.font(Theme.body).foregroundStyle(Theme.ink)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 22).padding(.bottom, 20).launchEntrance(row: 7)
        }
    }

    private func upcomingStudyRow(_ title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).frame(width: 15).accessibilityHidden(true)
            Text(title)
            Spacer()
            Text("Soon")
                .font(Theme.caption.weight(.semibold))
                .foregroundStyle(Theme.accentText)
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(Theme.goodWash, in: Capsule())
        }
        .font(Theme.body).foregroundStyle(Theme.quiet)
        .padding(.horizontal, 24).padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }

    private func isSelected(_ id: UUID) -> Bool {
        if case .export(let moduleID, _) = model.selection { return id == moduleID }
        return model.selection == .module(id)
    }

    private var backendHelp: String {
        switch model.settings.backend {
        case .claudeCLI: "Uses \(model.cliExecutable.path). Sign in with `claude auth login` in Terminal."
        case .codexCLI: "Uses \(model.codexExecutable.path). Sign in once with the button in Settings; Codex manages the Lectern-specific account credentials."
        case .messagesAPI: "The API key is stored in your Keychain."
        }
    }

    @ViewBuilder private var archived: some View {
        let archived = model.archivedModules
        if !archived.isEmpty {
            Button { withAnimation(.easeOut(duration: 0.15)) { archivedExpanded.toggle() } } label: {
                HStack {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(archivedExpanded ? 90 : 0))
                    Text("Archived")
                    Spacer()
                    Text("\(archived.count)").monospacedDigit()
                }
                .font(Theme.body).foregroundStyle(Theme.quiet)
                .padding(.horizontal, 22).padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if archivedExpanded {
                ForEach(archived) { module in
                    SidebarRow(title: module.name, detail: nil, isSelected: isSelected(module.id), muted: true) {
                        model.selection = .module(module.id)
                    }
                }
            }
        }
    }
}

private struct SidebarRow: View {
    let title: String
    let detail: String?
    let isSelected: Bool
    var muted = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: detail == nil && !muted ? "square.grid.2x2" : "folder")
                    .font(.system(size: 13))
                Text(title).font(.system(size: 13, weight: isSelected ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 8)
                if let detail { Text(detail).font(Theme.small).monospacedDigit().foregroundStyle(Theme.quiet) }
            }
            .foregroundStyle(isSelected ? Theme.accentText : muted ? Theme.quiet : Theme.ink)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(isSelected ? Theme.goodWash : .clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isSelected ? Theme.accentText.opacity(0.25) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
    }
}

// MARK: - Sheets

struct ModuleCreationForm: View {
    @Environment(AppModel.self) private var model
    var onClose: (() -> Void)?
    @State private var name = ""
    @State private var saving = false
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 24) {
                    LogoMark().fill(Theme.accent).padding(10).frame(width: 64, height: 64)
                        .background(Theme.goodWash, in: RoundedRectangle(cornerRadius: 14))
                    VStack(spacing: 10) {
                        Text("Start with a module.").font(Theme.heading(60)).tracking(-2.4)
                        Text("A module is one course. Name it, then drop its lecture PDFs on it.")
                            .font(Theme.body).foregroundStyle(Theme.quiet)
                    }
                    HStack(spacing: 10) {
                        TextField("Module name", text: $name)
                            .textFieldStyle(.plain).moduleFormInput()
                            .focused($nameFocused)
                            .accessibilityLabel("Module name").onSubmit(save)
                        Button(action: save) {
                            Image(systemName: "arrow.right").frame(width: 16, height: 28)
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .accessibilityLabel("Create module")
                        .help("Create module")
                        .keyboardShortcut(.defaultAction)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .frame(maxWidth: 500)
                    if let error { ErrorBanner(message: error) }
                    if let onClose {
                        Button("Cancel", action: onClose)
                            .buttonStyle(LinkButtonStyle(color: Theme.quiet)).keyboardShortcut(.cancelAction)
                    }
                }
                .padding(40)
                .frame(maxWidth: 760, minHeight: 440)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Theme.border))
                .padding(32)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }
        .background(Theme.canvasGrid.ignoresSafeArea(edges: .top))
        .disabled(saving)
        .onAppear { nameFocused = true }
    }

    private func save() {
        guard !saving, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                try await model.createModule(name: name)
                onClose?()
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct BootstrapReportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Library opened").font(Theme.heading(24))
            if let report = model.bootstrapReport {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if report.interruptedJobs > 0 {
                            Text("\(Format.count(report.interruptedJobs, "AI job")) stopped when Lectern last quit. They're marked Interrupted in their lectures; retry them there. Nothing reran automatically.")
                        }
                        ForEach(Array(report.migrations.enumerated()), id: \.offset) { _, migration in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(migration.source?.lastPathComponent ?? "Earlier app data").font(.system(size: 13, weight: .semibold))
                                Text("Imported \(migration.imported.count), already imported \(migration.skipped.count), failed \(migration.failures.count).")
                                ForEach(Array(migration.failures.enumerated()), id: \.offset) { _, failure in
                                    Text("\(failure.source): \(failure.message)").font(Theme.small).foregroundStyle(Theme.bad).textSelection(.enabled)
                                }
                                if let source = migration.source {
                                    Text(source.path).font(Theme.caption.monospaced()).foregroundStyle(Theme.faint).textSelection(.enabled)
                                }
                            }
                        }
                        ForEach(report.warnings, id: \.self) { warning in
                            Text(warning).font(Theme.small).foregroundStyle(Theme.amber)
                        }
                        Text("Original Slide Learning and Flashcard Reviewer files were read, not changed.")
                            .font(Theme.small).foregroundStyle(Theme.quiet)
                    }
                    .font(Theme.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction) }
        }
        .padding(28)
        .frame(width: 560, height: 420)
        .background(Theme.surface)
    }
}
