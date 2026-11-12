import LecternCore
import SwiftUI
import UniformTypeIdentifiers

struct ModuleView: View {
    @Environment(AppModel.self) private var model
    let moduleID: UUID

    @State private var allLectures: [Lecture] = []
    @State private var showArchive = false

    private var lectures: [Lecture] { allLectures.filter { !$0.isArchived } }
    private var archivedLectures: [Lecture] { allLectures.filter(\.isArchived) }
    @State private var rulesSummary = ""
    @State private var editingInstructions = false
    @State private var instructionsDraft = ""
    /// Number of files hovering over the lecture list, 0 when nothing is dragged over it.
    @State private var dropCount = 0
    /// The lecture under the cursor while dropping: the files are added to it instead of becoming a new lecture.
    @State private var dropLectureID: UUID?
    @State private var rowFrames: [UUID: CGRect] = [:]
    @State private var emptyRowFrames: [Int: CGRect] = [:]
    @State private var dropSlot: Int?
    @State private var importing = false

    private var module: Module? { model.module(moduleID) }
    private var progress: ModuleProgress? { model.progress(moduleID) }
    private var archived: Bool { module?.isArchived ?? false }
    private var slots: [LectureSlot] {
        if let progress { return progress.slots }
        guard let module else { return [] }
        let positions = module.resolvedLectureSlots(for: lectures.map(\.id))
        let bySlot = Dictionary(uniqueKeysWithValues: positions.map { ($0.value, $0.key) })
        return (0..<module.plannedLectureCount).map { index in
            LectureSlot(id: .init(moduleID: moduleID, index: index + 1), lectureID: bySlot[index + 1],
                        status: module.slotStatusOverrides[index + 1] ?? .notImported,
                        statusOverride: module.slotStatusOverrides[index + 1])
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if archived { ReadOnlyBanner() }
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    if let progress, !progress.slots.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            SlotStrip(slots: progress.slots, height: 18) { slot in
                                if let lectureID = slot.lectureID {
                                    model.openLecture(LectureRef(moduleID: moduleID, lectureID: lectureID), mode: nil)
                                } else if !archived {
                                    Task { await model.chooseAndImportPDFs(into: moduleID, slot: slot.id.index) }
                                }
                            }
                            Text("Click an empty lecture block to import its PDF. Right-click to set its status.")
                                .font(Theme.small).foregroundStyle(Theme.quiet)
                        }
                    }
                    table
                    lectureArchive
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
            allLectures = try await model.store.lectures(in: moduleID, includingArchived: true)
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
                if importing { ProgressView().controlSize(.small) } else { Text("Import PDFs…") }
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
        LazyVStack(spacing: 0) {
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
                Text("No lectures yet. Drop lecture PDFs here or use Import PDFs….")
                    .font(Theme.body).foregroundStyle(Theme.quiet).padding(24)
            }
            ForEach(slots) { slot in
                if let lectureID = slot.lectureID, let lecture = lectures.first(where: { $0.id == lectureID }) {
                    LectureRow(index: slot.id.index - 1, lecture: lecture,
                               progress: progress?.lectures.first { $0.lectureID == lecture.id }, archived: archived,
                               dropCount: dropLectureID == lecture.id ? dropCount : 0) { mode in
                        model.openLecture(LectureRef(moduleID: moduleID, lectureID: lecture.id), mode: mode)
                    } archive: {
                        setArchived(true, lecture: lecture)
                    }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("lectureTable")) } action: { rowFrames[lecture.id] = $0 }
                    .onDisappear { rowFrames[lecture.id] = nil }
                } else {
                    emptySlotRow(slot)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("lectureTable")) } action: { emptyRowFrames[slot.id.index] = $0 }
                        .onDisappear { emptyRowFrames[slot.id.index] = nil }
                }
                Divider().overlay(Theme.border)
            }
            if dropCount > 0 && dropLectureID == nil && dropSlot == nil {
                dropTarget
            } else {
                Text("Drop PDFs on an empty slot to import there, or on an existing lecture to add slides.")
                    .font(Theme.small).foregroundStyle(Theme.quiet)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.vertical, 12)
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, lineWidth: 1))
        .coordinateSpace(.named("lectureTable"))
        .onDrop(of: [.fileURL], delegate: PDFDropDelegate(count: $dropCount, lectureID: $dropLectureID, slot: $dropSlot, enabled: !archived,
                                                          lectureAt: lectureAccepting, slotAt: { point in
            emptyRowFrames.first { $0.value.contains(point) }?.key
        }) { urls, lectureID, slot in
            if let lectureID { Task { await model.appendPDFs(urls, to: LectureRef(moduleID: moduleID, lectureID: lectureID)) } }
            else { Task { await model.importPDFs(urls, into: moduleID, slot: slot) } }
        })
    }

    /// A lecture row under `point` that can take more pages (it has slides).
    private func lectureAccepting(_ point: CGPoint) -> UUID? {
        lectures.first { $0.pageCount > 0 && rowFrames[$0.id]?.contains(point) == true }?.id
    }

    @ViewBuilder private var lectureArchive: some View {
        if !archivedLectures.isEmpty {
            DisclosureGroup(isExpanded: $showArchive) {
                ForEach(archivedLectures) { lecture in
                    HStack {
                        Text(lecture.name)
                        Spacer()
                        Button("Restore") { setArchived(false, lecture: lecture) }
                            .buttonStyle(LinkButtonStyle())
                            .disabled(archived)
                    }
                    .padding(.vertical, 8)
                }
            } label: {
                Text("Archived lectures (\(archivedLectures.count))")
            }
        }
    }

    private func setArchived(_ archived: Bool, lecture: Lecture) {
        Task {
            await model.perform {
                try await model.store.setLectureArchived(moduleID: moduleID, lectureID: lecture.id, archived: archived)
                await load()
                try await model.reloadNow()
            }
        }
    }

    /// The next slot as a dashed drop target while files hover over the list.
    private var dropTarget: some View {
        let slot = String(format: "%02d", progress?.slots.first { $0.lectureID == nil && $0.status != .done }?.id.index ?? ((module?.plannedLectureCount ?? 0) + 1))
        let what = dropCount == 1 ? "Drop to import as lecture \(slot)" : "Drop to import \(dropCount) PDFs as lecture \(slot)"
        return HStack(spacing: 12) {
            Image(systemName: "arrow.down.to.line").font(.system(size: 15, weight: .medium))
            Text(slot).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
            Text(what).font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity, alignment: .leading)
            if dropCount > 1 { Text("You set the order next").font(Theme.small) }
        }
        .foregroundStyle(Theme.accentText)
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(Theme.goodWash, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    private func emptySlotRow(_ slot: LectureSlot) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(String(format: "%02d", slot.id.index)).font(.system(size: 13, weight: .semibold))
                Text("Not imported yet").italic().foregroundStyle(Theme.quiet)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("—").foregroundStyle(Theme.quiet).frame(width: 150, alignment: .leading)
            Text("—").foregroundStyle(Theme.quiet).frame(width: 220, alignment: .leading)
            Menu {
                LectureStatusOptions(current: slot.statusOverride) { status in
                    Task { await model.setEmptySlotStatus(status, for: slot.id) }
                }
            } label: {
                if let status = slot.statusOverride {
                    Pill(text: "\(Format.statusLabel(status)) · Manual", tone: .neutral)
                } else {
                    Pill(text: "Planned", tone: .outline)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(archived)
            .frame(width: 300, alignment: .leading)
            Button("Import PDF") { Task { await model.chooseAndImportPDFs(into: moduleID, slot: slot.id.index) } }
                .buttonStyle(LinkButtonStyle()).disabled(archived || importing)
                .frame(width: 90, alignment: .trailing)
                .accessibilityLabel("Import PDF for lecture \(slot.id.index)")
        }
        .font(Theme.body)
        .padding(.horizontal, 20).padding(.vertical, 14)
        .background(dropSlot == slot.id.index && dropCount > 0 ? Theme.goodWash : Color.clear)
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

/// File drops on the lecture list. Reports how many files hover so the next slot can say
/// "Drop to import 3 PDFs as lecture 05"; one PDF imports directly, several open the import sheet.
private struct PDFDropDelegate: DropDelegate {
    @Binding var count: Int
    /// Set while the cursor is over a lecture that can take more pages.
    @Binding var lectureID: UUID?
    @Binding var slot: Int?
    let enabled: Bool
    let lectureAt: (CGPoint) -> UUID?
    let slotAt: (CGPoint) -> Int?
    /// The dropped files, and the lecture to add them to (nil: a new lecture).
    let perform: ([URL], UUID?, Int?) -> Void

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL]) }
    func dropEntered(info: DropInfo) {
        guard enabled else { return }
        count = info.itemProviders(for: [.fileURL]).count
        lectureID = lectureAt(info.location)
        slot = slotAt(info.location)
    }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        if enabled {
            let hovered = lectureAt(info.location)
            if hovered != lectureID { lectureID = hovered }
            let hoveredSlot = slotAt(info.location)
            if hoveredSlot != slot { slot = hoveredSlot }
        }
        return DropProposal(operation: enabled ? .copy : .forbidden)
    }
    func dropExited(info: DropInfo) { count = 0; lectureID = nil; slot = nil }

    func performDrop(info: DropInfo) -> Bool {
        let target = lectureAt(info.location)
        let targetSlot = slotAt(info.location)
        count = 0; lectureID = nil; slot = nil
        guard enabled else { return false }
        let providers = info.itemProviders(for: [.fileURL])
        Task {
            var urls: [URL] = []
            for provider in providers {
                let url: URL? = await withCheckedContinuation { continuation in
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
                }
                if let url { urls.append(url) }
            }
            if !urls.isEmpty { perform(urls, target, targetSlot) }
        }
        return true
    }
}

