import LecternCore
import SwiftUI
import UniformTypeIdentifiers

struct ModuleView: View {
    @Environment(AppModel.self) private var model
    let moduleID: UUID

    @State private var lectures: [Lecture] = []
    @State private var rulesSummary = ""
    @State private var editingInstructions = false
    @State private var instructionsDraft = ""
    @State private var dropTargeted = false
    @State private var importing = false

    private var module: Module? { model.module(moduleID) }
    private var progress: ModuleProgress? { model.progress(moduleID) }
    private var archived: Bool { module?.isArchived ?? false }

    var body: some View {
        VStack(spacing: 0) {
            if archived { ReadOnlyBanner() }
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    table
                    HStack(alignment: .top, spacing: 18) {
                        instructions.frame(maxWidth: .infinity)
                        globalRules.frame(width: 380)
                    }
                }
                .padding(.horizontal, 44).padding(.vertical, 30)
                .frame(maxWidth: 1240, alignment: .leading)
            }
        }
        .task(id: model.dashboard) { await load() }
    }

    private func load() async {
        do {
            lectures = try await model.store.lectures(in: moduleID)
            let rules = try await model.store.loadRules()
            rulesSummary = rules.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty && !$0.hasPrefix("#") } ?? "Short, self-contained, transferable cards."
        } catch { model.errorMessage = error.localizedDescription }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .bottom, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text(module?.name ?? "Module").font(Theme.serif(38)).lineLimit(1)
                Text(summaryLine).font(Theme.body).foregroundStyle(Theme.quiet)
            }
            Spacer()
            Button("Module settings") { model.settingsModuleID = moduleID }.buttonStyle(SecondaryButtonStyle())
            Button {
                Task { importing = true; await model.chooseAndImportPDFs(into: moduleID); importing = false }
            } label: {
                if importing { ProgressView().controlSize(.small) } else { Text("Import PDF") }
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(archived || importing)
            Button("Export module to Anki") { model.selection = .export(moduleID) }.buttonStyle(PrimaryButtonStyle())
        }
    }

    private var summaryLine: String {
        guard let progress else {
            return archived ? "Archived · \(Format.count(lectures.count, "lecture"))" : ""
        }
        let approved = lectures.flatMap(\.cards).filter { !$0.isSuperseded && $0.verdict == .good }.count
        var parts = ["\(progress.totals.doneLectureCount) of \(Format.count(progress.totals.plannedLectureCount, "lecture")) done",
                     "\(approved) approved",
                     "\(progress.totals.reviewCardCount) to review",
                     "\(progress.totals.readyExportCount) ready to export"]
        if let exam = progress.module.examDate { parts.append("exam \(Format.dayMonth(exam.date(in: .current)))") }
        return parts.joined(separator: " · ")
    }

    // MARK: Table

    private var table: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Lecture").frame(maxWidth: .infinity, alignment: .leading)
                Text("Slides selected").frame(width: 150, alignment: .leading)
                Text("Cards").frame(width: 220, alignment: .leading)
                Text("Status").frame(width: 300, alignment: .leading)
                Color.clear.frame(width: 90)
            }
            .eyebrow()
            .padding(.horizontal, 20).padding(.vertical, 12)
            Divider().overlay(Theme.border)
            if lectures.isEmpty && (module?.plannedLectureCount ?? 0) == 0 {
                Text("No lectures yet. Drop lecture PDFs here or use Import PDF.")
                    .font(Theme.body).foregroundStyle(Theme.quiet).padding(24)
            }
            ForEach(Array(lectures.enumerated()), id: \.element.id) { index, lecture in
                LectureRow(index: index, lecture: lecture, progress: progress?.lectures.first { $0.lectureID == lecture.id }, archived: archived) { mode in
                    model.openLecture(LectureRef(moduleID: moduleID, lectureID: lecture.id), mode: mode)
                }
                Divider().overlay(Theme.border)
            }
            emptySlots
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(dropTargeted ? Theme.accent : Theme.border, lineWidth: dropTargeted ? 2 : 1))
        .dropDestination(for: URL.self) { urls, _ in
            guard !archived else { model.errorMessage = "This module is archived. Unarchive it to import lectures."; return false }
            Task { await model.importPDFs(urls, into: moduleID) }
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    @ViewBuilder private var emptySlots: some View {
        let planned = module?.plannedLectureCount ?? 0
        let next = lectures.count + 1
        if planned >= next {
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    Text(String(format: "%02d", next)).font(.system(size: 13, weight: .semibold))
                    Text("Not imported yet").italic().foregroundStyle(Theme.quiet)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("—").foregroundStyle(Theme.quiet).frame(width: 150, alignment: .leading)
                Text("—").foregroundStyle(Theme.quiet).frame(width: 220, alignment: .leading)
                Pill(text: "Planned", tone: .outline).frame(width: 300, alignment: .leading)
                Button("Import PDF") { Task { await model.chooseAndImportPDFs(into: moduleID) } }
                    .buttonStyle(LinkButtonStyle()).disabled(archived)
                    .frame(width: 90, alignment: .trailing)
            }
            .font(Theme.body)
            .padding(.horizontal, 20).padding(.vertical, 14)
            if planned > next {
                Divider().overlay(Theme.border)
                Text("\(String(format: "%02d", next + 1)) to \(String(format: "%02d", planned)) · \(Format.count(planned - next, "more planned slot")). Drop a PDF anywhere on this list to fill the next one.")
                    .font(Theme.small).foregroundStyle(Theme.quiet)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.vertical, 12)
            }
        } else {
            Text("Drop a PDF anywhere on this list to add the next lecture.")
                .font(Theme.small).foregroundStyle(Theme.quiet)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.vertical, 12)
        }
    }

    // MARK: Instructions and rules

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Module instructions").font(.system(size: 14, weight: .semibold))
                Spacer()
                if editingInstructions {
                    Button("Cancel") { editingInstructions = false }.buttonStyle(SecondaryButtonStyle())
                    Button("Save") {
                        Task {
                            do { try await model.saveInstructions(moduleID: moduleID, instructions: instructionsDraft); editingInstructions = false }
                            catch { model.errorMessage = error.localizedDescription }
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                } else {
                    Button("Edit") { instructionsDraft = module?.instructions ?? ""; editingInstructions = true }
                        .buttonStyle(SecondaryButtonStyle()).disabled(archived)
                }
            }
            if editingInstructions {
                TextEditor(text: $instructionsDraft)
                    .font(Theme.body).frame(minHeight: 110)
                    .scrollContentBackground(.hidden).padding(6)
                    .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.borderStrong))
            } else {
                let text = module?.instructions.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                Text(text.isEmpty ? "None yet. Say what the exam rewards, e.g. “Open-book on formulas; test interpretation and when to use each method.”" : text)
                    .font(Theme.body).foregroundStyle(text.isEmpty ? Theme.quiet : Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Text("Applied after the global rules, before slide notes. “Make module rule” in Review appends here.")
                .font(Theme.small).foregroundStyle(Theme.quiet)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: 22)
    }

    private var globalRules: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Global card rules").font(.system(size: 14, weight: .semibold))
            Text(rulesSummary).font(Theme.body).lineLimit(3)
            SettingsLink { Text("Open rules in Settings") }.buttonStyle(LinkButtonStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: 22)
    }
}

