import Foundation

/// Where a candidate library lives and why this server looked there.
public enum LibraryOrigin: String, Sendable, Equatable {
    /// Set by the person installing the extension.
    case configured
    /// The Voice Memos app's own sandbox container. Readable only with Full Disk Access.
    case voiceMemosContainer
    /// The pre-sandbox location. Still documented in the wild and cheap to check.
    case legacyApplicationSupport
}

/// One candidate root, with what could be observed about it without opening anything.
///
/// `recordings_status` prints every candidate rather than only the winner: when the
/// library is unreachable, "which paths were tried and what each one said" is the whole
/// diagnosis, and it is invisible from any other tool.
public struct LibraryLocation: Sendable, Equatable {
    public let path: String
    public let origin: LibraryOrigin
    public let exists: Bool
    /// A directory can exist and still refuse to be listed — that is exactly what the
    /// Voice Memos container does without Full Disk Access.
    public let isReadable: Bool

    public init(path: String, origin: LibraryOrigin, exists: Bool, isReadable: Bool) {
        self.path = path
        self.origin = origin
        self.exists = exists
        self.isReadable = isReadable
    }

    public var isUsable: Bool { exists && isReadable }
}

public enum SpeechAuthorization: Sendable, Equatable {
    case notDetermined
    case denied
    case restricted
    case authorized

    public var isUsable: Bool { self == .authorized }
}

/// What the Speech framework can actually do for one locale, asked before a long
/// transcription is started rather than after it fails.
public struct OnDeviceSupport: Sendable, Equatable {
    public let localeIdentifier: String
    /// False when the system has no recogniser for that locale at all.
    public let recognizerExists: Bool
    /// False when the locale's model has not been downloaded. Dictation in that language
    /// has to be used once, from System Settings, before it appears.
    public let supportsOnDevice: Bool

    public init(localeIdentifier: String, recognizerExists: Bool, supportsOnDevice: Bool) {
        self.localeIdentifier = localeIdentifier
        self.recognizerExists = recognizerExists
        self.supportsOnDevice = supportsOnDevice
    }
}

/// Filters for `recordings_list`. Every field mirrors something the filesystem already
/// knows; nothing here is computed or judged.
public struct RecordingQuery: Sendable, Equatable {
    public var nameContains: String?
    public var folder: String?
    public var createdAfter: Date?
    public var createdBefore: Date?
    public var limit: Int
    public var offset: Int

    public init(
        nameContains: String? = nil, folder: String? = nil,
        createdAfter: Date? = nil, createdBefore: Date? = nil,
        limit: Int = 50, offset: Int = 0
    ) {
        self.nameContains = nameContains
        self.folder = folder
        self.createdAfter = createdAfter
        self.createdBefore = createdBefore
        self.limit = limit
        self.offset = offset
    }
}

/// One line of a listing.
///
/// `id` is the recording's path relative to the library root. It is legible on purpose —
/// a person reading a transcript should be able to tell which file it came from — and it
/// is never joined back onto a path: `fetch(ids:)` enumerates the library and matches,
/// so a crafted id cannot walk out of the root.
public struct RecordingSummary: Sendable, Equatable {
    public let id: String
    public let name: String
    public let created: Date
    public let duration: TimeInterval
    /// Sub-path under the library root, `""` at the root itself. Voice Memos' own in-app
    /// folders live in its database and leave no trace on disk, so under the container
    /// route every recording reports the root.
    public let folder: String

    public init(id: String, name: String, created: Date, duration: TimeInterval, folder: String) {
        self.id = id
        self.name = name
        self.created = created
        self.duration = duration
        self.folder = folder
    }
}

public struct RecordingPage: Sendable, Equatable {
    public let results: [RecordingSummary]
    /// Matches before paging, so a truncated answer can say what it withheld.
    public let total: Int
    public let libraryPath: String

    public init(results: [RecordingSummary], total: Int, libraryPath: String) {
        self.results = results
        self.total = total
        self.libraryPath = libraryPath
    }
}

public struct RecordingDetail: Sendable, Equatable {
    public let id: String
    public let name: String
    public let fileName: String
    public let path: String
    public let folder: String
    public let created: Date
    public let modified: Date
    public let duration: TimeInterval
    public let byteSize: Int
    /// Uniform type identifier as the filesystem reports it, e.g. `com.apple.m4a-audio`.
    public let typeIdentifier: String?

    public init(
        id: String, name: String, fileName: String, path: String, folder: String,
        created: Date, modified: Date, duration: TimeInterval, byteSize: Int,
        typeIdentifier: String?
    ) {
        self.id = id
        self.name = name
        self.fileName = fileName
        self.path = path
        self.folder = folder
        self.created = created
        self.modified = modified
        self.duration = duration
        self.byteSize = byteSize
        self.typeIdentifier = typeIdentifier
    }

    public var summary: RecordingSummary {
        RecordingSummary(
            id: id, name: name, created: created, duration: duration, folder: folder)
    }
}

public struct Transcript: Sendable, Equatable, Codable {
    public let recordingID: String
    public let text: String
    public let localeIdentifier: String
    /// Recorded per transcript because the file may have been replaced since: the cache
    /// compares these against the file on disk before trusting an entry.
    public let byteSize: Int
    public let modified: Date
    public let transcribedAt: Date

    public init(
        recordingID: String, text: String, localeIdentifier: String,
        byteSize: Int, modified: Date, transcribedAt: Date
    ) {
        self.recordingID = recordingID
        self.text = text
        self.localeIdentifier = localeIdentifier
        self.byteSize = byteSize
        self.modified = modified
        self.transcribedAt = transcribedAt
    }
}

public struct ExportedFile: Sendable, Equatable {
    public let recordingID: String
    public let sourcePath: String
    public let destinationPath: String
    public let byteSize: Int

    public init(recordingID: String, sourcePath: String, destinationPath: String, byteSize: Int) {
        self.recordingID = recordingID
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.byteSize = byteSize
    }
}
