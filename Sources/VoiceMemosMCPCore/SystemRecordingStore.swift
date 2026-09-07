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
/// files.
public struct SystemRecordingStore: RecordingStore {

    /// Audio this server will consider. Voice Memos writes `.m4a`; the rest are here
    /// because a configured library is an ordinary folder that may hold anything, and
    /// silently skipping a file the owner can see is worse than trying it.
    static let audioExtensions: Set<String> = ["m4a", "mp3", "wav", "aiff", "aif", "caf", "mp4"]

    private let configuration: Configuration
    private let engine = TranscriptionEngine()

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

    public func onDeviceSupport(locale: String?) async -> OnDeviceSupport {
        let resolved = Self.locale(locale)
        guard let (_, installed) = await TranscriptionEngine.resolve(resolved) else {
            return OnDeviceSupport(
                localeIdentifier: resolved.identifier, recognizerExists: false,
                supportsOnDevice: false)
        }
        return OnDeviceSupport(
            localeIdentifier: resolved.identifier, recognizerExists: true,
            supportsOnDevice: installed)
    }

    static func locale(_ identifier: String?) -> Locale {
        guard let identifier, !identifier.isEmpty else { return Locale.current }
        return Locale(identifier: identifier)
    }

    // MARK: Library

    /// Candidate roots, in the order they are tried.
    ///
    /// The shared Group Container is tried first: confirmed by hand on macOS 26 as where
    /// Voice Memos actually keeps its recordings now, with its own private container
    /// holding none at all — not even an unreadable one, genuinely empty of them. The
    /// private container and the pre-sandbox path are kept as fallbacks for whichever
    /// macOS release used them before this move, and a directory that is simply absent
    /// costs one `stat` to rule out.
    public func libraries() -> [LibraryLocation] {
        let home = fileManager.homeDirectoryForCurrentUser.path
        var candidates: [(String, LibraryOrigin)] = []
        if let configured = configuration.libraryPath {
            candidates.append((configured, .configured))
        }
        candidates.append(
            (
                "\(home)/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings",
                .voiceMemosSharedGroupContainer
            ))
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
        let text = try await engine.transcribe(
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

/// Runs on-device recognition through `SpeechAnalyzer`/`SpeechTranscriber` (macOS 26),
/// the long-form replacement for `SFSpeechRecognizer`.
///
/// The old, short-form API ran a single recognition session over the whole file and was
/// unreliable well past a minute of audio — independent reports describe it silently
/// truncating or dropping everything past that point, with no error to catch. This module
/// is what Apple built to fix that at the source: it is designed to take a long, whole
/// recording in one call, with no chunking or stitching needed on this side. There is also
/// no on-device flag to set here, unlike the old API — this framework has no server-backed
/// path at all, so audio never has a way to leave this Mac in the first place.
///
/// One recognition session at a time: whether the platform supports running two on-device
/// sessions concurrently is an open question in Apple's own developer forums rather than a
/// documented guarantee, and this model runs well faster than real time on its own, so
/// queuing a batch costs little a parallel run would have saved.
private actor TranscriptionEngine {
    /// Resolves a locale to its transcriber and current install state in one place, so
    /// `SystemRecordingStore.onDeviceSupport` (a pure status read) and `transcribe` below
    /// (which acts on that state) cannot drift into checking this two different ways.
    static func resolve(_ locale: Locale) async -> (transcriber: SpeechTranscriber, installed: Bool)?
    {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        else { return nil }
        let transcriber = SpeechTranscriber(locale: supported, preset: .transcription)
        let installed = await AssetInventory.status(forModules: [transcriber]) == .installed
        return (transcriber, installed)
    }

    func transcribe(url: URL, locale: Locale, recordingID: String) async throws -> String {
        guard let (transcriber, installed) = await Self.resolve(locale) else {
            throw ToolError.onDeviceUnavailable(
                OnDeviceSupport(
                    localeIdentifier: locale.identifier, recognizerExists: false,
                    supportsOnDevice: false))
        }
        if !installed {
            try await Self.install(transcriber, locale: locale)
        }

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            throw ToolError.transcriptionFailed(
                id: recordingID, detail: "could not open the audio: \(error.localizedDescription)"
            )
        }

        do {
            // `finishAfterFile` is what makes this a one-shot call: the analyzer reads the
            // file to its end and then finishes on its own, which is also what lets the
            // `for try await` below end instead of waiting for a result that never comes.
            let analyzer = try await SpeechAnalyzer(
                inputAudioFile: audioFile, modules: [transcriber], finishAfterFile: true)
            var pieces: [String] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                if !text.isEmpty { pieces.append(text) }
            }
            // `analyzer` drives `transcriber.results` for as long as it stays alive; it has
            // no other reference holding it up, and nothing above reads it again, so without
            // this the optimizer is free to release it before the loop above is done pulling
            // from that sequence.
            withExtendedLifetime(analyzer) {}
            return pieces.joined(separator: " ")
        } catch {
            throw ToolError.transcriptionFailed(id: recordingID, detail: error.localizedDescription)
        }
    }

    /// Downloads this locale's model. Only called once `resolve` has already reported it
    /// missing, so this does not re-check `AssetInventory.status` itself.
    ///
    /// Verified by hand: the classic Dictation language list (System Settings → Keyboard →
    /// Dictation) does not install this — this framework's model is a separate asset, and
    /// `es-ES` came back not installed here even with Dictation already showing it enabled.
    /// `AssetInventory` is the actual, current way to get it, and it is exactly what an app
    /// is meant to call rather than sending the owner to a settings pane that would not help.
    private static func install(_ transcriber: SpeechTranscriber, locale: Locale) async throws {
        guard
            let request = try await AssetInventory.assetInstallationRequest(
                supporting: [transcriber])
        else {
            throw ToolError.onDeviceUnavailable(
                OnDeviceSupport(
                    localeIdentifier: locale.identifier, recognizerExists: true,
                    supportsOnDevice: false))
        }
        try await request.downloadAndInstall()
    }
}
