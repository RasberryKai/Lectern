import LecternCore
import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { geometry in
            let layout = TableLayout(width: min(geometry.size.width, 1240))
            ScrollView {
                if let dashboard = model.dashboard {
                    let now = model.studyNow
                    let overview = ExamOverview(dashboard: dashboard, study: model.studyCatalog, now: now)
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(Format.longDay(now)).eyebrow()
                            Text("Overview").font(Theme.heading(56)).tracking(-2.7)
                                .accessibilityAddTraits(.isHeader)
                        }
                        .padding(.bottom, 14)
                        if let error = model.studyError { ErrorBanner(message: error) }
                        if overview.rows.isEmpty {
                            Text("No upcoming exams or modules without an exam date.")
                                .font(Theme.body).foregroundStyle(Theme.quiet)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .panel()
                        } else {
                            exams(overview, layout: layout)
                            Text("Amber = faster than you're going now. ~ includes the cards your unfinished lectures are expected to add.")
                                .font(Theme.small).foregroundStyle(Theme.quiet)
                                .padding(.horizontal, 4)
                        }
                    }
                    .padding(.horizontal, layout.pageInset)
                    .padding(.vertical, 40)
                    .frame(maxWidth: 1240, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func exams(_ overview: ExamOverview, layout: TableLayout) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: layout.columnSpacing) {
                Text("Exam").frame(width: layout.exam, alignment: .leading)
                Text("Lectures done").frame(width: layout.progress, alignment: .leading)
                Text("Cards seen").frame(width: layout.progress, alignment: .leading)
                Text("Lectures /\nweek").frame(width: layout.pace, alignment: .trailing)
                    .accessibilityLabel("Lectures per week")
                Text("Cards / day").frame(width: layout.pace, alignment: .trailing)
            }
            .eyebrow()
            .multilineTextAlignment(.trailing)
            .frame(minHeight: 60)
            .accessibilityAddTraits(.isHeader)

            ForEach(overview.rows) { row in
                separator(layout)
                HStack(spacing: layout.columnSpacing) {
                    exam(row).frame(width: layout.exam, alignment: .leading)
                        .frame(minHeight: 74)
                    metrics(row.metrics, layout: layout)
                }
            }
            separator(layout)
            HStack(spacing: layout.columnSpacing) {
                Text("All modules").font(Theme.body.weight(.semibold))
                    .frame(width: layout.exam, alignment: .leading)
                metrics(overview.totals, layout: layout)
            }
            .frame(minHeight: 58)
        }
        .padding(.horizontal, layout.panelInset)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border).allowsHitTesting(false))
    }

    private func separator(_ layout: TableLayout) -> some View {
        HStack(spacing: layout.columnSpacing) {
            let widths = [layout.exam, layout.progress, layout.progress, layout.pace, layout.pace]
            ForEach(widths.indices, id: \.self) { index in
                Rectangle().fill(Theme.border).frame(width: widths[index], height: 1)
            }
        }
        .accessibilityHidden(true)
    }

    private func exam(_ row: ExamOverview.Row) -> some View {
        let date = examDateLine(row)
        return VStack(alignment: .leading, spacing: 4) {
            Button { model.selection = .module(row.id) } label: {
                Text(row.module.name)
                    .font(Theme.heading(18)).tracking(-0.5)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens module")
            Text(date).font(Theme.small).foregroundStyle(Theme.quiet)
        }
        .padding(.vertical, 17)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func examDateLine(_ row: ExamOverview.Row) -> String {
        guard let days = row.daysUntilExam, let exam = row.module.examDate else { return "No exam date" }
        let remaining = days == 0 ? "Today" : Format.count(days, "day")
        return "\(remaining) · \(Format.dayMonth(exam.date()))"
    }

    @ViewBuilder private func metrics(_ metrics: ExamOverview.Metrics, layout: TableLayout) -> some View {
        progressCell(metrics.lectures, label: "Lectures done")
            .frame(width: layout.progress, alignment: .leading)
        progressCell(metrics.cards, label: "Cards seen")
            .frame(width: layout.progress, alignment: .leading)
        paceCell(metrics.lecturesPerWeek, label: "Lectures per week")
            .frame(width: layout.pace, alignment: .trailing)
        paceCell(metrics.cardsPerDay, label: "Cards per day")
            .frame(width: layout.pace, alignment: .trailing)
    }

    private func progressCell(_ progress: ExamOverview.Progress?, label: String) -> some View {
        let total = progress?.total.formatted() ?? ""
        let completed = progress?.completed.formatted() ?? ""
        let estimated = progress?.isEstimate == true
        let value = progress.map { _ in "\(completed) / \(estimated ? "~" : "")\(total)" } ?? "–"
        let spoken = progress.map { _ in "\(completed) of \(estimated ? "about " : "")\(total)" } ?? "Unavailable"

        return HStack(spacing: 8) {
            Text(value).font(Theme.body.weight(.semibold)).monospacedDigit()
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 68, alignment: .leading)
            GeometryReader { proxy in
                let fraction = progress.map { Double($0.completed) / Double(max(1, $0.total)) } ?? 0
                ZStack(alignment: .leading) {
                    Theme.border
                    Theme.accentText.frame(width: proxy.size.width * fraction)
                }
                .clipShape(Capsule())
            }
            .frame(height: 4)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(spoken)
    }

    private func paceCell(_ pace: ExamOverview.Pace?, label: String) -> some View {
        let value = pace?.needed.formatted()
        let behind = pace?.isBehind == true
        return Text(value ?? "–")
            .font(Theme.heading(25)).monospacedDigit()
            .foregroundStyle(pace == nil ? Theme.faint : behind ? Theme.amber : Theme.ink)
            .accessibilityLabel(label)
            .accessibilityValue(value.map { behind ? "\($0), behind pace" : $0 } ?? "Unavailable")
    }

    private struct TableLayout {
        let pageInset: CGFloat
        let panelInset: CGFloat
        let columnSpacing: CGFloat
        let exam: CGFloat
        let progress: CGFloat
        let pace: CGFloat

        init(width: CGFloat) {
            let compact = width < 980
            pageInset = compact ? 28 : 40
            panelInset = compact ? 22 : 28
            columnSpacing = compact ? 20 : 32
            let available = max(0, width - 2 * (pageInset + panelInset) - 4 * columnSpacing)
            exam = available * 0.306
            progress = available * 0.204
            pace = available * 0.143
        }
    }
}

struct LectureSteps: View {
    let status: LectureProgressStatus
    private var current: Int {
        switch status {
        case .notImported: -1
        case .preparing: 0
        case .toReview: 1
        case .toExport, .done: 2
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            step("Prepare", index: 0)
            Rectangle().fill(Theme.border).frame(width: 8, height: 1)
            step("Review", index: 1)
        }
        .font(Theme.caption).fixedSize()
        .accessibilityElement(children: .ignore).accessibilityLabel(Format.statusLabel(status.cardMakingStatus))
    }

    private func step(_ label: String, index: Int) -> some View {
        HStack(spacing: 5) {
            Image(systemName: index < current ? "checkmark.circle.fill" : index == current ? "circle.inset.filled" : "circle")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(index < current ? Theme.good : index == current ? Theme.stage(status) : Theme.borderStrong)
            Text(label).foregroundStyle(index <= current ? Theme.ink : Theme.quiet)
        }
    }
}

extension ModuleProgress {
    func cardMakingPaceCaption(now: Date) -> String? {
        guard let exam = module.examDate else { return nil }
        let remaining = totals.plannedLectureCount - cardMakingDoneCount
        guard remaining > 0 else { return "All lectures done" }
        let days = exam.daysRemaining(from: now)
        guard days > 0 else { return days == 0 ? "Exam today" : "Exam passed" }
        let perWeek = (Double(remaining) * 7 / Double(days)).formatted(.number.precision(.fractionLength(0...1)))
        return "\(perWeek) lectures a week"
    }
}

enum LectureDestination {
    static func label(_ status: LectureProgressStatus) -> String {
        switch status {
        case .toReview: "Review"
        case .preparing: "Prepare"
        default: "Open"
        }
    }

    static func open(_ lecture: LectureProgress, in moduleID: UUID, model: AppModel) {
        let ref = LectureRef(moduleID: moduleID, lectureID: lecture.id)
        switch lecture.status {
        case .toReview: model.openLecture(ref, mode: .review)
        case .preparing: model.openLecture(ref, mode: lecture.preparationReasons.contains(.addCards) ? .review : .prepare)
        default: model.openLecture(ref, mode: nil)
        }
    }
}
