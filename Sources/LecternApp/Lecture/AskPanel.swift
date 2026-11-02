import LecternCore
import SwiftUI

/// Per-slide Ask thread, shared by Prepare and Review (threads are keyed by one-based anchor page).
struct AskPanel: View {
    @Bindable var model: LectureWindowModel
    /// One-based anchor page.
    let page: Int
    let cardID: UUID?
    var focus: FocusState<EditorField?>.Binding

    private var thread: SlideThread? { model.thread(page: page) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            contextChips
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if (thread?.messages.isEmpty ?? true) && model.runningConversationJob(page: page) == nil {
                            Text(cardID == nil
                                 ? "Ask about this slide when something is unclear. Claude answers from the slides you choose above; what you found hard becomes learning points for your cards."
                                 : "Ask about this card and its slides. The thread is shared with Prepare.")
                                .font(Theme.small).foregroundStyle(Theme.quiet)
                        }
                        ForEach(thread?.messages ?? []) { message in
                            MessageBubble(model: model, message: message, showUseAsFeedback: cardID != nil)
                        }
                        runningJob
                        failedJobs
                        if let thread, !thread.learningPoints.isEmpty { learningPoints(thread) }
                        Color.clear.frame(height: 1).id("end")
                    }
                }
                .onChange(of: thread?.messages.count) { _, _ in withAnimation { proxy.scrollTo("end") } }
                .onChange(of: model.runningConversationJob(page: page).flatMap { model.progress($0.id)?.streamedText.count }) { _, _ in
                    proxy.scrollTo("end")
                }
            }
            input
        }
        .padding(16)
    }

    // MARK: Header and context

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            HStack(spacing: 5) {
                Text("Ask").font(.system(size: 14, weight: .semibold))
                Text(cardID == nil ? "⇧⌘A" : "A").font(Theme.caption).foregroundStyle(Theme.faint)
            }
            Spacer()
            let questions = thread?.messages.filter { $0.role == .user }.count ?? 0
            Text(cardID == nil
                 ? "Thread on slide \(page)\(questions > 0 ? " · \(Format.count(questions, "question"))" : "")"
                 : "Same thread as slide \(page) in Prepare")
                .font(Theme.caption).foregroundStyle(Theme.quiet)
        }
    }

    private var contextChips: some View {
        let current = model.askContext(for: page)
        return HStack(spacing: 6) {
            chip("Current slide", .slide, current)
            chip("Whole lecture", .lecture, current)
        }
    }

    private func chip(_ title: String, _ context: ThreadContext, _ current: ThreadContext) -> some View {
        Button(title) { model.askContexts[page] = context }
            .buttonStyle(ChipButtonStyle(isOn: current == context))
            .disabled(model.readOnly)
    }

    private var contextLabel: String {
        switch model.askContext(for: page) {
        case .slide: "slide \(page)"
        case .neighbours(let n): Format.slides(Array(max(1, page - n)...min(model.lecture.pageCount, page + n)))
        case .lecture: "the whole lecture"
        }
    }

    // MARK: Jobs

    @ViewBuilder private var runningJob: some View {
        if let job = model.runningConversationJob(page: page) {
            let progress = model.progress(job.id)
            if job.kind == .ask {
                VStack(alignment: .leading, spacing: 6) {
                    if let text = progress?.streamedText, !text.isEmpty {
                        Text(text).font(Theme.small).textSelection(.enabled)
                    }
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(progress?.stage == "Queued" ? "Waiting for a free slot…" : "Claude is answering…").font(Theme.caption).foregroundStyle(Theme.quiet)
                        Spacer()
                        Button("Cancel") { Task { await model.cancel(job.id) } }.buttonStyle(LinkButtonStyle(color: Theme.quiet))
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Picking learning points from this chat…").font(Theme.caption).foregroundStyle(Theme.quiet)
                }
            }
        }
    }

    @ViewBuilder private var failedJobs: some View {
        if let thread {
            let failed = model.lecture.jobs.filter {
                $0.threadID == thread.id && [.failed, .interrupted].contains($0.state) && !model.dismissedJobIDs.contains($0.id)
            }
            ForEach(failed) { job in
                VStack(alignment: .leading, spacing: 6) {
                    Text(job.kind == .ask ? "The answer didn't arrive" : "Learning points couldn't be extracted")
                        .font(.system(size: 12, weight: .semibold))
                    Text(job.error ?? (job.state == .interrupted ? "Lectern quit before it finished." : "Unknown error.")).font(Theme.small)
                    HStack {
                        Button("Retry") { Task { await model.retry(job.id) } }.buttonStyle(SecondaryButtonStyle()).disabled(model.readOnly)
                        Button("Dismiss") { model.dismissedJobIDs.insert(job.id) }.buttonStyle(LinkButtonStyle(color: Theme.quiet))
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.badWash, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    // MARK: Learning points

    private func learningPoints(_ thread: SlideThread) -> some View {
        let hasCards = !model.cards(from: page).isEmpty
        return VStack(alignment: .leading, spacing: 8) {
            Text("For your cards, from this chat").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.aiStrong)
            ForEach(thread.learningPoints) { point in
                LearningPointRow(model: model, page: page, point: point)
            }
            HStack(alignment: .center, spacing: 8) {
                Text(hasCards
                     ? "Slide \(page) already has cards, so this becomes a revision proposal instead of new cards."
                     : "Ticked points go into the next Generate for these slides.")
                    .font(Theme.caption).foregroundStyle(Theme.quiet).fixedSize(horizontal: false, vertical: true)
                if hasCards {
                    Spacer(minLength: 4)
                    Button("Propose update") { Task { await model.proposeUpdates(page: page) } }
                        .buttonStyle(SecondaryButtonStyle(foreground: Theme.aiStrong, stroke: Theme.ai))
                        .disabled(model.readOnly || !thread.learningPoints.contains { $0.included && $0.pages.contains(page) })
                }
            }
            if let result = model.proposeResult {
                Text(result).font(Theme.caption).foregroundStyle(Theme.aiStrong)
            }
        }
        .padding(12)
        .background(Theme.aiWash, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.ai.opacity(0.35)))
    }

    // MARK: Input

    private var input: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Ask about \(contextLabel)",
                      text: Binding(get: { model.askDrafts[page] ?? "" }, set: { model.askDrafts[page] = $0 }),
                      axis: .vertical)
                .lineLimit(2...6)
                .textFieldStyle(.plain)
                .font(Theme.body)
                .focused(focus, equals: .ask)
                .onSubmit { Task { await model.ask(page: page, cardID: cardID) } }
                .padding(10)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focus.wrappedValue == .ask ? Theme.ai : Theme.borderStrong))
                .disabled(model.readOnly || model.runningConversationJob(page: page) != nil)
            Text("↩ send · questions you ask here shape the next cards").font(Theme.caption).foregroundStyle(Theme.faint)
        }
    }
}

