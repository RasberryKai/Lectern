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
    @State private var showAll = false
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
                    HStack {
                        Text(summaryLine).font(Theme.body).foregroundStyle(Theme.quiet)
                        Spacer()
                        if !archived { flashcardsLink }
                    }
                    if !slots.isEmpty { numberedSlots }
                    table
                    lectureArchive
                }
                .padding(.horizontal, 40).padding(.vertical, 36)
                .frame(maxWidth: 1240, alignment: .leading)
            }
        }
        .task(id: model.dashboard) { await load() }
    }

    private func load() async {
        do {
            allLectures = try await model.store.lectures(in: moduleID, includingArchived: true)
        } catch { model.errorMessage = error.localizedDescription }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .bottom, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                if let module {
                    HStack(spacing: 8) {
                        Text(Format.examLine(module.examDate, now: model.studyNow)).eyebrow()
                        if let pace = progress?.cardMakingPaceCaption(now: model.studyNow) {
                            Pill(text: pace, tone: .neutral)
                        }
                    }
                }
                Text(module?.name ?? "Module").font(Theme.heading(56)).tracking(-2.24).lineLimit(1)
            }
            Spacer()
            Button("Module settings") { model.settingsModuleID = moduleID }.buttonStyle(SecondaryButtonStyle())
            Button {
                Task { importing = true; await model.chooseAndImportPDFs(into: moduleID); importing = false }
            } label: {
                if importing { ProgressView().controlSize(.small) } else { Text("Import PDFs") }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(archived || importing)
        }
    }

    private var summaryLine: String {
        guard let progress else {
            return archived ? "Archived · \(Format.count(lectures.count, "lecture"))" : ""
        }
        let outstandingSlides = progress.lectures.flatMap(\.preparationReasons).reduce(into: 0) { count, reason in
            if case .generateMissingCoverage(let pages) = reason { count += pages.count }
        }
        var parts = ["\(progress.cardMakingDoneCount) of \(progress.totals.plannedLectureCount) done"]
        let cardsToReview = progress.lectures.reduce(into: 0) { count, lecture in
            if lecture.status == .toReview { count += lecture.reviewCardCount }
        }
        if cardsToReview > 0 {
            parts.append("\(Format.count(cardsToReview, "card")) to review")
        }
        if outstandingSlides > 0 {
            parts.append("\(Format.count(outstandingSlides, "slide")) left to prepare")
        }
        return parts.joined(separator: " · ")
    }

    private var flashcardsLink: some View {
        let approved = model.studyCatalog.decks.first { $0.module.id == moduleID }?.approvedCount ?? 0
        let verb = approved == 1 ? "is" : "are"
        return Button {
            model.selection = .flashcards
        } label: {
            HStack(spacing: 6) {
                Text("\(Format.count(approved, "approved card")) \(verb) in Flashcards")
                Image(systemName: "arrow.right").accessibilityHidden(true)
            }.font(Theme.body.weight(.semibold)).foregroundStyle(Theme.accentText)
        }.buttonStyle(.plain)
    }

    private var numberedSlots: some View {
        GeometryReader { geometry in
            let count = CGFloat(max(1, slots.count))
            let slotWidth = min(96, max(34, (geometry.size.width - (count - 1) * 6) / count))
            ScrollView(.horizontal) {
                LazyHStack(spacing: 6) {
                    ForEach(slots) { slot in
                        let status = slot.status.cardMakingStatus
                        Button {
                            if let id = slot.lectureID {
                                if let lecture = progress?.lectures.first(where: { $0.id == id }) {
                                    LectureDestination.open(lecture, in: moduleID, model: model)
                                } else { model.openLecture(LectureRef(moduleID: moduleID, lectureID: id), mode: nil) }
                            } else { Task { await model.chooseAndImportPDFs(into: moduleID, slot: slot.id.index) } }
                        } label: {
                            Text(String(format: "%02d", slot.id.index)).font(Theme.caption.monospacedDigit().weight(.semibold))
                                .foregroundStyle(slotTextColor(status))
                                .padding(.leading, 8).padding(.bottom, 6)
                                .frame(width: slotWidth, height: 44, alignment: .bottomLeading)
                                .background(status == .notImported ? Theme.surface : Theme.stage(status),
                                            in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(status == .notImported ? Theme.borderStrong : .clear))
                        }
                        .buttonStyle(.plain).disabled(archived && slot.lectureID == nil)
                        .help(slotHelp(slot)).accessibilityLabel(slotHelp(slot))
                        .contextMenu {
                            if !archived {
                                LectureStatusOptions(current: slot.statusOverride?.cardMakingStatus) { status in
                                    Task {
                                        if let lectureID = slot.lectureID {
                                            await model.setLectureStatus(status, for: LectureRef(moduleID: moduleID, lectureID: lectureID))
                                        } else { await model.setEmptySlotStatus(status, for: slot.id) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(height: 48)
        .accessibilityLabel("Lecture slots")
    }

    private func slotTextColor(_ status: LectureProgressStatus) -> Color {
        switch status {
        case .done, .toExport: Theme.onAccent
        case .toReview: Color(hex: 0x0E1E30)
        case .preparing: Color(hex: 0x3A2A12)
        case .notImported: Theme.quiet
        }
    }

    private func slotHelp(_ slot: LectureSlot) -> String {
        let name = "Lecture \(String(format: "%02d", slot.id.index))"
        return "\(name) · \(Format.statusLabel(slot.status.cardMakingStatus))\(slot.statusOverride == nil ? "" : " · Manual")"
    }

    // MARK: Table

    private var table: some View {
        let allSlots = slots
        let lastOccupied = allSlots.last { $0.lectureID != nil || $0.statusOverride != nil }?.id.index ?? 0
        let visibleCount = showAll ? allSlots.count : min(allSlots.count, lastOccupied + 2)
        return LazyVStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Lecture").frame(maxWidth: .infinity, alignment: .leading)
                Text("Slides").frame(width: 75, alignment: .leading)
                Text("Cards").frame(width: 150, alignment: .leading)
                Text("Progress").frame(width: 170, alignment: .leading)
                Color.clear.frame(width: 76)
            }
            .eyebrow()
            .padding(.horizontal, 20).padding(.vertical, 12)
            Divider().overlay(Theme.border)
            if lectures.isEmpty && (module?.plannedLectureCount ?? 0) == 0 {
                Text("No lectures yet. Drop lecture PDFs here or use Import PDFs….")
                    .font(Theme.body).foregroundStyle(Theme.quiet).padding(24)
            }
            ForEach(allSlots.prefix(visibleCount)) { slot in
                if let lectureID = slot.lectureID, let lecture = lectures.first(where: { $0.id == lectureID }) {
                    LectureRow(slotNumber: slot.id.index, lecture: lecture,
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
            } else if visibleCount < allSlots.count || showAll && lastOccupied + 2 < allSlots.count {
                HStack {
                    Text(showAll ? "All planned lectures" : "\(String(format: "%02d", visibleCount + 1)) to \(allSlots.count) planned · drop PDFs anywhere on the list")
                        .font(Theme.small).foregroundStyle(Theme.quiet)
                    Spacer()
                    Button(showAll ? "Show fewer" : "Show all") { showAll.toggle() }.buttonStyle(LinkButtonStyle())
                }.padding(.horizontal, 20).padding(.vertical, 12)
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, lineWidth: 1))
        .coordinateSpace(.named("lectureTable"))
        .onDrop(of: [.fileURL], delegate: PDFDropDelegate(count: $dropCount, lectureID: $dropLectureID, slot: $dropSlot, enabled: !archived,
                                                          lectureAt: lectureAccepting, slotAt: { point in
            emptyRowFrames.first { $0.value.contains(point) }?.key
        }) { urls, lectureID, slot in
            if let lectureID { Task { await model.openPDFEditor(for: LectureRef(moduleID: moduleID, lectureID: lectureID), adding: urls) } }
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
                Text("Not imported").italic().foregroundStyle(Theme.quiet)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(slot.statusOverride.map { "\(Format.statusLabel($0.cardMakingStatus)) · Manual" } ?? "Drop a PDF on this row")
                .font(Theme.small).foregroundStyle(Theme.quiet)
            Button("Import") { Task { await model.chooseAndImportPDFs(into: moduleID, slot: slot.id.index) } }
                .buttonStyle(LinkButtonStyle()).disabled(archived || importing)
                .frame(width: 76, alignment: .trailing)
                .accessibilityLabel("Import PDF for lecture \(slot.id.index)")
        }
        .font(Theme.body)
        .padding(.horizontal, 20).padding(.vertical, 14)
        .background(dropSlot == slot.id.index && dropCount > 0 ? Theme.goodWash : Color.clear)
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
    let slotNumber: Int
    let lecture: Lecture
    let progress: LectureProgress?
    let archived: Bool
    /// Files hovering over this row, 0 when none.
    var dropCount: Int = 0
    let open: (LectureMode?) -> Void
    let archive: () -> Void

    private var ref: LectureRef { LectureRef(moduleID: lecture.moduleID, lectureID: lecture.id) }

    private var lectureName: String { Format.lectureName(lecture.name, slotNumber: slotNumber) }

    private var activeCards: [Card] { lecture.cards.filter { !$0.isSuperseded } }

    var body: some View {
        HStack(spacing: 0) {
            Button { open(nil) } label: {
                Text(lectureName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(lecture.pageCount > 0 ? "\(lecture.slides.filter(\.isSelected).count) / \(lecture.pageCount)" : "No slides")
                .foregroundStyle(Theme.quiet).frame(width: 75, alignment: .leading)
            Text(cardsText).frame(width: 150, alignment: .leading)
            status.frame(width: 170, alignment: .leading)
            rowAction.frame(width: 76, alignment: .trailing)
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
            Button("Move lecture…") { model.movingLecture = ref }.disabled(archived)
            Button("Edit PDFs…") { Task { await model.openPDFEditor(for: ref) } }
                .disabled(archived || lecture.pageCount == 0)
            if !archived, let progress {
                Menu("Lecture status") {
                    LectureStatusOptions(current: progress.statusOverride?.cardMakingStatus) { status in
                        Task { await model.setLectureStatus(status, for: ref) }
                    }
                }
            }
            Divider()
            Button("Export Lecture Backup…") { exportBackup() }
            Divider()
            Button("Archive Lecture", action: archive).disabled(archived)
        }
    }

    private var dropTarget: some View {
        HStack(spacing: 12) {
            Image(systemName: "plus.rectangle.on.rectangle").font(.system(size: 15, weight: .medium))
            Text("Drop to add \(Format.count(dropCount, "PDF")) to \(lectureName)")
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
        if activeCards.isEmpty { return "No cards yet" }
        let total = Format.count(activeCards.count, "card")
        guard let progress else { return total }
        switch progress.status {
        case .toReview: return "\(total) · \(progress.reviewCardCount) to review"
        default: return total
        }
    }

    @ViewBuilder private var rowAction: some View {
        let button = Button(progress.map { LectureDestination.label($0.status) } ?? "Open") {
            if let progress { LectureDestination.open(progress, in: lecture.moduleID, model: model) }
            else { open(nil) }
        }
        if progress?.status == .toReview { button.buttonStyle(PrimaryButtonStyle()) }
        else { button.buttonStyle(SecondaryButtonStyle()) }
    }

    @ViewBuilder private var status: some View {
        if let progress {
            let label = Format.statusLabel(progress.status.cardMakingStatus)
            LectureSteps(status: progress.status)
                .help(progress.statusOverride == nil ? label : "\(label) · Manual")
        } else { Text(archived ? "Archived" : "—").foregroundStyle(Theme.quiet) }
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


struct MoveLectureSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let ref: LectureRef
    @State private var module: Module?
    @State private var name = ""
    @State private var destination = ""
    @State private var error: String?
    @State private var saving = false
    @FocusState private var destinationFocused: Bool

    private var slot: Int? { Int(destination.trimmingCharacters(in: .whitespacesAndNewlines)) }
    private var currentSlot: Int? { module?.lectureSlots[ref.lectureID] }
    private var validation: String? {
        guard let module else { return nil }
        guard let slot, (1...Module.maximumPlannedLectureCount).contains(slot) else {
            return "Enter a whole number from 1 to \(Module.maximumPlannedLectureCount)."
        }
        if slot == currentSlot { return "This presentation is already Lecture \(slot)." }
        if module.lectureSlots.values.contains(slot) { return "Lecture \(slot) already has a presentation. Choose an empty slot." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Move lecture").font(Theme.heading(26))
            if let currentSlot {
                Text(Format.lectureTitle(index: currentSlot - 1, name: name))
                    .font(Theme.body).foregroundStyle(Theme.quiet).lineLimit(2)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("New lecture number").font(.system(size: 13, weight: .semibold))
                TextField("e.g. 5", text: $destination)
                    .textFieldStyle(.roundedBorder).focused($destinationFocused)
                    .accessibilityLabel("New lecture number").onSubmit(save)
            }
            Text("Slides, notes, cards, chats, history and status move together. The old slot becomes empty; other lectures keep their numbers.")
                .font(Theme.body).foregroundStyle(Theme.quiet).fixedSize(horizontal: false, vertical: true)
            if let module, let slot, validation == nil {
                if slot > module.plannedLectureCount {
                    Text("The module plan will expand to \(slot) lectures.")
                        .font(Theme.small).foregroundStyle(Theme.quiet)
                }
                if let status = module.slotStatusOverrides[slot] {
                    Text("Replaces Lecture \(slot)'s manual “\(Format.statusLabel(status))” status with this lecture's status.")
                        .font(Theme.small).foregroundStyle(Theme.amber)
                }
            }
            if !destination.isEmpty, let validation {
                Text(validation).font(Theme.small).foregroundStyle(Theme.quiet)
            }
            if let error { ErrorBanner(message: error) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Move", action: save)
                    .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(module == nil || saving || validation != nil)
            }
        }
        .padding(28).frame(width: 480).background(Theme.surface)
        .disabled(saving).interactiveDismissDisabled(saving)
        .task {
            do {
                module = try await model.store.loadModule(moduleID: ref.moduleID)
                name = try await model.store.loadLecture(moduleID: ref.moduleID, lectureID: ref.lectureID).name
                destinationFocused = true
            } catch { self.error = error.localizedDescription }
        }
    }

    private func save() {
        guard !saving, module != nil, validation == nil, let slot else { return }
        saving = true
        Task {
            do {
                try await model.moveLecture(ref, toSlot: slot)
                dismiss()
            } catch { self.error = error.localizedDescription }
            saving = false
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
            Text("Rename presentation").font(Theme.heading(26))
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
