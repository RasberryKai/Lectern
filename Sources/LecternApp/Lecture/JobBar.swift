import LecternCore
import SwiftUI

/// Bottom bar for AI work on this lecture: queued/running jobs with stages and Cancel,
/// failed and interrupted jobs with Retry. Editing stays enabled; jobs use snapshots.
struct JobBar: View {
    let model: LectureWindowModel

    var body: some View {
        let running = model.runningJobs.filter { $0.kind == .generate || $0.kind == .revise }
        let attention = model.attentionJobs.filter { $0.kind == .generate || $0.kind == .revise }
        if !running.isEmpty || !attention.isEmpty {
            VStack(spacing: 0) {
                Rectangle().fill(Theme.border).frame(height: 1)
                VStack(spacing: 8) {
                    ForEach(running.prefix(3)) { RunningJobRow(model: model, job: $0) }
                    if running.count > 3 {
                        Text("and \(running.count - 3) more queued").font(Theme.small).foregroundStyle(Theme.quiet)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(attention) { AttentionJobRow(model: model, job: $0) }
                }
                .padding(.horizontal, 22).padding(.vertical, 12)
                .background(Theme.surface)
            }
        }
    }
}

private struct RunningJobRow: View {
    let model: LectureWindowModel
    let job: Job

    private static let stages = ["Queued", "Sending", "Writing", "Checking"]

    var body: some View {
        let stage = model.progress(job.id)?.stage ?? "Queued"
        let index = Self.stages.firstIndex(of: stage) ?? 2
        HStack(spacing: 16) {
            ProgressView(value: Double(index + 1), total: Double(Self.stages.count + 1))
                .progressViewStyle(.linear).tint(Theme.accent).frame(width: 150)
            Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            HStack(spacing: 10) {
                ForEach(Array(["Sent", "Writing", "Checking"].enumerated()), id: \.offset) { offset, name in
                    let step = offset + 1
                    Text(step < index ? "\(name) ✓" : name)
                        .font(Theme.small)
                        .fontWeight(step == index ? .semibold : .regular)
                        .foregroundStyle(step <= index ? Theme.ink : Theme.faint)
                }
                if stage == "Queued" { Text("Waiting for a free slot").font(Theme.small).foregroundStyle(Theme.quiet) }
                else if !Self.stages.contains(stage) { Text(stage).font(Theme.small).foregroundStyle(Theme.quiet) }
            }
            Text("You can keep editing; the job uses a snapshot.").font(Theme.small).foregroundStyle(Theme.quiet).lineLimit(1)
            Spacer(minLength: 8)
            if let warning = model.progress(job.id)?.warning {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.amber).help(warning)
            }
            Button("Cancel") { Task { await model.cancel(job.id) } }.buttonStyle(SecondaryButtonStyle())
        }
    }

    private var title: String {
        switch job.kind {
        case .generate: "Writing cards from \(Format.count(job.pages.count, "slide"))"
        case .revise:
            if let id = job.targetCardID, let number = model.cardNumbers[id] { "Revising card \(number)" } else { "Revising a card" }
        case .ask: "Answering on \(Format.slides(job.pages))"
        case .distil: "Picking learning points"
        }
    }
}

private struct AttentionJobRow: View {
    let model: LectureWindowModel
    let job: Job

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: job.state == .interrupted ? "pause.circle" : "exclamationmark.triangle.fill")
                .foregroundStyle(job.state == .interrupted ? Theme.amber : Theme.bad)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline).font(.system(size: 13, weight: .semibold))
                if let error = job.error { Text(error).font(Theme.small).foregroundStyle(Theme.quiet).lineLimit(2).textSelection(.enabled) }
            }
            Spacer()
            Button("Retry") { Task { await model.retry(job.id) } }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(model.readOnly)
                .help("Retries with the exact same snapshot. No automatic paid retries.")
            Button("Dismiss") { model.dismissedJobIDs.insert(job.id) }.buttonStyle(LinkButtonStyle(color: Theme.quiet))
        }
    }

    private var headline: String {
        let what = job.kind == .generate ? "Generating cards from \(Format.count(job.pages.count, "slide"))" : "Revising a card"
        return job.state == .interrupted ? "\(what) was interrupted" : "\(what) failed"
    }
}

// MARK: - Generate sheet

