import LecternCore
import SwiftUI

/// Card drafts from explanations the student understood, waiting above the composer to be added or skipped.
/// Slides up from behind the composer when a discussion ends with a point, collapses to a one-line count, and
/// leaves once every draft is decided. Undecided drafts still go into Generate, so ignoring the drawer loses nothing.
struct LearningPointDrawer: View {
    @Bindable var model: LectureWindowModel
    @Binding var expanded: Bool
    @State private var listHeight: CGFloat = 0
    @State private var hovered: UUID?
    @State private var editing: UUID?
    @State private var editFront = ""
    @State private var editBack = ""

    private var points: [LearningPoint] { model.newChatLearningPoints }
    private var draftCount: Int { points.filter { $0.draft != nil }.count }
    private var legacyCount: Int { points.count - draftCount }
    private var bulkActionTitle: String {
        if draftCount == 0 { return "Keep all" }
        if legacyCount == 0 { return "Add all" }
        return "Add drafts + keep"
    }
    private var bulkActionHelp: String {
        if draftCount == 0 { return "Keep older learning points for Generate; this doesn't create cards" }
        if legacyCount == 0 { return "Add every card draft to your cards" }
        return "Add every card draft and keep older learning points for Generate"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                Divider().overlay(Theme.border)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(points) { point in
                            if point.draft != nil { draftRow(point) } else { legacyRow(point) }
                            if point.id != points.last?.id { Divider().overlay(Theme.border) }
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                }
                .scrollIndicators(.automatic)
                .frame(height: min(listHeight, 280))
            }
        }
        // Extra bottom room tucks under the composer, so the drawer reads as sliding out from behind it.
        .padding(.bottom, 12)
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 11, topTrailingRadius: 11).fill(Theme.inset)
        }
        .overlay {
            UnevenRoundedRectangle(topLeadingRadius: 11, topTrailingRadius: 11).strokeBorder(Theme.border)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, -12)
    }

    private var title: String {
        if draftCount == points.count { return draftCount == 1 ? "card draft" : "card drafts" }
        return "for your cards"
    }

    private var header: some View {
        HStack(spacing: 7) {
            Button { withAnimation(.snappy(duration: 0.22)) { expanded.toggle() } } label: {
                HStack(spacing: 7) {
                    Image(systemName: "sparkles").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.ai)
                    Text("\(points.count)").font(.system(size: 10.5, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.canvas)
                        .padding(.horizontal, 5).frame(minWidth: 16, minHeight: 16).background(Theme.ai, in: Capsule())
                    Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text("from what clicked in this chat").font(.system(size: 11.5)).foregroundStyle(Theme.quiet).lineLimit(1)
                    Spacer(minLength: 4)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Collapse" : "Show the cards drafted from explanations that worked for you")
            .accessibilityLabel("\(points.count) learning points for your cards, \(expanded ? "expanded" : "collapsed")")
            if expanded {
                Button(bulkActionTitle) { Task { await model.addAllChatCardDrafts() } }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.ai)
                    .help(bulkActionHelp).disabled(model.readOnly)
            }
            Button { withAnimation(.snappy(duration: 0.22)) { expanded.toggle() } } label: {
                Image(systemName: "chevron.down").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Theme.quiet)
                    .rotationEffect(.degrees(expanded ? 0 : 180)).frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityHidden(true)
        }
        .padding(.leading, 12).padding(.trailing, 8).padding(.vertical, 8)
    }

    private func draftRow(_ point: LearningPoint) -> some View {
        let draft = point.draft!
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                ForEach(reasons(point), id: \.text) { reason in chip(reason.text, tint: reason.tint, wash: reason.wash) }
                ForEach(point.pages.sorted(), id: \.self) { page in
                    Button("Slide \(page)") { model.previewLearningPointSlide(page) }
                        .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Theme.ai)
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(Theme.aiWash, in: RoundedRectangle(cornerRadius: 4))
                        .help("Open slide \(page)")
                }
                if let number = model.cardNumber(replacedBy: point) {
                    Text("improves Card \(number)").font(.system(size: 10)).foregroundStyle(Theme.faint)
                }
                Spacer(minLength: 0)
            }
            if editing == point.id {
                VStack(spacing: 0) {
                    TextField("Front", text: $editFront, axis: .vertical).textFieldStyle(.plain).font(.system(size: 12, weight: .medium)).padding(8)
                    Divider().overlay(Theme.border)
                    TextField("Back", text: $editBack, axis: .vertical).textFieldStyle(.plain).font(.system(size: 12)).padding(8)
                }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.ai))
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Text(draft.front).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.ink).padding(8)
                    Divider().overlay(Theme.border)
                    Text(draft.back).font(.system(size: 12)).foregroundStyle(Theme.quiet).padding(8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border))
            }
            HStack(spacing: 10) {
                Spacer()
                Button("Skip") { Task { await model.removeChatLearningPoint(point.id) } }
                    .buttonStyle(.plain).foregroundStyle(Theme.quiet).help("No card for this; it won't feed Generate either")
                if editing == point.id {
                    Button("Cancel") { editing = nil }.buttonStyle(.plain).foregroundStyle(Theme.quiet)
                    Button(addTitle(point)) { let front = editFront, back = editBack; editing = nil; Task { await model.addChatCardDraft(point, front: front, back: back) } }
                        .buttonStyle(.plain).fontWeight(.semibold).foregroundStyle(Theme.ai)
                        .disabled(editFront.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || editBack.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    Button("Edit") { editFront = draft.front; editBack = draft.back; editing = point.id }
                        .buttonStyle(.plain).foregroundStyle(Theme.quiet)
                    Button(addTitle(point)) { Task { await model.addChatCardDraft(point) } }
                        .buttonStyle(.plain).fontWeight(.semibold).foregroundStyle(Theme.ai)
                }
            }
            .font(.system(size: 11)).disabled(model.readOnly)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(hovered == point.id ? Theme.surface.opacity(0.35) : .clear)
        .onHover { hovered = $0 ? point.id : (hovered == point.id ? nil : hovered) }
        .transition(.opacity)
    }

    private func addTitle(_ point: LearningPoint) -> String {
        model.cardNumber(replacedBy: point).map { "Update Card \($0)" } ?? "Add"
    }

    private struct Reason { let text: String; let tint: Color; let wash: Color }
    private func reasons(_ point: LearningPoint) -> [Reason] {
        var result: [Reason] = []
        switch point.kind {
        case .misconception: result.append(Reason(text: "Misconception", tint: Theme.amber, wash: Theme.amberWash))
        case .ownWords: result.append(Reason(text: "Your words", tint: Theme.good, wash: Theme.goodWash))
        case .understood, nil: break
        }
        if let difficulty = point.difficulty, difficulty > 0 { result.append(Reason(text: "Took \(difficulty + 1) tries", tint: Theme.bad, wash: Theme.badWash)) }
        return result
    }
    private func chip(_ text: String, tint: Color, wash: Color) -> some View {
        Text(text).font(.system(size: 10, weight: .semibold)).foregroundStyle(tint)
            .padding(.horizontal, 5).padding(.vertical, 1.5).background(wash, in: RoundedRectangle(cornerRadius: 4))
    }

    /// Points from before card drafts: keep or drop, as before.
    private func legacyRow(_ point: LearningPoint) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(point.text).font(Theme.small).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                if !point.pages.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(point.pages.sorted(), id: \.self) { page in
                            Button("Slide \(page)") { model.previewLearningPointSlide(page) }
                                .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Theme.ai)
                                .padding(.horizontal, 5).padding(.vertical, 1.5)
                                .background(Theme.aiWash, in: RoundedRectangle(cornerRadius: 4))
                                .help("Open slide \(page)")
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                decisionButton("checkmark", help: "Keep for your cards", tint: Theme.good) { await model.keepChatLearningPoints([point.id]) }
                decisionButton("xmark", help: "Drop this learning point", tint: Theme.bad) { await model.removeChatLearningPoint(point.id) }
            }
            .opacity(hovered == point.id ? 1 : 0.65)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(hovered == point.id ? Theme.surface.opacity(0.5) : .clear)
        .onHover { hovered = $0 ? point.id : (hovered == point.id ? nil : hovered) }
        .transition(.opacity)
    }

    private func decisionButton(_ symbol: String, help: String, tint: Color, action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(DrawerIconButtonStyle(tint: tint))
        .help(help).accessibilityLabel(help).disabled(model.readOnly)
    }
}

private struct DrawerIconButtonStyle: ButtonStyle {
    let tint: Color
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(hovering ? tint : Theme.quiet)
            .background(hovering ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: 5))
            .opacity(configuration.isPressed ? 0.6 : 1)
            .onHover { hovering = $0 }
    }
}
