import LecternCore
import SwiftUI

/// Coverage: every slide on the left, a curved line to each card made from it on the right.
///
/// View-only. It reads card sources, slide selection, skip reasons and verdicts the lecture
/// already stores, so it needs no AI and changes nothing. A slide that is selected but has no
/// card that isn't Bad gets a red outline; slides left out in Prepare are greyed.
struct CoverageView: View {
    let model: LectureWindowModel

    private var sourceURL: URL { model.app.store.sourceURL(moduleID: model.ref.moduleID, lectureID: model.ref.lectureID) }

    var body: some View {
        let lecture = model.lecture
        let cards = model.activeCards
        let numbers = model.cardNumbers
        var cardsByPage: [Int: [Card]] = [:]
        for card in cards { for page in Set(card.sourcePages) { cardsByPage[page, default: []].append(card) } }
        var skipReasons: [Int: String] = [:]
        for skipped in lecture.skippedSlides { skipReasons[skipped.slide] = skipped.reason }
        return ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 28) {
                ForEach(lecture.slides) { slide in
                    let page = slide.pageIndex + 1
                    CoverageRow(slide: slide, cards: cardsByPage[page] ?? [], numbers: numbers,
                                skipReason: skipReasons[page], showsBacks: model.coverageShowsBacks,
                                sourceURL: sourceURL) { model.enlargedPage = page }
                }
            }
            .frame(maxWidth: 1000, alignment: .leading)
            .padding(.horizontal, 32).padding(.top, 28).padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.canvas)
    }
}

// MARK: - Row

private struct CoverageRow: View {
    let slide: SlideState
    let cards: [Card]
    let numbers: [UUID: Int]
    let skipReason: String?
    let showsBacks: Bool
    let sourceURL: URL
    let enlarge: () -> Void

    static let slideWidth: CGFloat = 320
    static let unselectedWidth: CGFloat = 200
    static let linesWidth: CGFloat = 140
    static let cardSpacing: CGFloat = 10

    private var page: Int { slide.pageIndex + 1 }
    private var cardHeight: CGFloat { showsBacks ? 78 : 40 }
    private var hasLiveCards: Bool { cards.contains { $0.verdict != .bad } }
    private var uncovered: Bool { slide.isSelected && !hasLiveCards }
    private var stackHeight: CGFloat {
        cards.isEmpty ? 0 : CGFloat(cards.count) * cardHeight + CGFloat(cards.count - 1) * Self.cardSpacing
    }

    var body: some View {
        HStack(alignment: .slideCenter, spacing: 0) {
            slideColumn.frame(width: Self.slideWidth, alignment: .leading)
            CoverageLines(count: cards.count, cardHeight: cardHeight, spacing: Self.cardSpacing)
                .stroke(Theme.faint, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                .frame(width: Self.linesWidth, height: stackHeight)
                .alignmentGuide(.slideCenter) { $0[VerticalAlignment.center] }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Self.cardSpacing) {
                ForEach(cards) { card in
                    CoverageCard(card: card, number: numbers[card.id] ?? 0,
                                 otherPages: Set(card.sourcePages).subtracting([page]).sorted(),
                                 showsBack: showsBacks, height: cardHeight)
                }
            }
            .frame(minWidth: 240, maxWidth: 520, alignment: .leading)
            .alignmentGuide(.slideCenter) { $0[VerticalAlignment.center] }
        }
        .accessibilityElement(children: .contain)
    }

