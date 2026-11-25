import Foundation

public enum ToolError: Error, Equatable {
    case notAuthorized(SpeechAuthorization)
    case onDeviceUnavailable(OnDeviceSupport)
    case libraryUnreachable([LibraryLocation])
    case missingArgument(String)
    case badArgument(name: String, reason: String)
    case badDate(argument: String, value: String)
    case endBeforeStart
    case tooManyIDs(asked: Int, maximum: Int, adjustable: Bool)
    case notFound(ids: [String])
    case exportRootNotConfigured
    case destinationOutsideRoot(destination: String, root: String)
    case destinationExists(String)
    case transcriptionFailed(id: String, detail: String)
    case storeFailure(String)
    case unknownTool(String)
    case unknownArguments([String], allowed: [String])
    case timedOut(seconds: Int, mayHaveWritten: Bool)
    case libraryScanTimedOut

    public var message: String {
        switch self {
        case .notAuthorized(let status):
            return Self.authorizationMessage(status)

        case .onDeviceUnavailable(let support):
            return Self.onDeviceMessage(support)

        case .libraryUnreachable(let candidates):
            return Self.libraryMessage(candidates)

        case .missingArgument(let name):
            return "Missing required argument '\(name)'."

        case .badArgument(let name, let reason):
            return "Argument '\(name)' is not valid: \(reason)"

        case .unknownTool(let name):
            return "'\(ToolStandard.echo(name))' is not a tool of this server."

        case .unknownArguments(let names, let allowed):
            let shown = names.prefix(3).map { "'\(ToolStandard.echo($0))'" }.joined(separator: ", ")
            let more = names.count > 3 ? " and \(names.count - 3) more" : ""
            let list = allowed.isEmpty ? "none" : allowed.joined(separator: ", ")
            return "Not an argument of this tool: \(shown)\(more). Allowed: \(list)."

        case .endBeforeStart:
            return "to_date is before from_date. A date range cannot end before it begins."

        case .timedOut(let seconds, let mayHaveWritten):
            guard mayHaveWritten else {
                return """
                    The call did not finish within \(seconds) seconds and was abandoned. This \
                    call only reads, so nothing was changed.

                    Try again with fewer ids, or with a narrower listing: a smaller limit, or \
                    from_date, to_date, folder or name_contains.
                    """
            }
            return """
                The copy did not finish within \(seconds) seconds and was abandoned, so the \
                file may still have been written, whole or in part, in the export folder.

                Look for it there before asking again: an existing file is never overwritten, \
                so pass another destination if it is there.
                """

        case .libraryScanTimedOut:
            return """
                Walking the recording library took too long to find every id that was asked \
                for, so none could be told apart from a recording that does not exist.

                Ask for fewer ids, or list the recordings first with from_date and to_date \
                to confirm the ids.
                """

        case .badDate(let argument, let value):
            return """
                Argument '\(argument)' is not a date this server accepts: '\(ToolStandard.echo(value))'

                Use one of:
                \(DateParsing.acceptedForms)
                """

        case .tooManyIDs(let asked, let maximum, let adjustable):
            let remedy =
                adjustable
                ? "Split the list, or raise the limit in Claude Desktop → Settings → Extensions."
                : "Split the list and call again."
            return """
                \(asked) ids were given; this tool takes at most \(maximum) per call.

                \(remedy)
                """

        case .notFound(let ids):
            return """
                No recording matches:

                \(Self.listed(ids))

                An id is the file's path relative to the library root, exactly as
                recordings_list prints it. Renaming or moving a recording changes its id,
                so list again rather than reusing one from an earlier conversation.
                """

        case .exportRootNotConfigured:
            return """
                No export folder is configured, so there is nowhere this server may write.

                Set "Folder Claude may export recordings into" in
                Claude Desktop → Settings → Extensions → Apple Voice Memos.

                This is deliberate: without a folder chosen by hand, an export tool would
                be able to write anywhere the user account can.
                """

        case .destinationOutsideRoot(let destination, let root):
            return """
                '\(ToolStandard.echo(destination))' is outside the configured export folder.

                Export folder: \(root)

                Everything written by this server has to land inside that folder. Pass a
                relative path such as "meeting.m4a" or "2026/meeting.m4a" instead.
                """

        case .destinationExists(let path):
            return """
                '\(ToolStandard.echo(path))' already exists and this server does not overwrite files.

                Pass a different name. Nothing was written.
                """

        case .transcriptionFailed(let id, let detail):
            return """
                Transcription of '\(ToolStandard.echo(id))' failed: \(detail.prefix(300))

                Speech recognition gives up on silence and on audio it cannot decode. A
                missing on-device model would not surface here at all: this server
                downloads one itself before recognition ever starts, so by this point the
                model was never the problem.
                """

        case .storeFailure(let detail):
            return "The recording library returned an error: \(detail.prefix(300))"
        }
    }

