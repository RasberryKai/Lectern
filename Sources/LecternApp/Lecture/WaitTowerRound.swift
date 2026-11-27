import Foundation
import Observation

enum WaitTowerVariant: String {
    case cutoff, perfectStreak

    var title: String { self == .cutoff ? "Cutoff" : "Perfect Streak" }
    var scoreLabel: String { self == .cutoff ? "Height" : "Streak" }

    func receipt(for score: Int) -> String {
        switch self {
        case .cutoff: "Cutoff · \(score) high"
        case .perfectStreak: "Perfect Streak · \(score) in a row"
        }
    }
}

@Observable final class WaitTowerRound {
    struct Block {
        let center: Double
        let width: Double
        let perfect: Bool

        var left: Double { center - width / 2 }
        var right: Double { center + width / 2 }

        init(center: Double, width: Double, perfect: Bool = false) {
            self.center = center
            self.width = width
            self.perfect = perfect
        }

        init(left: Double, right: Double) {
            self.init(center: (left + right) / 2, width: right - left)
        }
    }

    struct Drop {
        let block: Block
        let time: TimeInterval
        let landed: Bool
        let perfect: Bool
    }

    struct FallingPiece {
        let block: Block
        let level: Int
        let time: TimeInterval
        let direction: Double
    }

    static let landingDuration: TimeInterval = 0.24
    static let fallDuration: TimeInterval = 0.55
    private static let visibleBlockLimit = 256
    private let start = ProcessInfo.processInfo.systemUptime
    private let defaults: UserDefaults
    private let scoreKey: String
    let variant: WaitTowerVariant
    private(set) var blocks: [Block] = []
    private(set) var height = 0
    private(set) var streak = 0
    private(set) var roundBest = 0
    private(set) var highScore: Int
    private(set) var lastDrop: Drop?
    private(set) var fallingPieces: [FallingPiece] = []
    @ObservationIgnored var reduceMotion = false
    @ObservationIgnored private var didSignalReadiness = false

    var score: Int { variant == .cutoff ? height : streak }
    var needsRestart: Bool { lastDrop?.landed == false }
    var receipt: String { variant.receipt(for: roundBest) }

    private var support: Block { blocks.last ?? Block(center: 0, width: 1) }

    init(variant: WaitTowerVariant = Bool.random() ? .cutoff : .perfectStreak, defaults: UserDefaults = .standard) {
        let key = "lectern.waitTower.best.\(variant.rawValue)"
        self.variant = variant
        self.defaults = defaults
        scoreKey = key
        highScore = max(0, defaults.integer(forKey: key))
    }

    func drop() {
        let time = ProcessInfo.processInfo.systemUptime
        if !reduceMotion, let lastDrop, time - lastDrop.time < Self.landingDuration { return }
        if needsRestart {
            blocks = []
            height = 0
            fallingPieces = []
            lastDrop = nil
        } else {
            place(movingBlock(at: time, reduceMotion: reduceMotion), at: time)
        }
    }

    func movingBlock(at time: TimeInterval, reduceMotion: Bool) -> Block {
        let swing = reduceMotion ? 0 : sin((time - start) * 2 * .pi / 2.6)
        if variant == .cutoff {
            return Block(center: support.center + swing * 0.9, width: support.width)
        }
        return Block(center: reduceMotion ? support.center : swing * 0.43, width: 1)
    }

    func place(_ block: Block, at time: TimeInterval) {
        let support = support
        let perfect = abs(block.center - support.center) <= min(0.026, support.width * 0.12)
        let level = height + 1
        let left = max(block.left, support.left)
        let right = min(block.right, support.right)
        var landed: Block?
        var offcut: Block?

        if variant == .perfectStreak {
            landed = Block(center: block.center, width: block.width, perfect: perfect)
            streak = perfect ? streak + 1 : 0
        } else if perfect {
            landed = Block(center: support.center, width: support.width, perfect: true)
        } else if right > left {
            landed = Block(left: left, right: right)
            offcut = block.center < support.center
                ? Block(left: block.left, right: left)
                : Block(left: right, right: block.right)
        } else {
            offcut = block
        }

        fallingPieces.removeAll { time - $0.time >= Self.fallDuration }
        if let offcut, offcut.width > 0, !reduceMotion {
            fallingPieces.append(FallingPiece(block: offcut, level: level, time: time + Self.landingDuration,
                                              direction: block.center < support.center ? -1 : 1))
        }
        lastDrop = Drop(block: block, time: time, landed: landed != nil, perfect: perfect)
        guard let landed else { return }
        height = level
        blocks.append(landed)
        if blocks.count > Self.visibleBlockLimit { blocks.removeFirst() }
        roundBest = max(roundBest, score)
        if roundBest > highScore {
            highScore = max(roundBest, defaults.integer(forKey: scoreKey))
            defaults.set(highScore, forKey: scoreKey)
        }
    }

    func signalReadiness() -> Bool {
        guard !didSignalReadiness else { return false }
        didSignalReadiness = true
        return true
    }
}
