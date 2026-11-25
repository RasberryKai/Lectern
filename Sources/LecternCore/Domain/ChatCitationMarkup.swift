import Foundation

public enum ChatCitationMarkup {
    public static let literalPattern = #"`([^`]+)`|\\\([\s\S]+?\\\)|\\\[[\s\S]+?\\\]|\$\$[\s\S]+?\$\$|\$[^$\n]+?\$|!\[[^\]]*\]\([^)]*\)"#
    public static let citationPattern = #"\[([SC]\d+(?:\s*[,;–—-]\s*[SC]?\d+)*)\]"#

    public static func targets(in source: String) -> [(String, Int)]? {
        let pattern = #"^\s*([SC])?(\d+)(?:\s*[–—-]\s*([SC])?(\d+))?\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        var kind = "S", targets: [(String, Int)] = []
        for group in source.split(whereSeparator: { $0 == "," || $0 == ";" }) {
            let text = String(group) as NSString
            guard let match = regex.firstMatch(in: text as String, range: NSRange(location: 0, length: text.length)) else { return nil }
            if match.range(at: 1).location != NSNotFound { kind = text.substring(with: match.range(at: 1)) }
            if match.range(at: 3).location != NSNotFound,
               text.substring(with: match.range(at: 3)) != kind { return nil }
            guard let start = Int(text.substring(with: match.range(at: 2))), start > 0 else { return nil }
            let end: Int
            if match.range(at: 4).location == NSNotFound { end = start }
            else if let number = Int(text.substring(with: match.range(at: 4))) { end = number }
            else { return nil }
            guard end >= start, end - start < 100, targets.count + (end - start + 1) <= 100 else { return nil }
            for number in start...end where !targets.contains(where: { $0.0 == kind && $0.1 == number }) {
                targets.append((kind, number))
            }
        }
        return targets
    }
}
