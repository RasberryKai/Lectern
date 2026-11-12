import LecternCore
import SwiftUI

/// Several PDFs, one lecture: name it, put the files in order, press Import.
/// The order is final once imported; afterwards it is a normal lecture.
/// The same sheet adds PDFs after the last slide of an existing lecture.
struct ImportPDFsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let pending: PendingPDFImport

    @State private var files: [PendingPDFImport.File] = []
    @State private var name = ""
    @State private var error: String?
    @State private var importing = false
    @State private var loaded = false

    private static let rowHeight: CGFloat = 52

    private var totalPages: Int { files.reduce(0) { $0 + $1.pageCount } }
    private var blocked: Bool { files.isEmpty || files.contains { $0.problem != nil } }
    private var module: Module? { model.module(pending.moduleID) }
    /// Pages already in the lecture: 0 for a new one.
    private var existingPages: Int {
        if case .append(_, _, let pages) = pending.target { return pages }
        return 0
    }
    private var isAppend: Bool { existingPages > 0 }

    private var title: String {
        switch pending.target {
        case .newLecture: files.count == 1 ? "Import 1 PDF as a lecture" : "Import \(files.count) PDFs as one lecture"
        case .append(_, let title, _): "Add \(Format.count(files.count, "PDF")) to \(title)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(Theme.serif(26)).lineLimit(2)
                Text(subtitle).font(Theme.small).foregroundStyle(Theme.quiet)
            }

            if !isAppend {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Lecture name").font(.system(size: 13, weight: .semibold))
                    TextField("Lecture name", text: $name)
                        .textFieldStyle(.roundedBorder).controlSize(.large)
                        .onSubmit(save)
                    Text("From the shared start of the file names.").font(Theme.small).foregroundStyle(Theme.quiet)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Order").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("Sorted by file name. Drag to change.").font(Theme.small).foregroundStyle(Theme.quiet)
                }
                fileList
            }

            if let error { ErrorBanner(message: error) }

            HStack(spacing: 10) {
                Text(summary).font(Theme.small).foregroundStyle(blocked ? Theme.bad : Theme.quiet)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Cancel") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button(action: save) {
                    if importing { ProgressView().controlSize(.small).tint(Theme.onAccent) } else { Text(isAppend ? "Add" : "Import") }
                }
                .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                .disabled(blocked || importing)
            }
        }
        .padding(28)
        .frame(width: 540)
        .background(Theme.surface)
        .disabled(importing)
        .interactiveDismissDisabled(importing)
        .onAppear {
            guard !loaded else { return }
            files = pending.files; name = pending.name; loaded = true
        }
    }

    private var subtitle: String {
        let moduleName = module?.name ?? "Module"
        switch pending.target {
        case .newLecture(let number):
            let slot = String(format: "%02d", number)
            let planned = module?.plannedLectureCount ?? 0
            return number <= planned ? "\(moduleName) · fills planned slot \(slot)" : "\(moduleName) · becomes lecture \(slot)"
        case .append(_, _, let pages):
            return "Added after slide \(pages). Existing slides, notes and cards keep their numbers."
        }
    }

    private var summary: String {
        if let bad = files.first(where: { $0.problem != nil }) { return "Leave out \(bad.url.lastPathComponent) to continue." }
        if files.isEmpty { return isAppend ? "No files left to add." : "No files left to import." }
        if isAppend { return "The lecture grows from \(existingPages) to \(existingPages + totalPages) slides. This can't be undone." }
        if files.count == 1 { return "Imported as one \(totalPages)-slide lecture." }
        return "Merged into one \(totalPages)-slide lecture. From here it is a normal lecture."
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
        HStack(spacing: 10) {
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
                Text(file.url.lastPathComponent).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                if let problem = file.problem {
                    Text(problem).font(Theme.small).foregroundStyle(Theme.bad).lineLimit(1)
                } else {
                    Text("\(Format.count(file.pageCount, "page")) · becomes \(range(for: index))")
                        .font(Theme.small).foregroundStyle(Theme.quiet)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                files.removeAll { $0.id == file.id }
            } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.quiet)
            .help("Leave this file out")
            .accessibilityLabel("Leave \(file.url.lastPathComponent) out")
        }
        .frame(height: Self.rowHeight)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Move Up") { files.swapAt(index, index - 1) }.disabled(index == 0)
            Button("Move Down") { files.swapAt(index, index + 1) }.disabled(index == files.count - 1)
            Divider()
            Button("Leave Out") { files.removeAll { $0.id == file.id } }
        }
    }

    private func range(for index: Int) -> String {
        let start = existingPages + files.prefix(index).reduce(0) { $0 + $1.pageCount } + 1
        let end = start + files[index].pageCount - 1
        return start == end ? "slide \(start)" : "slides \(start)–\(end)"
    }

    private func save() {
        guard !blocked, !importing else { return }
        importing = true; error = nil
        let urls = files.map(\.url)
        Task {
            do {
                switch pending.target {
                case .newLecture(let slot): try await model.importMerged(urls, name: name, into: pending.moduleID, slot: slot)
                case .append(let lectureID, _, _): try await model.appendConfirmed(urls, to: LectureRef(moduleID: pending.moduleID, lectureID: lectureID))
                }
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            importing = false
        }
    }
}