    /// Ids as an error or a result may repeat them: each clipped, a few shown, the rest
    /// counted.
    /// `whole` is for ids that are this server's own, which a retry needs exactly; an id the
    /// caller wrote is clipped.
    static func listed(_ ids: [String], shown: Int = 5, whole: Bool = false) -> String {
        let lines = ids.prefix(shown).map { "  \(whole ? $0 : ToolStandard.echo($0))" }
        let more = ids.count > shown ? ["  and \(ids.count - shown) more"] : []
        return (lines + more).joined(separator: "\n")
    }

    static func authorizationMessage(_ status: SpeechAuthorization) -> String {
        switch status {
        case .authorized:
            return "Speech recognition access granted."

        case .notDetermined:
            return """
                No speech recognition access: macOS has not asked yet.

                Restart Claude Desktop and call this tool again; the consent dialog should
                appear.

                If it does not, check that the binary named under "Binary" in
                recordings_status still carries its embedded Info.plist:
                  otool -P <that path> | grep NSSpeechRecognition
                """

        case .denied:
            return """
                No speech recognition access: it is denied.

                Grant it in:
                  System Settings → Privacy & Security → Speech Recognition → enable
                  "apple-voicememos-mcp"
                  (Spanish UI: Ajustes del Sistema → Privacidad y seguridad →
                  Reconocimiento de voz)

                Then restart Claude Desktop: the permission is resolved when the process
                starts.

                Listing and exporting recordings do not need this grant — only
                recording_transcribe does.
                """

        case .restricted:
            return """
                No speech recognition access: restricted by a system policy (parental
                controls or a device management profile).

                This cannot be granted from System Settings; the policy imposing it has to
                be lifted.
                """
        }
    }

    static func onDeviceMessage(_ support: OnDeviceSupport) -> String {
        guard support.recognizerExists else {
            return """
                Speech recognition has no recogniser for '\(ToolStandard.echo(support.localeIdentifier))'.

                Pass a 'locale' this Mac supports (for example "en-US" or "es-ES"), or set
                a default in Claude Desktop → Settings → Extensions.
                """
        }
        return """
            '\(ToolStandard.echo(support.localeIdentifier))' has a recogniser, but this server could not
            arrange to install its on-device model, and it never sends audio to Apple's
            servers as a fallback.

            recording_transcribe normally downloads a missing model itself the first time
            it is needed — this message means that request itself could not be made.
            Check this Mac has a network connection for the one-time download, then try
            again.
            """
    }

    static func libraryMessage(_ candidates: [LibraryLocation]) -> String {
        let rows =
            candidates
            .map { location in
                let verdict =
                    !location.exists
                    ? "does not exist"
                    : (location.isReadable ? "readable" : "exists but cannot be listed")
                return "  \(location.path)\n    \(verdict)"
            }
            .joined(separator: "\n")

        return """
            No readable recording library was found. Paths tried:

            \(rows)

            Voice Memos keeps its recordings inside its own sandbox container, which is
            protected by Full Disk Access. Full Disk Access has no consent dialog and no
            Info.plist key — it can only be granted by hand:

              System Settings → Privacy & Security → Full Disk Access → + →
              add the server binary, then restart Claude Desktop
              (Spanish UI: Ajustes del Sistema → Privacidad y seguridad →
              Acceso a disco completo)

            The alternative, which needs no grant at all, is to point this server at an
            ordinary folder of audio files: set "Recording library folder" in
            Claude Desktop → Settings → Extensions → Apple Voice Memos.
            """
    }
}
