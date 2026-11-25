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

    /// Default page size of `recordings_list`, a setting within `listLimitRange`.
    public var listLimit: Int = Configuration.defaultListLimit

    /// Ceiling on how many recordings one `recording_transcribe` call may take, a setting
    /// within `transcribeCountRange`. A first use of a locale downloads its on-device
    /// model, and each recording's transcript is a text of any length.
    public var maximumTranscribeCount: Int = 5

    public init() {}

    public static let defaultListLimit = 50

    /// One row is about 150 characters, so 100 of them stay near 15,000, inside
    /// `ToolStandard.longestResult` even with a long id on every row. No setting can raise
    /// the page above this.
    public static let listLimitRange = 1...100
    public static let transcribeCountRange = 1...25

    /// Ids one `recording_get` call may take. A record is about 600 characters, and a path
    /// can add a thousand, so ten stay well inside the longest result.
    public static let maximumGetIDs = 10
    public static let getIDsRange = 1...maximumGetIDs

    /// Paging ceiling. Declared here so the advertised schema and the enforced clamp
    /// cannot drift: both read this one value.
    public static let offsetRange = 0...10_000_000

    /// The window on one transcript. The maximum is half the longest result, so one
    /// transcript of ordinary text leaves room for the rest of the answer;
    /// `ToolStandard.fitting` makes a window smaller when several transcripts, or
    /// characters that take several UTF-16 units each, would not fit.
    public static let maxCharactersRange = 1...(ToolStandard.longestResult / 2)

    /// What a call with no `max_characters` aims to return in all: a usual page, shared by
    /// the transcripts asked for.
    public static let defaultMaxCharacters = ToolStandard.usualPage

    /// The window each transcript gets when `max_characters` is not given.
    public static func defaultWindow(forIDs count: Int) -> Int {
        Swift.max(defaultMaxCharacters / Swift.max(count, 1), maxCharactersRange.lowerBound)
    }

    /// Width a recording's name is clipped to in a listing; `recording_get` returns it whole.
    public static let listNameWidth = 80

    /// The most matching recordings a listing collects before it stops walking the library,
    /// and the longest it walks. Past either, the result says the scan stopped.
    public static let scanLimit = 10_000
    public static let scanTime = Duration.seconds(20)

    /// How long a call may run before it is answered. They stay below
    /// `ToolStandard.timeLimit`, so the answer is ours and not the client's generic
    /// "no result". Transcription gets the longest: its work stops at nine tenths of it and
    /// the transcripts finished by then are returned.
    public static let timeout = Duration.seconds(45)
    public static let transcribeTimeout = Duration.seconds(180)

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
