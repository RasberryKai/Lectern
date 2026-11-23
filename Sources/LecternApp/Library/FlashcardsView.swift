import LecternCore
import SwiftUI

struct FlashcardsView: View {
    @Environment(AppModel.self) private var model
    @State private var showingOptions = false
    @State private var sessionOptions: StudySessionOptions?

    var body: some View {
        ScrollView {
            let catalog = model.studyCatalog
            let now = model.studyNow
            let plan = catalog.plan(now: now)
            VStack(alignment: .leading, spacing: 16) {
                header(catalog, plan: plan)
                if let error = model.studyError { ErrorBanner(message: error) }
                overallPace(catalog, now: now)
                ForEach(catalog.decks, id: \.module.id) { deck in
                    FlashcardsDeckView(deck: deck, now: now, expandByDefault: deck.module.id == catalog.decks.first?.module.id)
                }
                if catalog.decks.isEmpty {
                    Text("Approve cards in Review first.")
                        .font(Theme.body).foregroundStyle(Theme.quiet)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .panel()
                }
            }
            .padding(.horizontal, 40).padding(.vertical, 36)
            .frame(maxWidth: 1240, alignment: .leading)
        }
    }

    private func header(_ catalog: StudyCatalog, plan: StudyPlan) -> some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                let cards = catalog.decks.reduce(0) { $0 + $1.approvedCount }
                Text("\(Format.count(cards, "card")) · \(Format.count(catalog.decks.count, "module"))").eyebrow()
                Text("Flashcards").font(Theme.heading(56)).tracking(-2.2)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                workload(plan.cards.count)
                exportButton(catalog.decks.map(\.module))
                Button {
                    sessionOptions = catalog.preferences.defaults.session
                    showingOptions = true
                } label: {
                    Image(systemName: "slider.horizontal.3").frame(width: 16, height: 22)
                }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityLabel("Session options")
                .help("Session options")
                .popover(isPresented: $showingOptions, arrowEdge: .bottom) { optionsPopover }
                Button {
                    Task { await model.startStudy(scope: .all) }
                } label: {
                    StudyStartLabel(title: "Study all", count: plan.startingCount)
                }.buttonStyle(PrimaryButtonStyle())
            }.padding(.bottom, 5)
        }
        .frame(minHeight: 104, alignment: .bottomLeading)
        .padding(.bottom, 6)
    }

    private func workload(_ count: Int) -> some View {
        let minutes = max(1, Int((Double(count) * 16 / 60).rounded()))
        return Text(count == 0 ? "0 today" : "\(count) today · about \(minutes) min")
            .font(Theme.small).foregroundStyle(Theme.quiet).monospacedDigit()
            .padding(.trailing, 5)
    }

    @ViewBuilder private func exportButton(_ modules: [Module]) -> some View {
        if modules.count > 1 {
            Menu {
                ForEach(modules) { module in
                    Button("Export \(module.name)") { model.selection = .flashcardExport(module.id) }
                }
            } label: {
                Image(systemName: "square.and.arrow.up").frame(width: 16, height: 22)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Export to Anki")
            .help("Export to Anki (backup)")
        } else if let module = modules.first {
            Button {
                model.selection = .flashcardExport(module.id)
            } label: {
                Image(systemName: "square.and.arrow.up").frame(width: 16, height: 22)
            }
            .buttonStyle(SecondaryButtonStyle())
            .accessibilityLabel("Export to Anki")
            .help("Export to Anki (backup)")
        }
    }

    @ViewBuilder private func overallPace(_ catalog: StudyCatalog, now: Date) -> some View {
        if let cap = catalog.preferences.overallNewLimit {
            let needed = catalog.decks.reduce(0) { $0 + ($1.neededPerDay(now: now) ?? 0) }
            if needed > cap {
                Label("Your overall cap of \(cap) is below the \(needed) a day these exams need.", systemImage: "exclamationmark.triangle")
                    .font(Theme.body).foregroundStyle(Theme.amber)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .panel(padding: 14, fill: Theme.amberWash, stroke: Theme.amber.opacity(0.25))
            }
        }
    }

    private var optionsPopover: some View {
        let defaults = model.studyCatalog.preferences.defaults.session
        let options = sessionOptions ?? defaults
        let plan = model.studyCatalog.plan(options: options, now: model.studyNow)
        return VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text("This session").font(Theme.heading(21)).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Defaults in Settings") {
                    showingOptions = false
                    model.openStudySettings()
                }.buttonStyle(LinkButtonStyle(color: Theme.quiet))
            }
            Divider()
            StudySessionControls(options: Binding(get: { sessionOptions ?? defaults }, set: { sessionOptions = $0 }))
            Divider()
            HStack(spacing: 8) {
                if plan.dueRemaining > 0 {
                    let verb = plan.dueRemaining == 1 ? "stays" : "stay"
                    Text("About \(Format.count(plan.dueRemaining, "due card")) \(verb) for later")
                        .font(Theme.small).foregroundStyle(Theme.amber)
                }
                Spacer(minLength: 0)
                Button("Start · \(plan.startingCount)") {
                    showingOptions = false
                    Task { await model.startStudy(scope: .all, options: options) }
                }.buttonStyle(PrimaryButtonStyle())
            }
        }.padding(20).frame(width: 476)
    }
}

