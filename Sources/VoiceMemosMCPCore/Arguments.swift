import Foundation

/// Typed access to a `tools/call` argument bag.
///
/// A class, not a struct, so that reading a number can also record that it was moved into
/// its range without every reader having to be `mutating`. One instance serves one call and
/// never leaves it. The tool puts `notices` before the data.
public final class Arguments {
    private let values: [String: Value]
    private let calendar: Calendar

    /// One sentence for each number that was moved into its range, in the order read.
    public private(set) var notices: [String] = []

    /// Refuses an argument the tool does not declare, so that a call still using a name
    /// that was renamed fails instead of running without it.
    public init(_ values: [String: Value]?, calendar: Calendar, allowed: [String]) throws {
        self.values = values ?? [:]
        self.calendar = calendar
        let unknown = self.values.keys.filter { !allowed.contains($0) }.sorted()
        if !unknown.isEmpty { throw ToolError.unknownArguments(unknown, allowed: allowed) }
    }

    /// `nil` when the argument is absent or null, which mean the same: not given.
    private func given(_ name: String) -> Value? {
        guard let raw = values[name], !raw.isNull else { return nil }
        return raw
    }

    // MARK: Scalars

    public func requiredString(_ name: String) throws -> String {
        guard let text = try optionalString(name) else {
            if given(name) != nil { throw ToolError.badArgument(name: name, reason: "it is empty") }
            throw ToolError.missingArgument(name)
        }
        return text
    }

    /// Empty text is "not given", as it is for every other text argument. A value that is
    /// not text is refused, not ignored.
    public func optionalString(_ name: String) throws -> String? {
        guard let raw = given(name) else { return nil }
        guard let text = raw.stringValue else {
            throw ToolError.badArgument(name: name, reason: "text was expected")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A quantity: a size, a count, an offset. Outside its range it is moved to the nearest
    /// allowed value, and `notices` gains the sentence that says which value was used.
    public func int(_ name: String, default fallback: Int, in range: ClosedRange<Int>) throws
        -> Int
    {
        guard let raw = given(name) else { return fallback }
        guard let number = raw.intValue else {
            throw ToolError.badArgument(name: name, reason: "a whole number was expected")
        }
        return ToolStandard.clamp(number, to: range, argument: name, notices: &notices)
    }

    /// The `limit` and `offset` of a listing.
    public func page(defaultLimit: Int, limits: ClosedRange<Int>) throws -> (limit: Int, offset: Int) {
        (
            try int("limit", default: defaultLimit, in: limits),
            try int("offset", default: 0, in: Configuration.offsetRange)
        )
    }

    public func stringArray(_ name: String) throws -> [String] {
        guard let raw = given(name) else { return [] }
        // A single string where an array is expected is a common and harmless slip.
        if let single = raw.stringValue { return [single] }
        guard let entries = raw.arrayValue else {
            throw ToolError.badArgument(name: name, reason: "an array of strings was expected")
        }
        let texts = entries.compactMap(\.stringValue)
        guard texts.count == entries.count else {
            throw ToolError.badArgument(name: name, reason: "an array of strings was expected")
        }
        return texts
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

    /// Absent, empty and `null` all mean "no bound on this side of the range".
    public func optionalDate(_ name: String) throws -> ParsedDate? {
        guard let text = try optionalString(name) else { return nil }
        return try DateParsing.parse(text, argument: name, calendar: calendar)
    }
}
