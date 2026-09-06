import Foundation

/// Settings the person installing the extension can change.
///
/// These arrive as command-line arguments because that is how a Claude extension passes
/// `user_config`: the manifest substitutes `${user_config.key}` into `mcp_config.args`.
/// Parsing is hand-rolled rather than pulling in an argument-parsing package — the whole
/// surface is five settings, and every dependency in this repo has to earn its place.
public struct Configuration: Sendable, Equatable {
    /// Folder to read recordings from. When empty the server falls back to the Voice
    /// Memos container, which needs Full Disk Access; see `SystemRecordingStore`.
    public var libraryPath: String?

    /// The only folder this server may write into. Empty means `recording_export` is
    /// refused outright — an export tool with no configured root could write anywhere the
    /// user account can, and that is not a decision to leave to a default.
    public var exportRoot: String?

    /// Recognition locale, e.g. `es-ES`. Empty means the machine's current locale.
    public var localeIdentifier: String?

    public var listLimit: Int = 50

    /// Ceiling on one `recording_transcribe` call. Recognition itself is fast, but a first
    /// use of a locale downloads its on-device model, and an unbounded batch would let one
    /// call return an unreadable wall of transcript text besides.
    public var maximumTranscribeCount: Int = 5

    public init() {}

    public static let listLimitRange = 1...200
    public static let transcribeCountRange = 1...25

    /// Paging ceiling. Declared here so the advertised schema and the enforced clamp
    /// cannot drift: both read this one value.
    public static let offsetRange = 0...10_000

    /// True when an argument is an unsubstituted manifest placeholder.
    ///
    /// Claude Desktop leaves `${user_config.key}` untouched when the person left that
    /// setting empty, so the literal text arrives as an argument. Taking it at face value
    /// is worse than ignoring it: an export root of `${user_config.export_root}` would be
    /// created as a real directory with that name.
    static func isPlaceholder(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("${") && trimmed.hasSuffix("}")
    }

    /// A usable path, or nil. `~` is expanded here because a value typed into the
    /// extension's settings field is written the way a person writes a path, and the
    /// shell that would normally expand it is not involved.
    static func path(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isPlaceholder(trimmed) else { return nil }
        return (trimmed as NSString).expandingTildeInPath
    }

    /// Unknown flags are ignored rather than fatal, and numbers are clamped rather than
    /// rejected. A server that will not launch is much harder to diagnose than one
    /// running on a default.
    public static func parse(_ arguments: [String]) -> Configuration {
        var configuration = Configuration()
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            let value = index + 1 < arguments.count ? arguments[index + 1] : nil

            func clamped(_ range: ClosedRange<Int>) -> Int? {
                guard let value, !isPlaceholder(value), let number = Int(value) else {
                    return nil
                }
                return min(max(number, range.lowerBound), range.upperBound)
            }

            switch flag {
            case "--library":
                configuration.libraryPath = path(value)
                index += 2

            case "--export-root":
                configuration.exportRoot = path(value)
                index += 2

            case "--locale":
                if let value, !isPlaceholder(value) {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    configuration.localeIdentifier = trimmed.isEmpty ? nil : trimmed
                }
                index += 2

            case "--list-limit":
                if let number = clamped(listLimitRange) { configuration.listLimit = number }
                index += 2

            case "--max-transcribe":
                if let number = clamped(transcribeCountRange) {
                    configuration.maximumTranscribeCount = number
                }
                index += 2

            default:
                index += 1
            }
        }
        return configuration
    }
}
