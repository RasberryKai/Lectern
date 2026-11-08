import AppKit
import LecternCore
import SwiftUI

/// In-window lecture destination; the library root guards window close.
struct LectureWindow: View {
    @Environment(AppModel.self) private var app
    let ref: LectureRef
    @State private var model: LectureWindowModel?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let model {
                LectureWorkspace(model: model)
            } else if let loadError {
                VStack(alignment: .leading, spacing: 10) {
                    Text("This lecture can't be opened").font(Theme.serif(24))
                    Text(loadError).font(Theme.body).foregroundStyle(Theme.quiet).textSelection(.enabled)
                }
                .padding(40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.canvas)
        .foregroundStyle(Theme.ink)
        .task { await load() }
    }

    private func load() async {
        // Sessions must open after library bootstrap finishes.
        while app.phase == .loading {
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if case .failed(let message) = app.phase { loadError = message; return }
        do {
            let lecture = try await app.store.loadLecture(moduleID: ref.moduleID, lectureID: ref.lectureID)
            guard !Task.isCancelled, app.activeLecture == ref else { return }
            let session = LectureSession(lecture: lecture, store: app.store, runner: app.runner)
            session.startObserving()
            let windowModel = LectureWindowModel(ref: ref, session: session, app: app)
            if let mode = app.requestedModes.removeValue(forKey: ref.lectureID) { windowModel.setMode(mode) }
            app.register(windowModel)
            model = windowModel
        } catch {
            loadError = error.localizedDescription
        }
    }
}

nonisolated enum EditorField: Hashable {
    case note, front, back, sources, feedback, ask, title
}

struct LectureWorkspace: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: LectureWindowModel
    @FocusState private var focus: EditorField?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            LectureTopBar(model: model, focus: $focus)
            if model.readOnly && !model.isClosing { ReadOnlyBanner() }
            if let message = model.errorMessage ?? (model.session.lastError != model.dismissedSessionError ? model.session.lastError : nil) {
                ErrorBanner(message: message) {
                    model.errorMessage = nil
                    model.dismissedSessionError = model.session.lastError
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
            Group {
                switch model.mode {
                case .prepare: PrepareView(model: model, focus: $focus)
                case .review:
                    ZStack {
                        ReviewView(model: model, focus: $focus)
                        if let job = model.runningGenerate {
                            GenerationOverlay(model: model, job: job)
                                .transition(reduceMotion ? AnyTransition.opacity
                                            : .asymmetric(insertion: .opacity, removal: .opacity.combined(with: .scale(scale: 1.03))))
                                .zIndex(1)
                        }
                    }
                    .animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.4), value: model.runningGenerate?.id)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            JobBar(model: model)
        }
        .background(Theme.canvas)
        .navigationTitle(model.lecture.name)
        .navigationSubtitle(model.moduleName)
        .sheet(isPresented: $model.showGenerateSheet) { GenerateSheet(model: model) }
        .sheet(item: Binding(get: { model.enlargedPage.map(EnlargedPage.init) }, set: { model.enlargedPage = $0?.page })) { item in
            EnlargedSlideSheet(model: model, page: item.page)
        }
        .background(KeyMonitor { event, editing in handleKey(event, editing: editing) })
        .onChange(of: model.session.lecture) { _, _ in model.syncEditor() }
        .onChange(of: model.runningGenerate?.id) { old, new in
            if let old, new == nil { model.revealGenerated(old) }
        }
        .onChange(of: app.requestedModes[model.ref.lectureID]) { _, mode in
            guard let mode else { return }
            app.requestedModes.removeValue(forKey: model.ref.lectureID)
            model.setMode(mode)
        }
        .onChange(of: focus) { old, _ in
            if old == .feedback { Task { await model.saveFeedback() } }
            if old == .note { model.flushNote() }
            if old == .front || old == .back || old == .sources { Task { await model.run { try await model.session.flushEdits() } } }
        }
    }

    // MARK: Keyboard