private struct FlashcardsDeckView: View {
    @Environment(AppModel.self) private var model
    let deck: StudyDeck
    let now: Date
    @State private var expanded: Bool
    @State private var selectedLectures: Set<UUID> = []
    @State private var includeFuture = false
    @State private var savingLimit = false

    init(deck: StudyDeck, now: Date, expandByDefault: Bool) {
        self.deck = deck
        self.now = now
        _expanded = State(initialValue: expandByDefault)
    }

    var body: some View {
        let module = deck.module
        let configuration = model.studyCatalog.configuration(moduleID: module.id)
        let plan = model.studyCatalog.plan(scope: .module(module.id), now: now)
        let currentNew = plan.cards.count { $0.memory == nil }
        VStack(spacing: 0) {
            deckHeader(module, plan: plan, new: currentNew)
            Divider()
            paceRow(configuration.newCardLimit)
            if expanded {
                Divider()
                lectureTable(plan: plan)
            }
        }
        .panel(padding: 0)
    }

    private func deckHeader(_ module: Module, plan: StudyPlan, new: Int) -> some View {
        HStack(spacing: 12) {
            Button {
                expanded.toggle()
            } label: {
                Image(systemName: expanded ? "chevron.down" : "chevron.right").frame(width: 20, height: 22)
            }
            .buttonStyle(.plain).foregroundStyle(Theme.quiet)
            .accessibilityLabel(expanded ? "Hide lectures in \(module.name)" : "Show lectures in \(module.name)")
            Button(module.name) { model.selection = .module(module.id) }
                .buttonStyle(.plain).font(Theme.heading(23)).lineLimit(1)
            Text(Format.examLine(module.examDate, now: now))
                .font(Theme.small).foregroundStyle(Theme.quiet).lineLimit(1)
            Spacer(minLength: 2)
            Text("\(plan.dueCount) due · \(new) new")
                .font(Theme.body.monospacedDigit()).foregroundStyle(Theme.quiet).fixedSize()
            if plan.startingCount > 0 {
                Button("Study \(plan.startingCount)") {
                    Task { await model.startStudy(scope: .module(module.id)) }
                }.buttonStyle(SecondaryButtonStyle())
            } else if deck.approvedCount == 0 {
                Text("No approved cards").font(Theme.small).foregroundStyle(Theme.quiet)
            } else if plan.dueCount == 0 {
                Text("Done today").font(Theme.small).foregroundStyle(Theme.quiet)
            }
        }.padding(.horizontal, 19).padding(.vertical, 13)
    }

