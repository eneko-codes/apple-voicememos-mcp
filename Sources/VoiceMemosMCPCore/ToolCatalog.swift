import Foundation
import MCP

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

    private static func stringArray(_ description: String) -> Value {
        .object([
            "type": .string("array"),
            "items": .object(["type": .string("string")]),
            "description": .string(description),
        ])
    }

    private static func integer(_ description: String, minimum: Int, maximum: Int, default def: Int)
        -> Value
    {
        .object([
            "type": .string("integer"), "description": .string(description),
            "minimum": .int(minimum), "maximum": .int(maximum), "default": .int(def),
        ])
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
                Lists recordings with their id, name, date, duration and folder, newest \
                first. Returns one line each and says how many matches were withheld.

                Always list before recording_get, recording_transcribe or \
                recording_export — ids come from here. Filters mirror what the files \
                themselves carry; there is no search over spoken words, because that would \
                mean transcribing the whole library.

                Note on folders: Voice Memos keeps its in-app folders in its own database, \
                not on disk, so 'folder' is the sub-folder under the library root and reads \
                as "(root)" for a library that has none.
                """,
            inputSchema: object(properties: [
                "name_contains": string("Optional text to match against the recording name."),
                "folder": string(
                    "Optional sub-folder under the library root. Omit to list every folder."),
                "created_after": string("Only recordings made at or after this. \(dateHelp)"),
                "created_before": string(
                    "Only recordings made before this. A plain day includes the whole of that day. \(dateHelp)"
                ),
                "limit": integer(
                    "Maximum number of recordings to return.",
                    minimum: Configuration.listLimitRange.lowerBound,
                    maximum: Configuration.listLimitRange.upperBound,
                    default: configuration.listLimit),
                "offset": integer(
                    "Skip this many matches; use it to page.",
                    minimum: Configuration.offsetRange.lowerBound,
                    maximum: Configuration.offsetRange.upperBound, default: 0),
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
            Returns everything stored about one or more recordings: name, file name, full \
            path, folder, creation and modification dates, duration, size and file type. \
            No audio and no transcript — use recording_transcribe for the words.

            Accepts several ids at once so a batch costs one call rather than ten.
            """,
        inputSchema: object(
            properties: ["ids": stringArray("One or more identifiers. \(idHelp)")],
            required: ["ids"]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    static func transcribe(_ configuration: Configuration) -> Tool {
        Tool(
            name: transcribeName,
            title: "Transcribe recordings",
            description: """
                Transcribes recordings to text with Apple's Speech framework, forced to \
                on-device recognition: the audio never leaves this Mac and no network \
                request is made. Needs the Speech Recognition permission, which the other \
                tools do not.

                SLOW — roughly the length of the audio itself, and nothing is reported \
                until the whole batch is done. At most \
                \(configuration.maximumTranscribeCount) recordings per call. Ask for the \
                ones that are actually needed rather than a whole listing.

                The text is what the recogniser heard, punctuation included and nothing \
                else: no summary, no speaker labels, no cleanup.
                """,
            inputSchema: object(
                properties: [
                    "ids": stringArray(
                        "One to \(configuration.maximumTranscribeCount) identifiers. \(idHelp)"),
                    "locale": string(
                        """
                        Optional recognition locale such as "en-US" or "es-ES". Omit to use \
                        the one this server is configured with. A locale whose on-device \
                        model is not installed is refused rather than sent to Apple.
                        """),
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
