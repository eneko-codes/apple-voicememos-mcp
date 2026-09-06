import AVFoundation
import Darwin
import Foundation
import Speech

/// The only type that touches a real file or a real speech recogniser.
///
/// **Why the filesystem and not the Shortcuts app.** Voice Memos ships no framework and
/// answers `sdef` with error -192, so Shortcuts is the usual way in. Its App Intents were
/// read out of `VoiceMemos.app/Contents/Resources/Metadata.appintents` on this Mac:
/// `RCRecordingEntity` exposes `name`, `creationDate` and `duration`, and every action on
/// it either plays, selects, combines, imports or deletes. Not one of them hands back the
/// audio. Transcription and export both need the bytes, so a Shortcuts route could only
/// have produced a listing nothing else could act on. The library is therefore read as
/// files, and `verification.md` records the whole check.
public struct SystemRecordingStore: RecordingStore {

    /// Audio this server will consider. Voice Memos writes `.m4a`; the rest are here
    /// because a configured library is an ordinary folder that may hold anything, and
    /// silently skipping a file the owner can see is worse than trying it.
    static let audioExtensions: Set<String> = ["m4a", "mp3", "wav", "aiff", "aif", "caf", "mp4"]

    private let configuration: Configuration
    private let transcriber = SpeechTranscriber()

    /// `FileManager.default` is used directly rather than held or injected. A stored
    /// `FileManager` cannot cross into a `Sendable` type — the class is not `Sendable` —
    /// and the shared instance is documented as safe to use from several threads, which a
    /// private one is not.
    private var fileManager: FileManager { .default }

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    // MARK: Permission

    public func speechAuthorization() -> SpeechAuthorization {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    @discardableResult
    public func requestSpeechAccess() async -> SpeechAuthorization {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { _ in
                // The callback's own status argument is discarded on purpose: reading it
                // back through the same accessor every other call uses keeps one mapping
                // rather than two that can drift.
                continuation.resume(returning: speechAuthorization())
            }
        }
    }

    public func onDeviceSupport(locale: String?) -> OnDeviceSupport {
        let resolved = Self.locale(locale)
        guard let recognizer = SFSpeechRecognizer(locale: resolved) else {
            return OnDeviceSupport(
                localeIdentifier: resolved.identifier, recognizerExists: false,
                supportsOnDevice: false)
        }
        return OnDeviceSupport(
            localeIdentifier: resolved.identifier,
            recognizerExists: true,
            supportsOnDevice: recognizer.supportsOnDeviceRecognition)
    }

    static func locale(_ identifier: String?) -> Locale {
        guard let identifier, !identifier.isEmpty else { return Locale.current }
        return Locale(identifier: identifier)
    }

    // MARK: Library

    /// Candidate roots, in the order they are tried.
    ///
    /// The container path is where Voice Memos actually keeps its recordings on a
    /// sandboxed macOS. The pre-sandbox path is checked after it because it is still what
    /// most documentation names, and a directory that is simply absent costs one `stat` to
    /// rule out.
    public func libraries() -> [LibraryLocation] {
        let home = fileManager.homeDirectoryForCurrentUser.path
        var candidates: [(String, LibraryOrigin)] = []
        if let configured = configuration.libraryPath {
            candidates.append((configured, .configured))
        }
        candidates.append(
            (
                "\(home)/Library/Containers/com.apple.VoiceMemos/Data/Library/Application Support/com.apple.voicememos/Recordings",
                .voiceMemosContainer
            ))
        candidates.append(
            ("\(home)/Library/Application Support/com.apple.voicememos/Recordings",
                .legacyApplicationSupport))

        return candidates.map { path, origin in
            let (exists, readable) = Self.probe(path, fileManager: fileManager)
            return LibraryLocation(path: path, origin: origin, exists: exists, isReadable: readable)
        }
    }

