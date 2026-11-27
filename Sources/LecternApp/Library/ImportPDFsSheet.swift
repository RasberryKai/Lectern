import LecternCore
import SwiftUI
import UniformTypeIdentifiers

/// Orders the PDF files for a new or existing lecture.
struct ImportPDFsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let pending: PendingPDFImport

    @State private var files: [PendingPDFImport.File] = []
    @State private var removedFiles: [PendingPDFImport.File] = []
    @State private var removalConfirmation: LecturePDFRemovalImpact?
    @State private var name = ""
    @State private var error: String?
    @State private var importing = false
    @State private var choosingFiles = false
    @State private var inspectingFiles = false
    @State private var splitFileID: UUID?
    @State private var splitSlide = ""

    init(pending: PendingPDFImport) {
        self.pending = pending
        _files = State(initialValue: pending.files)
        _name = State(initialValue: pending.name)
    }

    private static let rowHeight: CGFloat = 52

    private var totalPages: Int { files.reduce(0) { $0 + $1.pageCount } }
    private var blocked: Bool { (!isEditing && files.isEmpty) || files.contains { $0.problem != nil } }
    private var module: Module? { model.module(pending.moduleID) }
    private var isEditing: Bool {
        if case .edit = pending.target { return true }
        return false
    }
    private var hasEdits: Bool {
        guard case .edit(_, _, let existingParts) = pending.target else { return true }
        let currentParts = files.compactMap { file -> LecturePDFPart? in
            if case .existing(let part, _) = file.edit { return part }
            return nil
        }
        return files.count != currentParts.count || currentParts != existingParts
    }
    private var title: String {
        switch pending.target {
        case .newLecture: files.count == 1 ? "Import 1 PDF as a lecture" : "Import \(files.count) PDFs as one lecture"
        case .edit: "Edit PDFs"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(Theme.heading(26)).lineLimit(2)
                Text(subtitle).font(Theme.small).foregroundStyle(Theme.quiet)
            }

            if !isEditing {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Lecture name").font(.system(size: 13, weight: .semibold))
                    TextField("Lecture name", text: $name)
                        .textFieldStyle(.roundedBorder).controlSize(.large)
                        .onSubmit { save() }
                    Text("From the shared start of the file names.").font(Theme.small).foregroundStyle(Theme.quiet)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text(isEditing ? "PDF order" : "Order").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(isEditing ? "Drag to reorder" : "Sorted by file name. Drag to change.")
                        .font(Theme.small).foregroundStyle(Theme.quiet)
                    if isEditing {
                        if inspectingFiles { ProgressView().controlSize(.small) }
                        Button("Add PDFs…") { choosingFiles = true }
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(inspectingFiles)
                    }
                }
                fileList
                if let splitFileID, let file = files.first(where: { $0.id == splitFileID }),
                   case .existing(_, let pages) = file.edit {
                    splitControls(file, pages: pages)
                }
            }

            if let error { ErrorBanner(message: error) }

            HStack(spacing: 10) {
                Text(summary).font(Theme.small).foregroundStyle(blocked ? Theme.bad : Theme.quiet)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Cancel") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button {
                    save()
                } label: {
                    if importing { ProgressView().controlSize(.small).tint(Theme.onAccent) } else { Text(isEditing ? "Save Changes" : "Import") }
                }
                .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                .disabled(blocked || importing || inspectingFiles || !hasEdits || splitFileID != nil)
            }
        }
        .padding(28)
        .frame(width: 540)
        .background(Theme.surface)
        .disabled(importing)
        .interactiveDismissDisabled(importing)
        .alert(removalTitle, isPresented: Binding(
            get: { removalConfirmation != nil },
            set: { if !$0 { removalConfirmation = nil } }
        ), presenting: removalConfirmation) { confirmation in
            Button(removedFiles.count == 1 ? "Remove PDF" : "Remove PDFs", role: .destructive) {
                save(confirming: confirmation)
            }
            Button("Cancel", role: .cancel) {}
        } message: { confirmation in
            Text(removalMessage(confirmation))
        }
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                inspectingFiles = true
                error = nil
                Task {
                    files += await model.inspectPDFs(PDFMerge.naturalOrder(urls))
                    inspectingFiles = false
                }
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }

    private var subtitle: String {
        let moduleName = module?.name ?? "Module"
        switch pending.target {
        case .newLecture(let number):
            let slot = String(format: "%02d", number)
            let planned = module?.plannedLectureCount ?? 0
            return number <= planned ? "\(moduleName) · fills planned slot \(slot)" : "\(moduleName) · becomes lecture \(slot)"
        case .edit(_, let title, _):
            return title
        }
    }

    private var summary: String {
        if let bad = files.first(where: { $0.problem != nil }) { return "Leave out \(bad.filename) to continue." }
        if files.isEmpty { return isEditing ? "This lecture will have no PDFs." : "No files left to import." }
        if isEditing { return "\(Format.count(files.count, "PDF")) · \(Format.count(totalPages, "slide"))" }
        if files.count == 1 { return "Imported as one \(totalPages)-slide lecture." }
        return "Merged into one \(totalPages)-slide lecture."
    }

    private var removalTitle: String {
        if removedFiles.count == 1, let file = removedFiles.first { return "Remove “\(file.filename)”?" }
        return "Remove \(removedFiles.count) PDFs?"
    }

    private func removalMessage(_ impact: LecturePDFRemovalImpact) -> String {
        var deleted: [String] = []
        if impact.noteCount > 0 { deleted.append(Format.count(impact.noteCount, "slide note")) }
        if impact.deletedCardCount > 0 { deleted.append(Format.count(impact.deletedCardCount, "flashcard")) }
        if impact.slideThreadCount > 0 { deleted.append(Format.count(impact.slideThreadCount, "slide conversation")) }
        var sentences: [String] = []
        if !deleted.isEmpty { sentences.append("This will also remove \(deleted.formatted(.list(type: .and))).") }
        if impact.sharedCardCount > 0 {
            sentences.append("Lectern will keep \(Format.count(impact.sharedCardCount, "flashcard")) that also link to other slides.")
        }
        return sentences.joined(separator: " ")
    }

    private var fileList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                    row(index: index, file: file)
                        .padding(.leading, 4)
                        .padding(.trailing, 6)
                        .overlay(alignment: .bottom) {
                            if index < files.count - 1 { Divider().padding(.leading, 54) }
                        }
                }
            }
        }
        .frame(height: CGFloat(min(max(files.count, 1), 6)) * Self.rowHeight + 2)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
    }

    private func row(index: Int, file: PendingPDFImport.File) -> some View {
        let canSplit = isSplittable(file)
        let existing = if case .existing = file.edit { true } else { false }
        return HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(Theme.faint)
                .frame(width: 24, height: 36)
                .help("Drag to reorder")
                .contentShape(Rectangle())
                .gesture(DragGesture(coordinateSpace: .global).onEnded { drag in
                    let rows = Int((drag.translation.height / Self.rowHeight).rounded())
                    let target = min(max(index + rows, 0), files.count - 1)
                    guard target != index else { return }
                    files.move(fromOffsets: IndexSet(integer: index), toOffset: target > index ? target + 1 : target)
                })
                .accessibilityHidden(true)
            Text("\(index + 1)")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(Theme.inset, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(file.filename).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                if let problem = file.problem {
                    Text(problem).font(Theme.small).foregroundStyle(Theme.bad).lineLimit(1)
                } else {
                    Text("\(Format.count(file.pageCount, "page")) · \(range(for: index))")
                        .font(Theme.small).foregroundStyle(Theme.quiet)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if canSplit {
                Button("Split…") { beginSplit(file) }
                    .buttonStyle(LinkButtonStyle())
                    .help("Set a file boundary in a previously merged PDF")
                    .padding(.trailing, 6)
            }
            Button {
                remove(file)
            } label: {
                Image(systemName: existing ? "trash" : "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.quiet)
            .help(existing ? "Remove this PDF" : "Leave this file out")
            .accessibilityLabel(existing ? "Remove \(file.filename)" : "Leave \(file.filename) out")
        }
        .frame(height: Self.rowHeight)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Move Up") { files.swapAt(index, index - 1) }.disabled(index == 0)
            Button("Move Down") { files.swapAt(index, index + 1) }.disabled(index == files.count - 1)
            if canSplit { Button("Split…") { beginSplit(file) } }
            Divider()
            Button(existing ? "Remove PDF" : "Leave Out") { remove(file) }
        }
    }

    private func remove(_ file: PendingPDFImport.File) {
        guard files.contains(where: { $0.id == file.id }) else { return }
        if case .existing = file.edit { removedFiles.append(file) }
        files.removeAll { $0.id == file.id }
        if splitFileID == file.id { splitFileID = nil }
    }

    private func range(for index: Int) -> String {
        let start = files.prefix(index).reduce(0) { $0 + $1.pageCount } + 1
        let end = start + files[index].pageCount - 1
        return start == end ? "slide \(start)" : "slides \(start)–\(end)"
    }

    private func isSplittable(_ file: PendingPDFImport.File) -> Bool {
        if case .existing(let part, let pages) = file.edit { return part.canSplit && pages.count > 1 }
        return false
    }

    private func beginSplit(_ file: PendingPDFImport.File) {
        splitFileID = file.id
        splitSlide = ""
    }

    private func splitControls(_ file: PendingPDFImport.File, pages: Range<Int>) -> some View {
        let allowedSlides = (pages.lowerBound + 2)...pages.upperBound
        let slide = Int(splitSlide.trimmingCharacters(in: .whitespacesAndNewlines))
        return VStack(alignment: .leading, spacing: 6) {
            Text("This older import has no saved file boundaries. Enter the first slide of the next file using its number in the saved lecture.")
                .font(Theme.small).foregroundStyle(Theme.quiet).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text("Split before slide").font(Theme.body)
                TextField("\(allowedSlides.lowerBound)–\(allowedSlides.upperBound)", text: $splitSlide)
                    .textFieldStyle(.roundedBorder).frame(width: 85)
                    .accessibilityLabel("First slide of the next file")
                Button("Split") {
                    if let slide, allowedSlides.contains(slide) { split(file, pages: pages, at: slide - 1) }
                }
                .disabled(slide.map { !allowedSlides.contains($0) } ?? true)
                Button("Cancel Split") { splitFileID = nil }
            }
        }
    }

    private func split(_ file: PendingPDFImport.File, pages: Range<Int>, at index: Int) {
        guard let position = files.firstIndex(where: { $0.id == file.id }) else { return }
        let first = LecturePDFPart(filename: file.filename, pageCount: index - pages.lowerBound, canSplit: true)
        let second = LecturePDFPart(filename: "Split before slide \(index + 1)", pageCount: pages.upperBound - index, canSplit: true)
        files.replaceSubrange(position...position, with: [
            .init(edit: .existing(first, pages: pages.lowerBound..<index), pageCount: first.pageCount, problem: nil),
            .init(edit: .existing(second, pages: index..<pages.upperBound), pageCount: second.pageCount, problem: nil)
        ])
        splitFileID = nil
    }

    private func save(confirming confirmation: LecturePDFRemovalImpact? = nil) {
        guard !blocked, !importing, !inspectingFiles, hasEdits, splitFileID == nil else { return }
        importing = true; error = nil
        Task {
            do {
                switch pending.target {
                case .newLecture(let slot):
                    let urls = files.compactMap { if case .add(let url) = $0.edit { url } else { nil } }
                    try await model.importMerged(urls, name: name, into: pending.moduleID, slot: slot)
                case .edit(let lectureID, _, let parts):
                    let removedRanges = removedFiles.compactMap { file in
                        if case .existing(_, let pages) = file.edit { pages } else { nil }
                    }
                    try await model.savePDFEdits(files.map(\.edit), removing: removedRanges, confirming: confirmation,
                                                 basedOn: parts, for: LectureRef(moduleID: pending.moduleID, lectureID: lectureID))
                }
                dismiss()
            } catch let impact as LecturePDFRemovalImpact {
                removalConfirmation = impact
            } catch {
                self.error = error.localizedDescription
            }
            importing = false
        }
    }
}
