import AppKit
import LecternCore

struct AskTurn {
    let chatID: UUID
    let questionID: UUID
}

enum AskWaitActivity {
    case flashcard, tower
}

enum AskWaitPreference: String, CaseIterable {
    case tower, flashcards, random

    var title: String {
        switch self {
        case .tower: "Tower"
        case .flashcards: "Flashcards"
        case .random: "Random"
        }
    }

    func activity() -> AskWaitActivity {
        switch self {
        case .tower: .tower
        case .flashcards: .flashcard
        case .random: Bool.random() ? .flashcard : .tower
        }
    }
}

struct AskWaitTower {
    let turn: AskTurn
    let round: WaitTowerRound
}

extension LectureWindowModel {
    func askJob(for turn: AskTurn) -> Job? {
        guard turn.chatID == displayedChat.id,
              let id = displayedChat.messages.last(where: { $0.id == turn.questionID })?.editJobID else { return nil }
        return lecture.jobs.last { $0.id == id }
    }

    var isShowingAskActivity: Bool { currentAskFlashcard != nil || currentWaitTower != nil }

    var currentWaitTower: AskWaitTower? {
        guard app.adhdModeEnabled, !readOnly, waitTower?.turn.chatID == displayedChat.id else { return nil }
        return waitTower
    }

    func scheduleWaitTower(for turn: AskTurn) {
        waitTowerTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self, app.adhdModeEnabled, !app.showSettings, !readOnly, isAskVisible,
                  !(mode == .review && runningGenerate != nil), displayedChat.id == turn.chatID,
                  isStillWaiting(for: turn) else { return }
            waitTower = AskWaitTower(turn: turn, round: WaitTowerRound())
        }
    }

    private func isStillWaiting(for turn: AskTurn) -> Bool {
        if let job = askJob(for: turn) {
            let progress = progress(job.id)
            let visibleAnswer = ChatMarkdown.finishedBlocks(progress?.streamedText ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return job.state == .running && !hasEndedAsk(progress) && visibleAnswer.isEmpty
        }
        return pendingChatMessage?.message.id == turn.questionID && chatPreparationFailure == nil
    }

    func waitTowerStatus(_ tower: AskWaitTower) -> (text: String, ready: Bool) {
        let job = askJob(for: tower.turn)
        let progress = job.flatMap { self.progress($0.id) }
        if job?.state == .succeeded { return ("Answer ready · Esc", true) }
        if chatPreparationFailure?.messageID == tower.turn.questionID ||
            job.map({ [.failed, .cancelled, .interrupted].contains($0.state) }) == true || hasEndedAsk(progress) {
            return ("Answer ended · Esc", false)
        }
        return (chatWorkingHint(progress).doing, false)
    }

    func leaveWaitTower() {
        guard let tower = currentWaitTower else { return }
        let jobID = askJob(for: tower.turn)?.id
        let answer = displayedChat.messages.last { $0.role == .assistant && $0.editJobID == jobID && jobID != nil }
        waitTowerReceipts[tower.turn.questionID] = tower.round.receipt
        chatScrollTarget = answer?.id ?? tower.turn.questionID
        waitTower = nil
    }

    func clearAskActivity() {
        waitTowerTask?.cancel()
        waitTowerTask = nil
        waitTower = nil
        askFlashcard = nil
    }

    func handleWaitTowerKey(_ event: NSEvent) -> Bool {
        guard Key.modifiers(event).isEmpty, let tower = currentWaitTower else { return false }
        switch event.keyCode {
        case Key.escape:
            if !event.isARepeat { leaveWaitTower() }
        case Key.space:
            if !event.isARepeat { tower.round.drop() }
        default:
            return false
        }
        return true
    }

    func hasEndedAsk(_ progress: JobProgress?) -> Bool {
        guard let stage = progress?.stage else { return false }
        return ["Persistence failed", "Failed", "Cancelled"].contains(stage)
    }
}
