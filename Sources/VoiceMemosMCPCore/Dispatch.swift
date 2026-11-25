import Foundation
import Synchronization

/// Routes a `tools/call` to the store and renders the answer.
///
/// Never touches the filesystem or the Speech framework directly — everything goes
/// through `RecordingStore`, which is what lets the tests drive every branch below
/// against an in-memory double with no recordings and no consent dialog. The one
/// exception is the export path check, which is policy rather than access: it decides
/// where a copy may land, and it has to be testable.
public struct VoiceMemosTools: ToolHandler {
    private let store: any RecordingStore
    private let calendar: Calendar
    private let configuration: Configuration
    private let cache: TranscriptCache
    private let format: Format
    private let timeout: Duration
    private let transcribeTimeout: Duration
    /// Injected so a transcript's timestamp is fixed in the tests instead of depending on
    /// when the suite happens to run.
    private let now: @Sendable () -> Date

    /// Fixed location for the on-disk transcript cache, not a setting: a cache miss is
    /// always safe (it just means transcribing again), so there is nothing here worth
    /// asking the owner to decide, and scratch state like this belongs under `$TMPDIR`
    /// rather than somewhere that outlives the reasoning for keeping it.
    public static let defaultCacheDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("apple-voicememos-mcp", isDirectory: true)
        .appendingPathComponent("transcript-cache", isDirectory: true)

    public init(
        store: any RecordingStore,
        calendar: Calendar = .current,
        configuration: Configuration = Configuration(),
        cacheDirectory: URL = VoiceMemosTools.defaultCacheDirectory,
        now: @escaping @Sendable () -> Date = { Date() },
        timeout: Duration = Configuration.timeout,
        transcribeTimeout: Duration = Configuration.transcribeTimeout
    ) {
        self.timeout = timeout
        self.transcribeTimeout = transcribeTimeout
        self.store = store
        self.calendar = calendar
        self.configuration = configuration
        self.cache = TranscriptCache(directory: cacheDirectory)
        self.format = Format(calendar: calendar)
        self.now = now
    }

    public func handle(_ parameters: ToolCall) async -> ToolOutput {
        let started = ContinuousClock.now
        let limit = parameters.name == ToolCatalog.transcribeName ? transcribeTimeout : timeout
        let outcome = await Deadline.run(within: limit) {
            do {
                return Result<String, any Error>.success(try await run(parameters))
            } catch {
                return .failure(error)
            }
        }
        switch outcome {
        case .success(let text)?:
            return ToolOutput(text: text, isError: false)
        case .failure(let error)?:
            return failure(error, tool: parameters.name, since: started)
        case nil:
            return failure(
                ToolError.timedOut(
                    seconds: Int(limit.components.seconds),
                    mayHaveWritten: parameters.name == ToolCatalog.exportName),
                tool: parameters.name, since: started)
        }
    }

    private func failure(_ error: any Error, tool: String, since started: ContinuousClock.Instant)
        -> ToolOutput
    {
        Diagnostics.toolFailed(tool, error: error, since: started)
        // Only our own error types are described in full; a system error's text can quote
        // a path, and has no length of its own to rely on.
        let message =
            (error as? ToolError)?.message
            ?? ToolError.storeFailure(error.localizedDescription).message
        return ToolOutput(text: message, isError: true)
    }

    private func run(_ parameters: ToolCall) async throws -> String {
        guard ToolCatalog.all(configuration).contains(where: { $0.name == parameters.name }) else {
            throw ToolError.unknownTool(parameters.name)
        }
        let arguments = try Arguments(
            parameters.arguments, calendar: calendar,
            allowed: ToolCatalog.argumentNames(of: parameters.name, configuration: configuration))

        switch parameters.name {
        case ToolCatalog.statusName:
            return format.status(
                store.speechAuthorization(),
                onDevice: await store.onDeviceSupport(locale: configuration.localeIdentifier),
                libraries: store.libraries(),
                binaryPath: Self.binaryPath,
                configuration: configuration,
                cache: cache.health())

        case ToolCatalog.listName:
            return try await list(arguments)

        case ToolCatalog.getName:
            return try await get(arguments)

        case ToolCatalog.transcribeName:
            return try await transcribe(arguments)

        default:
            return try await export(arguments)
        }
    }

    // MARK: Tools

