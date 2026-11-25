import Foundation

public enum VoiceMemosMCPServer {

    public static let name = "apple-voicememos-mcp"
    public static let version = "2.0.0"

    /// Returned from `initialize`. It carries what per-tool descriptions cannot state
    /// once: the id workflow, what transcription costs, and where policy actually lives.
    public static let instructions = """
        Access to voice recordings on this Mac, and on-device transcription of them.

        Voice Memos has no framework and is not scriptable, and none of its Shortcuts \
        actions hands back the audio of a recording. This server therefore reads the \
        recordings as files. That means either Full Disk Access, which reaches the Voice \
        Memos library itself, or an ordinary folder of audio nominated in the extension's \
        settings. recordings_status says which is in force.

        Workflow: recordings_list first, then use the ids it returns. An id is the file's \
        path relative to the library root, so renaming or moving a recording changes it — \
        do not reuse one from an earlier conversation without listing again.

        What a call returns, and the rest. recordings_list gives one page of recordings, \
        newest first (the extension's page-size setting, at most \
        \(Configuration.listLimitRange.upperBound) with limit); recording_get takes up to \
        \(Configuration.maximumGetIDs) ids; recording_transcribe gives each transcript \
        through a window of about \(Configuration.defaultMaxCharacters) characters shared \
        among the ids. When a result holds less than exists, its first lines say how much \
        exists and the exact argument that returns the rest: offset for the next page of a \
        listing, character_offset (with only that id) for the rest of a transcript. Read \
        those lines before the data. A number outside its range is moved into it and the \
        first lines say which value was used; an argument a tool does not list is refused.

        Dates accept three forms: 2026-08-12 (that whole day), 2026-08-12T09:00 (local \
        time), or 2026-08-12T09:00:00+02:00 (explicit offset). from_date and to_date are \
        both inclusive, to_date at the precision written: to_date=2026-08-12 includes that \
        whole day.

        recording_transcribe runs well faster than the length of the audio once a \
        locale's on-device model is downloaded, and there is a cap on how many recordings \
        one call may take. A call that reaches its \
        \(Configuration.transcribeTimeout.components.seconds)-second limit returns the \
        transcripts finished so far, says so and names the recordings not reached; asking \
        again costs only those, since finished transcripts are cached. Other calls stop at \
        \(Configuration.timeout.components.seconds) seconds. Transcribe what is actually \
        needed. The audio never leaves this Mac — this server's speech framework has no \
        server-backed path at all, and a locale's model downloads automatically the first \
        time that locale is used.

        There is no search over spoken words. Finding a phrase means transcribing the \
        candidates and reading them; the server will not transcribe a library to answer a \
        question.

        This server never modifies a recording. It cannot rename, move or delete one, and \
        recording_export only ever writes a copy into a folder chosen in the extension's \
        settings.

        What may be used at any moment is decided by the permission switches in the \
        client, not by this code.
        """

    /// The store is a parameter so the whole server can be driven by a double. Nothing
    /// in this function opens a file by itself.
    public static func run(
        store: (any RecordingStore)? = nil,
        configuration: Configuration = Configuration()
    ) async {
        let tools = VoiceMemosTools(
            store: store ?? SystemRecordingStore(configuration: configuration),
            configuration: configuration)
        Diagnostics.started(version: version)
        await serveStandardStreams(handler: handler(tools: tools, configuration: configuration))
    }

    public static func handler(
        tools: VoiceMemosTools, configuration: Configuration = Configuration()
    ) -> MCPHandler {
        MCPHandler(
            name: name, version: version, instructions: instructions,
            catalog: ToolCatalog.all(configuration), tools: tools)
    }
}
