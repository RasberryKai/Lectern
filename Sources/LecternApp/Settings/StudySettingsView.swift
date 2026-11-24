import LecternCore
import SwiftUI

struct StudySettingsTab: View {
    @Environment(AppModel.self) private var model
    @State private var draft = StudyPreferences()
    @State private var saved = StudyPreferences()
    @State private var applying = false
    @State private var loaded = false
    @State private var timingChanged = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Study").settingsHeading()
                    Spacer()
                    Button("Save changes") { Task { await save() } }
                        .buttonStyle(PrimaryButtonStyle()).disabled(draft == saved)
                }
                if let error { ErrorBanner(message: error) }
                studyBlock("Daily workload") {
                    studyRow("New cards per module per day") {
                        StudyNumber(value: $draft.defaults.newCardLimit, range: 0...Int.max, unit: "cards", label: "New cards per module per day")
                    }
                    Divider()
                    studyRow("Overall new cards per day") {
                        HStack {
                            Picker("Overall new cards per day", selection: Binding(
                                get: { draft.overallNewLimit != nil },
                                set: { draft.overallNewLimit = $0 ? draft.overallNewLimit ?? 20 : nil }
                            )) {
                                Text("Off").tag(false)
                                Text("Limit").tag(true)
                            }.labelsHidden().pickerStyle(.segmented).fixedSize()
                            if draft.overallNewLimit != nil {
                                StudyNumber(value: Binding(
                                    get: { draft.overallNewLimit ?? 0 },
                                    set: { draft.overallNewLimit = $0 }
                                ), range: 0...Int.max, unit: "cards", label: "Overall new-card limit")
                            }
                        }
                    }
                }
                studyBlock("Timing") {
                    retention($draft.defaults.desiredRetention)
                    Divider()
                    firstCorrect("First correct answer, flip card", $draft.defaults.flipFirstCorrect)
                    Divider()
                    firstCorrect("First correct answer, solve card", $draft.defaults.solveFirstCorrect)
                    Divider()
                    retryPicker($draft.defaults.retryAfterMiss)
                    Divider()
                    retryMinutes("Retry delay, new card", $draft.defaults.newRetryMinutes)
                    Divider()
                    retryMinutes("Retry delay, established card", $draft.defaults.establishedRetryMinutes)
                    timingFlow(draft.defaults)
                }
                studyBlock("Session defaults") {
                    StudySessionControls(options: $draft.defaults.session)
                }
                studyBlock("Advanced") {
                    studyRow("Maximum review interval") { maximumInterval($draft.defaults.maximumInterval) }
                    Divider()
                    studyRow("Spread review dates") {
                        Toggle("Spread review dates", isOn: $draft.defaults.spreadReviewDates).labelsHidden().toggleStyle(.switch)
                    }
                    Divider()
                    studyRow("FSRS weights", detail: "Standard FSRS-6 weights") {
                        EmptyView()
                    }
                    Divider()
                    StudyRescheduleControls(moduleID: nil, recordCount: model.studyCatalog.decks.reduce(0) { $0 + $1.seenCount },
                                            settingsChanged: timingChanged || !sameSchedule(draft.defaults, saved.defaults),
                                            hasUnsavedSettings: draft != saved)
                }
            }
            .disabled(!loaded || applying)
            .padding(.horizontal, 40).padding(.vertical, 32)
            .frame(maxWidth: 960, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task {
            guard !loaded else { return }
            do {
                saved = try await model.store.studyPreferences()
                draft = saved
                loaded = true
            } catch { self.error = error.localizedDescription }
        }
    }

    private func save() async {
        applying = true
        defer { applying = false }
        do {
            try await model.store.saveStudyPreferences(draft)
            timingChanged = timingChanged || !sameSchedule(draft.defaults, saved.defaults)
            saved = draft
            error = nil
            await model.refreshStudy()
        } catch { self.error = error.localizedDescription }
    }
}

struct ModuleStudySettings: View {
    @Environment(AppModel.self) private var model
    let moduleID: UUID
    let archived: Bool
    @Binding var draft: StudyOverrides
    @Binding var saved: StudyOverrides
    @State private var applying = false
    @State private var timingChanged = false
    @State private var error: String?