private struct MessageBubble: View {
    let model: LectureWindowModel
    let message: ChatMessage
    let showUseAsFeedback: Bool

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 36)
                Text(message.text).font(Theme.small).textSelection(.enabled)
                    .padding(10)
                    .background(Theme.inset, in: RoundedRectangle(cornerRadius: 10))
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(message.text).font(Theme.small).textSelection(.enabled)
                    if !message.citedPages.isEmpty {
                        HStack(spacing: 5) {
                            ForEach(message.citedPages, id: \.self) { cited in
                                Button("Slide \(cited)") { open(cited) }
                                    .buttonStyle(.plain)
                                    .font(Theme.caption)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Theme.inset, in: RoundedRectangle(cornerRadius: 4))
                                    .help("Show slide \(cited)")
                            }
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
                if showUseAsFeedback {
                    Button("Use as feedback") {
                        let existing = model.feedbackDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        model.feedbackDraft = existing.isEmpty ? message.text : existing + "\n" + message.text
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(model.readOnly)
                }
            }
            .padding(.trailing, 14)
        }
    }

    private func open(_ page: Int) {
        if model.mode == .prepare { model.focus(page - 1) } else { model.enlargedPage = page }
    }
}

private struct LearningPointRow: View {
    let model: LectureWindowModel
    let page: Int
    let point: LearningPoint
    @State private var text = ""
    @FocusState private var editing: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Toggle("", isOn: Binding(get: { point.included },
                                     set: { value in Task { await model.updateLearningPoint(page: page, pointID: point.id, included: value) } }))
                .toggleStyle(.checkbox).labelsHidden()
                .disabled(model.readOnly)
            TextField("Learning point", text: $text, axis: .vertical)
                .textFieldStyle(.plain).font(Theme.small)
                .focused($editing)
                .onSubmit(commit)
                .onChange(of: editing) { _, now in if !now { commit() } }
                .disabled(model.readOnly)
                .opacity(point.included ? 1 : 0.55)
        }
        .onAppear { text = point.text }
        .onChange(of: point.text) { _, new in if !editing { text = new } }
        .help(point.usedBy.isEmpty ? "Not used by a job yet" : "Used by \(Format.count(point.usedBy.count, "job"))")
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != point.text else { text = point.text; return }
        Task { await model.updateLearningPoint(page: page, pointID: point.id, text: trimmed) }
    }
}
