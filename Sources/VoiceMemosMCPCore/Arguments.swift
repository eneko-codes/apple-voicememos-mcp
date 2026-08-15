import Foundation
import MCP

/// Typed access to a `tools/call` argument bag.
public struct Arguments {
    private let values: [String: Value]
    private let calendar: Calendar

    public init(_ values: [String: Value]?, calendar: Calendar) {
        self.values = values ?? [:]
        self.calendar = calendar
    }

    // MARK: Scalars

    public func requiredString(_ name: String) throws -> String {
        guard let raw = values[name]?.stringValue else { throw ToolError.missingArgument(name) }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ToolError.badArgument(name: name, reason: "it is empty")
        }
        return trimmed
    }

    public func optionalString(_ name: String) -> String? {
        guard let text = values[name]?.stringValue else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Clamps rather than rejects: a model asking for 500 results means "as many as you
    /// will give me".
    public func int(_ name: String, default fallback: Int, in range: ClosedRange<Int>) throws
        -> Int
    {
        guard let raw = values[name] else { return fallback }
        guard let number = raw.intValue else {
            throw ToolError.badArgument(name: name, reason: "an integer was expected")
        }
        return Swift.min(Swift.max(number, range.lowerBound), range.upperBound)
    }

    public func stringArray(_ name: String) throws -> [String] {
        guard let raw = values[name] else { return [] }
        if case .null = raw { return [] }
        // A single string where an array is expected is a common and harmless slip.
        if let single = raw.stringValue { return [single] }
        guard let entries = raw.arrayValue else {
            throw ToolError.badArgument(name: name, reason: "an array of strings was expected")
        }
        return entries.compactMap(\.stringValue)
    }

    /// Ids, de-duplicated with the first occurrence's position kept.
    ///
    /// Repeats matter here in a way they do not elsewhere: transcribing the same
    /// recording twice in one call costs a second full pass over the audio.
    public func identifiers(_ name: String) throws -> [String] {
        let raw = try stringArray(name).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !raw.isEmpty else { throw ToolError.missingArgument(name) }

        var seen = Set<String>()
        return raw.filter { seen.insert($0).inserted }
    }

    // MARK: Dates

    public func optionalDate(_ name: String) throws -> ParsedDate? {
        guard let raw = optionalString(name) else { return nil }
        return try DateParsing.parse(raw, argument: name, calendar: calendar)
    }

    /// The exclusive end of a range.
    ///
    /// A plain day means the whole of it, so `created_before: 2026-08-12` includes
    /// everything recorded on the 12th. Read literally it would exclude the entire day,
    /// which makes a single-day window return nothing at all.
    public func rangeEnd(_ name: String) throws -> Date? {
        guard let parsed = try optionalDate(name) else { return nil }
        guard parsed.isDateOnly else { return parsed.date }
        return calendar.date(byAdding: .day, value: 1, to: parsed.date) ?? parsed.date
    }
}