    /// Paged at the source: the store collects only the matches, sorts them and loads the
    /// name and duration of the page asked for, and the notice is built from the total it
    /// reports.
    private func list(_ arguments: Arguments) async throws -> String {
        var query = RecordingQuery()
        query.nameContains = try arguments.optionalString("name_contains")
        query.folder = try arguments.optionalString("folder")
        let from = try arguments.optionalDate("from_date")
        let to = try arguments.optionalDate("to_date")
        // `to_date` is inclusive at the precision written, so the store is given the first
        // instant after everything it covers.
        let end = to?.endExclusive(calendar: calendar)
        if let from, let end, end <= from.date { throw ToolError.endBeforeStart }
        query.createdAfter = from?.date
        query.createdBefore = end
        let page = try arguments.page(
            defaultLimit: configuration.listLimit, limits: Configuration.listLimitRange)
        query.limit = page.limit
        query.offset = page.offset

        let found = try await store.list(query)
        let stopped = found.scanStoppedAfter.map {
            Notice.scanStopped(
                after: $0, things: "recordings", narrowBy: "folder, name_contains, from_date or to_date")
        }

        // The page is halved when its rows are wider than any ordinary row, so the notice
        // below always describes what was rendered.
        return ToolStandard.fitting(page.limit) { size in
            let shown = Array(found.results.prefix(size))
            var notices = arguments.notices + [stopped].compactMap { $0 }
            if let position = Notice.page(
                offset: page.offset, count: shown.count, total: found.total, things: "recordings")
            {
                notices.append(position)
            }
            if shown.contains(where: { $0.name.count > Configuration.listNameWidth }) {
                notices.append(
                    Notice.clipped(
                        field: "Name", width: Configuration.listNameWidth, tool: ToolCatalog.getName))
            }
            return ToolStandard.withNotices(
                notices,
                format.listing(
                    shown, total: found.total, libraryPath: found.libraryPath, from: from, to: to))
        }
    }

    private func get(_ arguments: Arguments) async throws -> String {
        let ids = try arguments.identifiers("ids")
        guard Configuration.getIDsRange.contains(ids.count) else {
            throw ToolError.tooManyIDs(
                asked: ids.count, maximum: Configuration.maximumGetIDs, adjustable: false)
        }
        let found = try await store.fetch(ids: ids)
        let missing = Self.missing(asked: ids, found: found)
        guard !found.isEmpty else { throw ToolError.notFound(ids: missing) }
        return format.details(found, missing: missing)
    }

    private func transcribe(_ arguments: Arguments) async throws -> String {
        let ids = try arguments.identifiers("ids")
        guard ids.count <= configuration.maximumTranscribeCount else {
            throw ToolError.tooManyIDs(
                asked: ids.count, maximum: configuration.maximumTranscribeCount, adjustable: true)
        }
        let characterOffset = try arguments.int(
            "character_offset", default: 0, in: Configuration.offsetRange)
        let maxCharacters = try arguments.int(
            "max_characters", default: Configuration.defaultWindow(forIDs: ids.count),
            in: Configuration.maxCharactersRange)

        let locale = try arguments.optionalString("locale") ?? configuration.localeIdentifier
        let support = await store.onDeviceSupport(locale: locale)
        // A model that is not installed yet is not a dead end any more: the store
        // downloads it on demand before recognising. Only a locale this Mac has no
        // recogniser for at all is refused up front, before any audio is opened.
        guard support.recognizerExists else { throw ToolError.onDeviceUnavailable(support) }

        try await requireSpeechAccess()

        let found = try await store.fetch(ids: ids)
        let missing = Self.missing(asked: ids, found: found)
        guard !found.isEmpty else { throw ToolError.notFound(ids: missing) }

        // The deadline abandons this work rather than stopping it, so what it has finished
        // is collected here and survives the abandonment. Each transcript is cached as it
        // is produced, so a second call only has the rest to do.
        let collected = Collected()
        let outcome = await Deadline.run(within: transcribeTimeout * 0.9) {
            do {
                try await self.transcribeBatch(
                    found, locale: locale, resolvedLocale: support.localeIdentifier,
                    into: collected)
                return Result<Void, any Error>.success(())
            } catch {
                return .failure(error)
            }
        }
        if case .failure(let error)? = outcome { throw error }

        let (results, failures) = collected.snapshot()
        var partial: [String] = []
        var unreached: [String] = []
        if outcome == nil {
            // Nothing finished at all is a failure to report, not a result.
            guard !results.isEmpty else {
                throw ToolError.timedOut(
                    seconds: Int(transcribeTimeout.components.seconds), mayHaveWritten: false)
            }
            let attempted = Set(results.map(\.recording.id) + failures.map(\.id))
            unreached = found.map(\.id).filter { !attempted.contains($0) }
            partial = [
                Notice.partial(after: results.count, things: "recordings", narrowBy: "ids")
            ]
        }
        guard !results.isEmpty else {
            throw ToolError.transcriptionFailed(
                id: failures.first?.id ?? ids[0],
                detail: failures.first?.reason ?? "no transcript was produced")
        }

        // Windows shrink only when the answer would not fit, and every notice is built from
        // what was rendered, so it stays true.
        return ToolStandard.fitting(maxCharacters) { size in
            let rendered = format.transcripts(
                results, characterOffset: characterOffset, maxCharacters: size,
                missing: missing, unreached: unreached, failures: failures)
            return ToolStandard.withNotices(
                arguments.notices + partial + rendered.notices, rendered.text)
        }
    }

