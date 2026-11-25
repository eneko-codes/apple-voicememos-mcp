import Foundation

/// The catalogue is the authorisation surface: a tool that is not listed here cannot
/// be called, and the name it is listed under is the label on the permission switch in
/// Claude Desktop. Every tool here is a read of the recording library; the one that
/// writes anything, `recording_export`, only ever writes a copy into a folder the owner
/// nominated.
public enum ToolCatalog {

    /// Names are constants rather than being read back off a `Tool`, because a tool
    /// whose schema depends on the configuration has to be built as a function and its
    /// name would then have nowhere stable to live.
    public static let statusName = "recordings_status"
    public static let listName = "recordings_list"
    public static let getName = "recording_get"
    public static let transcribeName = "recording_transcribe"
    public static let exportName = "recording_export"

    /// Built from the live configuration so a description never states a limit the
    /// running server does not actually enforce.
    public static func all(_ configuration: Configuration = Configuration()) -> [Tool] {
        [status, list(configuration), get, transcribe(configuration), export(configuration)]
    }

    /// The arguments a tool declares, read from its schema so that what is accepted and
    /// what is advertised cannot differ.
    public static func argumentNames(
        of toolName: String, configuration: Configuration = Configuration()
    ) -> [String] {
        let schema = all(configuration).first { $0.name == toolName }?.inputSchema
        return (schema?.objectValue?["properties"]?.objectValue ?? [:]).keys.sorted()
    }

    // MARK: Schema helpers

