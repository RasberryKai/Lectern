import LecternCore
import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let dashboard = model.dashboard {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .bottom) {
                            title
                            Spacer(minLength: 18)
                            totals(dashboard)
                        }
                        VStack(alignment: .leading, spacing: 12) { title; totals(dashboard) }
                    }.frame(minHeight: 104, alignment: .topLeading)
                    ForEach(dashboard.modules) { ModuleProgressCard(progress: $0) }
                    if dashboard.modules.isEmpty { ModuleCreationForm() }
                }
            }
            .padding(.horizontal, 40).padding(.vertical, 36)
            .frame(maxWidth: 1240, alignment: .leading)
        }
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Format.longDay(Date())).eyebrow()
            Text("Overview").font(Theme.heading(56)).tracking(-2.2)
        }
    }

    private func totals(_ dashboard: DashboardSnapshot) -> some View {
        func lectureCount(_ status: LectureProgressStatus) -> Int {
            dashboard.modules.reduce(0) { $0 + $1.statusCounts[status, default: 0] }
        }
        let lectures = dashboard.modules.flatMap(\.lectures)
        let reviewCards = lectures.filter { $0.status == .toReview }.reduce(0) { $0 + $1.reviewCardCount }
        let exportCards = lectures.filter { $0.status == .toExport }.reduce(0) { $0 + $1.readyExportCount }
        let totals = dashboard.totals
        return HStack(spacing: 6) {
            metric(lectureCount(.preparing), "preparing", Theme.amber)
            metric(lectureCount(.toReview), "to review · \(reviewCards) cards", Theme.ai)
            metric(lectureCount(.toExport), "ready to export · \(exportCards) cards", Theme.accentText)
            metric(totals.doneLectureCount, "of \(totals.plannedLectureCount) done", Theme.good)
        }
        .fixedSize()
    }

    private func metric(_ count: Int, _ caption: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(String(count)).font(.system(size: 12, weight: .bold)).monospacedDigit()
            Text(caption).font(Theme.small).foregroundStyle(Theme.quiet)
        }.padding(.horizontal, 9).frame(height: 32)
        .background(Theme.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.border))
    }
}

struct LectureSteps: View {
    let status: LectureProgressStatus
    private var current: Int {
        switch status {
        case .notImported: -1
        case .preparing: 0
        case .toReview: 1
        case .toExport: 2
        case .done: 3
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(["Prepare", "Review", "Export"].enumerated()), id: \.offset) { index, label in
                if index > 0 { Rectangle().fill(Theme.border).frame(width: 8, height: 1) }
                Image(systemName: index < current ? "checkmark.circle.fill" : index == current ? "circle.inset.filled" : "circle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(index < current ? Theme.good : index == current ? Theme.stage(status) : Theme.borderStrong)
                Text(label).foregroundStyle(index <= current ? Theme.ink : Theme.quiet)
            }
        }.font(Theme.caption).fixedSize()
        .accessibilityElement(children: .ignore).accessibilityLabel(Format.statusLabel(status))
    }
}

extension ModuleProgress {
    var examCaption: String {
        module.examDate.map { "Exam \(Format.dayMonth($0.date(in: .current)))" } ?? "No exam date"
    }

    var paceCaption: String? {
        switch pace {
        case .future(_, let weekly): "\(weekly.formatted(.number.precision(.fractionLength(0...1)))) a week to finish"
        case .dueToday: "Exam today"
        case .overdue(let days): "Exam was \(Format.count(days, "day")) ago"
        case .complete: totals.plannedLectureCount > 0 ? "All lectures done" : nil
        case .noExam: nil
        }
    }
}

