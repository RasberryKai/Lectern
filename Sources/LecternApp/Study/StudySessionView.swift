import AppKit
import LecternCore
import SwiftUI

struct StudySessionView: View {
    @Bindable var session: StudySessionModel
    @FocusState private var focus: EditorField?
    @State private var enlargedSource: StudySource?
    @State private var imageDropTargeted = false
    @State private var caseToRemove: UUID?

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            if let entry = session.current {
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        studyStage(entry)
                            .id(session.turnID)
                            .task(id: session.turnID) { await session.prepareCurrentSolveCase() }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        if let pane = session.pane {
                            Rectangle().fill(Theme.border).frame(width: 1)
                            rightPane(pane, entry: entry)
                                .frame(width: min(360, max(280, geometry.size.width * 0.40)))
                        }
                    }
                }
            } else {
                completion
            }
        }
        .background(Theme.canvasGrid.ignoresSafeArea(edges: .top))
        .navigationTitle("Study")
        .navigationSubtitle(session.scopeLabel)
        .task { await session.refreshCardAfterNavigation() }
        .onChange(of: session.isBusy) { _, busy in
            if !busy, session.error == nil, session.current?.card.solve != nil, session.currentSolveCase == nil {
                Task { await session.prepareCurrentSolveCase() }
            }
        }
        .sheet(item: $enlargedSource) { source in
            StudySourceSheet(source: source) { page in
                Task { await session.openPrepare(page: page) }
            }
        }
        .alert("Remove this case?", isPresented: Binding(
            get: { caseToRemove != nil }, set: { if !$0 { caseToRemove = nil } }
        ), presenting: caseToRemove) { id in
            Button("Remove case", role: .destructive) {
                guard session.currentSolveCase?.id == id else { return }
                Task { await session.retireSolveCase() }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Study will keep the card and its review history.")
        }
        .background(KeyMonitor { event, editing in handleKey(event, editing: editing) })
    }

    private var topBar: some View {
        HStack(spacing: 16) {
            Button {
                Task { await session.back() }
            } label: {
                Label(session.backLabel, systemImage: "arrow.left")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.quiet)
            .disabled(session.isBusy || session.editDraft != nil)
            .accessibilityLabel("Back to \(session.backLabel)")

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Study").font(Theme.heading(17))
                Text(session.scopeLabel).font(Theme.body).foregroundStyle(Theme.quiet).lineLimit(1)
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 0)
            if session.totalCount > 0 {
                HStack(spacing: 10) {
                    ProgressView(value: session.progress)
                        .tint(Theme.accent)
                        .frame(maxWidth: 220)
                        .accessibilityHidden(true)
                    Text("\(session.cardNumber) of \(session.totalCount)")
                        .font(Theme.body.monospacedDigit()).fixedSize()
                        .accessibilityLabel("Card \(session.cardNumber) of \(session.totalCount)")
                    if session.againCount > 0, session.status == .studying {
                        studyBadge("\(session.againCount) again", fill: Theme.amberWash, text: Theme.amber)
                    }
                }
            }
            Spacer(minLength: 0)

            if session.status == .studying {
                Button {
                    if session.pane == nil { session.showSlide() }
                    else { closePane() }
                } label: {
                    Image(systemName: "sidebar.right").frame(width: 14, height: 16)
                }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityLabel(session.pane == nil ? "Show right pane" : "Hide right pane")
                .help("Toggle right pane · ⌘⌥B")
                .disabled(session.editDraft != nil)

                Button {
                    Task { await session.stop() }
                } label: {
                    HStack(spacing: 6) { Text("End session"); ShortcutKey(text: "Esc").accessibilityHidden(true) }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(session.isBusy || session.editDraft != nil || session.hasPendingGrade)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 54)
        .background(Theme.surface)
    }

    private func studyStage(_ entry: StudyCard) -> some View {
        ScrollView {
            VStack(spacing: 14) {
                if let error = session.error {
                    VStack(alignment: .trailing, spacing: 8) {
                        ErrorBanner(message: error, dismiss: session.hasPendingGrade || session.canSkipCurrent ? nil : { session.error = nil })
                        if session.hasPendingGrade {
                            Button("Retry saving grade") { Task { await session.retrySavingGrade() } }
                                .buttonStyle(SecondaryButtonStyle())
                                .disabled(session.isBusy)
                        } else if session.canSkipCurrent {
                            HStack(spacing: 12) {
                                if entry.card.solve != nil, session.currentSolveCase == nil {
                                    Button("Retry loading case") { Task { await session.prepareCurrentSolveCase() } }
                                        .buttonStyle(SecondaryButtonStyle())
                                }
                                Button("Skip card") { Task { await session.skipUnavailableCard() } }
                                    .buttonStyle(LinkButtonStyle(color: Theme.quiet))
                            }
                            .disabled(session.isBusy)
                        }
                    }
                    .frame(maxWidth: 640)
                } else if let notice = session.toast {
                    toast(notice)
                }
                Group {
                    if entry.card.solve != nil { solveCard(entry) }
                    else { studyCard(entry) }
                }
                    .frame(maxWidth: 640)
                shortcuts
                    .frame(maxWidth: 640)
            }
            .padding(.vertical, 28)
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity)
        }
    }

    private func solveCard(_ entry: StudyCard) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 9) {
                Text("Solve card").eyebrow()
                cardStatus(entry)
            }
            if let exercise = session.currentSolveCase {
                SolveExerciseView(content: exercise.content, answers: session.currentSolveAnswers) { answers in
                    session.checkSolve(answers: answers)
                }
                .id(exercise.id)
                .disabled(session.isBusy)
                if session.revealed {
                    HStack(spacing: 12) {
                        if session.sourcePage != nil {
                            Button {
                                session.showSlide(cycle: true)
                                focus = nil
                            } label: {
                                Label("Source slide", systemImage: "display")
                            }
                            .buttonStyle(SecondaryButtonStyle())
                        }
                        Button(action: openAsk) { Label("Ask AI", systemImage: "sparkles") }
                            .buttonStyle(SecondaryButtonStyle(foreground: Theme.ai))
                    }
                    .disabled(session.isBusy || session.hasPendingGrade)
                    Divider()
                    gradeActions
                }
            } else if session.error == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Finding a verified case…").font(Theme.body).foregroundStyle(Theme.quiet)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: 26)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Solve card")
    }

    private func studyCard(_ entry: StudyCard) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 9) {
                Text("Flip card").eyebrow()
                cardStatus(entry)
                Spacer(minLength: 0)
                if session.revealed, let page = session.sourcePage {
                    Button {
                        session.showSlide(cycle: true)
                        focus = nil
                    } label: {
                        Label(sourceLabel(entry, page: page), systemImage: "display")
                            .lineLimit(1)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .help("Show source slide")
                    .disabled(session.editDraft != nil)
                }
            }
            if session.editDraft != nil {
                editor("Front", field: .front, text: draftText(\.front))
                    .onAppear { focus = .front }
            }
            else {
                RenderedCardText(text: entry.card.front, size: 26, emphasized: true)
                    .accessibilityLabel("Front, \(entry.card.front)")
            }
            Divider()

            if session.editDraft != nil {
                editor("Back", field: .back, text: draftText(\.back))
                editActions
            } else if session.revealed {
                RenderedCardText(text: entry.card.back, size: 17, emphasized: false)
                    .accessibilityLabel("Back, \(entry.card.back)")
                Divider()
                gradeActions
            } else {
                VStack(spacing: 10) {
                    Text("Answer it in your head first.").font(Theme.body).foregroundStyle(Theme.quiet)
                    Button(action: session.reveal) {
                        HStack(spacing: 6) {
                            Text("Show answer")
                            ShortcutKey(text: "Space").accessibilityHidden(true)
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(session.isBusy || session.editDraft != nil)
                }
                .frame(maxWidth: .infinity, minHeight: 96)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.borderStrong, style: StrokeStyle(dash: [5, 4])))
            }
        }
        .panel(padding: 26)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Flashcard")
    }

    private func draftText(_ side: WritableKeyPath<StudySessionModel.EditDraft, String>) -> Binding<String> {
        Binding(get: { session.editDraft?[keyPath: side] ?? "" }, set: { session.editDraft?[keyPath: side] = $0 })
    }

    private func editor(_ side: String, field: EditorField, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(side).eyebrow().accessibilityHidden(true)
            TextEditor(text: text)
                .font(field == .front ? .system(size: 22, weight: .semibold) : .system(size: 17))
                .scrollContentBackground(.hidden)
                .foregroundStyle(Theme.ink)
                .frame(minHeight: 90, idealHeight: 112, maxHeight: 160)
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.borderStrong, style: StrokeStyle(dash: [4, 3])))
                .focused($focus, equals: field)
                .accessibilityLabel("Card \(side.lowercased())")
        }
        .disabled(session.isBusy)
    }

    private var editActions: some View {
        HStack {
            Button("Save card") { Task { await session.saveEdit() } }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(session.editDraft?.canSave != true)
            Button("Cancel") { cancelEdit() }.buttonStyle(SecondaryButtonStyle())
        }
        .disabled(session.isBusy)
    }

    private var gradeActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                gradeButton("Got it", rating: .good, key: "1", color: Theme.accent)
                gradeButton("Missed", rating: .again, key: "2", color: Theme.bad)
                Spacer(minLength: 6)
                cardTools
            }
            VStack(alignment: .leading, spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        gradeButton("Got it", rating: .good, key: "1", color: Theme.accent)
                        gradeButton("Missed", rating: .again, key: "2", color: Theme.bad)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        gradeButton("Got it", rating: .good, key: "1", color: Theme.accent)
                        gradeButton("Missed", rating: .again, key: "2", color: Theme.bad)
                    }
                }
                cardTools
            }
        }
        .disabled(session.isBusy || session.editDraft != nil || session.hasPendingGrade)
    }

    private var cardTools: some View {
        HStack(spacing: 10) {
            if let exercise = session.currentSolveCase {
                Button("Remove case") { caseToRemove = exercise.id }
                    .buttonStyle(.plain).font(Theme.small).foregroundStyle(Theme.quiet)
            } else {
                toolButton("Edit", key: "E", action: session.beginEdit)
            }
            toolButton("Disable", key: "D") { Task { await session.disable() } }
        }
        .fixedSize()
    }

    private func gradeButton(_ title: String, rating: StudyRating, key: String, color: Color) -> some View {
        let interval = session.intervalLabel(rating)
        return Button {
            Task { await session.grade(rating) }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
                Text(title).font(Theme.body.weight(.semibold))
                if !interval.isEmpty { Text(interval).font(Theme.caption).foregroundStyle(Theme.quiet) }
                ShortcutKey(text: key).accessibilityHidden(true)
            }
            .fixedSize()
            .padding(.vertical, 4)
        }
        .buttonStyle(SecondaryButtonStyle())
        .accessibilityLabel(interval.isEmpty ? title : "\(title), \(interval)")
    }

    private func toolButton(_ title: String, key: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).font(Theme.small)
                ShortcutKey(text: key).accessibilityHidden(true)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.quiet)
    }

    private var shortcuts: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                recallHints
                navigationHints
            }.fixedSize()
            VStack(spacing: 5) { recallHints; navigationHints }
        }
        .font(Theme.caption)
        .foregroundStyle(Theme.faint)
        .accessibilityHidden(true)
    }

    private var recallHints: some View {
        Text(session.current?.card.solve == nil ? "Space show · 1 Got it · 2 Missed · G Prepare"
             : session.revealed ? "1 Got it · 2 Missed · G Prepare" : "")
    }

    private var navigationHints: some View {
        Text(session.current?.card.solve == nil ? "E edit · D disable · Esc end" : "D disable · Esc end")
    }

    private func toast(_ message: String) -> some View {
        HStack(spacing: 10) {
            Text(message).font(Theme.small)
                .accessibilityAddTraits(.updatesFrequently)
            if session.canUndoDisable {
                toolButton("Undo", key: "U") { Task { await session.undoLast() } }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Theme.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.border))
    }

    private func studyBadge(_ label: String, fill: Color, text: Color) -> some View {
        Text(label).font(Theme.caption.weight(.semibold)).foregroundStyle(text)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(fill, in: Capsule())
            .fixedSize()
    }

    @ViewBuilder private func cardStatus(_ entry: StudyCard) -> some View {
        if session.isRetry { studyBadge("Again", fill: Theme.amberWash, text: Theme.amber) }
        else if entry.memory == nil { studyBadge("New", fill: Theme.goodWash, text: Theme.accentText) }
        else { studyBadge("Review", fill: Theme.inset, text: Theme.quiet) }
    }

    private var completion: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if session.status == .done { completionMark }
                Text(completionTitle).font(Theme.heading(42)).tracking(-1.5)
                    .accessibilityAddTraits(.isHeader)
                Text(completionDetail).font(.system(size: 15)).foregroundStyle(Theme.quiet)
                    .fixedSize(horizontal: false, vertical: true)
                if session.status != .empty, session.deferredSolveCount > 0 {
                    Text(deferredSolveDetail).font(Theme.body).foregroundStyle(Theme.quiet)
                }
                if session.continuationDueCount == 0, let next = session.nextDue, session.status != .limited {
                    Text("Next review \(next.formatted(.relative(presentation: .numeric))).")
                        .font(Theme.body).foregroundStyle(Theme.quiet)
                }
                if let error = session.error { ErrorBanner(message: error) { session.error = nil } }
                if let notice = session.toast {
                    Text(notice).font(Theme.small).foregroundStyle(Theme.quiet)
                }
                completionActions
                if session.status == .done || session.status == .empty {
                    let cram = session.cramCount
                    if cram > 0 {
                        Divider()
                        HStack {
                            Button("Learn \(min(20, cram)) more new cards") {
                                var nextOptions = session.options
                                nextOptions.stop = .complete
                                Task {
                                    await session.app.startStudy(scope: session.scope, options: nextOptions,
                                                                  extraNewPerModule: session.nextCramAllowance,
                                                                  limitNewInSession: 20)
                                }
                            }
                            .buttonStyle(LinkButtonStyle())
                            Text("· \(session.unseenCount) new left").font(Theme.small).foregroundStyle(Theme.quiet)
                        }
                    }
                }
            }
            .panel(padding: 36)
            .frame(maxWidth: 580)
            .padding(32)
            .frame(maxWidth: .infinity, minHeight: 408)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var completionMark: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Theme.onAccent)
            .frame(width: 40, height: 40)
            .background(Theme.accent, in: Circle())
            .accessibilityHidden(true)
    }

    private var completionTitle: String {
        switch session.status {
        case .studying: "Study"
        case .empty:
            if session.continuationDueCount > 0 || session.readySolveCount > 0 { "Cards ready to review" }
            else if session.deferredSolveCount > 0 { "Waiting for fresh cases" }
            else if session.approvedCount == 0 { "Ready when you are" }
            else { "Nothing due" }
        case .done:
            session.continuationDueCount > 0 || session.readySolveCount > 0 || session.deferredSolveCount > 0
                ? "Session complete" : "Done for today"
        case .ended: "Session ended"
        case .limited:
            switch session.options.stop {
            case .minutes(let minutes): "\(Format.count(minutes, "minute")), done"
            case .cards(let count): "\(Format.count(count, "card")), done"
            case .complete: "Session paused"
            }
        }
    }

    private var completionDetail: String {
        switch session.status {
        case .studying: ""
        case .empty:
            if session.continuationDueCount > 0 { "\(Format.count(session.continuationDueCount, "card")) due now." }
            else if session.readySolveCount > 0 { "\(Format.count(session.readySolveCount, "solve card")) ready." }
            else if session.deferredSolveCount > 0 { deferredSolveDetail }
            else if session.approvedCount == 0 { "Approve cards in Review first." }
            else if session.nextDue != nil { "Your scheduled cards are up to date." }
            else if session.unseenCount > 0 { "You’ve reached your new-card limit for today." }
            else { "Your scheduled cards are up to date." }
        case .done, .ended:
            "\(Format.count(session.distinctGradeCount, "card")) in \(elapsedLabel). \(session.missCount) missed."
        case .limited:
            "\(Format.count(session.gradeCount, "grade")) in \(elapsedLabel). \(session.missCount) missed. \(Format.count(session.dueRemaining, "due card")) left for today."
        }
    }

    private var deferredSolveDetail: String {
        let count = session.deferredSolveCount
        return count == 1 ? "One solve card needs a fresh case." : "\(count) solve cards need fresh cases."
    }

    private var elapsedLabel: String {
        let seconds = session.elapsedSeconds
        if seconds < 60 { return Format.count(seconds, "second") }
        return Format.count(seconds / 60, "minute")
    }

    private var completionActions: some View {
        HStack(spacing: 8) {
            if (session.status == .limited || session.status == .ended), session.canKeepGoing {
                Button("Keep going") { session.keepGoing() }.buttonStyle(PrimaryButtonStyle())
            }
            if (session.status == .done || session.status == .empty), session.continuationDueCount > 0 {
                Button("Study \(session.continuationDueCount) due") {
                    Task {
                        await session.app.startStudy(scope: session.scope, options: session.options, limitNewInSession: 0)
                    }
                }.buttonStyle(PrimaryButtonStyle())
            } else if session.status == .done || session.status == .empty, session.readySolveCount > 0 {
                Button("Study ready solve cards") {
                    var nextOptions = session.options
                    nextOptions.cardTypes = .solve
                    Task { await session.app.startStudy(scope: session.scope, options: nextOptions) }
                }
                .buttonStyle(PrimaryButtonStyle())
            } else if session.status == .done, let next = session.nextModule {
                Button("Next · \(next.module.name) · \(next.count)") {
                    Task { await session.app.startStudy(scope: .module(next.module.id)) }
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            Button("Back to \(session.backLabel)") { Task { await session.back() } }
                .buttonStyle(SecondaryButtonStyle())
            if session.canUndoDisable {
                toolButton("Undo", key: "U") { Task { await session.undoLast() } }
            }
        }
        .disabled(session.isBusy)
    }

    private func rightPane(_ pane: StudySessionModel.Pane, entry: StudyCard) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                paneTab(.ask, title: "Ask AI", icon: "sparkles", shortcut: "⌘⇧A")
                paneTab(.slide, title: "Slide", icon: "display", shortcut: "⌘⇧S")
                Spacer(minLength: 0)
                if pane == .ask, let model = session.chatModel { ChatHistoryControls(model: model) }
                Button(action: closePane) { Image(systemName: "xmark").font(Theme.caption) }
                    .buttonStyle(.plain).padding(6)
                    .accessibilityLabel("Hide right pane")
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
            Divider()
            if pane == .slide { sourcePane(entry) }
            else { askPane(entry) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Study right pane")
    }

    private func paneTab(_ pane: StudySessionModel.Pane, title: String, icon: String, shortcut: String) -> some View {
        let selected = session.pane == pane
        return Button {
            if pane == .ask { openAsk() }
            else { session.showSlide(); focus = nil }
        } label: {
            HStack(spacing: 5) {
                Label(title, systemImage: icon).font(Theme.small.weight(.semibold))
                ShortcutKey(text: shortcut).accessibilityHidden(true)
            }
            .padding(.horizontal, 6).padding(.vertical, 8)
            .foregroundStyle(selected ? Theme.ink : Theme.quiet)
            .overlay(alignment: .bottom) { Rectangle().fill(selected ? Theme.ink : .clear).frame(height: 2) }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .disabled(session.editDraft != nil || session.isBusy ||
                  (pane == .ask && session.current?.card.solve != nil && !session.revealed))
    }

    private func askPane(_ entry: StudyCard) -> some View {
        Group {
            if let model = session.chatModel, model.ref.moduleID == entry.moduleID, model.ref.lectureID == entry.lectureID {
                VStack(spacing: 0) {
                    Label(imageDropTargeted ? "Drop images to add to chat" : "Drop images anywhere in this pane",
                          systemImage: "photo.badge.plus")
                        .font(Theme.caption).foregroundStyle(imageDropTargeted ? Theme.ai : Theme.faint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                    AskPanel(model: model, page: session.sourcePage ?? 0, cardID: entry.id, focus: $focus)
                }
                .overlay {
                    ChatImageDropOverlay(enabled: model.canAttachChatImages, isTargeted: $imageDropTargeted) { images in
                        guard model.canAttachChatImages, !images.isEmpty else { return false }
                        Task {
                            if await model.importChatImages(images) { focus = .ask }
                        }
                        return true
                    }
                }
                .onChange(of: model.lecture, initial: true) { _, lecture in session.updateChatCard(lecture) }
                .onChange(of: model.enlargedPage) { _, page in
                    if let page {
                        enlarge(entry, page: page)
                        model.enlargedPage = nil
                    }
                }
                .disabled(session.isBusy)
            } else if let error = session.chatError {
                ErrorBanner(message: error).padding(14)
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: session.turnID) { await session.loadAsk(for: entry) }
    }

    private func sourcePane(_ entry: StudyCard) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !session.revealed {
                    hiddenSlide
                } else if let page = session.sourcePage {
                    let source = studySource(entry, page: page)
                    Text(sourceLabel(entry, page: page)).eyebrow()
                    Button {
                        enlarge(entry, page: page)
                    } label: {
                        SlideImage(sourceURL: source.url, pageIndex: page - 1, width: 720)
                            .id(source.id)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Enlarge slide \(page)")
                    .help(entry.card.solve == nil ? "Enlarge slide · Space" : "Enlarge slide")
                    HStack {
                        if entry.card.sourcePages.count > 1 {
                            Button(action: session.previousSource) {
                                Image(systemName: "chevron.left").frame(width: 18, height: 20)
                            }.accessibilityLabel("Previous source")
                            Text("\(session.sourceIndex + 1) of \(entry.card.sourcePages.count) sources").font(Theme.caption)
                            Button { session.showSlide(cycle: true) } label: {
                                Image(systemName: "chevron.right").frame(width: 18, height: 20)
                            }.accessibilityLabel("Next source")
                        }
                        Spacer(minLength: 4)
                        Button("Prepare") { Task { await session.openPrepare(page: page) } }
                            .buttonStyle(LinkButtonStyle()).help("Open this slide in Prepare · G")
                            .disabled(session.editDraft != nil || session.isBusy)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.quiet)
                    if let note = source.note, !note.isEmpty {
                        Text(note).font(Theme.body).foregroundStyle(Theme.quiet).textSelection(.enabled)
                    }
                } else {
                    Text("No source slides linked to this card.").font(Theme.body).foregroundStyle(Theme.quiet)
                }
            }
            .padding(16)
        }
    }

    private var hiddenSlide: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Theme.inset)
            .aspectRatio(16 / 10, contentMode: .fit)
            .overlay {
                VStack(spacing: 10) {
                    Image(systemName: "display").font(.system(size: 30)).blur(radius: 3)
                        .accessibilityHidden(true)
                    Text(session.current?.card.solve == nil ? "Hidden until you show the answer" : "Hidden until you check your answer")
                        .font(Theme.small)
                }
                .foregroundStyle(Theme.quiet)
            }
    }

    private func sourceLabel(_ entry: StudyCard, page: Int) -> String {
        let module = session.scope == .all ? "\(entry.moduleName) · " : ""
        return "\(module)\(entry.lectureName) · Slide \(page)"
    }

    private func studySource(_ entry: StudyCard, page: Int) -> StudySource {
        let lecture = session.app.studyCatalog.decks.first { $0.module.id == entry.moduleID }?
            .lectures.first { $0.id == entry.lectureID }
        let note = lecture?.slides.first { $0.pageIndex == page - 1 }?.note
        let url = session.app.store.sourceURL(moduleID: entry.moduleID, lectureID: entry.lectureID)
        return StudySource(url: url, page: page, note: note)
    }

    private func enlarge(_ entry: StudyCard, page: Int) {
        guard session.revealed, session.editDraft == nil else { return }
        enlargedSource = studySource(entry, page: page)
    }

    private func openAsk() {
        session.showAsk()
        if session.pane == .ask, session.chatModel != nil { focus = .ask }
    }

    private func closePane() {
        session.closePane()
        if focus == .ask {
            focus = nil
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }

    private func cancelEdit() {
        session.editDraft = nil
        session.error = nil
        focus = nil
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    private func handleKey(_ event: NSEvent, editing: Bool) -> Bool {
        guard !session.app.showSettings else { return false }
        let mods = Key.modifiers(event)
        let letter = Key.letter(event)
        if event.isARepeat, event.keyCode == Key.space || ["1", "2", "d", "u"].contains(letter), !editing {
            return true
        }
        if session.editDraft != nil {
            if mods.isEmpty, event.keyCode == Key.escape, !session.isBusy { cancelEdit(); return true }
            return false
        }
        if session.current != nil, !session.isBusy {
            if mods == [.command, .shift], letter == "a" {
                if session.pane == .ask { closePane() } else { openAsk() }
                return true
            }
            if mods == [.command, .shift], letter == "s" {
                if session.pane == .slide { closePane() } else { session.showSlide(); focus = nil }
                return true
            }
            if mods == [.command, .option], letter == "b" {
                if session.pane != nil { closePane() } else { session.showSlide() }
                return true
            }
            if mods == .command, letter == "n", session.pane == .ask, let model = session.chatModel {
                Task { await model.newChat() }
                return true
            }
        }
        guard mods.isEmpty, !editing else { return false }
        if event.keyCode == Key.escape {
            if session.status == .studying { Task { await session.stop() } }
            else { Task { await session.back() } }
            return true
        }
        if letter == "u", session.canUndo { Task { await session.undoLast() }; return true }
        guard let entry = session.current, !session.isBusy else { return false }
        if event.keyCode == Key.space {
            guard entry.card.solve == nil else { return false }
            if !session.revealed { session.reveal() }
            else if let page = session.sourcePage { enlarge(entry, page: page) }
            return true
        }
        switch letter {
        case "1": Task { await session.grade(.good) }; return true
        case "2": Task { await session.grade(.again) }; return true
        case "g":
            if session.revealed, let page = session.sourcePage { Task { await session.openPrepare(page: page) } }
            return true
        case "e":
            guard entry.card.solve == nil else { return false }
            session.beginEdit()
            return true
        case "d": Task { await session.disable() }; return true
        default: return false
        }
    }
}

private nonisolated struct StudySource: Identifiable {
    let url: URL
    let page: Int
    let note: String?
    var id: String { "\(url.path)#\(page)" }
}

private struct StudySourceSheet: View {
    let source: StudySource
    let openPrepare: (Int) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Slide \(source.page)").font(Theme.heading(20))
                Spacer()
                Button("Open in Prepare") {
                    dismiss()
                    openPrepare(source.page)
                }
                .buttonStyle(SecondaryButtonStyle())
                Button("Close") { dismiss() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Close slide") { dismiss() }
                    .keyboardShortcut(.space, modifiers: [])
                    .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
            }
            ZoomableSlideView(sourceURL: source.url, pageIndex: source.page - 1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let note = source.note, !note.isEmpty {
                Text(note).font(Theme.body).foregroundStyle(Theme.quiet).textSelection(.enabled)
            }
        }
        .padding(24)
        .frame(minWidth: 730, minHeight: 500)
        .background(Theme.surface)
    }
}