    private static func object(properties: [String: Value], required: [String] = []) -> Value {
        var schema: [String: Value] = [
            "type": .string("object"),
            "properties": .object(properties),
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map { .string($0) })
        }
        schema["additionalProperties"] = .bool(false)
        return .object(schema)
    }

    /// `type` is always a single string, never `["string", "null"]`. Claude Desktop's
    /// schema sanitiser drops a property whose type is a union and hands the model a bare
    /// `{}` in its place; an array argument is then serialised to a string and rejected on
    /// arrival. A test walks the whole catalogue to keep unions out.
    private static func string(_ description: String) -> Value {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func stringArray(_ description: String, count: ClosedRange<Int>) -> Value {
        .object([
            "type": .string("array"),
            "items": .object(["type": .string("string")]),
            "minItems": .int(count.lowerBound), "maxItems": .int(count.upperBound),
            "description": .string(description),
        ])
    }

    private static func integer(_ description: String, range: ClosedRange<Int>, default def: Int? = nil)
        -> Value
    {
        var schema: [String: Value] = [
            "type": .string("integer"), "description": .string(description),
            "minimum": .int(range.lowerBound), "maximum": .int(range.upperBound),
        ]
        if let def { schema["default"] = .int(def) }
        return .object(schema)
    }

    private static let dateHelp = """
        Accepts 2026-08-12 (whole day), 2026-08-12T09:00 (local time), or \
        2026-08-12T09:00:00+02:00 (explicit offset).
        """

    private static let idHelp = """
        Identifier from recordings_list — the file's path relative to the library root, \
        such as "20260809 194500.m4a".
        """

    // MARK: Tools

    static let status = Tool(
        name: statusName,
        title: "Voice Memos server status",
        description: """
            Reports which recording library this server can reach, whether speech \
            recognition is granted, whether the on-device model for the recognition \
            locale is installed, and where exports and cached transcripts go. Reads no \
            audio.

            Call it first when setting the server up, and whenever another tool fails: it \
            lists every library path that was tried and what each one answered.
            """,
        inputSchema: object(properties: [:]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    static func list(_ configuration: Configuration) -> Tool {
        Tool(
            name: listName,
            title: "List recordings",
            description: """
                Lists recordings, newest first (ties by id), \(configuration.listLimit) to a \
                page, one line each with id, name, date, duration and folder. With no \
                argument it returns the newest page. When more match than the page holds, \
                the first lines of the result say how many there are and the offset to \
                pass for the next page; limit goes up to \(Configuration.listLimitRange.upperBound). \
                A name longer than \(Configuration.listNameWidth) characters is clipped, \
                and the first lines say so: recording_get reads it whole. from_date and \
                to_date bound the range, both inclusive: to_date=2026-08-12 includes the \
                whole of that day. A library too large to walk in \
                \(Configuration.scanTime.components.seconds) seconds or past \
                \(Configuration.scanLimit) matches is only partly scanned, and the first \
                lines say so: narrow with from_date, to_date, folder or name_contains.

                Always list before recording_get, recording_transcribe or \
                recording_export — ids come from here. Filters mirror what the files \
                themselves carry; there is no search over spoken words, because that would \
                mean transcribing the whole library.

                Note on folders: Voice Memos keeps its in-app folders in its own database, \
                not on disk, so 'folder' is the sub-folder under the library root and reads \
                as "(root)" for a library that has none.
                """,
            inputSchema: object(properties: [
                "name_contains": string("Optional text to match against the recording's file name."),
                "folder": string(
                    "Optional sub-folder under the library root. Omit to list every folder."),
                "from_date": string("Earliest recording time to include. \(dateHelp)"),
                "to_date": string(
                    "Latest recording time to include, inclusive at the precision written. \(dateHelp)"
                ),
                "limit": integer(
                    "Maximum number of recordings in one page.",
                    range: Configuration.listLimitRange, default: configuration.listLimit),
                "offset": integer(
                    """
                    Number of recordings to skip. A result that does not hold every match \
                    says, in its first lines, the offset to pass for the next page.
                    """, range: Configuration.offsetRange, default: 0),
            ]),
            annotations: .init(
                readOnlyHint: true, destructiveHint: false, idempotentHint: true,
                openWorldHint: false)
        )
    }

    static let get = Tool(
        name: getName,
        title: "Full recording records",
        description: """
            Returns everything stored about one to \(Configuration.maximumGetIDs) recordings: \
            name (whole), file name, full path, folder, creation and modification dates, \
            duration, size and file type. No audio and no transcript — use \
            recording_transcribe for the words.

            Accepts several ids at once so a batch costs one call rather than ten. More \
            than \(Configuration.maximumGetIDs) ids is refused: split the list.
            """,
        inputSchema: object(
            properties: [
                "ids": stringArray(
                    "One to \(Configuration.maximumGetIDs) identifiers. \(idHelp)",
                    count: Configuration.getIDsRange)
            ],
            required: ["ids"]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    static func transcribe(_ configuration: Configuration) -> Tool {
        let count = configuration.maximumTranscribeCount
        return Tool(
            name: transcribeName,
            title: "Transcribe recordings",
            description: """
                Transcribes one to \(count) recordings to text with Apple's Speech \
                framework (SpeechAnalyzer/SpeechTranscriber): recognition is on-device \
                only, so the audio never leaves this Mac. Needs the Speech Recognition \
                permission, which the other tools do not.

                Each transcript is returned through a window: with no argument, about \
                \(Configuration.defaultMaxCharacters) characters shared among the ids asked \
                for. When a transcript is longer, the first lines of the result say so and \
                give the character_offset that continues it; to read the rest of one, call \
                again with only its id (it is then served from the cache). max_characters \
                (up to \(Configuration.maxCharactersRange.upperBound)) sets the window of \
                each transcript, and a window that would not fit the answer is made \
                smaller, as the first lines say.

                Recognition runs well faster than the length of the audio, and a locale's \
                on-device model downloads the first time it is used, which can take a while. \
                A call that reaches its time limit (\(Configuration.transcribeTimeout.components.seconds) \
                seconds) returns the transcripts finished so far, says so, and lists the \
                recordings not reached; ask for those again, since finished ones are cached. \
                Ask for the recordings that are actually needed rather than a whole listing.

                The text is what the recogniser heard, punctuation included and nothing \
                else: no summary, no speaker labels, no cleanup.
                """,
            inputSchema: object(
                properties: [
                    "ids": stringArray(
                        "One to \(count) identifiers. \(idHelp)",
                        count: 1...count),
                    "locale": string(
                        """
                        Optional recognition locale such as "en-US" or "es-ES". Omit to use \
                        the one this server is configured with. Its on-device model \
                        downloads automatically if not already installed.
                        """),
                    "character_offset": integer(
                        """
                        Number of characters of each transcript to skip. A result that does \
                        not hold all of a transcript says, in its first lines, the value to \
                        pass for the rest; pass it with only that recording's id.
                        """, range: Configuration.offsetRange, default: 0),
                    "max_characters": integer(
                        """
                        The most characters of each transcript to return. Without it, \
                        \(Configuration.defaultMaxCharacters) divided by the number of ids.
                        """, range: Configuration.maxCharactersRange),
                ],
                required: ["ids"]),
            annotations: .init(
                readOnlyHint: true, destructiveHint: false, idempotentHint: true,
                openWorldHint: false)
        )
    }

    static func export(_ configuration: Configuration) -> Tool {
        let root = configuration.exportRoot ?? "(not configured — every export is refused)"
        return Tool(
            name: exportName,
            title: "Export a recording's audio",
            description: """
                Copies a recording's audio file into the configured export folder. The \
                original is never moved, renamed or touched.

                Export folder: \(root)

                'destination' is relative to that folder and cannot climb out of it. An \
                existing file is never overwritten.
                """,
            inputSchema: object(
                properties: [
                    "id": string("Identifier of the recording to copy. \(idHelp)"),
                    "destination": string(
                        """
                        Path relative to the export folder, such as "meeting.m4a" or \
                        "2026/meeting.m4a". Missing sub-folders are created. Omit to reuse \
                        the recording's own file name.
                        """),
                ],
                required: ["id"]),
            annotations: .init(
                readOnlyHint: false, destructiveHint: false, idempotentHint: false,
                openWorldHint: false)
        )
    }
}
