import Foundation

/// Plain-text rendering of every tool result.
public struct Format: Sendable {
    let calendar: Calendar

    public init(calendar: Calendar) {
        self.calendar = calendar
    }

    // MARK: Helpers

    static func pad(_ text: String, to width: Int) -> String {
        let shortfall = width - text.count
        return shortfall > 0 ? text + String(repeating: " ", count: shortfall) : text
    }

    static func block(_ rows: [(String, String?)]) -> String {
        let present = rows.compactMap { label, value -> (String, String)? in
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return (label, value)
        }
        guard let width = present.map(\.0.count).max() else { return "" }
        let indent = String(repeating: " ", count: width + 3)
        return present.map { label, value in
            let wrapped = value.split(separator: "\n", omittingEmptySubsequences: false)
                .joined(separator: "\n" + indent)
            return "  \(pad(label, to: width)) \(wrapped)"
        }.joined(separator: "\n")
    }

    /// `1:23:45` or `4:07`. Hours only appear when there are hours, so the common case
    /// stays as short as it reads out loud.
    static func duration(_ seconds: TimeInterval) -> String {
        let whole = max(Int(seconds.rounded()), 0)
        let hours = whole / 3600
        let minutes = (whole % 3600) / 60
        let remainder = whole % 60
        guard hours > 0 else { return String(format: "%d:%02d", minutes, remainder) }
        return String(format: "%d:%02d:%02d", hours, minutes, remainder)
    }

    /// Decimal megabytes, matching what Finder reports, so the two do not appear to
    /// disagree about the same file.
    static func size(_ bytes: Int) -> String {
        guard bytes >= 1_000_000 else { return "\(max(bytes, 0) / 1000) kB" }
        return String(format: "%.1f MB", Double(bytes) / 1_000_000)
    }

    /// `""` is the library root and has no name of its own to print.
    static func folder(_ folder: String) -> String {
        folder.isEmpty ? "(root)" : folder
    }

    func timestamp(_ date: Date) -> String {
        "\(DateParsing.dayWithYear(date, calendar: calendar)) \(DateParsing.time(date, calendar: calendar))"
    }

    // MARK: Tools

    public func status(
        _ authorization: SpeechAuthorization,
        onDevice: OnDeviceSupport,
        libraries: [LibraryLocation],
        binaryPath: String,
        configuration: Configuration,
        cache: TranscriptCache.Health
    ) -> String {
        let selected = libraries.first(where: \.isUsable)

        let libraryRows = libraries.map { location -> String in
            let verdict =
                !location.exists
                ? "missing"
                : (location.isReadable ? "readable" : "unreadable (needs Full Disk Access)")
            let marker = location.path == selected?.path ? "→" : " "
            return "  \(marker) \(location.path)\n      \(location.origin.label) · \(verdict)"
        }.joined(separator: "\n")

        let onDeviceLine: String
        if !onDevice.recognizerExists {
            onDeviceLine = "\(onDevice.localeIdentifier) — no recogniser on this Mac"
        } else if !onDevice.supportsOnDevice {
            onDeviceLine = "\(onDevice.localeIdentifier) — on-device model NOT installed"
        } else {
            onDeviceLine = "\(onDevice.localeIdentifier) — on-device model installed"
        }

        let cacheLine =
            cache.isWritable
            ? "\(cache.path) · \(cache.entryCount) transcript(s)"
            : "\(cache.path) · NOT WRITABLE — transcripts will not be kept"

        return """
            Voice Memos server status

            \(Self.block([
                ("Speech recognition", ToolError.authorizationMessage(authorization)
                    .split(separator: "\n").first.map(String.init)),
                ("Recognition locale", onDeviceLine),
                ("Export folder", configuration.exportRoot ?? "not configured (recording_export is refused)"),
                ("Transcript cache", cacheLine),
                ("Recordings per page", "\(configuration.listLimit) by default"),
                ("Transcriptions per call", "at most \(configuration.maximumTranscribeCount)"),
                ("Binary", binaryPath),
            ]))

            Recording library, in the order the paths are tried:
            \(libraryRows)

            \(selected == nil
                ? "No library is reachable. recordings_list and every id-taking tool will fail until one is."
                : "Reading from the marked folder.")
            """
    }

    public func listing(_ page: RecordingPage, offset: Int) -> String {
        guard !page.results.isEmpty else {
            return page.total == 0
                ? "No recordings match. Library: \(page.libraryPath)"
                : "No recordings on this page; \(page.total) match in total. Lower 'offset'."
        }

        let idWidth = page.results.map(\.id.count).max() ?? 0
        let nameWidth = page.results.map(\.name.count).max() ?? 0
        let lines = page.results.map { recording in
            "  \(Self.pad(recording.id, to: idWidth))  \(Self.pad(recording.name, to: nameWidth))  "
                + "\(timestamp(recording.created))  \(Self.duration(recording.duration))  "
                + Self.folder(recording.folder)
        }

        let shown = offset + page.results.count
        let footer =
            shown < page.total
            ? "\nShowing \(offset + 1)–\(shown) of \(page.total). Page with 'offset'."
            : "\n\(page.total) recording(s)."

        return """
            Library: \(page.libraryPath)
            id · name · recorded · duration · folder

            \(lines.joined(separator: "\n"))
            \(footer)
            """
    }

    public func details(_ recordings: [RecordingDetail], missing: [String]) -> String {
        let blocks = recordings.map { recording in
            Self.block([
                ("id", recording.id),
                ("name", recording.name),
                ("file", recording.fileName),
                ("path", recording.path),
                ("folder", Self.folder(recording.folder)),
                ("recorded", timestamp(recording.created)),
                ("modified", timestamp(recording.modified)),
                ("duration", Self.duration(recording.duration)),
                ("size", Self.size(recording.byteSize)),
                ("type", recording.typeIdentifier),
            ])
        }.joined(separator: "\n\n")

        guard !missing.isEmpty else { return blocks }
        let notFound = "Not found: \(missing.joined(separator: ", "))"
        return recordings.isEmpty ? notFound : "\(blocks)\n\n\(notFound)"
    }

    /// One block per transcript, each headed by the recording it came from so a batch
    /// cannot be misattributed.
    public func transcripts(
        _ transcripts: [(recording: RecordingDetail, transcript: Transcript, wasCached: Bool)],
        missing: [String],
        failures: [(id: String, reason: String)]
    ) -> String {
        var sections = transcripts.map { entry -> String in
            let provenance = entry.wasCached ? "from cache" : "transcribed on-device"
            return """
                \(entry.recording.name) · \(entry.recording.id)
                \(Self.duration(entry.recording.duration)) · \(entry.transcript.localeIdentifier) · \(provenance)

                \(entry.transcript.text.isEmpty ? "(no speech recognised)" : entry.transcript.text)
                """
        }

        if !missing.isEmpty {
            sections.append("Not found: \(missing.joined(separator: ", "))")
        }
        for failure in failures {
            sections.append("Failed: \(failure.id) — \(failure.reason)")
        }
        return sections.joined(separator: "\n\n———\n\n")
    }

    public func exported(_ file: ExportedFile) -> String {
        """
        Copied the audio. The original is untouched.

        \(Self.block([
            ("recording", file.recordingID),
            ("from", file.sourcePath),
            ("to", file.destinationPath),
            ("size", Self.size(file.byteSize)),
        ]))
        """
    }
}

extension LibraryOrigin {
    var label: String {
        switch self {
        case .configured: return "configured in the extension settings"
        case .voiceMemosContainer: return "Voice Memos container"
        case .legacyApplicationSupport: return "pre-sandbox Application Support"
        }
    }
}
