import LecternCore
import SwiftUI

/// Draft-based module settings. Cancel writes nothing; Save uses the narrow settings API;
/// Archive/Unarchive is a separate, immediate and reversible action.
struct ModuleSettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let moduleID: UUID

    @State private var loaded = false
    @State private var name = ""
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
        VStack(alignment: .leading, spacing: 18) {
            Text("Module settings").font(Theme.serif(30))
            if !loaded {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            } else {
                form
            }
        }
        .padding(30)
        .frame(width: 520)
        .background(Theme.surface)
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
        VStack(alignment: .leading, spacing: 6) {
            Text("Name").font(.system(size: 13, weight: .semibold))
            TextField("Module name", text: $name).textFieldStyle(.roundedBorder).controlSize(.large)
        }
        .disabled(archived)

        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Lectures planned").font(.system(size: 13, weight: .semibold))
                HStack(spacing: 8) {
                    Button("–") { planned = max(minimum, planned - 1) }
                        .buttonStyle(SecondaryButtonStyle()).disabled(planned <= minimum)
                    TextField("", value: $planned, format: .number)
                        .multilineTextAlignment(.center).textFieldStyle(.roundedBorder).frame(width: 70)
                        .onSubmit { planned = min(max(planned, minimum), Module.maximumPlannedLectureCount) }
                    Button("+") { planned = min(Module.maximumPlannedLectureCount, planned + 1) }
                        .buttonStyle(SecondaryButtonStyle())
                }
                Text("Empty slots show in the module and on the Overview. Can't go below the highest imported slot (\(minimum)).")
                    .font(Theme.small).foregroundStyle(Theme.quiet).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    Text("Exam date").font(.system(size: 13, weight: .semibold))
                    Text("optional").font(Theme.body).foregroundStyle(Theme.quiet)
                }
                if hasExam {
                    HStack {
                        DatePicker("Exam date", selection: $examDate, displayedComponents: .date)
                            .labelsHidden().datePickerStyle(.field)
                        Button("Clear") { hasExam = false }.buttonStyle(LinkButtonStyle(color: Theme.quiet))
                    }
                } else {
                    Button("Add exam date") { hasExam = true }.buttonStyle(SecondaryButtonStyle())
                }
                Text("Drives the pace line: lectures per week to finish in time.")
                    .font(Theme.small).foregroundStyle(Theme.quiet).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(archived)

        Divider().overlay(Theme.border)

        VStack(alignment: .leading, spacing: 10) {
            Text(archived ? "Archived" : "Archive").font(.system(size: 13, weight: .semibold))
            Text(archived
                 ? "This module is read-only and hidden from the Overview. Slides, cards, chats and export history are all still here. Export still works."
                 : "Moves the module under Archived and off the Overview. Slides, cards, chats and export history stay, read-only. Export still works. Unarchive any time; nothing is deleted.")
                .font(Theme.body).foregroundStyle(Theme.quiet).fixedSize(horizontal: false, vertical: true)
            if archived {
                Button("Unarchive module") { Task { await unarchive() } }.buttonStyle(SecondaryButtonStyle())
            } else {
                Button("Archive module") { Task { await startArchive() } }.buttonStyle(SecondaryButtonStyle())
            }
        }

        if let error { ErrorBanner(message: error) }

        HStack {
            Spacer()
            Button(archived ? "Close" : "Cancel") { dismiss() }
                .buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
            if !archived {
                Button("Save") { Task { await save() } }
                    .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func load() async {
        do {
            let module = try await model.store.loadModule(moduleID: moduleID)
            name = module.name
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
                                                       plannedLectureCount: planned, examDate: exam)
            try await model.reloadNow()
            dismiss()
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
