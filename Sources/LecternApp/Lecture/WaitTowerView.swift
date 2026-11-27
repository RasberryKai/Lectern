import SwiftUI

struct WaitTowerView: View {
    let round: WaitTowerRound
    let status: String
    let answerReady: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var readinessPulse = false
    @State private var showsPerfect = false

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack(alignment: .top) {
                TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { _ in
                    board(at: ProcessInfo.processInfo.systemUptime)
                }
                .accessibilityHidden(true)

                if showsPerfect || round.needsRestart {
                    Text(round.needsRestart ? "Missed" : "Perfect")
                        .font(Theme.caption.weight(.semibold))
                        .foregroundStyle(round.needsRestart ? Theme.quiet : Theme.accentText)
                        .padding(.top, 8)
                }
            }
            controls
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { Theme.canvasGrid }
        .onChange(of: reduceMotion, initial: true) { _, reduced in round.reduceMotion = reduced }
        .task(id: answerReady) {
            guard answerReady, round.signalReadiness(), !reduceMotion else { return }
            withAnimation(.easeOut(duration: 0.15)) { readinessPulse = true }
            try? await Task.sleep(for: .milliseconds(150))
            withAnimation(.easeInOut(duration: 0.25)) { readinessPulse = false }
        }
        .task(id: round.lastDrop?.time) {
            let elapsed = round.lastDrop.map { ProcessInfo.processInfo.systemUptime - $0.time } ?? 0
            let remaining = 0.7 - elapsed
            showsPerfect = round.lastDrop?.perfect == true && remaining > 0
            guard showsPerfect else { return }
            try? await Task.sleep(for: .seconds(remaining))
            if !Task.isCancelled { showsPerfect = false }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if answerReady {
                    LogoMark().fill(Theme.ai)
                        .frame(width: 18, height: 18)
                        .scaleEffect(readinessPulse ? 1.35 : 1)
                        .accessibilityHidden(true)
                    Text(status).font(Theme.small.weight(.semibold)).foregroundStyle(Theme.ink)
                } else {
                    ChatWorkingIndicator(doing: status, done: nil)
                }
            }
            HStack(spacing: 9) {
                Text(round.variant.title).font(Theme.small.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                Text(verbatim: "\(round.variant.scoreLabel) \(round.score.formatted())")
                    .font(Theme.small.monospacedDigit())
                    .foregroundStyle(Theme.ink)
                    .fixedSize()
                Text(verbatim: "Best \(round.highScore.formatted())")
                    .font(Theme.small.monospacedDigit())
                    .foregroundStyle(Theme.quiet)
                    .fixedSize()
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.canvas)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private var controls: some View {
        let action = round.needsRestart ? "Restart" : "Drop"
        let label = round.needsRestart ? "Restart tower" : "Drop block"
        return HStack(spacing: 18) {
            Button(action: round.drop) {
                keyHint("Space", action: action)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
            .accessibilityHint(round.needsRestart ? "Press Space to start a new tower" : "Press Space to drop a block")

            keyHint("Esc", action: "Back to Ask")
                .accessibilityLabel("Press Escape to return to Ask")
        }
        .padding(.vertical, 12)
    }

    private func keyHint(_ key: String, action: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(Theme.surface, in: .rect(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.borderStrong))
            Text(action).font(Theme.caption).foregroundStyle(Theme.quiet)
        }
        .fixedSize()
    }

    private func board(at time: TimeInterval) -> some View {
        let blockColor = Theme.ink
        let perfectColor = Theme.accent
        return Canvas { context, size in
            let blockWidth = min(112, size.width * (round.variant == .cutoff ? 0.28 : 0.36))
            let blockHeight = max(9, min(21, blockWidth * 0.2))
            let spacing = blockHeight + 2
            let centerX = size.width / 2
            let anchor = CGPoint(x: centerX, y: 5)
            let hangHeight = min(58, max(24, size.height * 0.13))
            let base = size.height - 16
            let drop = round.lastDrop
            let progress = drop.map { reduceMotion ? 1 : min(1, max(0, (time - $0.time) / WaitTowerRound.landingDuration)) } ?? 1
            let cameraProgress = drop?.landed == true ? progress * (2 - progress) : 1
            let cameraHeight = Double(round.height) - (1 - cameraProgress)
            let scroll = max(0, hangHeight + blockHeight * 2.2 + cameraHeight * spacing - base)
            let ground = base + scroll

            func hangingCenter(_ block: WaitTowerRound.Block) -> CGPoint {
                CGPoint(x: centerX + blockWidth * block.center, y: hangHeight - block.center * block.center * 8)
            }

            func levelCenter(_ level: Int) -> CGFloat {
                ground - CGFloat(level) * spacing + blockHeight / 2
            }

            func opacity(at y: CGFloat) -> Double {
                guard scroll > 0 else { return 1 }
                return min(1, max(0, (size.height - y) / 60))
            }

            func draw(_ block: WaitTowerRound.Block, at center: CGPoint, angle: Angle = .zero, opacity: Double = 1) {
                let width = max(1, blockWidth * block.width)
                let rect = CGRect(x: -width / 2, y: -blockHeight / 2, width: width, height: blockHeight)
                var layer = context
                layer.translateBy(x: center.x, y: center.y)
                layer.rotate(by: angle)
                layer.opacity = opacity
                layer.fill(Path(roundedRect: rect, cornerRadius: min(2, width / 2)),
                           with: .color(block.perfect ? perfectColor : blockColor))
            }

            var floor = context
            floor.opacity = opacity(at: ground)
            let floorLine = Path { line in
                line.move(to: CGPoint(x: centerX - blockWidth / 2, y: ground + 0.5))
                line.addLine(to: CGPoint(x: centerX + blockWidth / 2, y: ground + 0.5))
            }
            floor.stroke(floorLine, with: .color(Theme.borderStrong), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))

            if let drop, progress < 1 {
                let start = hangingCenter(drop.block)
                let landing = levelCenter(round.height + (drop.landed ? 0 : 1))
                draw(drop.block, at: CGPoint(x: start.x, y: start.y + (landing - start.y) * progress * progress))
            } else if !round.needsRestart {
                let block = round.movingBlock(at: time, reduceMotion: reduceMotion)
                let hanging = hangingCenter(block)
                let wire = Path { line in
                    line.move(to: anchor)
                    line.addLine(to: hanging)
                }
                context.stroke(wire, with: .color(Theme.faint), lineWidth: 1)
                draw(block, at: hanging)
            }

            for (index, block) in round.blocks.reversed().enumerated() {
                if index == 0, drop?.landed == true, progress < 1 { continue }
                let center = CGPoint(x: centerX + blockWidth * block.center, y: levelCenter(round.height - index))
                if center.y - blockHeight / 2 > size.height { break }
                draw(block, at: center, opacity: opacity(at: center.y))
            }

            if !reduceMotion {
                for piece in round.fallingPieces {
                    let age = (time - piece.time) / WaitTowerRound.fallDuration
                    guard age >= 0, age < 1 else { continue }
                    let center = CGPoint(
                        x: centerX + blockWidth * (piece.block.center + piece.direction * age * 0.65),
                        y: levelCenter(piece.level) + max(100, size.height * 0.65) * age * age
                    )
                    draw(piece.block, at: center, angle: .degrees(piece.direction * age * 85), opacity: 1 - age)
                }
            }
        }
    }
}
