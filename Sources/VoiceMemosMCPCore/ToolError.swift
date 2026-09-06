import Foundation

public enum ToolError: Error, Equatable {
    case notAuthorized(SpeechAuthorization)
    case onDeviceUnavailable(OnDeviceSupport)
    case libraryUnreachable([LibraryLocation])
    case missingArgument(String)
    case badArgument(name: String, reason: String)
    case badDate(argument: String, value: String)
    case tooManyIDs(asked: Int, maximum: Int)
    case notFound(ids: [String])
    case exportRootNotConfigured
    case destinationOutsideRoot(destination: String, root: String)
    case destinationExists(String)
    case transcriptionFailed(id: String, detail: String)
    case storeFailure(String)

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

        case .badDate(let argument, let value):
            return """
                Argument '\(argument)' is not a date this server accepts: '\(value)'

                Use one of:
                \(DateParsing.acceptedForms)
                """

        case .tooManyIDs(let asked, let maximum):
            return """
                \(asked) recordings were asked for at once; the maximum is \(maximum).

                Recognition itself is fast, but a locale's on-device model downloads on
                first use and a large batch returns as one wall of text. Split the list, or
                raise the limit in Claude Desktop → Settings → Extensions.
                """

        case .notFound(let ids):
            let list = ids.map { "  \($0)" }.joined(separator: "\n")
            return """
                No recording matches:

                \(list)

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
                '\(destination)' is outside the configured export folder.

                Export folder: \(root)

                Everything written by this server has to land inside that folder. Pass a
                relative path such as "meeting.m4a" or "2026/meeting.m4a" instead.
                """

        case .destinationExists(let path):
            return """
                '\(path)' already exists and this server does not overwrite files.

                Pass a different name. Nothing was written.
                """

        case .transcriptionFailed(let id, let detail):
            return """
                Transcription of '\(id)' failed: \(detail)

                Speech recognition gives up on silence, on audio it cannot decode, and on
                a locale whose on-device model is missing. recordings_status reports which
                of those applies.
                """

        case .storeFailure(let detail):
            return "The recording library returned an error: \(detail)"
        }
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

                If it does not, check that the binary still carries its embedded Info.plist:
                  otool -P .build/release/apple-voicememos-mcp | grep NSSpeechRecognition
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
                Speech recognition has no recogniser for '\(support.localeIdentifier)'.

                Pass a 'locale' this Mac supports (for example "en-US" or "es-ES"), or set
                a default in Claude Desktop → Settings → Extensions.
                """
        }
        return """
            '\(support.localeIdentifier)' has a recogniser, but this server could not
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
