import LecternCore
import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            if let dashboard = model.dashboard {
                let now = model.studyNow
                let modules = examOrder(dashboard.modules, now: now)
                let plan = model.studyCatalog.plan(now: now)
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(Format.longDay(now)).eyebrow()
                        Text("Overview").font(Theme.heading(56)).tracking(-2.2)
                            .accessibilityAddTraits(.isHeader)
                    }
                    .frame(minHeight: 104, alignment: .bottomLeading)
                    .padding(.bottom, 6)
                    if let error = model.studyError { ErrorBanner(message: error) }
                    HStack(alignment: .top, spacing: 16) {
                        studyToday(plan, modules: modules)
                        makeCardsNext(modules)
                    }
                    if !modules.isEmpty { exams(modules, now: now) }
                }
                .padding(.horizontal, 40).padding(.vertical, 36)
                .frame(maxWidth: 1240, alignment: .leading)
            }
        }
    }

    private func studyToday(_ plan: StudyPlan, modules: [ModuleProgress]) -> some View {
        let counts = plan.cards.reduce(into: [UUID: Int]()) { $0[$1.moduleID, default: 0] += 1 }
        return VStack(alignment: .leading, spacing: 14) {
            Text("Study today").eyebrow().accessibilityAddTraits(.isHeader)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(plan.cards.count.formatted()).font(Theme.heading(56)).monospacedDigit().tracking(-2)
                Text(workloadCaption(plan.cards.count)).font(Theme.body).foregroundStyle(Theme.quiet)
            }
            if !modules.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        ForEach(Array(modules.enumerated()), id: \.element.id) { index, progress in
                            if index != 0 { Text("·").foregroundStyle(Theme.quiet) }
                            moduleWorkload(progress.module, count: counts[progress.id, default: 0])
                        }
                    }.fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(modules) { progress in
                            moduleWorkload(progress.module, count: counts[progress.id, default: 0])
                        }
                    }
                }.font(Theme.small)
            }
            Spacer(minLength: 4)
            HStack(spacing: 16) {
                Button {
                    Task { await model.startStudy(scope: .all) }
                } label: {
                    StudyStartLabel(title: "Study all", count: plan.startingCount)
                }.buttonStyle(PrimaryButtonStyle())
                Button("By module or lecture") { model.selection = .flashcards }
                    .buttonStyle(LinkButtonStyle(color: Theme.quiet))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 196, maxHeight: .infinity, alignment: .topLeading)
        .panel(padding: 22)
    }

    private func moduleWorkload(_ module: Module, count: Int) -> some View {
        HStack(spacing: 4) {
            Button(module.name) { model.selection = .module(module.id) }
                .buttonStyle(.plain).foregroundStyle(Theme.accentText).lineLimit(1)
            Text(count.formatted()).foregroundStyle(Theme.quiet).monospacedDigit()
        }
    }

    private func workloadCaption(_ count: Int) -> String {
        guard count > 0 else { return "cards queued" }
        let minutes = max(1, Int((Double(count) * 16 / 60).rounded()))
        return "\(count == 1 ? "card" : "cards") · about \(minutes) min"
    }

    private func makeCardsNext(_ modules: [ModuleProgress]) -> some View {
        let tasks = modules.flatMap { progress in
            progress.slots.compactMap { slot -> CardMakingTask? in
                guard let lecture = progress.lectures.first(where: { $0.id == slot.lectureID }),
                      lecture.status == .preparing || lecture.status == .toReview else { return nil }
                return CardMakingTask(
                    module: progress.module, lecture: lecture,
                    title: Format.lectureTitle(index: slot.id.index - 1, name: lecture.name)
                )
            }.sorted { $0.isReviewing && !$1.isReviewing }
        }
        return VStack(alignment: .leading, spacing: 0) {
            Text("Make cards next").eyebrow().accessibilityAddTraits(.isHeader)
                .padding(.bottom, 10)
            if tasks.isEmpty {
                Text("No lectures to prepare or review.")
                    .font(Theme.body).foregroundStyle(Theme.quiet).padding(.vertical, 12)
            }
            ForEach(tasks.prefix(3)) { task in
                Divider()
                HStack(spacing: 9) {
                    Circle().fill(Theme.stage(task.lecture.status)).frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(task.title).font(Theme.body.weight(.semibold)).lineLimit(1)
                        HStack(spacing: 4) {
                            Button(task.module.name) { model.selection = .module(task.module.id) }
                                .buttonStyle(.plain).foregroundStyle(Theme.accentText).lineLimit(1)
                            Text("· \(task.detail)").foregroundStyle(Theme.quiet).lineLimit(1)
                        }.font(Theme.small)
                    }
                    Spacer(minLength: 0)
                    Button(task.isReviewing ? "Review" : "Prepare") {
                        LectureDestination.open(task.lecture, in: task.module.id, model: model)
                    }.buttonStyle(SecondaryButtonStyle())
                }.padding(.vertical, 9)
            }
            if tasks.count > 3 {
                Text("\(tasks.count - 3) more to prepare or review")
                    .font(Theme.small).foregroundStyle(Theme.quiet).padding(.top, 8)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 196, maxHeight: .infinity, alignment: .topLeading)
        .panel(padding: 22)
    }

    private func exams(_ modules: [ModuleProgress], now: Date) -> some View {
        let decks = Dictionary(uniqueKeysWithValues: model.studyCatalog.decks.map { ($0.module.id, $0) })
        return Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 0) {
            GridRow {
                Text("Exams").frame(maxWidth: .infinity, alignment: .leading)
                Text("Lectures turned into cards").frame(maxWidth: .infinity, alignment: .leading)
                Text("Cards seen at least once").frame(maxWidth: .infinity, alignment: .leading)
                Text("Pace you need").frame(maxWidth: .infinity, alignment: .leading)
            }.eyebrow().padding(.vertical, 13).accessibilityAddTraits(.isHeader)
            ForEach(modules) { progress in
                Divider().gridCellUnsizedAxes(.horizontal)
                examRow(progress, deck: decks[progress.id], now: now)
            }
        }
        .padding(.horizontal, 22)
        .panel(padding: 0)
    }

    private func examRow(_ progress: ModuleProgress, deck: StudyDeck?, now: Date) -> some View {
        GridRow(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Button(progress.module.name) { model.selection = .module(progress.id) }
                    .buttonStyle(.plain).font(Theme.heading(21)).lineLimit(2)
                Text(Format.examLine(progress.module.examDate, now: now))
                    .font(Theme.small).foregroundStyle(Theme.quiet)
            }
            StudyProgressMeter(value: progress.cardMakingDoneCount, total: progress.totals.plannedLectureCount,
                               unit: "lectures", tint: Theme.accent)
            StudyProgressMeter(value: deck?.seenCount ?? 0, total: deck?.approvedCount ?? 0,
                               unit: "cards", tint: Theme.good)
            VStack(alignment: .leading, spacing: 5) {
                Text(progress.cardMakingPaceCaption(now: now) ?? "Set an exam date to see a pace")
                    .foregroundStyle(Theme.quiet)
                if let needed = deck?.neededPerDay(now: now) {
                    let cap = model.studyCatalog.configuration(moduleID: progress.id).newCardLimit
                    if needed > cap {
                        Text("\(needed) new a day · set to \(cap)").foregroundStyle(Theme.amber)
                    }
                }
            }.font(Theme.small)
        }.padding(.vertical, 16)
    }

    private func examOrder(_ modules: [ModuleProgress], now: Date) -> [ModuleProgress] {
        modules.sorted { lhs, rhs in
            func days(_ module: Module) -> Int {
                guard let value = module.examDate?.daysRemaining(from: now), value >= 0 else { return .max }
                return value
            }
            return days(lhs.module) < days(rhs.module)
        }
    }
}

private struct CardMakingTask: Identifiable {
    let module: Module
    let lecture: LectureProgress
    let title: String
    var id: LectureRef { LectureRef(moduleID: module.id, lectureID: lecture.id) }
    var isReviewing: Bool { lecture.status == .toReview }
    var detail: String {
        if isReviewing { return Format.count(lecture.reviewCardCount, "card") }
        return Format.preparationText(lecture.preparationReasons)
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

extension LectureProgressStatus {
    var cardMakingStatus: Self { self == .toExport ? .done : self }
}

extension ModuleProgress {
    var cardMakingDoneCount: Int {
        slots.count { $0.status.cardMakingStatus == .done }
    }

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
