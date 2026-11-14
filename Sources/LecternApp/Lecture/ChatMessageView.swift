import AppKit
import LecternCore
import SwiftUI

struct ChatMessageView: View {
    let model: LectureWindowModel
    let message: ChatMessage
    @State private var hovering = false
    @State private var previewPage: Int?
    var body: some View {
        Group {
            if message.role == .user {
                HStack {
                    Spacer(minLength: 28)
                    VStack(alignment: .trailing, spacing: 5) {
                        if !message.context.isEmpty { Text("on " + model.chatContextLabel(message.context)).font(.system(size: 10.5)).foregroundStyle(Theme.faint) }
                        if !message.attachments.isEmpty { ChatAttachmentStrip(model: model, attachments: message.attachments) }
                        if !message.text.isEmpty { Text(message.text).font(.system(size: 13.5)).lineSpacing(4).textSelection(.enabled)
                            .padding(.horizontal, 12).padding(.vertical, 9).background(Theme.inset, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    if !message.read.isEmpty { Label("Read " + model.chatContextLabel(message.read), systemImage: "sparkle").font(.system(size: 10.5)).foregroundStyle(Theme.faint) }
                    ChatMarkdownView(text: message.text, onCitation: model.openChatCitation, onHoverCitation: { previewPage = $0 })
                        .popover(isPresented: Binding(get: { previewPage != nil }, set: { if !$0 { previewPage = nil } }), arrowEdge: .top) {
                            if let page = previewPage {
                                VStack(alignment: .leading, spacing: 8) {
                                    SlideImage(sourceURL: model.app.store.sourceURL(moduleID: model.ref.moduleID, lectureID: model.ref.lectureID), pageIndex: page - 1, width: 300)
                                    Text("Slide \(page)").font(Theme.caption).foregroundStyle(Theme.quiet)
                                }.padding(10).frame(width: 320).allowsHitTesting(false)
                            }
                        }
                    if message.stopped { Text("Stopped").font(Theme.caption).foregroundStyle(Theme.faint) }
                    if message.searchedLecture { Text("Searched the lecture").font(Theme.caption).foregroundStyle(Theme.faint) }
                    if !message.quiz.isEmpty { quiz }
                    if let ids = message.createdCardIDs, !ids.isEmpty { createdCards(ids) }
                    if let id = message.editJobID, let job = model.lecture.jobs.first(where: { $0.id == id }), job.chatEdits?.isEmpty == false || job.chatEditUndo?.isEmpty == false { ChatEditBlock(model: model, job: job) }
                    HStack(spacing: 14) {
                        action("Copy", "doc.on.doc") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.text, forType: .string) }
                        if message.createdCardIDs?.isEmpty != false, message.editJobID.flatMap({ id in model.lecture.jobs.first(where: { $0.id == id })?.kind }) != .revise {
                            action("Make a card", "rectangle.badge.plus") { Task { await model.makeCard(from: message) } }
                        }
                        if message.createdCardIDs?.isEmpty != false, let id = message.editJobID, model.lecture.jobs.contains(where: { $0.id == id && $0.kind == .chat && $0.isLectureChat == true }) {
                            action("Retry", "arrow.clockwise") { Task { await model.retryChatAnswer(message) } }
                        }
                    }.opacity(hovering ? 1 : 0).disabled(model.readOnly || model.runningChat != nil).accessibilityHidden(!hovering)
                }.frame(maxWidth: .infinity, alignment: .leading).onHover { hovering = $0 }
            }
        }
    }
    private func action(_ title: String, _ symbol: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) { Label(title, systemImage: symbol).font(.system(size: 10.5)) }.buttonStyle(.plain).foregroundStyle(Theme.faint)
    }
    private func createdCards(_ ids: [UUID]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Added \(Format.count(ids.count, "flashcard"))", systemImage: "rectangle.badge.plus")
                .font(.system(size: 12, weight: .semibold))
            ForEach(ids, id: \.self) { id in
                if let number = model.cardNumbers[id] {
                    Button("Open Card \(number)") { model.openChatCard(id) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.ai)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(Theme.aiWash.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
    }
    private var quiz: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(message.quiz.enumerated()), id: \.offset) { index, item in
                DisclosureGroup {
                    ChatMarkdownView(text: item.answer, onCitation: model.openChatCitation).padding(.top, 6)
                } label: { Text("\(index + 1). \(item.question)").font(.system(size: 13, weight: .medium)) }
                    .padding(10).background(Theme.inset, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

struct ChatEditBlock: View {
    let model: LectureWindowModel
    let job: Job
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Image(systemName: "rectangle.and.pencil.and.ellipsis").foregroundStyle(Theme.ai)
                Text(model.chatEditTitle(job)).font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { expanded.toggle() } label: { Image(systemName: expanded ? "chevron.up" : "chevron.down") }.buttonStyle(.plain)
            }
            if expanded || model.chatEditDiffs(job).count <= 3 {
                ForEach(model.chatEditDiffs(job)) { diff in
                    VStack(alignment: .leading, spacing: 5) {
                        Button("Card \(diff.number)") { model.openChatCard(diff.cardID) }.buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.ai)
                        if diff.oldFront != diff.newFront { ChatWordDiff(before: diff.oldFront, after: diff.newFront) }
                        if diff.oldBack != diff.newBack { ChatWordDiff(before: diff.oldBack, after: diff.newBack) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if model.chatEditPending(job) {
                HStack {
                    Button(model.chatEditConflicted(job) ? "Apply anyway" : "Apply all") { Task { await model.resolveChatEdits(job, apply: true) } }.buttonStyle(SecondaryButtonStyle())
                    Button("Dismiss") { Task { await model.resolveChatEdits(job, apply: false) } }.buttonStyle(.plain)
                }.disabled(model.readOnly)
            } else if job.chatEditsUndoneAt == nil, job.chatEditUndo?.isEmpty == false {
                Button("Undo") { Task { await model.undoChatEdits(jobID: job.id) } }
                    .buttonStyle(.plain).font(Theme.caption).foregroundStyle(Theme.ai)
                    .disabled(model.readOnly || !model.lecture.canUndoChatEdits(jobID: job.id))
            }
        }.padding(11).background(Theme.aiWash.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.ai.opacity(0.2)))
    }
}

struct ChatWordDiff: View {
    let before: String
    let after: String
    var body: some View { Text(attributed).font(.system(size: 12)).lineSpacing(3).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
    private var attributed: AttributedString {
        let old = before.split(whereSeparator: \.isWhitespace).map(String.init)
        let new = after.split(whereSeparator: \.isWhitespace).map(String.init)
        // Bounded LCS: long rewrites are clearer as old/new paragraphs and avoid quadratic work.
        guard old.count * new.count <= 40000 else { return rewrite }
        var dp = Array(repeating: Array(repeating: 0, count: new.count + 1), count: old.count + 1)
        if !old.isEmpty && !new.isEmpty {
            for i in stride(from: old.count - 1, through: 0, by: -1) {
                for j in stride(from: new.count - 1, through: 0, by: -1) { dp[i][j] = old[i] == new[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1]) }
            }
        }
        guard Double(dp[0][0]) / Double(max(1, max(old.count, new.count))) >= 0.45 else { return rewrite }
        var result = AttributedString(), i = 0, j = 0
        while i < old.count || j < new.count {
            if i < old.count, j < new.count, old[i] == new[j] { result += AttributedString(old[i] + " "); i += 1; j += 1 }
            else if j < new.count && (i == old.count || dp[i][j + 1] >= dp[i + 1][j]) { result += styled(new[j] + " ", removed: false); j += 1 }
            else { result += styled(old[i] + " ", removed: true); i += 1 }
        }
        return result
    }
    private var rewrite: AttributedString { styled(before + "\n", removed: true) + styled(after, removed: false) }
    private func styled(_ source: String, removed: Bool) -> AttributedString {
        var text = AttributedString(source)
        text.foregroundColor = removed ? Theme.diffRemovedText : Theme.diffAddedText
        text.backgroundColor = removed ? Theme.diffRemovedWash : Theme.diffAddedWash
        if removed { text.strikethroughStyle = .single }
        return text
    }
}

struct ChatEditDiff: Identifiable {
    let cardID: UUID
    let number: Int
    let oldFront: String
    let oldBack: String
    let newFront: String
    let newBack: String
    var id: UUID { cardID }
}