struct ModuleProgressCard: View {
    @Environment(AppModel.self) private var model
    let progress: ModuleProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Button(progress.module.name) { model.selection = .module(progress.id) }
                    .buttonStyle(.plain).font(Theme.heading(24)).foregroundStyle(Theme.ink).lineLimit(1)
                Text(progress.examCaption)
                if let pace = progress.paceCaption {
                    Text(pace).foregroundStyle(Theme.accentText).padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Theme.goodWash, in: Capsule())
                }
                Spacer()
                Text("\(progress.totals.doneLectureCount) / \(progress.totals.plannedLectureCount) done").monospacedDigit()
            }.font(Theme.small).foregroundStyle(Theme.quiet)
            if !progress.slots.isEmpty {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 4) {
                        ForEach(progress.slots) { slot in
                            Button {
                                if let lecture = progress.lectures.first(where: { $0.id == slot.lectureID }) {
                                    LectureDestination.open(lecture, in: progress.id, model: model)
                                } else { model.selection = .module(progress.id) }
                            } label: {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(slot.status == .notImported ? Theme.surface : Theme.stage(slot.status))
                                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(slot.status == .notImported ? Theme.borderStrong : .clear))
                                    .frame(width: 22, height: 14)
                            }.buttonStyle(.plain).help(Format.slotHelp(slot)).accessibilityLabel(Format.slotHelp(slot))
                            .contextMenu {
                                LectureStatusOptions(current: slot.statusOverride) { status in
                                    Task {
                                        if let id = slot.lectureID {
                                            await model.setLectureStatus(status, for: LectureRef(moduleID: progress.id, lectureID: id))
                                        } else { await model.setEmptySlotStatus(status, for: slot.id) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            ForEach(progress.slots.filter { $0.lectureID != nil && $0.status != .done }) { slot in
                if let lecture = progress.lectures.first(where: { $0.id == slot.lectureID }) {
                    Divider()
                    HStack(spacing: 12) {
                        Text(Format.lectureTitle(index: slot.id.index - 1, name: lecture.name))
                            .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(detail(lecture)).font(Theme.small).foregroundStyle(Theme.quiet).lineLimit(2)
                        Spacer()
                        LectureSteps(status: slot.status)
                        let button = Button(LectureDestination.label(slot.status)) {
                            LectureDestination.open(lecture, in: progress.id, model: model)
                        }
                        if slot.status == .toReview && progress.id == model.dashboard?.modules.first?.id {
                            button.buttonStyle(PrimaryButtonStyle()).frame(minWidth: 72, alignment: .trailing)
                        } else {
                            button.buttonStyle(SecondaryButtonStyle()).frame(minWidth: 72, alignment: .trailing)
                        }
                    }
                }
            }
            Divider()
            HStack {
                Text(footerSummary).font(Theme.small).foregroundStyle(Theme.quiet)
                Spacer()
                if let slot = progress.slots.first(where: { $0.lectureID == nil && $0.status != .done }) {
                    Button("Import lecture \(String(format: "%02d", slot.id.index))") {
                        model.selection = .module(progress.id)
                        Task { await model.chooseAndImportPDFs(into: progress.id, slot: slot.id.index) }
                    }.buttonStyle(LinkButtonStyle())
                }
            }
        }.panel(padding: 18)
    }

    private func detail(_ lecture: LectureProgress) -> String {
        switch lecture.status {
        case .toReview: "\(Format.count(lecture.reviewCardCount, "card")) to review"
        case .toExport: "\(Format.count(lecture.readyExportCount, "card")) ready for Anki"
        case .preparing: Format.preparationText(lecture.preparationReasons)
        default: Format.statusLabel(lecture.status)
        }
    }

    private var footerSummary: String {
        let done = progress.slots.filter { $0.status == .done }.map { $0.id.index }
        let ranges = IndexSet(done).rangeView.map { range in
            let first = String(format: "%02d", range.lowerBound)
            return range.count == 1 ? first : "\(first)–\(String(format: "%02d", range.upperBound - 1))"
        }
        return [ranges.isEmpty ? nil : ranges.joined(separator: ", ") + " done",
                progress.totals.notImportedCount > 0 ? "\(progress.totals.notImportedCount) not imported" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

enum LectureDestination {
    static func label(_ status: LectureProgressStatus) -> String {
        switch status {
        case .toReview: "Review"
        case .toExport: "Export"
        case .preparing: "Prepare"
        default: "Open"
        }
    }

    static func open(_ lecture: LectureProgress, in moduleID: UUID, model: AppModel) {
        let ref = LectureRef(moduleID: moduleID, lectureID: lecture.id)
        switch lecture.status {
        case .toExport: model.selection = .export(moduleID, lectureID: lecture.id)
        case .toReview: model.openLecture(ref, mode: .review)
        case .preparing: model.openLecture(ref, mode: lecture.preparationReasons.contains(.addCards) ? .review : .prepare)
        default: model.openLecture(ref, mode: nil)
        }
    }
}
