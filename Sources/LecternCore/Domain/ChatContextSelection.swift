import Foundation

extension ChatContext {
    /// A category-wide selection replaces its individual pins, and an individual
    /// selection narrows that category again. Other context stays attached.
    public mutating func pin(_ ref: ContextRef) {
        pins.removeAll { existing in
            switch (ref, existing) {
            case (.allSlides, .slide), (.allSlides, .allSlides), (.slide, .allSlides),
                 (.allCards, .card), (.allCards, .allCards), (.card, .allCards): true
            default: existing == ref
            }
        }
        pins.append(ref)
    }
}
