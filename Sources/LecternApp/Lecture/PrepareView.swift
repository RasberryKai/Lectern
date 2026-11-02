import LecternCore
import SwiftUI

struct PrepareView: View {
    @Bindable var model: LectureWindowModel
    var focus: FocusState<EditorField?>.Binding

    private var sourceURL: URL { model.app.store.sourceURL(moduleID: model.ref.moduleID, lectureID: model.ref.lectureID) }

    var body: some View {
        HStack(spacing: 0) {
            if model.thumbnailsVisible {
                thumbnails
                    .frame(width: thumbnailWidth + 34)
                    .background(Theme.sidebar)
                Rectangle().fill(Theme.border).frame(width: 1)
            }
            center.frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.askVisible, let page = model.focusedPage {
                Rectangle().fill(Theme.border).frame(width: 1)
                AskPanel(model: model, page: page, cardID: nil, focus: focus)
                    .frame(width: 350)
                    .background(Theme.surface)
            }
        }
    }

    private var thumbnailWidth: CGFloat {
        switch model.thumbnailSize {
        case .compact: 130
        case .regular: 170
        case .large: 230
        }
    }

    // MARK: Thumbnails

    private var thumbnails: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(model.filteredSlides) { slide in
                        SlideCell(model: model, slide: slide, width: thumbnailWidth, sourceURL: sourceURL)
                            .id(slide.pageIndex)
                    }
                    if model.filteredSlides.isEmpty {
                        Text(model.prepareFilter == .noCards ? "Every slide has cards." : "No slides match this filter.")
                            .font(Theme.small).foregroundStyle(Theme.quiet).padding(.top, 30)
                    }
                }
                .padding(16)
            }
            .onChange(of: model.focusedPageIndex) { _, page in
                guard let page else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(page) }
            }
            .onAppear { if let page = model.focusedPageIndex { proxy.scrollTo(page, anchor: .center) } }
        }
    }

    // MARK: Focused slide

    @ViewBuilder private var center: some View {
        if let index = model.focusedPageIndex, let slide = model.slide(index) {
            let page = index + 1
            let cards = model.cards(from: page)
            VStack(alignment: .leading, spacing: 14) {
                if let landed = model.landedGenerate { LandingBanner(model: model, job: landed) }
                HStack(spacing: 12) {
                    Text("Slide \(page)").font(.system(size: 14, weight: .semibold))
                    Button { Task { await model.toggleSelection(index) } } label: {
                        Pill(text: slide.isSelected ? "Selected" : "Not selected", tone: slide.isSelected ? .good : .outline)
                    }
                    .buttonStyle(.plain).disabled(model.readOnly)
                    .help("Space toggles selection")
                    Text(cardsLine(cards)).font(Theme.body).foregroundStyle(Theme.quiet)
                    Spacer()
                    if !cards.isEmpty {
                        Button("Show its cards in Review") { model.showCards(fromPage: page) }.buttonStyle(LinkButtonStyle())
                    }
                }
                ForEach(Array(model.lecture.skippedSlides.filter { $0.slide == page }.suffix(1).enumerated()), id: \.offset) { _, skipped in
                    Label("Claude skipped this slide: \(skipped.reason)", systemImage: "arrow.uturn.right")
                        .font(Theme.small).foregroundStyle(Theme.amber)
                }
                SlideImage(sourceURL: sourceURL, pageIndex: index, width: 960, cornerRadius: 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(14)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
                    .layoutPriority(1)
                if model.notesVisible { notes(index: index, page: page) }
            }
            .padding(.horizontal, 28).padding(.vertical, 20)
        } else {
            VStack(spacing: 8) {
                Text(model.lecture.pageCount == 0 ? "This lecture has no slides." : "Choose a slide on the left.")
                    .font(Theme.body).foregroundStyle(Theme.quiet)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func cardsLine(_ cards: [Card]) -> String {
        guard !cards.isEmpty else { return "No cards from this slide yet" }
        let approved = cards.filter { $0.verdict == .good }.count
        return "\(Format.count(cards.count, "card")) from this slide · \(approved) approved"
    }

    private func notes(index: Int, page: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("Notes for slide \(page)").eyebrow()
                Text("· win over module and global rules").font(Theme.caption).foregroundStyle(Theme.quiet)
            }
            TextEditor(text: Binding(get: { model.noteText(for: index) }, set: { model.editNote($0, pageIndex: index) }))
                .font(Theme.body)
                .focused(focus, equals: .note)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 88)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focus.wrappedValue == .note ? Theme.accent : Theme.borderStrong))
                .disabled(model.readOnly)
                .overlay(alignment: .topLeading) {
                    if model.noteText(for: index).isEmpty && focus.wrappedValue != .note {
                        Text("Start typing on a slide to note what the lecturer stressed. ⌘J hides notes; Esc leaves the editor.")
                            .font(Theme.body).foregroundStyle(Theme.faint).padding(.horizontal, 13).padding(.vertical, 9)
                            .allowsHitTesting(false)
                    }
                }
        }
    }
}