    private func paceRow(_ limit: Int) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) {
                seenMeter.frame(minWidth: 120, maxWidth: .infinity)
                capStepper(limit)
                paceLabel(limit).frame(minWidth: 204, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    seenMeter.frame(maxWidth: 260)
                    Spacer(minLength: 8)
                    capStepper(limit)
                }
                paceLabel(limit)
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 10)
    }

    private var seenMeter: some View {
        StudyProgressMeter(value: deck.seenCount, total: deck.approvedCount, unit: "seen", tint: Theme.good)
    }

    private func capStepper(_ limit: Int) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .trailing, spacing: 3) {
                Text("New a day").font(Theme.small).foregroundStyle(Theme.quiet)
                let isOverride = deck.overrides.newCardLimit != nil
                Text(isOverride ? "Module override" : "App default")
                    .font(Theme.caption).foregroundStyle(isOverride ? Theme.accentText : Theme.quiet)
            }
            HStack(spacing: 0) {
                Button { saveLimit(limit - 1) } label: {
                    Image(systemName: "minus").frame(width: 27, height: 27)
                }.buttonStyle(.plain).disabled(limit == 0 || savingLimit)
                    .accessibilityLabel("Fewer new cards a day")
                Rectangle().fill(Theme.border).frame(width: 1, height: 27)
                Text(limit.formatted()).font(Theme.small.weight(.semibold)).monospacedDigit()
                    .padding(.horizontal, 5).frame(minWidth: 34)
                    .accessibilityLabel("\(limit) new cards a day")
                Rectangle().fill(Theme.border).frame(width: 1, height: 27)
                Button { saveLimit(limit + 1) } label: {
                    Image(systemName: "plus").frame(width: 27, height: 27)
                }.buttonStyle(.plain).disabled(limit == .max || savingLimit)
                    .accessibilityLabel("More new cards a day")
            }
            .font(Theme.small)
            .background(Theme.inset, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.borderStrong).allowsHitTesting(false))
        }.fixedSize()
    }

    @ViewBuilder private func paceLabel(_ limit: Int) -> some View {
        if deck.approvedCount > 0 && deck.seenCount == deck.approvedCount {
            Text("Every card seen").font(Theme.small).foregroundStyle(Theme.good)
        } else if let exam = deck.module.examDate, let needed = deck.neededPerDay(now: now), needed > 0 {
            let examDay = exam.date()
            let completion = completionDate(limit: limit)
            if completion == nil || completion.map({ Calendar.current.startOfDay(for: $0) > examDay }) == true {
                let target = limitToFinish(by: exam)
                HStack(spacing: 8) {
                    Text("Needs \(needed) a day by \(Format.dayMonth(exam.date()))")
                        .font(Theme.small.weight(.semibold)).foregroundStyle(Theme.amber)
                    Button("Set to \(target)") { saveLimit(target) }
                        .buttonStyle(LinkButtonStyle(color: Theme.amber)).disabled(savingLimit).fixedSize()
                }
            } else if let date = completion {
                Text("Needs \(needed) a day · every card seen by \(Format.dayMonth(date))")
                    .font(Theme.small).foregroundStyle(Theme.good)
            }
        } else if deck.module.examDate == nil {
            Text("Set an exam date to see the pace you need").font(Theme.small).foregroundStyle(Theme.quiet)
        }
    }

    private func limitToFinish(by exam: ExamDate) -> Int {
        let unseen = deck.approvedCount - deck.seenCount
        let laterDays = max(0, exam.daysRemaining(from: now))
        let spentToday = deck.introducedToday
        if laterDays > 0 {
            let limitWithoutToday = ceil(Double(unseen) / Double(laterDays))
            if limitWithoutToday <= Double(spentToday) { return Int(limitWithoutToday) }
        }
        return Int(ceil((Double(unseen) + Double(spentToday)) / Double(laterDays + 1)))
    }

    private func completionDate(limit: Int) -> Date? {
        guard limit > 0 else { return nil }
        let unseen = deck.approvedCount - deck.seenCount
        let availableToday = max(0, limit - deck.introducedToday)
        let later = max(0, unseen - availableToday)
        let (days, remainder) = later.quotientAndRemainder(dividingBy: limit)
        return Calendar.current.date(byAdding: .day, value: days + (remainder == 0 ? 0 : 1), to: now)
    }

    private func saveLimit(_ limit: Int) {
        guard !savingLimit else { return }
        savingLimit = true
        Task {
            await model.setStudyNewCardLimit(moduleID: deck.module.id, limit: limit)
            savingLimit = false
        }
    }

    @ViewBuilder private func lectureTable(plan: StudyPlan) -> some View {
        let assets = Dictionary(grouping: deck.approvedCards, by: \.lectureID)
        let lectures = deck.lectures.filter { assets[$0.id] != nil }
        let newByLecture = Dictionary(grouping: plan.cards.filter { $0.memory == nil }, by: \.lectureID)
        if lectures.isEmpty {
            Text("Approve cards in Review first.").font(Theme.small).foregroundStyle(Theme.quiet)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22).padding(.vertical, 13)
        } else {
            HStack(spacing: 13) {
                Color.clear.frame(width: 18, height: 1).accessibilityHidden(true)
                Text("Lecture").frame(maxWidth: .infinity, alignment: .leading)
                Text("Cards").frame(width: 48, alignment: .trailing)
                Text("Seen").frame(width: 90, alignment: .trailing)
                Text("Due today").frame(width: 77, alignment: .trailing)
                Text("New").frame(width: 48, alignment: .trailing)
            }.eyebrow().padding(.horizontal, 22).padding(.vertical, 9)
            ForEach(lectures) { lecture in
                Divider()
                lectureRow(lecture, cards: assets[lecture.id, default: []], new: newByLecture[lecture.id]?.count ?? 0)
            }
            let selected = lectures.filter { selectedLectures.contains($0.id) }
            if !selected.isEmpty {
                Divider()
                selectedBar(selected)
            }
        }
    }

    private func lectureRow(_ lecture: Lecture, cards: [StudyCard], new: Int) -> some View {
        let seen = cards.count { $0.memory != nil }
        let due = cards.count { ($0.memory?.due ?? .distantFuture) <= now }
        let checked = selectedLectures.contains(lecture.id)
        let title = lectureTitle(lecture)
        return Button {
            if checked { selectedLectures.remove(lecture.id) }
            else { selectedLectures.insert(lecture.id) }
        } label: {
            HStack(spacing: 13) {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(checked ? Theme.accentText : Theme.faint)
                    .frame(width: 18)
                Text(title).font(Theme.body.weight(.medium)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(cards.count.formatted()).frame(width: 48, alignment: .trailing)
                HStack(spacing: 5) {
                    ProgressView(value: Double(seen), total: Double(max(1, cards.count)))
                        .progressViewStyle(.linear).tint(Theme.good).accessibilityHidden(true)
                    Text(seen.formatted())
                }.frame(width: 90, alignment: .trailing)
                Text(due.formatted()).frame(width: 77, alignment: .trailing)
                Text(new.formatted()).frame(width: 48, alignment: .trailing)
            }
            .font(Theme.small.monospacedDigit()).foregroundStyle(Theme.ink)
            .padding(.horizontal, 22).padding(.vertical, 10)
            .background(checked ? Theme.goodWash : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue("\(Format.count(cards.count, "card")), \(seen) seen, \(due) due, \(new) new")
        .accessibilityAddTraits(checked ? .isSelected : [])
    }

    private func lectureTitle(_ lecture: Lecture) -> String {
        guard let slot = deck.module.lectureSlots[lecture.id] else { return lecture.name }
        return Format.lectureTitle(index: slot - 1, name: lecture.name)
    }

    private func selectedBar(_ selected: [Lecture]) -> some View {
        let scope = StudyScope.lectures(moduleID: deck.module.id, lectureIDs: Set(selected.map(\.id)))
        let plan = model.studyCatalog.plan(scope: scope, includeFuture: includeFuture, now: now)
        return HStack(spacing: 12) {
            Text(selected.count == 1 ? lectureTitle(selected[0]) : Format.count(selected.count, "lecture"))
                .font(Theme.body.weight(.semibold)).lineLimit(1)
            Toggle("Also cards not due yet", isOn: $includeFuture)
                .toggleStyle(.checkbox).font(Theme.small)
            Spacer(minLength: 0)
            Button("Clear") { selectedLectures.removeAll(); includeFuture = false }
                .buttonStyle(LinkButtonStyle(color: Theme.quiet))
            Button("Study \(Format.count(plan.startingCount, "card"))") {
                let early = includeFuture
                Task { await model.startStudy(scope: scope, includeFuture: early) }
            }
            .buttonStyle(PrimaryButtonStyle()).disabled(plan.startingCount == 0)
        }
        .padding(.horizontal, 22).padding(.vertical, 10)
        .background(Theme.goodWash, in: .rect(bottomLeadingRadius: 12, bottomTrailingRadius: 12))
    }
}

struct StudyStartLabel: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
            Text(count.formatted()).font(Theme.small.weight(.semibold)).monospacedDigit()
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(.white.opacity(0.17), in: RoundedRectangle(cornerRadius: 5))
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title), \(Format.count(count, "card"))")
    }
}

struct StudyProgressMeter: View {
    let value: Int
    let total: Int
    let unit: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ProgressView(value: Double(value), total: Double(max(1, total)))
                .progressViewStyle(.linear).tint(tint).accessibilityHidden(true)
            Text("\(value) of \(total) \(unit)")
                .font(Theme.small).monospacedDigit().foregroundStyle(Theme.quiet)
        }
    }
}