    /// Distinguishes "nothing here" from "something here this process is not let see".
    ///
    /// `FileManager.fileExists` calls `stat` and turns *any* failure into `false` —
    /// genuine absence (`ENOENT`) and a TCC denial at the `stat` call itself (`EACCES` /
    /// `EPERM`, which is exactly what the sandboxed Voice Memos container returns without
    /// Full Disk Access) are indistinguishable through that API. Reading `errno` after a
    /// raw `stat` is the only way to tell "missing" from "unreadable", and getting that
    /// wrong sends someone hunting for a folder that is actually there.
    private static func probe(_ path: String, fileManager: FileManager) -> (
        exists: Bool, isReadable: Bool
    ) {
        var info = stat()
        guard path.withCString({ stat($0, &info) }) == 0 else {
            switch errno {
            case ENOENT, ENOTDIR: return (false, false)
            default: return (true, false)
            }
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { return (false, false) }
        let readable = (try? fileManager.contentsOfDirectory(atPath: path)) != nil
        return (true, readable)
    }

    private func libraryRoot() throws -> URL {
        let candidates = libraries()
        guard let usable = candidates.first(where: \.isUsable) else {
            throw ToolError.libraryUnreachable(candidates)
        }
        return URL(fileURLWithPath: usable.path, isDirectory: true)
    }

    /// Every audio file under the root, newest first, with only the metadata the
    /// filesystem already holds.
    ///
    /// Duration and name are deliberately NOT read here. Both need the audio file opened,
    /// and doing that for a library of hundreds while answering a question about ten of
    /// them is the difference between a listing that returns and one that appears to
    /// hang. They are loaded for the page that is actually returned.
    private func walk(_ root: URL) throws -> [(url: URL, relativePath: String, created: Date)] {
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .creationDateKey, .contentModificationDateKey,
        ]
        guard
            let enumerator = fileManager.enumerator(
                at: root, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { throw ToolError.libraryUnreachable(libraries()) }

        let rootPath = root.standardizedFileURL.path
        var found: [(URL, String, Date)] = []
        for case let url as URL in enumerator {
            guard Self.audioExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }

            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath + "/") else { continue }
            let relative = String(path.dropFirst(rootPath.count + 1))

            // Creation date is what Voice Memos means by "when this was recorded".
            // Modification date is the fallback because a file copied between volumes can
            // lose the former, and a listing with no date at all is unusable.
            let created =
                values?.creationDate ?? values?.contentModificationDate ?? Date.distantPast
            found.append((url, relative, created))
        }
        return found.sorted { $0.2 > $1.2 }
    }

    public func list(_ query: RecordingQuery) async throws -> RecordingPage {
        let root = try libraryRoot()
        var matches = try walk(root)

        if let folder = query.folder {
            let wanted = folder == "(root)" ? "" : folder
            matches = matches.filter { Self.folder(of: $0.relativePath) == wanted }
        }
        if let needle = query.nameContains, !needle.isEmpty {
            matches = matches.filter {
                Self.stem(of: $0.relativePath).localizedCaseInsensitiveContains(needle)
            }
        }
        if let after = query.createdAfter {
            matches = matches.filter { $0.created >= after }
        }
        if let before = query.createdBefore {
            matches = matches.filter { $0.created < before }
        }

        let total = matches.count
        let page = matches.dropFirst(query.offset).prefix(query.limit)

        var results: [RecordingSummary] = []
        for entry in page {
            results.append(
                RecordingSummary(
                    id: entry.relativePath,
                    name: await Self.displayName(of: entry.url, relativePath: entry.relativePath),
                    created: entry.created,
                    duration: await Self.duration(of: entry.url),
                    folder: Self.folder(of: entry.relativePath)))
        }
        return RecordingPage(results: results, total: total, libraryPath: root.path)
    }

    public func fetch(ids: [String]) async throws -> [RecordingDetail] {
        let root = try libraryRoot()
        // Matched against the enumeration rather than joined onto the root. An id is a
        // relative path, and joining one straight onto a directory is how `../` gets out.
        let byID = Dictionary(
            try walk(root).map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })

        var details: [RecordingDetail] = []
        for id in ids {
            guard let entry = byID[id] else { continue }
            let values = try? entry.url.resourceValues(forKeys: [
                .contentModificationDateKey, .fileSizeKey, .contentTypeKey,
            ])
            details.append(
                RecordingDetail(
                    id: entry.relativePath,
                    name: await Self.displayName(of: entry.url, relativePath: entry.relativePath),
                    fileName: entry.url.lastPathComponent,
                    path: entry.url.path,
                    folder: Self.folder(of: entry.relativePath),
                    created: entry.created,
                    modified: values?.contentModificationDate ?? entry.created,
                    duration: await Self.duration(of: entry.url),
                    byteSize: values?.fileSize ?? 0,
                    typeIdentifier: values?.contentType?.identifier))
        }
        return details
    }

    public func transcribe(_ recording: RecordingDetail, locale: String?) async throws -> Transcript
    {
        let resolved = Self.locale(locale)
        let text = try await transcriber.transcribe(
            url: URL(fileURLWithPath: recording.path), locale: resolved,
            recordingID: recording.id)
        return Transcript(
            recordingID: recording.id, text: text, localeIdentifier: resolved.identifier,
            byteSize: recording.byteSize, modified: recording.modified, transcribedAt: Date())
    }

    public func copy(_ recording: RecordingDetail, to destination: URL) async throws -> ExportedFile
    {
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: URL(fileURLWithPath: recording.path), to: destination)
        return ExportedFile(
            recordingID: recording.id, sourcePath: recording.path,
            destinationPath: destination.path, byteSize: recording.byteSize)
    }

    // MARK: Reading one file

    static func folder(of relativePath: String) -> String {
        let parts = relativePath.split(separator: "/")
        return parts.count > 1 ? parts.dropLast().joined(separator: "/") : ""
    }

    static func stem(of relativePath: String) -> String {
        (relativePath as NSString).lastPathComponent
    }

    /// The title written into the file, falling back to its name on disk.
    ///
    /// Voice Memos names its files by timestamp and keeps the title the owner typed in
    /// its own database, but it also writes that title into the audio's common metadata.
    /// Reading it back is the difference between a listing of dates and a listing of
    /// subjects.
    static func displayName(of url: URL, relativePath: String) async -> String {
        let fallback = (stem(of: relativePath) as NSString).deletingPathExtension
        let asset = AVURLAsset(url: url)
        guard let metadata = try? await asset.load(.commonMetadata) else { return fallback }
        let titles = AVMetadataItem.metadataItems(
            from: metadata, filteredByIdentifier: .commonIdentifierTitle)
        // `try?` flattens the double optional here — the item may be absent and the load
        // may return nil — so `value` is already a plain String by the time it binds.
        guard let value = try? await titles.first?.load(.stringValue) else { return fallback }
        let title = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return fallback }
        return title
    }

    /// Zero when the file cannot be opened. A listing that fails outright because one file
    /// in a folder is unreadable is worse than one that reports it as 0:00.
    static func duration(of url: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return 0 }
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite && seconds > 0 ? seconds : 0
    }
}