    private func transcribeBatch(
        _ found: [RecordingDetail], locale: String?, resolvedLocale: String, into collected: Collected
    ) async throws {
        for recording in found {
            // Cancelled by the deadline: starting another recording would only be work
            // nobody collects.
            if Task.isCancelled { return }
            if let hit = cache.lookup(recording, locale: resolvedLocale) {
                collected.append(recording, hit, wasCached: true)
                continue
            }
            do {
                // Recorded against the file as it was read, not as it is now: the cache
                // compares these back and a file replaced mid-batch must miss next time.
                let produced = try await store.transcribe(recording, locale: locale)
                let transcript = Transcript(
                    recordingID: recording.id, text: produced.text,
                    localeIdentifier: produced.localeIdentifier,
                    byteSize: recording.byteSize, modified: recording.modified,
                    transcribedAt: now())
                cache.store(transcript)
                collected.append(recording, transcript, wasCached: false)
            } catch let error as ToolError {
                // One unreadable file must not lose the transcripts already produced —
                // they cost minutes each.
                collected.fail(recording.id, error.message)
            } catch {
                collected.fail(recording.id, error.localizedDescription)
            }
        }
    }

    private func export(_ arguments: Arguments) async throws -> String {
        let id = try arguments.requiredString("id")
        guard let root = configuration.exportRoot else { throw ToolError.exportRootNotConfigured }

        let found = try await store.fetch(ids: [id])
        guard let recording = found.first else { throw ToolError.notFound(ids: [id]) }

        let requested = try arguments.optionalString("destination") ?? recording.fileName
        let destination = try Self.resolveDestination(requested, inside: root)

        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw ToolError.destinationExists(destination.path)
        }
        return format.exported(try await store.copy(recording, to: destination))
    }

    // MARK: Policy

    /// Where a copy may land.
    ///
    /// The check is on the standardised path rather than on the text of the argument:
    /// `../../secrets` and `a/../../secrets` are the same request, and only one of them
    /// looks suspicious. An absolute path is rejected outright rather than silently
    /// reinterpreted, because a caller that passed one meant somewhere else entirely.
    static func resolveDestination(_ requested: String, inside root: String) throws -> URL {
        let rootURL = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL
        guard !requested.hasPrefix("/") else {
            throw ToolError.destinationOutsideRoot(destination: requested, root: rootURL.path)
        }

        let candidate = rootURL.appendingPathComponent(requested).standardizedFileURL
        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard candidate.path.hasPrefix(rootPath) else {
            throw ToolError.destinationOutsideRoot(
                destination: candidate.path, root: rootURL.path)
        }
        return candidate
    }

    private func requireSpeechAccess() async throws {
        var authorization = store.speechAuthorization()
        if authorization == .notDetermined {
            authorization = await store.requestSpeechAccess()
        }
        guard authorization.isUsable else { throw ToolError.notAuthorized(authorization) }
    }

    /// Ids that resolved to nothing, in the order they were asked for.
    private static func missing(asked: [String], found: [RecordingDetail]) -> [String] {
        let resolved = Set(found.map(\.id))
        return asked.filter { !resolved.contains($0) }
    }

    static var binaryPath: String {
        CommandLine.arguments.first.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            ?? "(unknown)"
    }
}

/// What the batch has produced so far, readable from the thread that abandons the work.
private final class Collected: Sendable {
    typealias Finished = [(recording: RecordingDetail, transcript: Transcript, wasCached: Bool)]
    private let state = Mutex<(finished: Finished, failures: [(id: String, reason: String)])>(([], []))

    func append(_ recording: RecordingDetail, _ transcript: Transcript, wasCached: Bool) {
        state.withLock { $0.finished.append((recording, transcript, wasCached)) }
    }

    func fail(_ id: String, _ reason: String) {
        state.withLock { $0.failures.append((id, reason)) }
    }

    func snapshot() -> (Finished, [(id: String, reason: String)]) {
        state.withLock { ($0.finished, $0.failures) }
    }
}