    private var defaults: StudyConfiguration { model.studyCatalog.preferences.defaults }
    private var effective: StudyConfiguration { draft.applying(to: defaults) }

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            if archived { Text("Unarchive this module to change its study settings.").font(Theme.small).foregroundStyle(Theme.quiet) }
            if let error { ErrorBanner(message: error) }
            studyBlock("Daily workload") {
                override("New cards per day", \.newCardLimit, default: defaults.newCardLimit, describe: { "\($0) cards" }) {
                    StudyNumber(value: $0, range: 0...Int.max, unit: "cards", label: "New cards per day")
                }
            }
            studyBlock("Timing") {
                override("Desired retention", \.desiredRetention, default: defaults.desiredRetention, describe: { "\($0)%" }) {
                    StudyNumber(value: $0, range: 80...97, unit: "%", label: "Desired retention")
                }
                Divider()
                override("First correct answer, flip card", \.flipFirstCorrect, default: defaults.flipFirstCorrect, describe: firstCorrectDescription) {
                    firstCorrectControl($0, label: "First correct answer, flip card")
                }
                Divider()
                override("First correct answer, solve card", \.solveFirstCorrect, default: defaults.solveFirstCorrect, describe: firstCorrectDescription) {
                    firstCorrectControl($0, label: "First correct answer, solve card")
                }
                Divider()
                override("Retry after a miss", \.retryAfterMiss, default: defaults.retryAfterMiss,
                         describe: { $0 ? "At end of session" : "Wait until due" }, control: retryControl)
                Divider()
                override("Retry delay, new card", \.newRetryMinutes, default: defaults.newRetryMinutes, describe: { "\($0) min" }) {
                    StudyNumber(value: $0, range: 1...60, unit: "min", label: "Retry delay, new card")
                }
                Divider()
                override("Retry delay, established card", \.establishedRetryMinutes, default: defaults.establishedRetryMinutes, describe: { "\($0) min" }) {
                    StudyNumber(value: $0, range: 1...60, unit: "min", label: "Retry delay, established card")
                }
                timingFlow(effective)
            }
            studyBlock("Session defaults") {
                override("Card types", \.cardTypes, default: defaults.session.cardTypes, describe: \.title, control: cardTypes)
                Divider()
                override("Queue order", \.queueOrder, default: defaults.session.queueOrder, describe: \.title, control: queueOrder)
                Divider()
                override("New card order", \.newCardOrder, default: defaults.session.newCardOrder, describe: \.title, control: newCardOrder)
                Divider()
                override("Space related cards apart", \.spaceRelatedCards, default: defaults.session.spaceRelatedCards,
                         describe: { $0 ? "On" : "Off" }, help: relatedCardsSpacingHelp, control: relatedCardsSpacingToggle)
                Divider()
                override("Stop after", \.stop, default: defaults.session.stop, describe: \.summary, control: stopControl)
            }
            studyBlock("Advanced") {
                override("Maximum review interval", \.maximumInterval, default: defaults.maximumInterval, describe: \.summary, control: maximumInterval)
                Divider()
                override("Spread review dates", \.spreadReviewDates, default: defaults.spreadReviewDates, describe: { $0 ? "On" : "Off" }) {
                    Toggle("Spread review dates", isOn: $0).labelsHidden().toggleStyle(.switch)
                }
                Divider()
                StudyRescheduleControls(moduleID: moduleID, recordCount: model.studyCatalog.decks.first { $0.id == moduleID }?.seenCount ?? 0,
                                        settingsChanged: timingChanged || !sameSchedule(effective, saved.applying(to: defaults)),
                                        hasUnsavedSettings: draft != saved)
            }
            if !archived {
                HStack {
                    Spacer()
                    Button("Save study settings") { Task { await save() } }
                        .buttonStyle(PrimaryButtonStyle()).disabled(draft == saved)
                }
            }
        }
        .disabled(archived || applying)
    }

    private func override<Value: Sendable, Control: View>(
        _ name: String, _ key: WritableKeyPath<StudyOverrides, Value?>, default inherited: Value,
        describe: (Value) -> String, help: String? = nil, @ViewBuilder control: (Binding<Value>) -> Control
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    studySettingLabel(name, help: help)
                    Text(describe(draft[keyPath: key] ?? inherited)).font(Theme.small).foregroundStyle(Theme.quiet)
                }
                Spacer()
                Picker(name, selection: Binding(
                    get: { draft[keyPath: key] != nil },
                    set: { draft[keyPath: key] = $0 ? (draft[keyPath: key] ?? inherited) : nil }
                )) {
                    Text("App default").tag(false)
                    Text("Override").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            if draft[keyPath: key] != nil {
                HStack {
                    Spacer(minLength: 0)
                    control(Binding(get: { draft[keyPath: key] ?? inherited }, set: { draft[keyPath: key] = $0 }))
                }
            }
        }
    }

    private func save() async {
        applying = true
        defer { applying = false }
        do {
            try await model.store.saveStudyOverrides(moduleID: moduleID, draft)
            timingChanged = timingChanged || !sameSchedule(effective, saved.applying(to: defaults))
            saved = draft
            error = nil
            await model.refreshStudy()
        } catch { self.error = error.localizedDescription }
    }
}

