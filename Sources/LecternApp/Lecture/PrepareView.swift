import LecternCore
import SwiftUI

struct PrepareView: View {
    @Bindable var model: LectureWindowModel
    var focus: FocusState<EditorField?>.Binding

    private var sourceURL: URL { model.app.store.sourceURL(moduleID: model.ref.moduleID, lectureID: model.ref.lectureID) }

    var body: some View {
        LecturePanes(model: model) {
            VStack(spacing: 0) {
                SegmentedControl(options: [(PrepareFilter.all, "All"), (PrepareFilter.selected, "Selected")],
                                 selection: $model.prepareFilter, activeFill: Theme.inset, activeText: Theme.ink)
                    .padding(10)
                Divider().overlay(Theme.border)
                thumbnails
            }
            .contextMenu { sidebarOptions }
        } stage: {
            center
        } right: {
            LectureSidePanel(model: model, focus: focus)
        }
        .onChange(of: model.filteredSlides.map(\.pageIndex), initial: true) { _, _ in
            model.reconcilePrepareFocus()
        }
    }

    // MARK: Thumbnails

    /// Former header ⋯ menu items that aren't pane toggles; right-click the slide list.
    @ViewBuilder private var sidebarOptions: some View {
        Button("Select all slides") { Task { await model.setAllSelected(true) } }.disabled(model.readOnly)
        Button("Deselect all slides") { Task { await model.setAllSelected(false) } }.disabled(model.readOnly)
        Divider()
        Picker("Thumbnail size", selection: $model.thumbnailSize) {
            Text("Compact").tag(ThumbnailSize.compact)
            Text("Regular").tag(ThumbnailSize.regular)
            Text("Large").tag(ThumbnailSize.large)
        }
        Toggle("Show notes  ⌘J", isOn: $model.notesVisible)
    }

    private var thumbnails: some View {
        CenteredThumbnailList(pageIndices: model.filteredSlides.map(\.pageIndex), focusedPageIndex: model.focusedPageIndex) { pageIndex in
            if let slide = model.slide(pageIndex) {
                SlideCell(model: model, slide: slide, width: 320, sourceURL: sourceURL)
                    .frame(maxWidth: thumbnailWidth)
            }
        }
        .overlay {
            if model.filteredSlides.isEmpty {
                Text(model.prepareFilter == .noCards ? "Every slide has cards." : "No slides match this filter.")
                    .font(Theme.small).foregroundStyle(Theme.quiet).padding(10)
            }
        }
    }

    private var thumbnailWidth: CGFloat {
        switch model.thumbnailSize {
        case .compact: 105
        case .regular: 180
        case .large: .infinity
        }
    }

    // MARK: Focused slide

