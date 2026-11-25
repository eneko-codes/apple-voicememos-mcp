import Foundation

public struct ParsedDate: Sendable, Equatable {
    public let date: Date
    /// True when the caller wrote only a day. Kept so the range echo can be printed back
    /// in the shape it arrived in rather than in an invented one.
    public let isDateOnly: Bool
    /// The smallest unit the caller wrote: a day, a minute or a second. A range's upper
    /// bound is inclusive at this precision, so `2026-08-12` covers the whole day.
    public let precision: Calendar.Component

    public init(date: Date, isDateOnly: Bool, precision: Calendar.Component = .day) {
        self.date = date
        self.isDateOnly = isDateOnly
        self.precision = precision
    }

    /// The first instant after everything this value covers: the exclusive end of an
    /// inclusive upper bound written at this precision.
    public func endExclusive(calendar: Calendar) -> Date {
        calendar.date(byAdding: precision, value: 1, to: date) ?? date
    }
}

/// Parsing and rendering of the three date forms this server accepts.
///
/// Deliberately strict, and the same three forms the sibling servers take. A lenient
/// parser that guesses at `10/08/2026` will one day read it as 8 October for a caller who
/// meant 10 August, and a filter that quietly slides two months is worse than one that
/// refuses the input. A date that does not exist (30 February, an hour a clock change
/// skips) is refused too, because `Calendar` would roll it into the next valid one.
public enum DateParsing {

    public static let acceptedForms = """
        - 2026-08-12                  a whole day, local time
        - 2026-08-12T09:00            local time
        - 2026-08-12T09:00:00+02:00   explicit offset
        """

    public static func parse(_ raw: String, argument: String, calendar: Calendar) throws
        -> ParsedDate
    {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let refusal = ToolError.badDate(argument: argument, value: text)

        if let components = dayComponents(text) {
            guard let day = calendar.date(from: components),
                exists(components, as: day, calendar: calendar)
            else { throw refusal }
            return ParsedDate(date: calendar.startOfDay(for: day), isDateOnly: true, precision: .day)
        }

        if let components = localComponents(text) {
            guard let moment = calendar.date(from: components),
                exists(components, as: moment, calendar: calendar)
            else { throw refusal }
            return ParsedDate(
                date: moment, isDateOnly: false,
                precision: hasSeconds(text) ? .second : .minute)
        }

        // Only reached for a string carrying its own offset or Z suffix, where the
        // machine's time zone is irrelevant. The day is checked on its own first, because
        // the formatter may accept a day that does not exist.
        guard let separator = text.firstIndex(of: "T"),
            let day = dayComponents(String(text[..<separator])),
            existsInGregorian(day)
        else { throw refusal }
        let optionSets: [ISO8601DateFormatter.Options] = [
            [.withInternetDateTime],
            [.withInternetDateTime, .withFractionalSeconds],
        ]
        for options in optionSets {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let moment = formatter.date(from: text) {
                return ParsedDate(date: moment, isDateOnly: false, precision: .second)
            }
        }

        throw refusal
    }

    /// Whether `date` still reads as the components that were asked for. `Calendar` moves
    /// a day or an hour that does not exist to the nearest one that does, so a mismatch
    /// means the caller wrote something impossible.
    private static func exists(_ asked: DateComponents, as date: Date, calendar: Calendar) -> Bool {
        let units: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]
        let found = calendar.dateComponents(units, from: date)
        return found.year == asked.year && found.month == asked.month && found.day == asked.day
            && (found.hour ?? 0) == (asked.hour ?? 0) && (found.minute ?? 0) == (asked.minute ?? 0)
            && (found.second ?? 0) == (asked.second ?? 0)
    }

    private static func existsInGregorian(_ day: DateComponents) -> Bool {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(identifier: "UTC")!
        guard let date = gregorian.date(from: day) else { return false }
        return exists(day, as: date, calendar: gregorian)
    }

    private static func hasSeconds(_ text: String) -> Bool {
        text.split(separator: "T").last.map { $0.split(separator: ":").count == 3 } ?? false
    }

    /// `YYYY-MM-DD` and nothing else.
    private static func dayComponents(_ text: String) -> DateComponents? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
            let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
            (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        return DateComponents(year: year, month: month, day: day)
    }

    /// `YYYY-MM-DDTHH:MM` or `YYYY-MM-DDTHH:MM:SS`, with no offset suffix.
    private static func localComponents(_ text: String) -> DateComponents? {
        let halves = text.split(separator: "T", omittingEmptySubsequences: false)
        guard halves.count == 2, var day = dayComponents(String(halves[0])) else { return nil }

        let time = halves[1]
        // A trailing Z or offset means the string is absolute; that is the ISO path.
        guard !time.contains("Z"), !time.contains("+"), time.filter({ $0 == "-" }).isEmpty
        else { return nil }

        let pieces = time.split(separator: ":")
        guard (2...3).contains(pieces.count), pieces.allSatisfy({ $0.count == 2 }),
            let hour = Int(pieces[0]), let minute = Int(pieces[1]),
            (0...23).contains(hour), (0...59).contains(minute)
        else { return nil }
        let second = pieces.count == 3 ? Int(pieces[2]) : 0
        guard let second, (0...59).contains(second) else { return nil }

        day.hour = hour
        day.minute = minute
        day.second = second
        return day
    }

    // MARK: Rendering

    private static let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    private static let months = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ]

    /// Hand-rolled rather than `DateFormatter` so output does not change shape with the
    /// machine's locale. A model that has learned to read `Mon 10 Aug` should not be
    /// handed `lun 10 ago` on a differently configured Mac.
    public static func dayWithYear(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.weekday, .day, .month, .year], from: date)
        let weekday = parts.weekday.map { weekdays[($0 - 1) % 7] } ?? "???"
        let month = parts.month.map { months[($0 - 1) % 12] } ?? "???"
        return String(
            format: "%@ %02d %@ %04d", weekday, parts.day ?? 0, month, parts.year ?? 0)
    }

    public static func time(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// `2026-08-12T09:00`, or `2026-08-12` for a date-only value — the same forms the
    /// filter accepts, so an echoed range can be pasted straight back into a call.
    public static func roundTrip(_ date: Date, isDateOnly: Bool, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let day = String(
            format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        guard !isDateOnly else { return day }
        return day + String(format: "T%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}
