import AppKit
import LecternCore
import SwiftUI

/// One lecture conversation, kept alive across slide navigation and Prepare/Review.
struct AskPanel: View {
    @Environment(\.openSettings) private var openSettings
    @Bindable var model: LectureWindowModel
    let page: Int
    let cardID: UUID?
    var focus: FocusState<EditorField?>.Binding
    @State private var composerHeight: CGFloat = 76
    @State private var mentionSelection = 0
    @State private var dismissedMentionDraft: String?

    private var mentionQuery: String? {
        guard dismissedMentionDraft != model.chatDraft,
              let at = model.chatDraft.range(of: "@", options: .backwards) else { return nil }
        let query = String(model.chatDraft[at.upperBound...])
        return query.contains("\n") ? nil : query
    }
    private var mentions: [ChatMention] { model.chatMentions.filter { mentionQuery?.isEmpty == true || $0.label.localizedCaseInsensitiveContains(mentionQuery ?? "") } }
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 22) {
                            if model.chatMessages.isEmpty && model.runningChat == nil { starters }
                            ForEach(model.chatMessages) { message in
                                ChatMessageView(model: model, message: message).id(message.id)
                            }
                            runningAnswer
                            errors
                            learningPoints
                            Color.clear.frame(height: 1).id("chat-end")
                        }.padding(.horizontal, 18).padding(.vertical, 18)
                    }
                    .onChange(of: model.chatMessages.count) { _, _ in proxy.scrollTo("chat-end", anchor: .bottom) }
                    .onChange(of: model.runningChat.flatMap { model.progress($0.id)?.streamedText.count }) { _, _ in proxy.scrollTo("chat-end", anchor: .bottom) }
                    .onChange(of: model.chatScrollTarget) { _, target in if let target { withAnimation { proxy.scrollTo(target, anchor: .top) } } }
                    .onChange(of: model.displayedChat.id) { _, _ in proxy.scrollTo("chat-end", anchor: .bottom) }
                }
                composer(maximumHeight: max(100, geometry.size.height * 0.45))
            }
        }
    }
    private var emptyTitle: String {
        if model.mode == .review, let id = model.selectedCardID { return "Ask about card \(model.cardNumbers[id] ?? 1)" }
        return model.focusedPage.map { "Ask about slide \($0)" } ?? "Ask about this lecture"
    }
    private var composerPlaceholder: String {
        model.mode == .review ? "\(emptyTitle), or tell Claude what to change…" : "\(emptyTitle), or anything in this lecture…"
    }
    private var starterPrompts: [String] {
        model.mode == .review ? ["Why is this the right answer?", "Make the back shorter", "Give me a memory hook", "Quiz me on this slide"] : ["Explain this slide simply", "What will the exam ask from this?", "Quiz me on this slide", "Which words here matter most?"]
    }
    private var starters: some View {
        VStack(alignment: .leading, spacing: 14) {
            LogoMark().fill(Theme.accent).frame(width: 32, height: 32)
            Text(emptyTitle).font(Theme.serif(21))
            Text("Claude already sees what you’re looking at. Mention other slides or cards with @, or just ask: it finds them in the lecture.").font(Theme.body).foregroundStyle(Theme.quiet)
            ForEach(starterPrompts, id: \.self) { text in
                Button(text) { model.setChatDraft(text); focus.wrappedValue = .ask }
                    .buttonStyle(.plain).font(Theme.small).foregroundStyle(Theme.ink).padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Theme.surface, in: Capsule()).overlay(Capsule().strokeBorder(Theme.borderStrong))
            }
        }.padding(.vertical, 24).frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder private var runningAnswer: some View {
        if let job = model.runningChat {
            VStack(alignment: .leading, spacing: 8) {
                let progress = model.progress(job.id)
                if let text = progress?.streamedText, !text.isEmpty { ChatMarkdownView(text: text, streaming: true, onCitation: model.openChatCitation) }
                HStack(spacing: 7) {
                    ProgressView().controlSize(.mini)
                    Text(progress?.stage == "Queued" ? "Waiting for a free slot…" : (progress?.streamedText.isEmpty == false ? "Claude is answering…" : (progress?.stage ?? "Reading your context…")))
                        .font(Theme.caption).foregroundStyle(Theme.faint)
                }
            }
        } else if model.isStartingChat {
            HStack(spacing: 7) {
                ProgressView().controlSize(.mini)
                Text("Preparing your question…").font(Theme.caption).foregroundStyle(Theme.faint)
            }
        }
    }
    @ViewBuilder private var errors: some View {
        if let failure = model.chatPreparationFailure, failure.chatID == model.displayedChat.id {
            VStack(alignment: .leading, spacing: 9) {
                Label("Couldn’t prepare your question", systemImage: "exclamationmark.triangle").font(.system(size: 12.5, weight: .semibold))
                Text(failure.message).font(Theme.small).textSelection(.enabled)
                HStack {
                    Button("Try again") { Task { await model.sendChat(retrying: failure) } }.buttonStyle(SecondaryButtonStyle())
                    if needsSettings(failure.message) { Button("Open Settings") { openSettings() }.buttonStyle(SecondaryButtonStyle()) }
                    Button("Dismiss") { model.chatPreparationFailure = nil }.buttonStyle(.plain)
                }.disabled(model.readOnly || model.isStartingChat || model.runningChat != nil)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Theme.badWash, in: RoundedRectangle(cornerRadius: 9))
        }
        ForEach(model.chatFailures) { job in
            VStack(alignment: .leading, spacing: 9) {
                Label("Claude couldn’t finish", systemImage: "exclamationmark.triangle").font(.system(size: 12.5, weight: .semibold))
                Text(job.error ?? "Lectern closed before the answer finished.").font(Theme.small).textSelection(.enabled)
                HStack {
                    Button("Try again") { Task { await model.retry(job.id) } }.buttonStyle(SecondaryButtonStyle())
                    if needsSettings(job.error ?? "") {
                        Button("Open Settings") { openSettings() }.buttonStyle(SecondaryButtonStyle())
                    }
                    Button("Dismiss") { model.dismissedJobIDs.insert(job.id) }.buttonStyle(.plain)
                }.disabled(model.readOnly)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Theme.badWash, in: RoundedRectangle(cornerRadius: 9))
        }
    }
    private func needsSettings(_ message: String) -> Bool {
        ["login", "auth", "sign in", "subscription profile", "configure", "api key"].contains { message.localizedCaseInsensitiveContains($0) }
    }
    private var learningPoints: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.chatLearningPoints.filter(\.included)) { point in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "checkmark.circle").foregroundStyle(Theme.ai)
                    Text("Noted for your cards: \(point.text)").font(Theme.caption).foregroundStyle(Theme.quiet)
                    Spacer(minLength: 0)
                    Button { Task { await model.removeChatLearningPoint(point.id) } } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                        .buttonStyle(.plain).help("Drop this learning point").disabled(model.readOnly)
                }
            }
        }
    }
    private func composer(maximumHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            mentionMenu
                .frame(height: mentionQuery == nil ? 0 : nil)
                .opacity(mentionQuery == nil ? 0 : 1)
                .allowsHitTesting(mentionQuery != nil)
                .accessibilityHidden(mentionQuery == nil)
            composerBox(maximumHeight: maximumHeight)
            attachmentError
            Label("Claude sees attached images and the context chips, and looks up other slides or cards when needed.", systemImage: "magnifyingglass")
                .font(.system(size: 10.5)).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true)
        }.padding(.horizontal, 12).padding(.bottom, 12).padding(.top, 8)
            .onChange(of: model.chatDraft) { _, draft in
                if draft != dismissedMentionDraft { dismissedMentionDraft = nil }
            }
            .onChange(of: mentionQuery) { _, _ in mentionSelection = 0 }
    }
    private func composerBox(maximumHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    if model.chatContext.followsScreen && !model.visibleScreenChatContext.isEmpty {
                        contextChip(model.chatContextLabel(model.visibleScreenChatContext), automatic: true) { model.chatContext.followsScreen = false }
                    }
                    ForEach(model.chatContext.pins, id: \.self) { ref in contextChip(model.contextLabel(ref)) { model.chatContext.pins.removeAll { $0 == ref } } }
                }.padding(.horizontal, 10).padding(.top, 9)
            }
            if !model.chatDraftAttachments.isEmpty {
                ChatAttachmentStrip(model: model, attachments: model.chatDraftAttachments, remove: model.readOnly || model.isStartingChat ? nil : { model.removeChatImage($0) })
                    .padding(.horizontal, 9).padding(.top, 7)
            }
            ZStack(alignment: .topLeading) {
                if model.chatDraft.isEmpty { Text(composerPlaceholder).font(.system(size: 13.5)).foregroundStyle(Theme.faint).padding(.horizontal, 12).padding(.top, 10).allowsHitTesting(false) }
                ChatComposerTextView(text: Binding(get: { model.chatDraft }, set: { model.setChatDraft($0) }), height: $composerHeight,
                                     focused: focus.wrappedValue == .ask, editable: !model.readOnly, maximumHeight: max(76, maximumHeight - 80),
                                     onFocus: { focus.wrappedValue = $0 ? .ask : nil }, onSend: send, onMenuKey: menuKey,
                                     onImages: { images in Task { await model.importChatImages(images) }; focus.wrappedValue = .ask })
                    .frame(height: composerHeight).padding(.horizontal, 5)
            }
            HStack {
                Button { model.setChatDraft(model.chatDraft + "@"); focus.wrappedValue = .ask } label: { Image(systemName: "at") }
                    .buttonStyle(.plain).help("Attach context").disabled(model.readOnly)
                Button { model.chooseChatImages() } label: { Image(systemName: "paperclip").frame(width: 24, height: 24).contentShape(Rectangle()) }
                    .buttonStyle(.plain).help("Attach images · paste or drop anywhere in this pane")
                    .accessibilityLabel("Attach images").disabled(model.readOnly || model.isImportingChatImages || model.isStartingChat)
                if model.isImportingChatImages { ProgressView().controlSize(.mini).accessibilityLabel("Preparing images") }
                Text("↩ send · ⇧↩ new line").font(.system(size: 10.5)).foregroundStyle(Theme.faint)
                Spacer()
                if let job = model.runningChat {
                    Button { Task { await model.cancel(job.id) } } label: { Label("Stop", systemImage: "stop.fill") }
                        .buttonStyle(.plain).foregroundStyle(Theme.ai).help("Stop and keep the partial answer")
                } else {
                    Button(action: send) { Image(systemName: "arrow.up").font(.system(size: 13, weight: .semibold)).frame(width: 27, height: 27).background(Theme.ai, in: Circle()).foregroundStyle(.white) }
                        .buttonStyle(.plain).disabled((model.chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.chatDraftAttachments.isEmpty) || model.readOnly || model.isStartingChat || model.isImportingChatImages).help("Send")
                }
            }.padding(.horizontal, 12).padding(.bottom, 9)
        }
        .background { RoundedRectangle(cornerRadius: 13).fill(Theme.surface) }
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(focus.wrappedValue == .ask ? Theme.ai : Theme.borderStrong))
    }
    @ViewBuilder private var attachmentError: some View {
        if let error = model.chatAttachmentError {
            HStack(alignment: .top) {
                Text(error).font(Theme.caption).foregroundStyle(Theme.bad)
                Spacer(minLength: 4)
                Button { model.chatAttachmentError = nil } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                    .buttonStyle(.plain).help("Dismiss attachment error")
            }
        }
    }
    private var mentionMenu: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if mentions.isEmpty { Text("No matching slides or cards").font(Theme.small).padding(9) }
                    ForEach(Array(mentions.enumerated()), id: \.element.id) { index, mention in
                        Button { pick(mention) } label: {
                            HStack { Image(systemName: mention.icon); Text(mention.label).lineLimit(1); Spacer() }
                                .font(Theme.small).padding(.horizontal, 9).padding(.vertical, 7)
                                .background(index == mentionSelection ? Theme.aiWash : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                        }.buttonStyle(.plain).focusable(false).id(index)
                    }
                }.padding(4)
            }.frame(maxHeight: 190).background(Theme.surface, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border))
                .onChange(of: mentionSelection) { _, index in proxy.scrollTo(index) }
        }
    }
    private func contextChip(_ title: String, automatic: Bool = false, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            if automatic { Circle().fill(Theme.ai).frame(width: 5, height: 5) }
            Text(title).lineLimit(1)
            Button(action: remove) { Image(systemName: "xmark").font(.system(size: 8, weight: .semibold)) }.buttonStyle(.plain)
        }.font(.system(size: 10.5)).foregroundStyle(Theme.ai).padding(.horizontal, 7).padding(.vertical, 4).background(Theme.aiWash, in: RoundedRectangle(cornerRadius: 5))
    }
    private func menuKey(_ key: UInt16) -> Bool {
        guard mentionQuery != nil else { return false }
        if key == 53 { dismissedMentionDraft = model.chatDraft; return true }
        if key == 125 { mentionSelection = min(max(0, mentions.count - 1), mentionSelection + 1); return true }
        if key == 126 { mentionSelection = max(0, mentionSelection - 1); return true }
        if key == 36 || key == 76 {
            if !mentions.isEmpty { pick(mentions[min(mentionSelection, mentions.count - 1)]) }
            return true
        }
        return false
    }
    private func pick(_ mention: ChatMention) {
        if let ref = mention.ref { model.chatContext.pin(ref) }
        else { model.chatContext.followsScreen = true }
        if let at = model.chatDraft.range(of: "@", options: .backwards) { model.setChatDraft(String(model.chatDraft[..<at.lowerBound])) }
        focus.wrappedValue = .ask
    }
    private func send() { guard model.runningChat == nil else { return }; Task { await model.sendChat() } }
}