// MARK: - Thumbnail cell

private struct SlideCell: View {
    let model: LectureWindowModel
    let slide: SlideState
    let width: CGFloat
    let sourceURL: URL

    var body: some View {
        let page = slide.pageIndex + 1
        let focused = model.focusedPageIndex == slide.pageIndex
        let coverage = model.lecture.coverage(page: page)
        let hasThread = !(model.thread(page: page)?.messages.isEmpty ?? true)
        let hasNote = !model.noteText(for: slide.pageIndex).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        VStack(alignment: .leading, spacing: 7) {
            SlideImage(sourceURL: sourceURL, pageIndex: slide.pageIndex, width: width, cornerRadius: 4)
                .frame(width: width)
                .opacity(slide.isSelected ? 1 : 0.45)
            HStack(spacing: 5) {
                Text("\(page)").font(Theme.caption).monospacedDigit().foregroundStyle(Theme.quiet)
                Spacer(minLength: 2)
                if hasThread { Pill(text: "Q", tone: .ai) }
                if hasNote { Pill(text: "Note", tone: .amber) }
                Pill(text: coverage == 1 ? "1 card" : "\(coverage) cards", tone: coverage > 0 ? .good : .neutral)
                Button { Task { await model.toggleSelection(slide.pageIndex) } } label: {
                    Image(systemName: slide.isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15))
                        .foregroundStyle(slide.isSelected ? Theme.accent : Theme.faint)
                }
                .buttonStyle(.plain)
                .disabled(model.readOnly)
                .help(slide.isSelected ? "Deselect slide \(page)" : "Select slide \(page)")
            }
        }
        .padding(8)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? Theme.ai : (slide.isSelected ? Theme.accent : Theme.border),
                                                                   lineWidth: focused ? 2.5 : (slide.isSelected ? 1.5 : 1)))
        .contentShape(Rectangle())
        .onTapGesture { model.focus(slide.pageIndex) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Slide \(page), \(slide.isSelected ? "selected" : "not selected"), \(coverage) cards")
        .accessibilityAddTraits(focused ? .isSelected : [])
    }
}

// MARK: - Landing banner

struct LandingBanner: View {
    let model: LectureWindowModel
    let job: Job
    @State private var showSkipped = false

    var body: some View {
        let cards = model.lecture.cards.filter { if case .generated(let id) = $0.origin { return id == job.id }; return false }
        let skipped = model.lecture.skippedSlides.filter { job.pages.contains($0.slide) }
        let warning = model.progress(job.id)?.warning
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.good)
            VStack(alignment: .leading, spacing: 2) {
                Text("Added \(Format.count(cards.count, "card")) from \(Format.count(job.pages.count, "slide"))\(skipped.isEmpty ? "" : " · \(skipped.count) skipped")")
                    .font(.system(size: 13, weight: .semibold))
                if let warning { Text(warning).font(Theme.small).foregroundStyle(Theme.amber) }
            }
            Spacer()
            if !skipped.isEmpty {
                Button("Why skipped?") { showSkipped = true }.buttonStyle(LinkButtonStyle(color: Theme.quiet))
                    .popover(isPresented: $showSkipped) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(skipped.enumerated()), id: \.offset) { _, item in
                                Text("Slide \(item.slide): \(item.reason)").font(Theme.small)
                            }
                        }
                        .padding(14).frame(width: 340)
                    }
            }
            Button("Review them") {
                model.dismissedJobIDs.insert(job.id)
                model.setMode(.review)
                model.setReviewFilter(.unreviewed)
            }
            .buttonStyle(SecondaryButtonStyle())
            Button { model.dismissedJobIDs.insert(job.id) } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(Theme.quiet)
        }
        .padding(12)
        .background(Theme.goodWash, in: RoundedRectangle(cornerRadius: 10))
    }
}