struct StudySessionControls: View {
    @Binding var options: StudySessionOptions

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            studyRow("Card types") { cardTypes($options.cardTypes) }
            Divider()
            studyRow("Queue order") { queueOrder($options.queueOrder) }
            Divider()
            studyRow("New card order") { newCardOrder($options.newCardOrder) }
            Divider()
            studyRow("Space related cards apart", help: relatedCardsSpacingHelp) {
                relatedCardsSpacingToggle($options.spaceRelatedCards)
            }
            Divider()
            studyRow("Stop after") { stopControl($options.stop) }
        }
    }
}

private struct StudyRescheduleControls: View {
    @Environment(AppModel.self) private var model
    let moduleID: UUID?
    let recordCount: Int
    let settingsChanged: Bool
    let hasUnsavedSettings: Bool
    @State private var preview: StudyReschedulePreview?
    @State private var showingPreview = false
    @State private var busy = false
    @State private var status: String?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if settingsChanged {
                Label("Applies from the next grade", systemImage: "clock")
                    .font(Theme.small.weight(.semibold)).foregroundStyle(Theme.amber)
            }
            studyRow("Reschedule existing cards", detail: hasUnsavedSettings ? "Save changes to preview updated due dates." : nil) {
                Button(settingsChanged && recordCount > 0 ? "Reschedule \(recordCount) cards…" : "Preview…") {
                    Task { await loadPreview() }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(busy || hasUnsavedSettings || recordCount == 0)
            }
            if let status { Text(status).font(Theme.small).foregroundStyle(Theme.quiet) }
            if let failure { ErrorBanner(message: failure) }
        }
        .sheet(isPresented: $showingPreview) {
            if let preview {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Reschedule existing cards").font(Theme.heading(24))
                    Text(preview.count == 0 ? "All due dates already match these settings."
                         : "This will update the due dates of \(Format.count(preview.count, "card")).")
                    if let failure { ErrorBanner(message: failure) }
                    HStack {
                        Spacer()
                        Button(preview.count == 0 ? "Close" : "Cancel") { showingPreview = false }
                            .keyboardShortcut(.cancelAction)
                        if preview.count > 0 {
                            Button("Reschedule") { Task { await apply(preview) } }
                                .buttonStyle(PrimaryButtonStyle()).disabled(busy)
                        }
                    }
                }
                .padding(25).frame(width: 440)
                .interactiveDismissDisabled(busy)
            }
        }
    }

    private func loadPreview() async {
        busy = true
        defer { busy = false }
        do {
            preview = try await model.store.previewStudyReschedule(moduleID: moduleID)
            failure = nil
            showingPreview = true
        } catch { failure = error.localizedDescription }
    }

    private func apply(_ preview: StudyReschedulePreview) async {
        busy = true
        defer { busy = false }
        do {
            try await model.store.applyStudyReschedule(preview)
            await model.refreshStudy()
            status = "Updated \(Format.count(preview.count, "due date"))."
            showingPreview = false
        } catch {
            showingPreview = false
            failure = error.localizedDescription
        }
    }
}

private struct StudyNumber: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let unit: String
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            TextField(label, value: $value, format: .number)
                .labelsHidden().multilineTextAlignment(.trailing)
                .monospacedDigit().frame(width: 62)
                .onChange(of: value) { _, updated in value = min(max(updated, range.lowerBound), range.upperBound) }
            Text(unit).font(Theme.small).foregroundStyle(Theme.quiet)
            Stepper(label, onIncrement: {
                if value < range.upperBound { value += 1 }
            }, onDecrement: {
                if value > range.lowerBound { value -= 1 }
            })
            .labelsHidden()
        }
        .fixedSize()
    }
}