struct ChatHistoryControls: View {
    @Bindable var model: LectureWindowModel
    @State private var history = false
    @State private var deleting: UUID?
    var body: some View {
        HStack(spacing: 10) {
            Button { history.toggle() } label: { Image(systemName: "clock.arrow.circlepath") }
                .help("Earlier chats").popover(isPresented: $history, arrowEdge: .bottom) { historyList }
            Button { Task { await model.newChat() } } label: { Image(systemName: "square.and.pencil") }
                .help("New chat").disabled(model.readOnly || model.runningChat != nil || model.isStartingChat || model.isImportingChatImages)
        }.buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Theme.quiet)
    }
    private var historyList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Earlier chats").font(.system(size: 14, weight: .semibold))
            if model.earlierChats.isEmpty { Text("Your previous chats will appear here.").font(Theme.small).foregroundStyle(Theme.quiet) }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(model.earlierChats) { chat in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Button { Task { await model.resumeChat(chat.id); history = false } } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(chat.title.isEmpty ? "Untitled chat" : chat.title).font(.system(size: 12.5, weight: .medium)).lineLimit(2)
                                        Text("\(chat.updatedAt.formatted(date: .abbreviated, time: .omitted)) · \(chat.messages.count) messages").font(Theme.caption).foregroundStyle(Theme.faint)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(.plain).disabled(model.runningChat != nil || model.isStartingChat || model.isImportingChatImages)
                                Button { deleting = chat.id } label: { Image(systemName: "trash").foregroundStyle(Theme.faint) }.buttonStyle(.plain).help("Delete chat").disabled(model.readOnly)
                            }
                            if deleting == chat.id {
                                HStack { Text("Delete this chat?").font(Theme.small); Spacer(); Button("Cancel") { deleting = nil }; Button("Delete", role: .destructive) { Task { await model.deleteChat(chat.id); deleting = nil } } }.font(Theme.small)
                            }
                        }.padding(9).background(Theme.inset, in: RoundedRectangle(cornerRadius: 7))
                    }
                }
            }.frame(maxHeight: 330)
        }.padding(16).frame(width: 310)
    }
}
