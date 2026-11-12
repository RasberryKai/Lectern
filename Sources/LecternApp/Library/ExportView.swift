import AppKit
import LecternCore
import SwiftUI
import UniformTypeIdentifiers

/// Anki export for a module (or one lecture). The preview uses `AnkiExporter.export`, which never
/// marks anything; only a completed Save through `LibraryService.exportAnki` records export marks.
struct ExportView: View {
    @Environment(AppModel.self) private var model
    let moduleID: UUID

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

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Button(module?.name ?? "Module") { model.selection = .module(moduleID) }
                    .buttonStyle(.plain).font(Theme.body).foregroundStyle(Theme.accentText)
                Text("Export to Anki").font(Theme.serif(22))
                Spacer()
            }
            .padding(.horizontal, 28).padding(.vertical, 14)
            .background(Theme.surface)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
            ScrollView {
                HStack(alignment: .top, spacing: 22) {
                    VStack(alignment: .leading, spacing: 20) {
                        whatToExport
                        lectureTable
                        previewTable
                    }
                    .frame(maxWidth: .infinity)
                    summary.frame(width: 320)
                }
                .padding(.horizontal, 44).padding(.vertical, 28)
                .frame(maxWidth: 1240)
            }
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

    private var eligible: (new: Int, changed: Int, all: Int) {
        var new = 0, changed = 0, all = 0
        for lecture in scopedLectures {
            for card in lecture.cards where card.verdict == .good && !card.isSuperseded && lecture.issues(for: card).isEmpty {
                all += 1
                if card.exported == nil { new += 1 } else if card.changedSinceExport { changed += 1 }
            }
        }
        return (new, changed, all)
    }

    private var whatToExport: some View {
        let counts = eligible
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("What to export").font(.system(size: 14, weight: .semibold))
                Spacer()
                Picker("Lectures", selection: $lectureScope) {
                    Text("Whole module").tag(UUID?.none)
                    ForEach(Array(lectures.enumerated()), id: \.element.id) { index, lecture in
                        Text(Format.lectureTitle(index: (module?.lectureSlots[lecture.id] ?? (index + 1)) - 1, name: lecture.name)).tag(UUID?.some(lecture.id))
                    }
                }
                .labelsHidden().fixedSize()
            }
            option(isOn: changedOnly, title: "New and changed since last export · \(Format.count(counts.new + counts.changed, "card"))",
                   detail: "\(counts.new) new, \(counts.changed) edited after export. Edited cards keep their LecternID, so Anki updates them instead of creating duplicates.") { changedOnly = true }
            option(isOn: !changedOnly, title: "All approved cards · \(Format.count(counts.all, "card"))",
                   detail: "For a fresh deck or a new Anki profile.") { changedOnly = false }
        }
        .panel(padding: 20)
    }

    private func option(isOn: Bool, title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isOn ? "largecircle.fill.circle" : "circle").foregroundStyle(isOn ? Theme.accent : Theme.faint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(Theme.small).foregroundStyle(Theme.quiet).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(12)
            .background(isOn ? Theme.goodWash : Theme.surface, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(isOn ? Theme.accent : Theme.borderStrong, lineWidth: isOn ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Per lecture

    private var lectureTable: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Lecture").frame(maxWidth: .infinity, alignment: .leading)
                Text("Included").frame(width: 130, alignment: .leading)
                Text("Left out").frame(width: 300, alignment: .leading)
            }
            .eyebrow().padding(.horizontal, 18).padding(.vertical, 10)
            ForEach(Array(scopedLectures.enumerated()), id: \.element.id) { _, lecture in
                Divider().overlay(Theme.border)
                let index = (module?.lectureSlots[lecture.id] ?? 1) - 1
                HStack {
                    Text(Format.lectureTitle(index: index, name: lecture.name)).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                    Text(included(lecture)).frame(width: 130, alignment: .leading)
                    Text(leftOut(lecture)).foregroundStyle(Theme.quiet).frame(width: 300, alignment: .leading).lineLimit(2)
                }
                .font(Theme.body)
                .padding(.horizontal, 18).padding(.vertical, 11)
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
    }

    private func included(_ lecture: Lecture) -> String {
        let entries = preview?.entries.filter { $0.lectureID == lecture.id } ?? []
        guard !entries.isEmpty else { return "0" }
        let ids = Set(entries.map(\.cardID))
        let changed = lecture.cards.filter { ids.contains($0.id) && $0.exported != nil }.count
        let new = entries.count - changed
        switch (new, changed) {
        case (_, 0): return "\(new) new"
        case (0, _): return "\(changed) changed"
        default: return "\(new) new, \(changed) changed"
        }
    }

    private func leftOut(_ lecture: Lecture) -> String {
        if lecture.jobs.contains(where: { $0.kind == .generate && $0.state == .running }) { return "Generating" }
        let cards = lecture.cards.filter { !$0.isSuperseded }
        var parts: [String] = []
        let unreviewed = cards.filter { $0.verdict == .unreviewed }.count
        let adjust = cards.filter { $0.verdict == .needsAdjustment }.count
        let bad = cards.filter { $0.verdict == .bad }.count
        if unreviewed > 0 { parts.append("\(unreviewed) unreviewed") }
        if adjust > 0 { parts.append("\(adjust) need\(adjust == 1 ? "s" : "") adjustment") }
        if bad > 0 { parts.append("\(bad) bad") }
        if parts.isEmpty {
            let good = cards.filter { $0.verdict == .good }.count
            let included = preview?.entries.filter { $0.lectureID == lecture.id }.count ?? 0
            if cards.isEmpty { return "No cards yet" }
            return good > included ? "\(good - included) exported already" : "None"
        }
        return parts.joined(separator: ", ")
    }

    // MARK: Preview

    private struct PreviewRow: Identifiable {
        let id: Int
        let lecternID: String
        let front: String
        let back: String
        let tags: String
    }

    private var previewRows: [PreviewRow] {
        guard let text = preview?.text else { return [] }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.hasPrefix("#") && !$0.isEmpty }
        return lines.prefix(8).enumerated().map { index, line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map { Self.display(String($0)) }
            return PreviewRow(id: index, lecternID: fields.count > 0 ? fields[0] : "", front: fields.count > 1 ? fields[1] : "",
                              back: fields.count > 2 ? fields[2] : "", tags: fields.count > 3 ? fields[3] : "")
        }
    }

    /// Reverses the file's HTML escaping for on-screen reading only.
    private static func display(_ field: String) -> String {
        var value = field
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "\"\"", with: "\"")
        }
        return value.replacingOccurrences(of: "<br>", with: "\n").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&amp;", with: "&")
    }

    private var previewTable: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Preview of the file").font(.system(size: 14, weight: .semibold))
            if let previewError {
                ErrorBanner(message: previewError)
            } else if previewRows.isEmpty {
                Text(changedOnly ? "Nothing new or changed since the last export." : "No approved cards yet.")
                    .font(Theme.body).foregroundStyle(Theme.quiet)
            } else {
                VStack(spacing: 0) {
                    HStack(alignment: .top) {
                        Text("Front").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Back").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Tags").frame(width: 170, alignment: .leading)
                    }
                    .eyebrow().padding(.horizontal, 14).padding(.vertical, 9)
                    ForEach(previewRows) { row in
                        Divider().overlay(Theme.border)
                        HStack(alignment: .top) {
                            Text(row.front).frame(maxWidth: .infinity, alignment: .leading)
                            Text(row.back).foregroundStyle(Theme.quiet).frame(maxWidth: .infinity, alignment: .leading)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(row.tags).lineLimit(2)
                                Text(shortID(row.lecternID)).font(Theme.caption.monospaced()).foregroundStyle(Theme.faint)
                                    .help("LecternID \(row.lecternID): Anki matches on this to update instead of duplicating.")
                            }
                            .frame(width: 170, alignment: .leading)
                        }
                        .font(Theme.small)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                    }
                    if let count = preview?.entries.count, count > previewRows.count {
                        Divider().overlay(Theme.border)
                        Text("and \(count - previewRows.count) more").font(Theme.small).foregroundStyle(Theme.quiet)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 8)
                    }
                }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
            }
        }
    }

    private func shortID(_ id: String) -> String {
        guard let card = id.split(separator: ":").last, card.count > 8 else { return id }
        return "\(card.prefix(4).lowercased())…\(card.suffix(3).lowercased())"
    }

    // MARK: Summary and actions

    private var summary: some View {
        let count = preview?.entries.count ?? 0
        let ambiguous = scopedLectures.flatMap { lecture in
            lecture.cards.filter { !$0.isSuperseded && lecture.issues(for: $0).contains { $0.kind == .unresolvedMath } }
        }.count
        return VStack(alignment: .leading, spacing: 12) {
            Text(Format.count(count, "card")).font(Theme.serif(32))
            Text("Anki text file · LecternID, Front, Back, Tags · math adapted to \\( \\) delimiters")
                .font(Theme.small).foregroundStyle(Theme.quiet)
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
            Text("In Anki: File › Import, pick the file and your deck. Cards are marked exported here only after the file is saved.")
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
            Button("Download module backup") { backup() }.buttonStyle(SecondaryButtonStyle())
            Button("Restore a module backup…") { restore() }.buttonStyle(LinkButtonStyle(color: Theme.quiet))
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