private struct LectureRow: View {
    @Environment(AppModel.self) private var model
    let index: Int
    let lecture: Lecture
    let progress: LectureProgress?
    let archived: Bool
    let open: (LectureMode?) -> Void

    private var activeCards: [Card] { lecture.cards.filter { !$0.isSuperseded } }

    var body: some View {
        HStack(spacing: 0) {
            Button { open(nil) } label: {
                Text(Format.lectureTitle(index: index, name: lecture.name)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(lecture.pageCount > 0 ? "\(lecture.slides.filter(\.isSelected).count) of \(lecture.pageCount)" : "No slides")
                .foregroundStyle(Theme.quiet).frame(width: 150, alignment: .leading)
            Text(cardsText).frame(width: 220, alignment: .leading)
            status.frame(width: 300, alignment: .leading)
            Button(progress?.status == .toReview ? "Review" : "Open") { open(progress?.status == .toReview ? .review : nil) }
                .buttonStyle(LinkButtonStyle())
                .frame(width: 90, alignment: .trailing)
        }
        .font(Theme.body)
        .padding(.horizontal, 20).padding(.vertical, 14)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Open in Prepare") { open(.prepare) }.disabled(lecture.pageCount == 0)
            Button("Open in Review") { open(.review) }
            Button("Rename presentation…") {
                model.renamingLecture = LectureRef(moduleID: lecture.moduleID, lectureID: lecture.id)
            }.disabled(archived)
            Divider()
            Button("Export Lecture Backup…") { exportBackup() }
            Button("Export Lecture to Anki…") { model.selection = .export(lecture.moduleID) }
        }
    }

    private var cardsText: String {
        let approved = activeCards.filter { $0.verdict == .good }.count
        let review = progress?.reviewCardCount ?? 0
        if activeCards.isEmpty { return "None yet" }
        return review > 0 ? "\(approved) approved · \(review) to review" : "\(approved) approved"
    }

    @ViewBuilder private var status: some View {
        if let generate = lecture.jobs.first(where: { $0.kind == .generate && $0.state == .running }) {
            HStack(spacing: 10) {
                ProgressView().progressViewStyle(.linear).tint(Theme.accent).frame(width: 90)
                Text("Writing cards from \(Format.count(generate.pages.count, "slide"))").font(Theme.small).foregroundStyle(Theme.quiet)
            }
        } else if let progress {
            switch progress.status {
            case .toReview: Pill(text: "Ready to review", tone: .ai)
            case .toExport:
                if progress.changedExportCount > 0 { Pill(text: "\(progress.changedExportCount) changed since export", tone: .amber) }
                else { Pill(text: "\(progress.readyExportCount) ready to export", tone: .good) }
            case .done:
                if let date = activeCards.compactMap(\.exported?.date).max() { Pill(text: "Exported \(Format.dayMonth(date))", tone: .good) }
                else { Pill(text: "Done", tone: .good) }
            case .preparing:
                Pill(text: Format.preparationText(progress.preparationReasons), tone: .amber)
            case .notImported: Pill(text: "Planned", tone: .outline)
            }
        } else {
            Pill(text: archived ? "Archived" : "—", tone: .neutral)
        }
    }

    private func exportBackup() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(lecture.name).lectern-lecture.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do { try await model.store.exportBackup(moduleID: lecture.moduleID, lectureID: lecture.id, to: url) }
            catch { model.errorMessage = error.localizedDescription }
        }
    }
}


struct RenameLectureSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let ref: LectureRef
    @State private var name = ""
    @State private var error: String?
    @State private var saving = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename presentation").font(Theme.serif(26))
            TextField("Presentation name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onSubmit(save)
            if let error { ErrorBanner(message: error) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(28).frame(width: 440)
        .background(Theme.surface)
        .disabled(saving)
        .interactiveDismissDisabled(saving)
        .task {
            do {
                name = try await model.store.loadLecture(moduleID: ref.moduleID, lectureID: ref.lectureID).name
                nameFocused = true
            } catch { self.error = error.localizedDescription }
        }
    }

    private func save() {
        guard !saving, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        saving = true
        Task {
            do {
                try await model.renameLecture(ref, name: name)
                dismiss()
            } catch { self.error = error.localizedDescription }
            saving = false
        }
    }
}
