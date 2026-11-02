import LecternCore
import SwiftUI

struct LibraryWindow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if let ref = model.activeLecture {
                LectureWindow(ref: ref).id(ref)
            } else {
                HStack(spacing: 0) {
                    Sidebar()
                        .frame(width: 236)
                        .background(Theme.sidebar)
                    Rectangle().fill(Theme.border).frame(width: 1)
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.canvas)
                }
            }
        }
        .background(WindowCloseGuard { await model.closeAllLectureWindows() })
        .foregroundStyle(Theme.ink)
        .sheet(item: $model.renamingLecture) { ref in RenameLectureSheet(ref: ref) }
        .sheet(isPresented: $model.showNewModule) { NewModuleSheet() }
        .sheet(item: Binding(get: { model.settingsModuleID.map(IdentifiedUUID.init) },
                             set: { model.settingsModuleID = $0?.id })) { item in
            ModuleSettingsSheet(moduleID: item.id)
        }
        .sheet(isPresented: $model.showBootstrapReport) { BootstrapReportSheet() }
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
                Text("Lectern couldn't open its library").font(Theme.serif(26))
                Text(message).font(Theme.body).foregroundStyle(Theme.quiet).textSelection(.enabled)
                Text(model.store.rootURL.path).font(Theme.caption.monospaced()).foregroundStyle(Theme.faint).textSelection(.enabled)
            }
            .frame(maxWidth: 560)
        case .ready:
            switch model.selection {
            case .overview, .settings: OverviewView()
            case .module(let id): ModuleView(moduleID: id).id(id)
            case .export(let id): ExportView(moduleID: id).id(id)
            }
        }
    }
}

nonisolated struct IdentifiedUUID: Identifiable { let id: UUID }

// MARK: - Sidebar

private struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @State private var archivedExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Wordmark(size: 24).padding(.horizontal, 22).padding(.top, 22).padding(.bottom, 20)
            SidebarRow(title: "Overview", detail: nil, isSelected: model.selection == .overview) { model.selection = .overview }
            HStack(spacing: 4) {
                Text("Modules").eyebrow()
                Text("· done / planned").font(Theme.caption).foregroundStyle(Theme.quiet)
            }
            .padding(.horizontal, 22).padding(.top, 22).padding(.bottom, 6)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.dashboard?.modules ?? []) { progress in
                        SidebarRow(title: progress.module.name,
                                   detail: "\(progress.totals.doneLectureCount) / \(progress.totals.plannedLectureCount)",
                                   isSelected: isSelected(progress.module.id)) {
                            model.selection = .module(progress.module.id)
                        }
                    }
                    Button { model.showNewModule = true } label: {
                        Text("+ New module").font(Theme.body).foregroundStyle(Theme.accentText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.borderStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 14).padding(.top, 10)
                    archived.padding(.top, 18)
                }
            }
            Spacer(minLength: 12)
            let status = model.backendStatus
            HStack(spacing: 8) {
                Circle().fill(status.ready ? Theme.good : Theme.amber).frame(width: 7, height: 7)
                Text(status.text).font(Theme.small).foregroundStyle(Theme.quiet)
            }
            .help(model.settings.backend == .claudeCLI
                  ? "Uses \(model.cliExecutable.path). Sign in once with `claude auth login` in Terminal."
                  : "The API key is stored in your Keychain.")
            .padding(.horizontal, 22).padding(.bottom, 12)
            SettingsLink {
                Text("Settings").font(Theme.body).foregroundStyle(Theme.ink)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 22).padding(.bottom, 20)
        }
    }

    private func isSelected(_ id: UUID) -> Bool {
        model.selection == .module(id) || model.selection == .export(id)
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
                Text(title).font(.system(size: 13, weight: isSelected ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 8)
                if let detail { Text(detail).font(Theme.small).monospacedDigit().foregroundStyle(Theme.quiet) }
            }
            .foregroundStyle(muted && !isSelected ? Theme.quiet : Theme.ink)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(isSelected ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isSelected ? Theme.border : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
    }
}

// MARK: - Sheets

struct NewModuleSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var instructions = ""
    @State private var planned = 0
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New module").font(Theme.serif(26))
            field("Name") {
                TextField("e.g. Statistics II", text: $name).textFieldStyle(.roundedBorder).onSubmit(save)
            }
            field("Lectures planned") {
                Stepper(value: $planned, in: 0...Module.maximumPlannedLectureCount) {
                    Text(planned == 0 ? "Not set" : "\(planned)").monospacedDigit()
                }
                .fixedSize()
            }
            field("Module instructions (optional)") {
                TextEditor(text: $instructions).font(Theme.body).frame(height: 80)
                    .scrollContentBackground(.hidden).padding(6)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.borderStrong))
                Text("Applied after the global rules, before slide notes. Example: “Open-book exam, test interpretation only.”")
                    .font(Theme.caption).foregroundStyle(Theme.quiet)
            }
            if let error { ErrorBanner(message: error) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Create", action: save).buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(28)
        .frame(width: 480)
        .background(Theme.surface)
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .semibold))
            content()
        }
    }

    private func save() {
        Task {
            do {
                let module = try await model.createModule(name: name, instructions: instructions)
                if planned > 0 {
                    try await model.store.updateModuleSettings(moduleID: module.id, name: module.name, plannedLectureCount: planned, examDate: nil)
                    try await model.reloadNow()
                }
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct BootstrapReportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Library opened").font(Theme.serif(24))
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