/// Serialises speech recognition.
///
/// `SFSpeechRecognizer` is not `Sendable` and an on-device pass is heavy in both CPU and
/// memory; one at a time keeps the cost of a batch predictable and keeps the recogniser
/// confined to a single isolation domain.
private actor SpeechTranscriber {

    func transcribe(url: URL, locale: Locale, recordingID: String) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw ToolError.onDeviceUnavailable(
                OnDeviceSupport(
                    localeIdentifier: locale.identifier, recognizerExists: false,
                    supportsOnDevice: false))
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw ToolError.onDeviceUnavailable(
                OnDeviceSupport(
                    localeIdentifier: locale.identifier, recognizerExists: true,
                    supportsOnDevice: false))
        }
        guard recognizer.isAvailable else {
            throw ToolError.transcriptionFailed(
                id: recordingID,
                detail: "the recogniser for \(locale.identifier) is not available right now")
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        // The whole point of this tool: with this flag the audio is processed by the
        // model on this Mac and no part of it is sent to Apple. Without it, Speech falls
        // back to a server request, which is exactly what a private recording must never
        // do.
        request.requiresOnDeviceRecognition = true
        // Partial results would fire the handler repeatedly for a result nobody can use:
        // nothing is streamed anywhere, the answer is returned once at the end.
        request.shouldReportPartialResults = false
        request.addsPunctuation = true

        return try await withCheckedThrowingContinuation { continuation in
            let box = ContinuationBox(continuation)
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    box.finish(
                        .failure(
                            ToolError.transcriptionFailed(
                                id: recordingID, detail: error.localizedDescription)))
                    return
                }
                guard let result, result.isFinal else { return }
                box.finish(.success(result.bestTranscription.formattedString))
            }
        }
    }
}

/// Resumes a continuation exactly once.
///
/// `recognitionTask`'s handler can be called more than once, and can be called with both
/// a final result and a later error. Resuming a checked continuation twice is a crash, so
/// the guard is not defensive padding — it is the contract.
private final class ContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?

    init(_ continuation: CheckedContinuation<String, Error>) {
        self.continuation = continuation
    }

    func finish(_ outcome: Result<String, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: outcome)
    }
}
