import LecternCore
import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if let dashboard = model.dashboard {
                    totals(dashboard.totals)
                    if dashboard.modules.isEmpty {
                        emptyState
                    } else {
                        ForEach(dashboard.modules) { ModuleProgressCard(progress: $0) }
                    }
                    footer
                }
            }
            .padding(.horizontal, 44).padding(.vertical, 34)
            .frame(maxWidth: 1240, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Overview").font(Theme.serif(40))
                let active = model.dashboard?.modules.count ?? 0
                let archived = model.dashboard?.archivedModuleCount ?? 0
                Text("\(Format.longDay(Date())) · \(Format.count(active, "active module"))\(archived > 0 ? " · \(archived) archived" : "")")
                    .font(Theme.body).foregroundStyle(Theme.quiet)
            }
            Spacer()
            HStack(spacing: 16) {
                ForEach(Format.legendOrder, id: \.self) { status in
                    HStack(spacing: 6) {
                        LegendSwatch(status: status)
                        Text(Format.statusLabel(status)).font(Theme.small).foregroundStyle(Theme.quiet)
                    }
                }
            }
        }
    }

    private func totals(_ totals: ProgressTotals) -> some View {
        HStack(spacing: 14) {
            tile("\(totals.doneLectureCount) / \(totals.plannedLectureCount)", "Lectures done", "Completed automatically or manually")
            tile("\(totals.reviewCardCount)", "Cards to review",
                 "In \(Format.count(totals.reviewLectureCount, "lecture"))\(totals.proposalCount > 0 ? ", \(Format.count(totals.proposalCount, "proposal")) waiting" : "")")
            tile("\(totals.readyExportCount)", "Ready to export",
                 totals.changedExportCount > 0 ? "\(totals.changedExportCount) of them changed since export" : "Approved and not yet in Anki")
            tile("\(totals.notImportedCount)", "Lectures not imported", "Planned slots still empty")
        }
    }

    private func tile(_ value: String, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value).font(Theme.serif(34)).monospacedDigit()
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(detail).font(Theme.small).foregroundStyle(Theme.quiet).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .panel(padding: 18)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Start with a module").font(Theme.serif(22))
            Text("A module is a course. Give it a name, how many lectures you expect and, if you like, the exam date. Then drop lecture PDFs on it.")
                .font(Theme.body).foregroundStyle(Theme.quiet)
            Button("New module") { model.showNewModule = true }.buttonStyle(PrimaryButtonStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: 24)
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Text("Right-click any lecture block to set its status, even without a PDF. Automatic completion tracks card generation, review and export.")
                .foregroundStyle(Theme.quiet)
            if let first = model.dashboard?.modules.first {
                Button("Module settings") { model.settingsModuleID = first.module.id }.buttonStyle(LinkButtonStyle())
            }
        }
        .font(Theme.small)
    }
}

struct ModuleProgressCard: View {
    @Environment(AppModel.self) private var model
    let progress: ModuleProgress

    var body: some View {
        HStack(alignment: .top, spacing: 36) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Button { model.selection = .module(progress.module.id) } label: {
                        Text(progress.module.name).font(Theme.serif(26)).lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    Text(Format.examLine(progress.module.examDate)).font(Theme.body).foregroundStyle(Theme.quiet)
                    Spacer(minLength: 12)
                    Pill(text: Format.paceBadge(progress.pace, remaining: progress.totals.remainingLectureCount), tone: Format.paceTone(progress.pace))
                }
                SlotStrip(slots: progress.slots) { slot in
                    if let lectureID = slot.lectureID {
                        model.openLecture(LectureRef(moduleID: progress.module.id, lectureID: lectureID), mode: progress.lectures.first { $0.lectureID == lectureID }?.automaticStatus == .toReview ? .review : nil)
                    } else {
                        model.selection = .module(progress.module.id)
                    }
                }
                Text(Format.statusSummary(counts: progress.statusCounts)).font(Theme.body).foregroundStyle(Theme.quiet)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 10) {
                Text("Next up").eyebrow()
                if progress.nextUp.isEmpty {
                    Text("Nothing waiting. Import the next lecture when it's out.").font(Theme.body).foregroundStyle(Theme.quiet)
                }
                ForEach(Array(progress.nextUp.enumerated()), id: \.offset) { _, action in
                    let line = Format.nextUp(action, in: progress)
                    HStack {
                        Text(line.text).font(Theme.body).lineLimit(1)
                        Spacer(minLength: 12)
                        Button(line.action) { NextUpRouter.perform(action, model: model) }
                            .buttonStyle(LinkButtonStyle())
                    }
                }
            }
            .frame(width: 400, alignment: .leading)
        }
        .panel(padding: 24)
    }
}

/// Routes typed Next-up actions by ID; never by label.
enum NextUpRouter {
    static func perform(_ action: NextUpAction, model: AppModel) {
        switch action {
        case .review(let lectureID, _):
            guard let moduleID = moduleID(of: lectureID, model: model) else { return }
            model.openLecture(LectureRef(moduleID: moduleID, lectureID: lectureID), mode: .review)
        case .export(let moduleID, _, _, _):
            model.selection = .export(moduleID)
        case .prepare(let lectureID, let reasons):
            guard let moduleID = moduleID(of: lectureID, model: model) else { return }
            let sourceless = reasons.contains(.addCards)
            model.openLecture(LectureRef(moduleID: moduleID, lectureID: lectureID), mode: sourceless ? .review : .prepare)
        case .importLecture(let moduleID, let slotID):
            model.selection = .module(moduleID)
            Task { await model.chooseAndImportPDFs(into: moduleID, slot: slotID.index) }
        }
    }

    private static func moduleID(of lectureID: UUID, model: AppModel) -> UUID? {
        model.modules.first { $0.lectureIDs.contains(lectureID) }?.id
    }
}