    private func handleKey(_ event: NSEvent, editing: Bool) -> Bool {
        let modifiers = Key.modifiers(event)
        let letter = Key.letter(event)
        if model.titleDraft != nil && editing { return false }
        if modifiers == [.command, .option], letter == "b" {
            model.askVisible.toggle()
            if !model.askVisible, focus == .ask { focus = nil }
            return true
        }

        // Window-wide command shortcuts work even while typing.
        if modifiers == .command {
            switch letter {
            case "1": model.setMode(.prepare); return true
            case "2": model.setMode(.review); return true
            case "g":
                guard !model.readOnly, model.lecture.pageCount > 0 else { return false }
                model.showGenerateSheet = true; return true
            case "j":
                guard model.mode == .prepare else { return false }
                model.notesVisible.toggle()
                if !model.notesVisible, focus == .note { focus = nil }
                return true
            case "b":
                guard model.mode == .prepare else { return false }
                model.thumbnailsVisible.toggle(); return true
            default: break
            }
            if Key.isReturn(event) {
                switch focus {
                case .feedback: Task { await model.sendFeedback() }; return true
                case .ask:
                    if let page = askPage { Task { await model.ask(page: page, cardID: model.mode == .review ? model.selectedCard?.id : nil) } }
                    return true
                default: return false
                }
            }
        }
        if modifiers == [.command, .shift], letter == "a" {
            model.askVisible = true; focus = .ask; return true
        }
        if event.keyCode == Key.escape, editing {
            if focus == .feedback { Task { await model.saveFeedback() } }
            focus = nil
            NSApp.keyWindow?.makeFirstResponder(nil)
            return true
        }
        // Card shortcuts would act on cards hidden behind the generation overlay.
        if model.mode == .review, model.runningGenerate != nil { return false }
        guard !editing else { return false }
        return model.mode == .prepare ? handlePrepareKey(event, modifiers: modifiers) : handleReviewKey(event, modifiers: modifiers, letter: letter)
    }

    private var askPage: Int? {
        model.mode == .prepare ? model.focusedPage : model.selectedCard?.sourcePages.first
    }

    private func handlePrepareKey(_ event: NSEvent, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard modifiers.isSubset(of: [.shift]) else { return false }
        switch event.keyCode {
        case Key.left, Key.up: model.moveFocus(-1); return true
        case Key.right, Key.down: model.moveFocus(1); return true
        case Key.space:
            if let page = model.focusedPageIndex { Task { await model.toggleSelection(page) } }
            return true
        case Key.escape: return false
        default:
            // Typing on a focused slide opens its note and keeps the first character.
            guard let text = Key.printable(event), model.appendToNote(text) else { return false }
            focus = .note
            return true
        }
    }

    private func handleReviewKey(_ event: NSEvent, modifiers: NSEvent.ModifierFlags, letter: String) -> Bool {
        if Key.isReturn(event) {
            guard model.selectedCard?.proposal?.state == .ready else { return false }
            Task { await model.acceptProposal(approve: modifiers == .shift) }
            return true
        }
        guard modifiers.isEmpty else { return false }
        switch event.keyCode {
        case Key.left, Key.up: model.stepCard(-1); return true
        case Key.right, Key.down: model.stepCard(1); return true
        case Key.space:
            guard let card = model.selectedCard, !card.sourcePages.isEmpty else { return false }
            let pages = card.sourcePages
            model.enlargedPage = pages[min(model.sourceIndex, pages.count - 1)]
            return true
        default: break
        }
        switch letter {
        case "1": Task { await model.setVerdict(.good) }; return true
        case "2": Task { await model.setVerdict(.bad) }; return true
        case "3":
            Task { await model.setVerdict(.needsAdjustment) }
            focus = .feedback
            return true
        case "x": Task { await model.discardProposal() }; return true
        case "u": Task { await model.undo() }; return true
        case "s":
            guard let count = model.selectedCard?.sourcePages.count, count > 0 else { return false }
            model.sourceIndex = (model.sourceIndex + 1) % count
            return true
        case "g":
            guard let card = model.selectedCard, !card.sourcePages.isEmpty else { return false }
            model.jumpToPrepare(page: card.sourcePages[min(model.sourceIndex, card.sourcePages.count - 1)])
            return true
        case "a":
            guard model.selectedCard?.sourcePages.isEmpty == false else { return false }
            model.askVisible = true
            focus = .ask
            return true
        case "e":
            focus = .front
            return true
        default: return false
        }
    }
}

private nonisolated struct EnlargedPage: Identifiable { let page: Int; var id: Int { page } }

private struct EnlargedSlideSheet: View {
    let model: LectureWindowModel
    let page: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Slide \(page)").font(Theme.serif(20))
                Spacer()
                Button("Open in Prepare") { dismiss(); model.jumpToPrepare(page: page) }.buttonStyle(SecondaryButtonStyle())
                Button("Close") { dismiss() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button("") { dismiss() }.keyboardShortcut(.space, modifiers: []).opacity(0).frame(width: 0, height: 0)
            }
            SlideImage(sourceURL: model.app.store.sourceURL(moduleID: model.ref.moduleID, lectureID: model.ref.lectureID),
                       pageIndex: page - 1, width: 1100, cornerRadius: 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            let note = model.noteText(for: page - 1)
            if !note.isEmpty { Text("Note: \(note)").font(Theme.body).foregroundStyle(Theme.quiet) }
        }
        .padding(24)
        .frame(minWidth: 900, minHeight: 640)
        .background(Theme.surface)
    }
}

// MARK: - Top bar