    @ViewBuilder private var center: some View {
        if let index = model.focusedPageIndex, model.slide(index) != nil,
           model.filteredSlides.contains(where: { $0.pageIndex == index }) {
            let page = index + 1
            VStack(alignment: .leading, spacing: 8) {
                if let landed = model.landedGenerate { LandingBanner(model: model, job: landed) }
                ForEach(Array(model.lecture.skippedSlides.filter { $0.slide == page }.suffix(1).enumerated()), id: \.offset) { _, skipped in
                    Label("AI skipped this slide: \(skipped.reason)", systemImage: "arrow.uturn.right")
                        .font(Theme.small).foregroundStyle(Theme.amber)
                }
                ZoomableSlideView(sourceURL: sourceURL, pageIndex: index)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)
                if model.notesVisible { notes(index: index, page: page) }
            }
            .padding(8)
        } else {
            VStack(spacing: 8) {
                Text(model.lecture.pageCount == 0 ? "This lecture has no slides." : model.filteredSlides.isEmpty ? "No slides match this filter." : "Choose a slide on the left.")
                    .font(Theme.body).foregroundStyle(Theme.quiet)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func notes(index: Int, page: Int) -> some View {
        TextEditor(text: Binding(get: { model.noteText(for: index) }, set: { model.editNote($0, pageIndex: index) }))
            .font(Theme.body)
            .focused(focus, equals: .note)
            .scrollContentBackground(.hidden)
            .padding(8)
            .frame(height: 58)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(focus.wrappedValue == .note ? Theme.ai : Theme.border))
            .disabled(model.readOnly)
            .overlay(alignment: .topLeading) {
                if model.noteText(for: index).isEmpty && focus.wrappedValue != .note {
                    Text("Note for this slide: what matters, what to skip. Steers card generation.")
                        .font(Theme.body).foregroundStyle(Theme.faint).padding(.horizontal, 13).padding(.vertical, 10)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityLabel("Note for slide \(page)")
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
        let hasThread = model.hasChat(forPage: page)
        let hasNote = !model.noteText(for: slide.pageIndex).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        HStack(alignment: .top, spacing: 6) {
            Text("\(page)").font(Theme.caption).monospacedDigit()
                .foregroundStyle(focused ? Theme.aiStrong : Theme.quiet)
                .fontWeight(focused ? .bold : .regular)
                .frame(minWidth: 15, alignment: .trailing)
            VStack(alignment: .trailing, spacing: 4) {
                SlideImage(sourceURL: sourceURL, pageIndex: slide.pageIndex, width: width, cornerRadius: 6)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(focused ? Theme.ai : Theme.border, lineWidth: focused ? 2.5 : 1)
                    }
                    .opacity(slide.isSelected ? 1 : 0.55)
                HStack(spacing: 5) {
                    if hasThread {
                        Button { model.showChat(forPage: page) } label: { Image(systemName: "bubble.right") }
                            .buttonStyle(.plain).foregroundStyle(Theme.ai)
                            .accessibilityLabel("Show chat about slide \(page)")
                    }
                    if hasNote {
                        Image(systemName: "note.text").foregroundStyle(Theme.quiet)
                            .accessibilityLabel("Has a note")
                    }
                    Spacer(minLength: 0)
                    Button { Task { await model.toggleSelection(slide.pageIndex) } } label: {
                        Image(systemName: slide.isSelected ? "checkmark.square.fill" : "square")
                            .foregroundStyle(slide.isSelected ? Theme.accentText : Theme.faint)
                    }
                    .buttonStyle(.plain).disabled(model.readOnly)
                    .accessibilityLabel(slide.isSelected ? "Deselect slide \(page)" : "Select slide \(page)")
                }
                .font(Theme.caption)
            }
        }
        .padding(7)
        .background(focused ? Theme.aiWash : .clear, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(focused ? Theme.ai : .clear, lineWidth: 1.5))
        .help("Slide \(page) · \(Format.count(coverage, "card"))")
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

struct PrepareCardsPane: View {
    let model: LectureWindowModel
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                let cards = model.cards(from: model.focusedPage ?? 0)
                if cards.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No cards from this slide yet").font(Theme.heading(20))
                        Text("Select the slides you want to learn, then generate cards.").font(Theme.body).foregroundStyle(Theme.quiet)
                    }.padding(12)
                }
                ForEach(cards) { card in
                    Button {
                        model.showCards(fromPage: model.focusedPage ?? 0)
                        model.selectCard(card.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(card.front).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                            Text(card.back).font(Theme.body).foregroundStyle(Theme.quiet).lineLimit(5)
                            HStack(spacing: 5) {
                                Circle().fill(card.verdict.v2Color).frame(width: 7, height: 7)
                                Text("\(card.verdict.v2Title) · card \(model.cardNumbers[card.id] ?? 0)")
                                    .font(Theme.caption).foregroundStyle(Theme.faint)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border))
                    }.buttonStyle(.plain)
                }
            }.padding(14)
        }
    }
}

extension CardVerdict {
    var v2Title: String {
        switch self { case .unreviewed: "To review"; case .good: "Good"; case .bad: "Bad"; case .needsAdjustment: "To review" }
    }
    var v2Color: Color {
        switch self { case .unreviewed: Theme.faint; case .good: Theme.good; case .bad: Theme.bad; case .needsAdjustment: Theme.faint }
    }
}