private func studyBlock<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 12) {
        Text(title).font(Theme.heading(20)).accessibilityAddTraits(.isHeader)
        content()
    }.frame(maxWidth: .infinity, alignment: .leading).panel(padding: 16)
}

private func studyRow<Control: View>(
    _ title: String, detail: String? = nil, help: String? = nil, @ViewBuilder control: () -> Control
) -> some View {
    let label = VStack(alignment: .leading, spacing: 3) {
        studySettingLabel(title, help: help)
        if let detail { Text(detail).font(Theme.small).foregroundStyle(Theme.quiet) }
    }
    return ViewThatFits(in: .horizontal) {
        HStack(spacing: 16) { label; Spacer(minLength: 12); control() }
        VStack(alignment: .leading, spacing: 8) { label; control() }
    }
}

@ViewBuilder
private func studySettingLabel(_ title: String, help: String?) -> some View {
    let label = Text(title).font(Theme.body.weight(.semibold))
    if let help {
        label.help(help)
    } else {
        label
    }
}

private func retention(_ value: Binding<Int>) -> some View {
    studyRow("Desired retention", detail: "80–97%") {
        StudyNumber(value: value, range: 80...97, unit: "%", label: "Desired retention")
    }
}

private func firstCorrect(_ label: String, _ value: Binding<StudyFirstCorrect>) -> some View {
    studyRow(label) { firstCorrectControl(value, label: label) }
}

private func firstCorrectControl(_ value: Binding<StudyFirstCorrect>, label: String) -> some View {
    let minutes = Binding<Int?>(get: {
        if case .repeatAfter(let value) = value.wrappedValue { return value }
        return nil
    }, set: { value.wrappedValue = $0.map(StudyFirstCorrect.repeatAfter) ?? .startSpacedReviews })
    return HStack(spacing: 8) {
        Picker(label, selection: Binding(get: { minutes.wrappedValue != nil }, set: { minutes.wrappedValue = $0 ? 10 : nil })) {
            Text("Start spaced reviews").tag(false)
            Text("Repeat after").tag(true)
        }.labelsHidden().fixedSize()
        if minutes.wrappedValue != nil {
            StudyNumber(value: Binding(get: { minutes.wrappedValue ?? 10 }, set: { minutes.wrappedValue = $0 }),
                        range: 1...60, unit: "min", label: "Repeat after minutes")
        }
    }
}

private func firstCorrectDescription(_ value: StudyFirstCorrect) -> String {
    switch value {
    case .startSpacedReviews: "Start spaced reviews"
    case .repeatAfter(let minutes): "Repeat after \(minutes) min"
    }
}

private func retryPicker(_ retry: Binding<Bool>) -> some View {
    studyRow("Retry after a miss") { retryControl(retry) }
}

private func retryControl(_ retry: Binding<Bool>) -> some View {
    Picker("Retry after a miss", selection: retry) {
        Text("At end of session").tag(true)
        Text("Wait until due").tag(false)
    }.labelsHidden().fixedSize()
}

private func retryMinutes(_ title: String, _ value: Binding<Int>) -> some View {
    studyRow(title) { StudyNumber(value: value, range: 1...60, unit: "min", label: title) }
}

private func cardTypes(_ value: Binding<StudyCardTypes>) -> some View {
    Picker("Card types", selection: value) {
        ForEach(StudyCardTypes.allCases, id: \.self) { Text($0.title).tag($0) }
    }.pickerStyle(.segmented).labelsHidden().fixedSize()
}

private func queueOrder(_ value: Binding<StudyQueueOrder>) -> some View {
    Picker("Queue order", selection: value) {
        ForEach(StudyQueueOrder.allCases, id: \.self) { Text($0.title).tag($0) }
    }.pickerStyle(.segmented).labelsHidden().fixedSize()
}

private func newCardOrder(_ value: Binding<StudyNewCardOrder>) -> some View {
    Picker("New card order", selection: value) {
        ForEach(StudyNewCardOrder.allCases, id: \.self) { Text($0.title).tag($0) }
    }.pickerStyle(.menu).labelsHidden().fixedSize()
}

private let relatedCardsSpacingHelp = "Tries to put another card between cards from the same slide or split from the same original card. For new cards shuffled within each lecture, spacing stays within that lecture."