struct LectureTopBar: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: LectureWindowModel
    var focus: FocusState<EditorField?>.Binding

    var body: some View {
        HStack(spacing: 18) {
            Button {
                Task { await app.returnToLibrary() }
            } label: {
                Label("Back to library", systemImage: "chevron.left")
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(app.leavingLecture)
            presentationTitle
            SegmentedControl(options: [(LectureMode.prepare, "Prepare"), (LectureMode.review, "Review")],
                             selection: Binding(get: { model.mode }, set: { model.setMode($0) }))
                .help("⌘1 Prepare · ⌘2 Review")
                .disabled(model.lecture.pageCount == 0)
            if model.mode == .prepare {
                SegmentedControl(options: [(PrepareFilter.all, "All"), (PrepareFilter.selected, "Selected"), (PrepareFilter.noCards, "No cards")],
                                 selection: $model.prepareFilter, activeFill: Theme.inset, activeText: Theme.ink)
            }
            Spacer(minLength: 10)
            if model.mode == .prepare { prepareTrailing } else { reviewTrailing }
            Button {
                model.askVisible.toggle()
            } label: {
                Image(systemName: "sidebar.right")
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.askVisible ? Theme.accentText : Theme.quiet)
            .accessibilityLabel("Toggle right sidebar")
            .help("Toggle right sidebar · ⌘⌥B")
            .keyboardShortcut("b", modifiers: [.command, .option])
        }
        .padding(.horizontal, 22).padding(.vertical, 12)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    @ViewBuilder private var presentationTitle: some View {
        if model.titleDraft != nil {
            TextField("Presentation name", text: Binding(
                get: { model.titleDraft ?? model.lecture.name },
                set: { model.titleDraft = $0 }
            ))
            .font(Theme.serif(20))
            .textFieldStyle(.plain)
            .focused(focus, equals: .title)
            .frame(minWidth: 100, idealWidth: 220, maxWidth: 300)
            .disabled(model.isSavingTitle)
            .task {
                await Task.yield()
                focus.wrappedValue = .title
            }
            .onSubmit { saveTitle() }
            .onExitCommand { model.titleDraft = nil; focus.wrappedValue = nil }
            .onChange(of: focus.wrappedValue) { old, current in
                if old == .title, current != .title, model.titleDraft != nil { saveTitle() }
            }
        } else {
            Button { beginRename() } label: {
                Text(model.lecture.name).font(Theme.serif(20)).lineLimit(1)
            }
            .buttonStyle(.plain)
            .help("Click to rename presentation")
            .disabled(model.readOnly)
            .contextMenu {
                Button("Rename presentation…") { beginRename() }.disabled(model.readOnly)
            }
        }
    }

    private func beginRename() {
        model.titleDraft = model.lecture.name
    }

    private func saveTitle() {
        Task {
            await model.run { try await model.commitTitle() }
            if model.titleDraft != nil { focus.wrappedValue = .title }
        }
    }

    @ViewBuilder private var prepareTrailing: some View {
        let selected = model.lecture.slides.filter(\.isSelected).count
        let uncovered = model.lecture.uncoveredSelectedPages.count
        Text("\(selected) of \(model.lecture.pageCount) selected · \(uncovered) without cards")
            .font(Theme.body).foregroundStyle(Theme.quiet).monospacedDigit()
        Menu {
            Button("Select all slides") { Task { await model.setAllSelected(true) } }
            Button("Deselect all slides") { Task { await model.setAllSelected(false) } }
            Divider()
            Picker("Thumbnail size", selection: $model.thumbnailSize) {
                Text("Compact").tag(ThumbnailSize.compact)
                Text("Regular").tag(ThumbnailSize.regular)
                Text("Large").tag(ThumbnailSize.large)
            }
            Toggle("Show notes  ⌘J", isOn: $model.notesVisible)
            Toggle("Show thumbnails  ⌘B", isOn: $model.thumbnailsVisible)
            Toggle("Show Ask panel", isOn: $model.askVisible)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton).fixedSize()
        if let running = model.runningGenerate {
            Button("Generating…") {}.buttonStyle(SecondaryButtonStyle(foreground: Theme.quiet, fill: Theme.inset)).disabled(true)
                .help("Writing cards from \(Format.count(running.pages.count, "slide"))")
        } else {
            Button("Generate cards…") { model.showGenerateSheet = true }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.readOnly)
                .help("⌘G")
        }
    }

    @ViewBuilder private var reviewTrailing: some View {
        Text("\(model.reviewedCount) / \(model.activeCards.count) reviewed").font(Theme.body).foregroundStyle(Theme.quiet).monospacedDigit()
        Text(model.readOnly ? "Read-only" : "Saved on this Mac").font(Theme.small).foregroundStyle(Theme.faint)
        Button("Export") {
            Task { await app.returnToLibrary(destination: .export(model.ref.moduleID)) }
        }
        .buttonStyle(SecondaryButtonStyle())
    }
}
