import CryptoKit
import Foundation

/// An on-disk store of transcripts already produced, so a second question about the same
/// recording does not pay for a second pass over the audio.
///
/// It is a cache and nothing more: an entry is the exact text the recogniser returned,
/// and a miss is always safe because it just means transcribing again. It lives above the
/// `RecordingStore` seam so the tests can drive it against a temporary directory.
///
/// Its directory is fixed under `$TMPDIR` (see `VoiceMemosTools.defaultCacheDirectory`)
/// rather than configured by the owner: nothing here is worth a setting when losing the
/// whole directory has no worse consequence than a slower answer.
public struct TranscriptCache: Sendable {

    /// What `recordings_status` reports about the cache, so a silently unwritable
    /// directory is visible rather than being inferred from transcription never speeding
    /// up.
    public struct Health: Sendable, Equatable {
        public let path: String
        public let isWritable: Bool
        public let entryCount: Int
    }

    private let directory: URL

    /// See `SystemRecordingStore`: the shared instance is the only one safe to reach from
    /// a `Sendable` type, and nothing here ever wanted a different one.
    private var fileManager: FileManager { .default }

    public init(directory: URL) {
        self.directory = directory
    }

    /// The entry file name for a recording.
    ///
    /// Hashed because an id is a relative path: it contains separators and may contain
    /// anything else a file name can, so using it directly would put the cache's layout
    /// under the control of whatever the library happens to contain.
    private func entryURL(for recordingID: String, locale: String) -> URL {
        let digest = SHA256.hash(data: Data("\(locale)\n\(recordingID)".utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(name).json", isDirectory: false)
    }

    /// A stored transcript for this exact file, or nil.
    ///
    /// Size and modification date are compared as well as the id: a recording that was
    /// re-recorded under the same name is a different recording, and serving the old text
    /// for it would be a lie no caller could detect.
    public func lookup(_ recording: RecordingDetail, locale: String) -> Transcript? {
        let url = entryURL(for: recording.id, locale: locale)
        guard let data = try? Data(contentsOf: url),
            let stored = try? JSONDecoder().decode(Transcript.self, from: data),
            stored.recordingID == recording.id,
            stored.localeIdentifier == locale,
            stored.byteSize == recording.byteSize,
            // Timestamps round-trip through JSON as doubles; a second of slack is far
            // below the resolution at which a file could plausibly change twice.
            abs(stored.modified.timeIntervalSince(recording.modified)) < 1
        else { return nil }
        return stored
    }

    /// Writes an entry, or gives up quietly.
    ///
    /// A cache that cannot be written must never turn a successful transcription into a
    /// failed tool call. `recordings_status` is where an unwritable directory is
    /// reported, and it is checked there rather than here.
    public func store(_ transcript: Transcript) {
        guard
            (try? fileManager.createDirectory(
                at: directory, withIntermediateDirectories: true)) != nil,
            let data = try? JSONEncoder().encode(transcript)
        else { return }
        try? data.write(
            to: entryURL(for: transcript.recordingID, locale: transcript.localeIdentifier),
            options: .atomic)
    }

    public func health() -> Health {
        let path = directory.path
        let entries =
            (try? fileManager.contentsOfDirectory(atPath: path))?
            .filter { $0.hasSuffix(".json") }.count ?? 0

        // Creating the directory is the only honest test of writability: a directory that
        // does not exist yet is writable if its parent is, and isWritableFileAtPath on a
        // missing path just says no.
        let created = (try? fileManager.createDirectory(
            at: directory, withIntermediateDirectories: true)) != nil
        return Health(
            path: path,
            isWritable: created && fileManager.isWritableFile(atPath: path),
            entryCount: entries)
    }
}
