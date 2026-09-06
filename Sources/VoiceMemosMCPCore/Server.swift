import Foundation
import MCP

public enum VoiceMemosMCPServer {

    public static let name = "apple-voicememos-mcp"
    public static let version = "1.0.3"

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

        Dates accept three forms: 2026-08-12 (that whole day), 2026-08-12T09:00 (local \
        time), or 2026-08-12T09:00:00+02:00 (explicit offset).

        recording_transcribe is SLOW: on-device recognition takes roughly as long as the \
        audio, nothing is reported until the batch finishes, and there is a cap on how \
        many recordings one call may take. Transcribe what is actually needed. The audio \
        never leaves this Mac — on-device recognition is forced, and a locale whose local \
        model is missing is refused rather than sent to Apple.

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
    ) async throws {
        let tools = VoiceMemosTools(
            store: store ?? SystemRecordingStore(configuration: configuration),
            configuration: configuration)
        let server = Server(
            name: name,
            version: version,
            instructions: instructions,
            capabilities: .init(tools: .init(listChanged: false))
        )

        await server.withMethodHandler(ListTools.self) { _ in .init(tools: ToolCatalog.all(configuration)) }
        await server.withMethodHandler(CallTool.self) { await tools.handle($0) }

        // The default StdioTransport logger is a no-op handler. Leave it that way: a
        // logger writing to stdout would interleave with the JSON-RPC stream and break
        // every response after the first log line.
        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    }
}
