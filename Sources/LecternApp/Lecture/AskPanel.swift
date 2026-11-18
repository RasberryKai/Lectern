import AppKit
import LecternCore
import SwiftUI

/// One lecture conversation, kept alive across slide navigation and Prepare/Review.
struct AskPanel: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var model: LectureWindowModel
    let page: Int
    let cardID: UUID?
    var focus: FocusState<EditorField?>.Binding
    @State private var composerHeight: CGFloat = 76
    @State private var mentionSelection = 0
    @State private var dismissedMentionDraft: String?
    @State private var learningPointsExpanded = false

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
                            if model.chatMessages.isEmpty && model.runningChat == nil { emptyState }
                            ForEach(model.chatMessages) { message in
                                ChatMessageView(model: model, message: message).id(message.id)
                            }
                            runningAnswer
                            errors
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
        .task(id: model.displayedChat.id) {
            guard !model.readOnly, !(model.mode == .review && model.runningGenerate != nil) else { return }
            focus.wrappedValue = .ask
        }
    }
    private var emptyTitle: String {
        if model.mode == .review, let id = model.selectedCardID { return "Ask about card \(model.cardNumbers[id] ?? 1)" }
        return model.focusedPage.map { "Ask about slide \($0)" } ?? "Ask about this lecture"
    }
    private var composerPlaceholder: String { "Ask anything · @ adds slides or cards" }
    private var emptyLine: String {
        if model.mode == .review, model.selectedCardID != nil { return "Ask about it, or tell it what to change on the card." }
        return model.focusedPage == nil ? "It finds what it needs in the lecture on its own." : "It sees this slide and finds the rest of the lecture on its own."
    }
    /// Calm, centred empty chat: the mark on a white tile inside faint rings, a title that follows the screen, one line.
    private var emptyState: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle().strokeBorder(Theme.border, lineWidth: 1).frame(width: 200, height: 200)
                Circle().strokeBorder(Theme.borderStrong.opacity(0.6), lineWidth: 1).frame(width: 132, height: 132)
                Circle().fill(Theme.aiWash).frame(width: 68, height: 68)
                RoundedRectangle(cornerRadius: 15).fill(Theme.surface)
                    .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(Theme.ai.opacity(0.18)))
                    .shadow(color: Theme.ai.opacity(0.14), radius: 8, y: 6)
                    .overlay(LogoMark().fill(Theme.ai).frame(width: 26, height: 26))
                    .frame(width: 52, height: 52)
                Circle().fill(Theme.ai.opacity(0.4)).frame(width: 6, height: 6).offset(x: 59, y: -67)
                Circle().fill(Theme.borderStrong).frame(width: 4, height: 4).offset(x: -76, y: 54)
            }
            .frame(width: 200, height: 200)
            .accessibilityHidden(true)
            Text(emptyTitle).font(Theme.serif(25)).foregroundStyle(Theme.ink).padding(.top, 6)
            Text(emptyLine).font(.system(size: 13)).foregroundStyle(Theme.quiet).multilineTextAlignment(.center)
                .lineSpacing(2).frame(maxWidth: 230).padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .containerRelativeFrame(.vertical) { length, _ in max(0, length - 36) }
        .accessibilityElement(children: .combine)
    }
    @ViewBuilder private var runningAnswer: some View {
        if let job = model.runningChat {
            let progress = model.progress(job.id)
            let text = progress?.streamedText ?? ""
            // Hints stay until a whole paragraph can be shown; then the line becomes the saved message's "Read …" receipt.
            let answering = !ChatMarkdown.finishedBlocks(text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            VStack(alignment: .leading, spacing: 10) {
                if progress?.stage == "Persistence failed" {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Couldn’t save the answer", systemImage: "exclamationmark.triangle").font(.system(size: 12.5, weight: .semibold))
                        if let warning = progress?.warning { Text(warning).font(Theme.small).textSelection(.enabled) }
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Theme.badWash, in: RoundedRectangle(cornerRadius: 9))
                } else if answering {
                    if let read = progress?.read, !read.isEmpty {
                        Label("Read " + model.chatContextLabel(read), systemImage: "sparkle").font(.system(size: 10.5)).foregroundStyle(Theme.faint)
                    }
                    ChatCitedMarkdownView(model: model, text: text, streaming: true)
                } else {
                    let hint = model.chatWorkingHint(progress)
                    ChatWorkingIndicator(doing: hint.doing, done: hint.done)
                }
            }
            .transition(.opacity)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: answering)
        } else if model.isStartingChat {
            ChatWorkingIndicator(doing: "Preparing your question", done: nil)
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
                Label("AI couldn’t finish", systemImage: "exclamationmark.triangle").font(.system(size: 12.5, weight: .semibold))
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
    private func composer(maximumHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            mentionMenu
                .frame(height: mentionQuery == nil ? 0 : nil)
                .opacity(mentionQuery == nil ? 0 : 1)
                .allowsHitTesting(mentionQuery != nil)
                .accessibilityHidden(mentionQuery == nil)
            VStack(spacing: 0) {
                if mentionQuery == nil && !model.newChatLearningPoints.isEmpty {
                    LearningPointDrawer(model: model, expanded: $learningPointsExpanded)
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                        .zIndex(0)
                }
                composerBox(maximumHeight: maximumHeight).zIndex(1)
            }
            .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: model.newChatLearningPoints.map(\.id))
            .clipped()
            attachmentError
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
                    .focused(focus, equals: .ask)
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
                .help("New chat · ⌘N").accessibilityLabel("New chat")
                .disabled(model.readOnly || model.runningChat != nil || model.isStartingChat || model.isImportingChatImages)
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