private func relatedCardsSpacingToggle(_ value: Binding<Bool>) -> some View {
    Toggle("Space related cards apart", isOn: value)
        .labelsHidden().toggleStyle(.switch)
        .help(relatedCardsSpacingHelp)
        .accessibilityHint(relatedCardsSpacingHelp)
}

private func stopControl(_ value: Binding<StudyStop>) -> some View {
    let kind = Binding<Int>(
        get: {
            switch value.wrappedValue {
            case .complete: 0
            case .cards: 1
            case .minutes: 2
            }
        },
        set: { kind in
            switch kind {
            case 1: value.wrappedValue = .cards(25)
            case 2: value.wrappedValue = .minutes(15)
            default: value.wrappedValue = .complete
            }
        }
    )
    return HStack(spacing: 8) {
        Picker("Stop after", selection: kind) {
            Text("Queue is complete").tag(0)
            Text("Cards").tag(1)
            Text("Minutes").tag(2)
        }.labelsHidden().fixedSize()
        if kind.wrappedValue != 0 {
            StudyNumber(value: Binding(get: {
                switch value.wrappedValue {
                case .complete: 1
                case .cards(let count), .minutes(let count): count
                }
            }, set: { value.wrappedValue = kind.wrappedValue == 1 ? .cards($0) : .minutes($0) }),
            range: 1...Int.max, unit: kind.wrappedValue == 1 ? "cards" : "min", label: "Session limit")
        }
    }
}

private func maximumInterval(_ value: Binding<StudyIntervalLimit>) -> some View {
    let days = Binding<Int?>(get: {
        if case .days(let days) = value.wrappedValue { return days }
        return nil
    }, set: { value.wrappedValue = $0.map(StudyIntervalLimit.days) ?? .automatic })
    return HStack(spacing: 8) {
        Picker("Maximum review interval", selection: Binding(get: { days.wrappedValue != nil }, set: { days.wrappedValue = $0 ? 365 : nil })) {
            Text("Automatic").tag(false)
            Text("Limit").tag(true)
        }.labelsHidden().pickerStyle(.segmented).fixedSize()
        if days.wrappedValue != nil {
            StudyNumber(value: Binding(get: { days.wrappedValue ?? 365 }, set: { days.wrappedValue = $0 }),
                        range: 1...36_500, unit: "days", label: "Maximum review days")
        }
    }
}

private func timingFlow(_ configuration: StudyConfiguration) -> some View {
    let correct: String
    switch configuration.flipFirstCorrect {
    case .startSpacedReviews: correct = "Got it → FSRS schedules"
    case .repeatAfter(let minutes): correct = "Got it → Back in \(minutes) min → Got it → FSRS schedules"
    }
    let retry = configuration.retryAfterMiss ? "End of session" : "Back in \(configuration.newRetryMinutes) min"
    return VStack(alignment: .leading, spacing: 3) {
        Text(correct)
        Text("Missed → " + retry + " → " + correct)
    }
    .font(Theme.small).foregroundStyle(Theme.quiet)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(10).background(Theme.goodWash, in: RoundedRectangle(cornerRadius: 8))
    .accessibilityElement(children: .combine)
}

private func sameSchedule(_ lhs: StudyConfiguration, _ rhs: StudyConfiguration) -> Bool {
    var left = lhs
    left.newCardLimit = rhs.newCardLimit
    left.session = rhs.session
    return left == rhs
}

private extension StudyCardTypes {
    var title: String {
        switch self {
        case .all: "Flip and solve"
        case .flip: "Flip only"
        case .solve: "Solve only"
        }
    }
}

private extension StudyQueueOrder {
    var title: String { self == .dueFirst ? "Due first" : "Mix new with due" }
}

private extension StudyNewCardOrder {
    var title: String {
        switch self {
        case .sequential: "Sequential"
        case .shuffleWithinLecture: "Shuffle within each lecture"
        case .shuffleAcrossSelection: "Shuffle across selected lectures"
        }
    }
}

private extension StudyStop {
    var summary: String {
        switch self {
        case .complete: "Queue is complete"
        case .cards(let count): Format.count(count, "card")
        case .minutes(let count): Format.count(count, "minute")
        }
    }
}

private extension StudyIntervalLimit {
    var summary: String {
        switch self {
        case .automatic: "Automatic"
        case .days(let days): Format.count(days, "day")
        }
    }
}
