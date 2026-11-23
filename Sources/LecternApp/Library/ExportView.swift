import AppKit
import LecternCore
import SwiftUI
import UniformTypeIdentifiers

/// Anki export for a module (or one lecture). The preview uses `AnkiExporter.export`, which never
/// marks anything; only a completed Save through `LibraryService.exportAnki` records export marks.
struct ExportView: View {
    @Environment(AppModel.self) private var model
    let moduleID: UUID
    let fromFlashcards: Bool

    @State private var lectures: [Lecture] = []
    @State private var changedOnly = true
    @State private var lectureScope: UUID?
    @State private var preview: AnkiExportResult?
    @State private var previewError: String?
    @State private var saving = false
    @State private var savedMessage: String?
    @State private var savedURL: URL?
    @State private var showSetup = false

    private var module: Module? { model.module(moduleID) }
    private var scopedLectures: [Lecture] { lectureScope.map { id in lectures.filter { $0.id == id } } ?? lectures }

    init(moduleID: UUID, initialLectureID: UUID? = nil, fromFlashcards: Bool = false) {
        self.moduleID = moduleID
        self.fromFlashcards = fromFlashcards
        _lectureScope = State(initialValue: initialLectureID)
        _changedOnly = State(initialValue: !fromFlashcards)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Button { model.selection = fromFlashcards ? .flashcards : .module(moduleID) } label: {
                    Label(fromFlashcards ? "Flashcards" : module?.name ?? "Module", systemImage: "arrow.left").eyebrow()
                }.buttonStyle(.plain)
                Text("Export to Anki").font(Theme.heading(56)).tracking(-2.24)
                HStack(alignment: .top, spacing: 40) {
                    VStack(alignment: .leading, spacing: 16) {
                        whatToExport
                        lectureTable
                        previewTable
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    summary.frame(width: 300)
                }
            }
            .padding(.horizontal, 40).padding(.vertical, 36)
            .frame(maxWidth: 1240, alignment: .leading)
        }
        .task(id: model.dashboard) { await load() }
        .onChange(of: changedOnly) { _, _ in rebuildPreview() }
        .onChange(of: lectureScope) { _, _ in rebuildPreview() }
    }

    private func load() async {
        do {
            lectures = try await model.store.lectures(in: moduleID)
            rebuildPreview()
        } catch { previewError = error.localizedDescription }
    }

    private func rebuildPreview() {
        do {
            preview = try AnkiExporter.export(lectures: scopedLectures, moduleName: module?.name ?? "", changedOnly: changedOnly)
            previewError = nil
        } catch {
            preview = nil
            previewError = LectureWindowModel.describe(error)
        }
    }

    // MARK: Options

    private var changedCount: Int {
        let included = Set(preview?.entries.map(\.cardID) ?? [])
        return scopedLectures.reduce(0) { total, lecture in
            total + lecture.cards.filter { included.contains($0.id) && $0.changedSinceExport }.count
        }
    }

    private var whatToExport: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 2) {
                    Button { lectureScope = nil } label: {
                        scopeLabel("Whole module", selected: lectureScope == nil)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(lectureScope == nil ? .isSelected : [])

                    Menu {
                        Picker("Lecture", selection: $lectureScope) {
                            Text("Whole module").tag(nil as UUID?)
                            Divider()
                            ForEach(Array(lectures.enumerated()), id: \.element.id) { index, lecture in
                                Text(lectureTitle(lecture, fallback: index)).tag(Optional(lecture.id))
                            }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        scopeLabel(scopedLectureTitle, selected: lectureScope != nil, showsMenu: true)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .disabled(lectures.isEmpty)
                    .accessibilityLabel("Choose lecture")
                    .accessibilityValue(lectureScope == nil ? "Whole module" : scopedLectureTitle)
                }
                .padding(3)
                .background(Theme.inset, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border))
                Spacer()
                Menu {
                    Button("New and changed cards") { changedOnly = true }
                    Button("All approved cards") { changedOnly = false }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Export options")
            }
            Text(changedOnly ? "Approved cards that are new or changed since the last export" : "All approved cards, including previous exports")
                .font(Theme.small).foregroundStyle(Theme.quiet)
        }
    }

    private func scopeLabel(_ title: String, selected: Bool, showsMenu: Bool = false) -> some View {
        HStack(spacing: 7) {
            Text(title).lineLimit(1).truncationMode(.tail)
            if showsMenu {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    .accessibilityHidden(true)
            }
        }
        .font(.system(size: 13, weight: selected ? .semibold : .medium))
        .foregroundStyle(selected ? Theme.ink : Theme.quiet)
        .padding(.horizontal, 12).frame(height: 29)
        .background(selected ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Theme.borderStrong : .clear))
        .contentShape(Rectangle())
    }

    private var scopedLectureTitle: String {
        guard let lectureScope, let index = lectures.firstIndex(where: { $0.id == lectureScope }) else {
            return "Choose lecture"
        }
        return lectureTitle(lectures[index], fallback: index)
    }

    private func lectureTitle(_ lecture: Lecture, fallback: Int) -> String {
        Format.lectureTitle(index: module?.lectureSlots[lecture.id].map { $0 - 1 } ?? fallback, name: lecture.name)
    }

    // MARK: Per lecture

    private var lectureTable: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Lecture").frame(maxWidth: .infinity, alignment: .leading)
                Text("Included").frame(width: 76, alignment: .leading)
                Text("Left out").frame(width: 136, alignment: .leading)
            }
            .eyebrow().padding(.horizontal, 18).padding(.vertical, 10)
            ForEach(Array(scopedLectures.enumerated()), id: \.element.id) { fallback, lecture in
                Divider().overlay(Theme.border)
                HStack {
                    Text(lectureTitle(lecture, fallback: fallback)).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                    Text(included(lecture)).frame(width: 76, alignment: .leading)
                    Text(leftOut(lecture)).foregroundStyle(Theme.quiet).frame(width: 136, alignment: .leading).lineLimit(2)
                }
                .font(Theme.body)
                .padding(.horizontal, 18).padding(.vertical, 11)
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
    }

    private func included(_ lecture: Lecture) -> String {
        String(preview?.entries.filter { $0.lectureID == lecture.id }.count ?? 0)
    }

    private enum Exclusion: String, CaseIterable {
        case bad = "Bad"
        case math = "ambiguous math"
        case unreviewed = "not reviewed yet"
        case exported = "already in Anki"
    }

    private func exclusions(_ lecture: Lecture) -> [Exclusion: Int] {
        var counts: [Exclusion: Int] = [:]
        for card in lecture.cards where !card.isSuperseded {
            if lecture.issues(for: card).contains(where: { $0.kind == .unresolvedMath }) {
                counts[.math, default: 0] += 1
                continue
            }
            switch card.verdict {
            case .bad: counts[.bad, default: 0] += 1
            case .needsAdjustment: counts[.unreviewed, default: 0] += 1
            case .unreviewed: counts[.unreviewed, default: 0] += 1
            case .good:
                if changedOnly && card.exported != nil && !card.changedSinceExport {
                    counts[.exported, default: 0] += 1
                }
            }
        }
        return counts
    }

    private func leftOut(_ lecture: Lecture) -> String {
        guard lecture.cards.contains(where: { !$0.isSuperseded }) else { return "No cards yet" }
        let counts = exclusions(lecture)
        let reasons = Exclusion.allCases.compactMap { reason in
            counts[reason].map { "\($0) \(reason.rawValue)" }
        }
        return reasons.isEmpty ? "None" : reasons.joined(separator: " · ")
    }

    // MARK: Preview

    private struct PreviewRow: Identifiable {
        let id: UUID
        let front: String
        let back: String
        let tags: String
    }

    private var previewRows: [PreviewRow] {
        guard let preview else { return [] }
        // The final column is the tag. Front and back can contain quoted tabs, so
        // display their source values with the same math conversion as the exporter.
        let tags = preview.text.split(separator: "\n").filter { !$0.hasPrefix("#") }
            .prefix(3).map { $0.split(separator: "\t").last.map(String.init) ?? "" }
        return zip(preview.entries.prefix(3), tags).compactMap { entry, tag in
            guard let lecture = lectures.first(where: { $0.id == entry.lectureID }),
                  let card = lecture.cards.first(where: { $0.id == entry.cardID }),
                  let front = try? FlashcardMathFormatter.formatForAnki(card.front, interpretations: card.mathInterpretations),
                  let back = try? FlashcardMathFormatter.formatForAnki(card.back, interpretations: card.mathInterpretations)
            else { return nil }
            return PreviewRow(id: card.id, front: front, back: back, tags: tag)
        }
    }

    private var previewTable: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Preview").font(.headline)
                Spacer()
                Text("Front, Back, Tags").font(Theme.small).foregroundStyle(Theme.quiet)
            }
            if let previewError {
                ErrorBanner(message: previewError)
            } else if previewRows.isEmpty {
                Text(changedOnly ? "Nothing new or changed since the last export." : "No approved cards yet.")
                    .font(Theme.body).foregroundStyle(Theme.quiet)
            } else {
                VStack(spacing: 0) {
                    ForEach(previewRows) { row in
                        Divider().overlay(Theme.border)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.front).font(.system(size: 13, weight: .semibold))
                            Text(row.back).font(Theme.body).foregroundStyle(Theme.quiet)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 10)
                        .help(row.tags)
                    }
                    if let count = preview?.entries.count, count > previewRows.count {
                        Divider().overlay(Theme.border)
                        Text("and \(count - previewRows.count) more").font(Theme.small).foregroundStyle(Theme.quiet)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 8)
                    }
                }
            }
        }.panel(padding: 18)
    }

    // MARK: Summary and actions

    private var summary: some View {
        let count = preview?.entries.count ?? 0
        let ambiguous = scopedLectures.reduce(0) { $0 + exclusions($1)[.math, default: 0] }
        return VStack(alignment: .leading, spacing: 12) {
            Text("\(Format.count(count, "card")) ready").font(Theme.heading(30))
            let changed = changedCount
            if changed > 0 {
                Text("\(changed) changed since the last export").font(Theme.small).foregroundStyle(Theme.quiet)
            }
            if ambiguous > 0 {
                Text("\(Format.count(ambiguous, "card")) \(ambiguous == 1 ? "has" : "have") ambiguous math and \(ambiguous == 1 ? "is" : "are") left out until resolved in Review.")
                    .font(Theme.small).foregroundStyle(Theme.amber)
                    .padding(8).background(Theme.amberWash, in: RoundedRectangle(cornerRadius: 7))
            }
            Button {
                Task { await save() }
            } label: {
                HStack {
                    if saving { ProgressView().controlSize(.small) }
                    Text("Download for Anki")
                }
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(count == 0 || saving)
            if let savedMessage {
                VStack(alignment: .leading, spacing: 4) {
                    Label(savedMessage, systemImage: "checkmark.circle.fill").font(Theme.small).foregroundStyle(Theme.good)
                    if let savedURL {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([savedURL]) }.buttonStyle(LinkButtonStyle())
                    }
                }
            }
            Text("1   Download the file\n2   In Anki, choose File › Import\n3   Pick your deck").lineSpacing(6)
            Text(verbatim: "Cards count as exported once the file is saved. Math is converted to \\( \\) for Anki.")
                .font(Theme.small).foregroundStyle(Theme.quiet).fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("One-time Anki setup", isExpanded: $showSetup) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(AnkiExporter.setupInstructions).font(Theme.small).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Button("Copy instructions") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(AnkiExporter.setupInstructions, forType: .string)
                    }
                    .buttonStyle(LinkButtonStyle())
                }
                .padding(.top, 6)
            }
            .font(Theme.small)
            Divider().overlay(Theme.border)
            Button("Download module backup") { backup() }.buttonStyle(LinkButtonStyle())
            Button("Restore a backup…") { restore() }.buttonStyle(LinkButtonStyle(color: Theme.quiet))
        }
        .panel(padding: 22)
    }

    private func save() async {
        guard let name = module?.name else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        let lectureName = lectureScope.flatMap { id in lectures.first { $0.id == id }?.name }
        panel.nameFieldStringValue = "\(name)\(lectureName.map { " – \($0)" } ?? "") – Anki.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }   // Cancel marks nothing.
        saving = true; defer { saving = false }
        do {
            let result = try await model.library.exportAnki(moduleID: moduleID, lectureID: lectureScope, to: url, changedOnly: changedOnly)
            savedMessage = "Saved \(Format.count(result.entries.count, "card")) to \(url.lastPathComponent)."
            savedURL = url
            try? await model.reloadNow()
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    private func backup() {
        guard let name = module?.name else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(name).lectern-module.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await model.store.exportModuleBackup(moduleID: moduleID, to: url)
                savedMessage = "Module backup saved."
                savedURL = url
            } catch { model.errorMessage = error.localizedDescription }
        }
    }

    private func restore() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Choose a Lectern module backup. It is restored as its own module; nothing is merged."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let restored = try await model.store.restoreModuleBackup(from: url)
                try await model.reloadNow()
                model.selection = .module(restored.id)
            } catch { model.errorMessage = error.localizedDescription }
        }
    }
}
