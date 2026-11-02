import Foundation

/// A Gregorian calendar date, independent of the user's current time zone.
/// Persisting a midnight timestamp would move an exam to another day when travelling.
public struct ExamDate: Codable, Equatable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              calendar.component(.year, from: date) == year,
              calendar.component(.month, from: date) == month,
              calendar.component(.day, from: date) == day else {
            throw LibraryError.invalid("Exam date must be a valid Gregorian calendar date.")
        }
        self.year = year; self.month = month; self.day = day
    }

    public init(date: Date, timeZone: TimeZone = .current) throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        try self.init(year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0)
    }

    /// Use this only at the DatePicker boundary; the stored value remains date-only.
    public func date(in timeZone: TimeZone = .current) -> Date {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    public func daysRemaining(from now: Date, timeZone: TimeZone = .current) -> Int {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date(in: timeZone))).day ?? 0
    }

    private enum CodingKeys: String, CodingKey { case year, month, day }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(year: values.decode(Int.self, forKey: .year), month: values.decode(Int.self, forKey: .month), day: values.decode(Int.self, forKey: .day))
    }
}
