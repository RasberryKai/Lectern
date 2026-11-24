import LecternCore
import SwiftUI

struct FlashcardsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("lectern.flashcards.expandedModules") private var savedExpandedModules = ""
    @State private var showingOptions = false
    @State private var sessionOptions: StudySessionOptions?

    private var expandedModules: Set<UUID> {
        Set(savedExpandedModules.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
    }

    var body: some View {
        ScrollView {
            let catalog = model.studyCatalog
            let now = model.studyNow
            let plan = catalog.plan(shuffleSeed: model.studyShuffleSeed, now: now)
            let expanded = expandedModules
            VStack(alignment: .leading, spacing: 16) {
                header(catalog, plan: plan)
                if let error = model.studyError { ErrorBanner(message: error) }
                overallPace(catalog, now: now)
                ForEach(catalog.decks, id: \.module.id) { deck in
                    FlashcardsDeckView(deck: deck, now: now, isExpanded: expanded.contains(deck.id)) {
                        toggleExpansion(deck.id)
                    }
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

    private func toggleExpansion(_ moduleID: UUID) {
        var expanded = expandedModules
        if expanded.remove(moduleID) == nil { expanded.insert(moduleID) }
        savedExpandedModules = expanded.map(\.uuidString).sorted().joined(separator: ",")
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
        let plan = model.studyCatalog.plan(options: options, shuffleSeed: model.studyShuffleSeed, now: model.studyNow)
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
    let isExpanded: Bool
    let toggleExpansion: () -> Void
    @State private var selectedLectures: Set<UUID> = []
    @State private var includeFuture = false

    private let progressWidth: CGFloat = 130
    private let todayWidth: CGFloat = 145

    var body: some View {
        let module = deck.module
        let plan = model.studyCatalog.plan(scope: .module(module.id), shuffleSeed: model.studyShuffleSeed, now: now)
        let limit = model.studyCatalog.configuration(moduleID: module.id).newCardLimit
        let currentNew = plan.cards.count { $0.memory == nil }
        VStack(spacing: 0) {
            deckHeader(module, plan: plan, new: currentNew)
            if isExpanded {
                Divider()
                if plan.approvedCount > 0 {
                    paceRow(total: plan.approvedCount, limit: limit)
                    Divider()
                    lectureTable(plan: plan)
                } else {
                    HStack {
                        Text("Approve cards in Review first.").font(Theme.small).foregroundStyle(Theme.quiet)
                        Spacer()
                        dailyLimitButton(limit)
                        openModuleButton
                    }
                    .padding(.horizontal, 22).padding(.vertical, 13)
                }
            }
        }
        .panel(padding: 0)
    }

    private func deckHeader(_ module: Module, plan: StudyPlan, new: Int) -> some View {
        HStack(spacing: 12) {
            Button(action: toggleExpansion) {
                HStack(spacing: 10) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.quiet)
                        .frame(width: 30, height: 30)
                        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 7))
                        .accessibilityHidden(true)
                    Text(module.name).font(Theme.heading(23)).lineLimit(1)
                    Text(Format.examLine(module.examDate, now: now))
                        .font(Theme.small).foregroundStyle(Theme.quiet).fixedSize()
                }
                .padding(.leading, 18)
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Hide lectures in \(module.name)" : "Show lectures in \(module.name)")
            .accessibilityValue(Format.examLine(module.examDate, now: now))
            if let workload = studyCounts(due: plan.dueCount, new: new) {
                Text(workload).font(Theme.body.monospacedDigit()).foregroundStyle(Theme.quiet).fixedSize()
            }
            if plan.startingCount > 0 {
                Button("Study \(plan.startingCount)") {
                    Task { await model.startStudy(scope: .module(module.id)) }
                }.buttonStyle(SecondaryButtonStyle())
            } else if plan.approvedCount == 0 {
                Text("No approved cards").font(Theme.small).foregroundStyle(Theme.quiet)
            } else if plan.dueCount == 0 {
                Text("Done today").font(Theme.small).foregroundStyle(Theme.quiet)
            }
        }.padding(.trailing, 19)
    }

    private func paceRow(total: Int, limit: Int) -> some View {
        let seen = deck.seenCount
        return HStack(spacing: 20) {
            StudyProgressMeter(value: seen, total: total, unit: "seen", tint: Theme.good)
                .frame(minWidth: 120, maxWidth: .infinity)
            paceLabel(unseen: total - seen, limit: limit)
            dailyLimitButton(limit)
            openModuleButton
        }
        .padding(.horizontal, 22).padding(.vertical, 10)
    }

    private func dailyLimitButton(_ limit: Int) -> some View {
        Button("\(limit.formatted()) new cards/day") {
            model.showModuleStudySettingsOnOpen = true
            model.settingsModuleID = deck.id
        }
        .buttonStyle(LinkButtonStyle(color: Theme.quiet))
        .accessibilityHint("Opens study settings for this module")
        .fixedSize()
    }

    private var openModuleButton: some View {
        Button("Open module") { model.selection = .module(deck.id) }
            .buttonStyle(LinkButtonStyle(color: Theme.quiet)).fixedSize()
    }

    @ViewBuilder private func paceLabel(unseen: Int, limit: Int) -> some View {
        if unseen == 0 {
            Text("Every card seen").font(Theme.small).foregroundStyle(Theme.good)
        } else if let exam = deck.module.examDate, let needed = deck.neededPerDay(now: now), needed > 0 {
            if let date = completionDate(unseen: unseen, limit: limit), Calendar.current.startOfDay(for: date) <= exam.date() {
                Text("Needs \(needed) a day · every card seen by \(Format.dayMonth(date))")
                    .font(Theme.small).foregroundStyle(Theme.good)
            } else {
                Text("Needs \(needed) a day by \(Format.dayMonth(exam.date()))")
                    .font(Theme.small.weight(.semibold)).foregroundStyle(Theme.amber)
            }
        } else if deck.module.examDate == nil {
            Text("Set an exam date to see the pace you need").font(Theme.small).foregroundStyle(Theme.quiet)
        }
    }

    private func completionDate(unseen: Int, limit: Int) -> Date? {
        guard limit > 0 else { return nil }
        let availableToday = max(0, limit - deck.introducedToday)
        let later = max(0, unseen - availableToday)
        let (days, remainder) = later.quotientAndRemainder(dividingBy: limit)
        return Calendar.current.date(byAdding: .day, value: days + (remainder == 0 ? 0 : 1), to: now)
    }

    private func studyCounts(due: Int, new: Int) -> String? {
        let counts = [due > 0 ? "\(due.formatted()) due" : nil, new > 0 ? "\(new.formatted()) new" : nil]
            .compactMap { $0 }
        return counts.isEmpty ? nil : counts.joined(separator: " · ")
    }

    @ViewBuilder private func lectureTable(plan: StudyPlan) -> some View {
        let assets = Dictionary(grouping: deck.approvedCards, by: \.lectureID)
        let lectures = deck.lectures.filter { assets[$0.id] != nil }
        let newByLecture = Dictionary(grouping: plan.cards.filter { $0.memory == nil }, by: \.lectureID)
        HStack(spacing: 13) {
            Color.clear.frame(width: 18, height: 1).accessibilityHidden(true)
            Text("Lecture").frame(maxWidth: .infinity, alignment: .leading)
            Text("Progress").frame(width: progressWidth, alignment: .leading)
            Text("Today").frame(width: todayWidth, alignment: .leading)
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

    private func lectureRow(_ lecture: Lecture, cards: [StudyCard], new: Int) -> some View {
        let seen = cards.count { $0.memory != nil }
        let due = cards.count { $0.memory.map { $0.due <= now } ?? false }
        let workload = studyCounts(due: due, new: new)
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
                Text("\(seen.formatted()) of \(cards.count.formatted()) seen")
                    .foregroundStyle(Theme.quiet)
                    .frame(width: progressWidth, alignment: .leading)
                Text(workload ?? "—")
                    .fontWeight(workload == nil ? .regular : .medium)
                    .foregroundStyle(workload == nil ? Theme.quiet : Theme.ink)
                    .frame(width: todayWidth, alignment: .leading)
            }
            .font(Theme.small.monospacedDigit()).foregroundStyle(Theme.ink)
            .padding(.horizontal, 22).padding(.vertical, 10)
            .background(checked ? Theme.goodWash : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue("\(seen) of \(cards.count) cards seen. \(workload ?? "No cards queued today")")
        .accessibilityAddTraits(checked ? .isSelected : [])
    }

    private func lectureTitle(_ lecture: Lecture) -> String {
        guard let slot = deck.module.lectureSlots[lecture.id] else { return lecture.name }
        return Format.lectureTitle(index: slot - 1, name: lecture.name)
    }

    private func selectedBar(_ selected: [Lecture]) -> some View {
        let scope = StudyScope.lectures(moduleID: deck.module.id, lectureIDs: Set(selected.map(\.id)))
        let plan = model.studyCatalog.plan(scope: scope, includeFuture: includeFuture,
                                          shuffleSeed: model.studyShuffleSeed, now: now)
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
