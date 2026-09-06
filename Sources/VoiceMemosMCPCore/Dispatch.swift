import Foundation
import MCP

/// Routes a `tools/call` to the store and renders the answer.
///
/// Never touches the filesystem or the Speech framework directly — everything goes
/// through `RecordingStore`, which is what lets the tests drive every branch below
/// against an in-memory double with no recordings and no consent dialog. The one
/// exception is the export path check, which is policy rather than access: it decides
/// where a copy may land, and it has to be testable.
public struct VoiceMemosTools: Sendable {
    private let store: any RecordingStore
    private let calendar: Calendar
    private let configuration: Configuration
    private let cache: TranscriptCache
    private let format: Format
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
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.calendar = calendar
        self.configuration = configuration
        self.cache = TranscriptCache(directory: cacheDirectory)
        self.format = Format(calendar: calendar)
        self.now = now
    }

    public func handle(_ parameters: CallTool.Parameters) async -> CallTool.Result {
        do {
            let text = try await run(parameters)
            return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
        } catch let error as ToolError {
            return .init(
                content: [.text(text: error.message, annotations: nil, _meta: nil)], isError: true)
        } catch {
            return .init(
                content: [
                    .text(
                        text: ToolError.storeFailure(error.localizedDescription).message,
                        annotations: nil, _meta: nil)
                ], isError: true)
        }
    }

    private func run(_ parameters: CallTool.Parameters) async throws -> String {
        let arguments = Arguments(parameters.arguments, calendar: calendar)

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

        case ToolCatalog.exportName:
            return try await export(arguments)

        default:
            throw ToolError.badArgument(
                name: "name", reason: "'\(parameters.name)' is not a tool of this server")
        }
    }

    // MARK: Tools

    private func list(_ arguments: Arguments) async throws -> String {
        var query = RecordingQuery()
        query.nameContains = arguments.optionalString("name_contains")
        query.folder = arguments.optionalString("folder")
        query.createdAfter = try arguments.optionalDate("created_after")?.date
        query.createdBefore = try arguments.rangeEnd("created_before")
        query.limit = try arguments.int(
            "limit", default: configuration.listLimit, in: Configuration.listLimitRange)
        query.offset = try arguments.int("offset", default: 0, in: Configuration.offsetRange)

        return format.listing(try await store.list(query), offset: query.offset)
    }

    private func get(_ arguments: Arguments) async throws -> String {
        let ids = try arguments.identifiers("ids")
        let found = try await store.fetch(ids: ids)
        let missing = Self.missing(asked: ids, found: found)
        guard !found.isEmpty else { throw ToolError.notFound(ids: missing) }
        return format.details(found, missing: missing)
    }

    private func transcribe(_ arguments: Arguments) async throws -> String {
        let ids = try arguments.identifiers("ids")
        guard ids.count <= configuration.maximumTranscribeCount else {
            throw ToolError.tooManyIDs(
                asked: ids.count, maximum: configuration.maximumTranscribeCount)
        }

        let locale = arguments.optionalString("locale") ?? configuration.localeIdentifier
        let support = await store.onDeviceSupport(locale: locale)
        // A model that is not installed yet is not a dead end any more: the store
        // downloads it on demand before recognising. Only a locale this Mac has no
        // recogniser for at all is refused up front, before any audio is opened.
        guard support.recognizerExists else { throw ToolError.onDeviceUnavailable(support) }

        try await requireSpeechAccess()

        let found = try await store.fetch(ids: ids)
        let missing = Self.missing(asked: ids, found: found)
        guard !found.isEmpty else { throw ToolError.notFound(ids: missing) }

        var results: [(recording: RecordingDetail, transcript: Transcript, wasCached: Bool)] = []
        var failures: [(id: String, reason: String)] = []

        for recording in found {
            if let hit = cache.lookup(recording, locale: support.localeIdentifier) {
                results.append((recording, hit, true))
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
                results.append((recording, transcript, false))
            } catch let error as ToolError {
                // One unreadable file must not lose the transcripts already produced —
                // they cost minutes each.
                failures.append((recording.id, error.message))
            } catch {
                failures.append((recording.id, error.localizedDescription))
            }
        }

        guard !results.isEmpty else {
            throw ToolError.transcriptionFailed(
                id: failures.first?.id ?? ids[0],
                detail: failures.first?.reason ?? "no transcript was produced")
        }
        return format.transcripts(results, missing: missing, failures: failures)
    }

    private func export(_ arguments: Arguments) async throws -> String {
        let id = try arguments.requiredString("id")
        guard let root = configuration.exportRoot else { throw ToolError.exportRootNotConfigured }

        let found = try await store.fetch(ids: [id])
        guard let recording = found.first else { throw ToolError.notFound(ids: [id]) }

        let requested = arguments.optionalString("destination") ?? recording.fileName
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