private struct LectureRow: View {
    @Environment(AppModel.self) private var model
    let index: Int
    let lecture: Lecture
    let progress: LectureProgress?
    let archived: Bool
    /// Files hovering over this row, 0 when none.
    var dropCount: Int = 0
    let open: (LectureMode?) -> Void
    let archive: () -> Void

    private var ref: LectureRef { LectureRef(moduleID: lecture.moduleID, lectureID: lecture.id) }

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
            Button(progress?.automaticStatus == .toReview ? "Review" : "Open") { open(progress?.automaticStatus == .toReview ? .review : nil) }
                .buttonStyle(LinkButtonStyle())
                .frame(width: 90, alignment: .trailing)
        }
        .font(Theme.body)
        .padding(.horizontal, 20).padding(.vertical, 14)
        .contentShape(Rectangle())
        .overlay { if dropCount > 0 { dropTarget } }
        .contextMenu {
            Button("Open in Prepare") { open(.prepare) }.disabled(lecture.pageCount == 0)
            Button("Open in Review") { open(.review) }
            Button("Rename presentation…") {
                model.renamingLecture = LectureRef(moduleID: lecture.moduleID, lectureID: lecture.id)
            }.disabled(archived)
            Button("Add PDFs…") { Task { await model.chooseAndAppendPDFs(to: ref) } }
                .disabled(archived || lecture.pageCount == 0)
            if !archived, let progress {
                Menu("Lecture status") {
                    LectureStatusOptions(current: progress.statusOverride) { status in
                        Task { await model.setLectureStatus(status, for: ref) }
                    }
                }
            }
            Divider()
            Button("Export Lecture Backup…") { exportBackup() }
            Button("Export Lecture to Anki…") { model.selection = .export(lecture.moduleID) }
            Divider()
            Button("Archive Lecture", action: archive).disabled(archived)
        }
    }

    private var dropTarget: some View {
        HStack(spacing: 12) {
            Image(systemName: "plus.rectangle.on.rectangle").font(.system(size: 15, weight: .medium))
            Text("Drop to add \(Format.count(dropCount, "PDF")) to \(Format.lectureTitle(index: index, name: lecture.name)) after slide \(lecture.pageCount)")
                .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("You set the order next").font(Theme.small)
        }
        .foregroundStyle(Theme.accentText)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.goodWash, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
        .padding(.horizontal, 10).padding(.vertical, 4)
    }

    private var cardsText: String {
        let approved = activeCards.filter { $0.verdict == .good }.count
        let review = progress?.reviewCardCount ?? 0
        if activeCards.isEmpty { return "None yet" }
        return review > 0 ? "\(approved) approved · \(review) to review" : "\(approved) approved"
    }

    @ViewBuilder private var status: some View {
        if let manual = progress?.statusOverride {
            Pill(text: "\(Format.statusLabel(manual)) · Manual", tone: .neutral)
        } else if let generate = lecture.jobs.first(where: { $0.kind == .generate && $0.state == .running }) {
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
