import LecternCore
import SwiftUI

/// Draft-based module settings. Cancel writes nothing; Save uses the narrow settings API;
/// Archive/Unarchive is a separate, immediate and reversible action.
struct ModuleSettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let moduleID: UUID
    var onClose: (() -> Void)? = nil

    @State private var loaded = false
    @State private var name = ""
    @State private var instructions = ""
    @State private var originalInstructions = ""
    @State private var planned = 0
    @State private var minimum = 0
    @State private var hasExam = false
    @State private var examDate = Date()
    @State private var archived = false
    @State private var error: String?
    @State private var saving = false
    @State private var runningJobCount = 0
    @State private var confirmCancelJobs = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Module settings").font(Theme.heading(32)).tracking(-1)
                if !loaded {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    form
                }
            }
            .padding(36)
            .frame(maxWidth: 560, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.border))
            .frame(maxWidth: .infinity)
            .padding(32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .disabled(saving).interactiveDismissDisabled(saving)
        .task { await load() }
        .confirmationDialog("AI is still working on \(Format.count(runningJobCount, "job")) in this module",
                            isPresented: $confirmCancelJobs) {
            Button("Cancel jobs and archive", role: .destructive) { Task { await archive(cancellingJobs: true) } }
            Button("Keep working", role: .cancel) {}
        } message: {
            Text("Archiving never discards work silently. Cancel the running jobs first, or wait until they finish.")
        }
    }

    @ViewBuilder private var form: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Name").font(.system(size: 14, weight: .semibold))
            TextField("Module name", text: $name)
                .textFieldStyle(.plain).moduleFormInput()
                .accessibilityLabel("Module name")
        }
        .disabled(archived)

        HStack(alignment: .top, spacing: 32) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Lectures planned").font(.system(size: 14, weight: .semibold))
                HStack(spacing: 8) {
                    Button { planned = max(minimum, planned - 1) } label: {
                        Image(systemName: "minus").frame(width: 16, height: 26)
                    }
                    .buttonStyle(SecondaryButtonStyle()).disabled(planned <= minimum)
                    .accessibilityLabel("One fewer")
                    TextField("", value: $planned, format: .number)
                        .multilineTextAlignment(.center).textFieldStyle(.plain)
                        .moduleFormInput().frame(width: 76)
                        .accessibilityLabel("Lectures planned")
                        .onSubmit { planned = min(max(planned, minimum), Module.maximumPlannedLectureCount) }
                    Button { planned = min(Module.maximumPlannedLectureCount, planned + 1) } label: {
                        Image(systemName: "plus").frame(width: 16, height: 26)
                    }
                    .buttonStyle(SecondaryButtonStyle()).disabled(planned >= Module.maximumPlannedLectureCount)
                    .accessibilityLabel("One more")
                }
                Text("At least \(minimum), the highest imported lecture number.")
                    .font(Theme.small).foregroundStyle(Theme.quiet).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 5) {
                    Text("Exam date").font(.system(size: 14, weight: .semibold))
                    Text("optional").font(Theme.body).foregroundStyle(Theme.quiet)
                }
                if hasExam {
                    HStack {
                        DatePicker("Exam date", selection: $examDate, displayedComponents: .date)
                            .labelsHidden().datePickerStyle(.field)
                        Spacer(minLength: 0)
                        Button("Clear") { hasExam = false }.buttonStyle(LinkButtonStyle(color: Theme.quiet))
                    }
                    .frame(minHeight: 20).moduleFormInput()
                } else {
                    Button { hasExam = true } label: {
                        Label("Add exam date", systemImage: "calendar")
                            .frame(maxWidth: .infinity, minHeight: 26)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                Text("Sets the pace: lectures per week to finish in time.")
                    .font(Theme.small).foregroundStyle(Theme.quiet).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(archived)

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Text("Module instructions").font(.system(size: 14, weight: .semibold))
                Text("optional").font(Theme.body).foregroundStyle(Theme.quiet)
            }
            TextEditor(text: $instructions)
                .font(Theme.body).scrollContentBackground(.hidden)
                .frame(height: 84).moduleFormInput()
                .accessibilityLabel("Module instructions").disabled(archived)
            Text("Added after your global card rules, before slide notes.")
                .font(Theme.small).foregroundStyle(Theme.quiet)
        }

        Divider().overlay(Theme.border)
        if let error { ErrorBanner(message: error) }
        HStack(spacing: 10) {
            if archived {
                Button("Unarchive module") { Task { await unarchive() } }.buttonStyle(LinkButtonStyle())
            } else {
                Button("Archive module") { Task { await startArchive() } }.buttonStyle(LinkButtonStyle(color: Theme.quiet))
            }
            Spacer()
            Button(archived ? "Close" : "Cancel", action: close)
                .buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
            if !archived {
                Button(saving ? "Saving…" : "Save") { Task { await save() } }
                    .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.top, 8)
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    private func load() async {
        do {
            let module = try await model.store.loadModule(moduleID: moduleID)
            name = module.name
            instructions = module.instructions
            originalInstructions = module.instructions
            minimum = module.lectureSlots.values.max() ?? 0
            planned = module.plannedLectureCount
            archived = module.isArchived
            if let exam = module.examDate { hasExam = true; examDate = exam.date(in: .current) }
            loaded = true
        } catch { self.error = error.localizedDescription; loaded = true }
    }

    private func save() async {
        saving = true; defer { saving = false }
        do {
            let exam = hasExam ? try ExamDate(date: examDate, timeZone: .current) : nil
            try await model.store.updateModuleSettings(moduleID: moduleID, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                                       plannedLectureCount: planned, examDate: exam,
                                                       instructions: instructions == originalInstructions ? nil : instructions,
                                                       expectedInstructions: originalInstructions)
            try await model.reloadNow()
            close()
        } catch {
            // An import may have raced this draft; show the new minimum.
            if let module = try? await model.store.loadModule(moduleID: moduleID) {
                minimum = module.lectureSlots.values.max() ?? 0
                planned = max(planned, minimum)
            }
            self.error = error.localizedDescription
        }
    }

    private func startArchive() async {
        do {
            runningJobCount = try await model.runningJobs(in: moduleID).count
            if runningJobCount > 0 { confirmCancelJobs = true } else { await archive(cancellingJobs: false) }
        } catch { self.error = error.localizedDescription }
    }

    private func archive(cancellingJobs: Bool) async {
        do {
            try await model.archive(moduleID: moduleID, cancellingJobs: cancellingJobs)
            archived = true
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func unarchive() async {
        do {
            try await model.unarchive(moduleID: moduleID)
            archived = false
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

/// The generous bordered fields used by the module forms.
private struct ModuleFormInput: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 14))
            .padding(12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.borderStrong))
    }
}

extension View {
    func moduleFormInput() -> some View { modifier(ModuleFormInput()) }
}
