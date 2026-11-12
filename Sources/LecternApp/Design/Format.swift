import Foundation
import LecternCore

/// All user-facing date, number and status wording. The backend deliberately returns
/// typed values only, so formatting lives here.
enum Format {
    static func statusLabel(_ status: LectureProgressStatus) -> String {
        switch status {
        case .done: "Done"
        case .toExport: "To export"
        case .toReview: "To review"
        case .preparing: "Preparing"
        case .notImported: "Not imported"
        }
    }

    static let legendOrder: [LectureProgressStatus] = [.done, .toExport, .toReview, .preparing, .notImported]

    static func statusSummary(counts: [LectureProgressStatus: Int]) -> String {
        let parts = legendOrder.compactMap { status -> String? in
            guard let count = counts[status], count > 0 else { return nil }
            return "\(count) \(statusLabel(status).lowercased())"
        }
        return parts.isEmpty ? "No lectures planned" : parts.joined(separator: " · ")
    }

    static func slotHelp(_ slot: LectureSlot) -> String {
        "Lecture \(String(format: "%02d", slot.id.index)) · \(statusLabel(slot.status))\(slot.statusOverride == nil ? "" : " · Manual")"
    }

    /// "03 Distributions". Names that already start with a number keep their own numbering.
    static func lectureTitle(index: Int, name: String) -> String {
        if let first = name.first, first.isNumber { return name }
        return String(format: "%02d ", index + 1) + name
    }

    static func lectureTitle(_ lectureID: UUID, in module: ModuleProgress) -> String {
        guard let lecture = module.lectures.first(where: { $0.lectureID == lectureID }),
              let slot = module.slots.first(where: { $0.lectureID == lectureID }) else { return "Lecture" }
        return lectureTitle(index: slot.id.index - 1, name: lecture.name)
    }

    static func count(_ value: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(value) \(value == 1 ? singular : (plural ?? singular + "s"))"
    }

    // MARK: Dates

    static func dayMonth(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated))
    }

    static func longDay(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    static func examLine(_ exam: ExamDate?, now: Date = Date()) -> String {
        guard let exam else { return "No exam date" }
        let days = exam.daysRemaining(from: now, timeZone: .current)
        let date = dayMonth(exam.date(in: .current))
        switch days {
        case ..<0: return "Exam \(date) · passed"
        case 0: return "Exam today"
        case 1..<14: return "Exam \(date) · \(count(days, "day"))"
        default: return "Exam \(date) · \(count(days / 7, "week"))"
        }
    }

    static func paceBadge(_ pace: ModulePace, remaining: Int) -> String {
        let left = "\(remaining) left"
        switch pace {
        case .noExam: return "\(left) · no exam date set"
        case .future(_, let perWeek):
            return "\(left) · \(perWeek.formatted(.number.precision(.fractionLength(1)))) a week until the exam"
        case .dueToday: return "\(left) · exam is today"
        case .overdue(let days): return "\(left) · exam was \(count(days, "day")) ago"
        case .complete: return "All lectures done"
        }
    }

    static func paceTone(_ pace: ModulePace) -> Tone {
        switch pace {
        case .overdue, .dueToday: .amber
        case .complete: .good
        default: .neutral
        }
    }

    // MARK: Next up

    struct NextUpLine {
        var text: String
        var action: String
    }

    static func nextUp(_ action: NextUpAction, in module: ModuleProgress) -> NextUpLine {
        switch action {
        case .review(let lectureID, let cards):
            return .init(text: "Review \(count(cards, "card")) · \(lectureTitle(lectureID, in: module))", action: "Review")
        case .export(_, let lectureIDs, let cards, _):
            let first = lectureIDs.first.map { lectureTitle($0, in: module) } ?? ""
            let others = lectureIDs.count > 1 ? " and others" : ""
            return .init(text: "Export \(count(cards, "card")) · \(first)\(others)", action: "Export")
        case .prepare(let lectureID, let reasons):
            return .init(text: "\(preparationText(reasons)) · \(lectureTitle(lectureID, in: module))", action: "Open")
        case .importLecture(_, let slot):
            return .init(text: "Import lecture \(String(format: "%02d", slot.index))", action: "Import")
        }
    }

    static func preparationText(_ reasons: [PreparationReason]) -> String {
        guard let first = reasons.first else { return "Prepare" }
        switch first {
        case .selectSlides: return "Finish selecting slides"
        case .generateMissingCoverage(let pages): return "Generate cards for \(count(pages.count, "slide"))"
        case .waitingForJobs: return "Waiting for AI"
        case .addCards: return "Add cards"
        }
    }

    // MARK: Pages

    /// "slide 4", "slides 3 and 5", "slides 3 to 6", "slides 1, 3 and 9".
    static func slides(_ pages: [Int]) -> String {
        let sorted = Array(Set(pages)).sorted()
        guard let first = sorted.first else { return "no slide" }
        if sorted.count == 1 { return "slide \(first)" }
        if sorted.count > 2, sorted.last! - first == sorted.count - 1 { return "slides \(first) to \(sorted.last!)" }
        let head = sorted.dropLast().map(String.init).joined(separator: ", ")
        return "slides \(head) and \(sorted.last!)"
    }

    static func usd(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }
}