struct GenerateSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let model: LectureWindowModel

    @State private var regenerateAll = false
    @State private var confirmRegenerate = false
    @State private var rulesTitle = "Global rules"
    @State private var moduleCardCount = 0
    @State private var starting = false

    private var lecture: Lecture { model.lecture }
    private var uncovered: [Int] { lecture.uncoveredSelectedPages }
    private var selected: [Int] { lecture.slides.filter(\.isSelected).map { $0.pageIndex + 1 } }
    private var scope: [Int] { regenerateAll ? selected : uncovered }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Generate cards").font(Theme.serif(26))

            VStack(alignment: .leading, spacing: 8) {
                Text("Scope").font(.system(size: 13, weight: .semibold))
                scopeOption(isOn: !regenerateAll, title: "Slides without cards (\(uncovered.count))",
                            detail: "Recommended. Never duplicates cards you already have.") { regenerateAll = false }
                scopeOption(isOn: regenerateAll, title: "All selected slides (\(selected.count))",
                            detail: "Adds new cards next to the existing \(model.activeCards.filter { $0.verdict != .bad }.count). Asks to confirm.") { regenerateAll = true }
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("Sent with the slides").font(.system(size: 13, weight: .semibold))
                bullet(rulesTitle)
                let instructions = app.module(model.ref.moduleID)?.instructions.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                bullet(instructions.isEmpty ? "No module instructions" : "Module instructions · \(model.moduleName)")
                let notes = scope.filter { !(model.slide($0 - 1)?.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }.count
                bullet("\(Format.count(notes, "slide note")), which take precedence")
                let points = lecture.threads.flatMap(\.learningPoints).filter { $0.included && $0.pages.contains(where: { scope.contains($0) }) }
                let pointSlides = Set(points.flatMap(\.pages)).intersection(scope).count
                bullet("\(Format.count(points.count, "learning point")) from your questions on \(Format.count(pointSlides, "slide"))")
                bullet("\(Format.count(moduleCardCount, "existing module card")), marked as already covered")
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.inset, in: RoundedRectangle(cornerRadius: 10))

            HStack {
                Image(systemName: app.settings.backend == .claudeCLI ? "terminal" : "key")
                Text("\(app.settings.backend.displayName) · \(app.settings.selectedModel) · \(app.settings.backend.billingNote)")
                    .font(Theme.body)
                Spacer()
                SettingsLink { Text("Change") }.buttonStyle(LinkButtonStyle())
            }

            if scope.count > 100 {
                ErrorBanner(message: "\(scope.count) slides is over the 100-slide limit per request. Deselect slides or generate in parts; Lectern doesn't split or truncate silently.")
            } else if scope.isEmpty {
                Text(regenerateAll ? "No slides are selected." : "Every selected slide already has cards. Choose All selected slides to add more.")
                    .font(Theme.small).foregroundStyle(Theme.quiet)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Start ⌘↩") { start() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(scope.isEmpty || scope.count > 100 || starting || model.readOnly)
            }
        }
        .padding(28)
        .frame(width: 540)
        .background(Theme.surface)
        .task { await loadContext() }
        .alert("Add cards for all \(selected.count) selected slides?", isPresented: $confirmRegenerate) {
            Button("Cancel", role: .cancel) {}
            Button("Generate") { Task { await run() } }
        } message: {
            Text("Slides that already have cards will get more. Existing cards stay as they are.")
        }
    }

    private func scopeOption(isOn: Bool, title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isOn ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isOn ? Theme.accent : Theme.faint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(Theme.small).foregroundStyle(Theme.quiet)
                }
                Spacer()
            }
            .padding(12)
            .background(isOn ? Theme.goodWash : Theme.surface, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(isOn ? Theme.accent : Theme.borderStrong, lineWidth: isOn ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(Theme.quiet).frame(width: 4, height: 4)
            Text(text).font(Theme.body)
        }
    }

    private func loadContext() async {
        if let rules = try? await app.store.loadRules() {
            let heading = rules.split(separator: "\n").first { $0.hasPrefix("#") }
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) }
            rulesTitle = "Global rules · \(heading ?? "rules.md")"
        }
        if let lectures = try? await app.store.lectures(in: model.ref.moduleID) {
            moduleCardCount = lectures.flatMap(\.cards).filter { !$0.isSuperseded && $0.verdict != .bad }.count
        }
    }

    private func start() {
        if regenerateAll { confirmRegenerate = true } else { Task { await run() } }
    }

    private func run() async {
        starting = true
        await model.generate(regenerateAll: regenerateAll)
        starting = false
        if model.errorMessage == nil { dismiss() }
    }
}
