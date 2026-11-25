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
                ("Recordings per page", "\(configuration.listLimit) by default, at most \(Configuration.listLimitRange.upperBound)"),
                ("Transcriptions per call", "at most \(configuration.maximumTranscribeCount)"),
                ("Time limit per call", "\(Configuration.timeout.components.seconds) seconds, \(Configuration.transcribeTimeout.components.seconds) for transcription"),
                ("Binary", binaryPath),
            ]))

            Recording library, in the order the paths are tried:
            \(libraryRows)

            \(selected == nil
                ? "No library is reachable. recordings_list and every id-taking tool will fail until one is."
                : "Reading from the marked folder.")
            """
    }

    /// `text` cut to `width` characters with an ellipsis, for a field a row holds only the
    /// start of.
    static func clip(_ text: String, to width: Int) -> String {
        text.count > width ? String(text.prefix(width - 1)) + "…" : text
    }

    /// The header and one line per recording. What the page leaves out is announced by the
    /// caller, before this text, with `Notice`.
    public func listing(
        _ shown: [RecordingSummary], total: Int, libraryPath: String, from: ParsedDate?,
        to: ParsedDate?
    ) -> String {
        let range: String
        switch (from, to) {
        case (nil, nil): range = "whole library"
        case (let start?, nil): range = "from \(echo(start)) onwards"
        case (nil, let end?): range = "up to \(echo(end))"
        case (let start?, let end?): range = "\(echo(start)) → \(echo(end))"
        }
        // The resolved range and zone are echoed so a model can catch its own off-by-one-day.
        let header =
            "Library: \(libraryPath)\n\(total) recording\(total == 1 ? "" : "s") · \(range) · "
            + "\(calendar.timeZone.identifier) · newest first, then by id"

        guard total > 0 else { return header + "\nNo recordings match." }
        guard !shown.isEmpty else { return header + "\n(nothing at this offset)" }

        let names = shown.map { Self.clip($0.name, to: Configuration.listNameWidth) }
        let idWidth = shown.map(\.id.count).max() ?? 0
        let nameWidth = names.map(\.count).max() ?? 0
        let lines = zip(shown, names).map { recording, name in
            "  \(Self.pad(recording.id, to: idWidth))  \(Self.pad(name, to: nameWidth))  "
                + "\(timestamp(recording.created))  \(Self.duration(recording.duration))  "
                + Self.folder(recording.folder)
        }
        return header + "\nid · name · recorded · duration · folder\n\n" + lines.joined(separator: "\n")
    }

    /// A filter bound printed back in the shape it arrived in, so the echoed range can be
    /// pasted straight into the next call.
    func echo(_ bound: ParsedDate) -> String {
        DateParsing.roundTrip(bound.date, isDateOnly: bound.isDateOnly, calendar: calendar)
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
        let notFound = "Not found:\n\(ToolError.listed(missing))"
        return recordings.isEmpty ? notFound : "\(blocks)\n\n\(notFound)"
    }

    /// One block per transcript, each headed by the recording it came from so a batch
    /// cannot be misattributed, and each transcript cut to the window asked for. The
    /// windows' notices come back separately because they go before all the data, not
    /// beside each block.
    ///
    /// The transcript is printed flush left under its header rather than indented, because
    /// indentation would silently change the content the caller asked for.
    public func transcripts(
        _ transcripts: [(recording: RecordingDetail, transcript: Transcript, wasCached: Bool)],
        characterOffset: Int, maxCharacters: Int,
        missing: [String], unreached: [String], failures: [(id: String, reason: String)]
    ) -> (text: String, notices: [String]) {
        var notices: [String] = []
        var sections = transcripts.map { entry -> String in
            let provenance = entry.wasCached ? "from cache" : "transcribed on-device"
            var section = """
                \(Self.clip(entry.recording.name, to: Configuration.listNameWidth)) · \(entry.recording.id)
                \(Self.duration(entry.recording.duration)) · \(entry.transcript.localeIdentifier) · \(provenance)

                """
            guard !entry.transcript.text.isEmpty else {
                return section + "(no speech recognised)"
            }
            let window = ToolStandard.window(
                of: entry.transcript.text, characterOffset: characterOffset,
                maxCharacters: maxCharacters,
                label: transcripts.count > 1
                    ? "id=\(entry.recording.id) (ask for it alone)" : "id=\(entry.recording.id)")
            if let notice = window.notice { notices.append(notice) }
            section += window.text
            return section
        }

        if transcripts.contains(where: { $0.recording.name.count > Configuration.listNameWidth }) {
            notices.append(
                Notice.clipped(
                    field: "Name", width: Configuration.listNameWidth, tool: ToolCatalog.getName))
        }
        if !missing.isEmpty {
            sections.append("Not found:\n\(ToolError.listed(missing))")
        }
        if !unreached.isEmpty {
            sections.append(
                "Not transcribed before the time limit:\n"
                    + ToolError.listed(unreached, shown: unreached.count, whole: true))
        }
        for failure in failures.prefix(5) {
            sections.append(
                "Failed: \(ToolStandard.echo(failure.id)) — \(failure.reason.prefix(300))")
        }
        if failures.count > 5 { sections.append("and \(failures.count - 5) more failed") }
        return (sections.joined(separator: "\n\n———\n\n"), notices)
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
        case .voiceMemosSharedGroupContainer: return "Voice Memos shared Group Container"
        case .voiceMemosContainer: return "Voice Memos container"
        case .legacyApplicationSupport: return "pre-sandbox Application Support"
        }
    }
}