    private var slideColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Slide \(page)")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.faint)
            Button(action: enlarge) {
                SlideImage(sourceURL: sourceURL, pageIndex: slide.pageIndex,
                           width: slide.isSelected ? Self.slideWidth : Self.unselectedWidth, cornerRadius: 6)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.black.opacity(0.08)))
                    .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
                    .overlay {
                        if uncovered {
                            RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.bad, lineWidth: 2).padding(-2)
                        }
                    }
                    .frame(width: slide.isSelected ? Self.slideWidth : Self.unselectedWidth)
                    .opacity(slide.isSelected ? 1 : 0.4)
            }
            .buttonStyle(.plain)
            .help("Enlarge slide \(page)")
            .alignmentGuide(.slideCenter) { $0[VerticalAlignment.center] }
            .accessibilityLabel("Slide \(page), \(statusText ?? "\(cards.count) cards")")
            if let statusText {
                Text(statusText)
                    .font(.system(size: 12, weight: uncovered ? .semibold : .regular))
                    .foregroundStyle(uncovered ? Theme.bad : Theme.faint)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var statusText: String? {
        if !slide.isSelected { return "Not selected in Prepare" }
        guard uncovered else { return nil }
        if let skipReason { return "No cards · AI skipped it: “\(skipReason)”" }
        return "No cards"
    }
}

private extension VerticalAlignment {
    /// The slide thumbnail's centre, so lines leave from the slide itself rather than its label.
    nonisolated enum SlideCenter: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat { context[VerticalAlignment.center] }
    }
    static let slideCenter = VerticalAlignment(SlideCenter.self)
}

// MARK: - Lines

/// One curve from the slide's centre (left edge, mid height) to the centre of each card,
/// ending in a small arrowhead. Each row draws its own lines, so lines from different slides
/// never cross. Cards have a fixed height, so their centres are known without measuring.
private nonisolated struct CoverageLines: Shape {
    let count: Int
    let cardHeight: CGFloat
    let spacing: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let width = rect.width, mid = rect.midY
        for index in 0..<max(0, count) {
            let y = rect.minY + CGFloat(index) * (cardHeight + spacing) + cardHeight / 2
            path.move(to: CGPoint(x: rect.minX + 4, y: mid))
            path.addCurve(to: CGPoint(x: rect.minX + width - 6, y: y),
                          control1: CGPoint(x: rect.minX + width * 0.5, y: mid),
                          control2: CGPoint(x: rect.minX + width * 0.45, y: y))
            path.move(to: CGPoint(x: rect.minX + width - 13, y: y - 5))
            path.addLine(to: CGPoint(x: rect.minX + width - 6, y: y))
            path.addLine(to: CGPoint(x: rect.minX + width - 13, y: y + 5))
        }
        return path
    }
}

// MARK: - Card

private struct CoverageCard: View {
    let card: Card
    let number: Int
    let otherPages: [Int]
    let showsBack: Bool
    let height: CGFloat

    private var isBad: Bool { card.verdict == .bad }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                VerdictDot(verdict: card.verdict)
                Text("C\(number)")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.faint)
                Text(singleLine(card.front))
                    .font(.system(size: 13))
                    .strikethrough(isBad)
                    .foregroundStyle(isBad ? Theme.faint : Theme.ink)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !otherPages.isEmpty {
                    Text("also slide\(otherPages.count == 1 ? "" : "s") \(otherPages.map(String.init).joined(separator: ", "))")
                        .font(.system(size: 11)).foregroundStyle(Theme.faint)
                        .lineLimit(1).fixedSize()
                }
            }
            if showsBack {
                Text(card.back)
                    .font(.system(size: 12)).foregroundStyle(Theme.quiet)
                    .lineLimit(2).truncationMode(.tail)
                    .padding(.leading, 15)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.borderStrong))
        .help(showsBack ? "" : card.back)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Card \(number), \(card.verdict.v2Title): \(card.front)")
    }

    private func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }
}

/// Green Good, amber Needs work, red Bad, hollow To review.
private struct VerdictDot: View {
    let verdict: CardVerdict
    var body: some View {
        Group {
            if verdict == .unreviewed {
                Circle().strokeBorder(Theme.faint, lineWidth: 1.5)
            } else {
                Circle().fill(verdict.v2Color)
            }
        }
        .frame(width: 7, height: 7)
    }
}
