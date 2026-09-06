import Foundation

@testable import VoiceMemosMCPCore

/// In-memory `RecordingStore` for the tests.
///
/// Every fixture here is invented and no test in this suite opens a real file, asks for
/// a permission, or starts a recogniser: see the hard rule in CLAUDE.md.
final class FakeRecordingStore: RecordingStore, @unchecked Sendable {
    var speechStatus: SpeechAuthorization
    var onDevice: OnDeviceSupport
    var locations: [LibraryLocation]
    var recordings: [RecordingDetail]
    /// Ids the fake refuses to transcribe, so the partial-failure path is reachable.
    var unreadable: Set<String> = []
    var transcriptText: String = "This is the invented transcript."

    private(set) var transcribed: [String] = []
    private(set) var copied: [(id: String, destination: URL)] = []
    private(set) var accessRequests = 0

    init(
        speechStatus: SpeechAuthorization = .authorized,
        onDevice: OnDeviceSupport = Fixtures.onDevice,
        locations: [LibraryLocation] = Fixtures.locations,
        recordings: [RecordingDetail] = Fixtures.recordings
    ) {
        self.speechStatus = speechStatus
        self.onDevice = onDevice
        self.locations = locations
        self.recordings = recordings
    }

    func speechAuthorization() -> SpeechAuthorization { speechStatus }

    @discardableResult
    func requestSpeechAccess() async -> SpeechAuthorization {
        accessRequests += 1
        if speechStatus == .notDetermined { speechStatus = .authorized }
        return speechStatus
    }

    func libraries() -> [LibraryLocation] { locations }

    func onDeviceSupport(locale: String?) async -> OnDeviceSupport {
        guard let locale, !locale.isEmpty else { return onDevice }
        return OnDeviceSupport(
            localeIdentifier: locale,
            recognizerExists: onDevice.recognizerExists,
            supportsOnDevice: onDevice.supportsOnDevice)
    }

    func list(_ query: RecordingQuery) async throws -> RecordingPage {
        guard let root = locations.first(where: \.isUsable) else {
            throw ToolError.libraryUnreachable(locations)
        }
        var matches = recordings
        if let folder = query.folder {
            matches = matches.filter { $0.folder == (folder == "(root)" ? "" : folder) }
        }
        if let needle = query.nameContains, !needle.isEmpty {
            matches = matches.filter { $0.name.localizedCaseInsensitiveContains(needle) }
        }
        if let after = query.createdAfter { matches = matches.filter { $0.created >= after } }
        if let before = query.createdBefore { matches = matches.filter { $0.created < before } }
        matches.sort { $0.created > $1.created }

        let page = matches.dropFirst(query.offset).prefix(query.limit).map(\.summary)
        return RecordingPage(
            results: Array(page), total: matches.count, libraryPath: root.path)
    }

    func fetch(ids: [String]) async throws -> [RecordingDetail] {
        guard locations.contains(where: \.isUsable) else {
            throw ToolError.libraryUnreachable(locations)
        }
        return ids.compactMap { id in recordings.first { $0.id == id } }
    }

    func transcribe(_ recording: RecordingDetail, locale: String?) async throws -> Transcript {
        guard !unreadable.contains(recording.id) else {
            throw ToolError.transcriptionFailed(
                id: recording.id, detail: "the fake was told this file is unreadable")
        }
        transcribed.append(recording.id)
        return Transcript(
            recordingID: recording.id, text: transcriptText,
            localeIdentifier: locale ?? onDevice.localeIdentifier,
            byteSize: recording.byteSize, modified: recording.modified,
            transcribedAt: Fixtures.now)
    }

    func copy(_ recording: RecordingDetail, to destination: URL) async throws -> ExportedFile {
        copied.append((recording.id, destination))
        return ExportedFile(
            recordingID: recording.id, sourcePath: recording.path,
            destinationPath: destination.path, byteSize: recording.byteSize)
    }
}

enum Fixtures {
    /// Fixed so a rendered timestamp is decided by the fixtures, not by where the suite
    /// happens to run.
    static let timeZone = TimeZone(identifier: "Europe/Madrid")!

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// 2026-08-09 12:00 Europe/Madrid.
    static let now = date(2026, 8, 9, 12, 0)

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0)
        -> Date
    {
        calendar.date(
            from: DateComponents(
                timeZone: timeZone, year: year, month: month, day: day, hour: hour, minute: minute)
        )!
    }

    static let libraryPath = "/invented/Recordings"

    static let onDevice = OnDeviceSupport(
        localeIdentifier: "en-US", recognizerExists: true, supportsOnDevice: true)

    static let locations: [LibraryLocation] = [
        LibraryLocation(
            path: libraryPath, origin: .configured, exists: true, isReadable: true),
        LibraryLocation(
            path: "/invented/Containers/Recordings", origin: .voiceMemosContainer,
            exists: true, isReadable: false),
    ]

    /// No library this server can read — the state a fresh install is in.
    static let unreachableLocations: [LibraryLocation] = [
        LibraryLocation(
            path: "/invented/Containers/Recordings", origin: .voiceMemosContainer,
            exists: true, isReadable: false),
        LibraryLocation(
            path: "/invented/Application Support/Recordings",
            origin: .legacyApplicationSupport, exists: false, isReadable: false),
    ]

    static func recording(
        id: String,
        name: String,
        created: Date,
        duration: TimeInterval = 65,
        folder: String = "",
        byteSize: Int = 512_000
    ) -> RecordingDetail {
        RecordingDetail(
            id: id, name: name, fileName: (id as NSString).lastPathComponent,
            path: "\(libraryPath)/\(id)", folder: folder,
            created: created, modified: created, duration: duration,
            byteSize: byteSize, typeIdentifier: "com.apple.m4a-audio")
    }

    static let recordings: [RecordingDetail] = [
        recording(
            id: "20260803 090000.m4a", name: "Quarterly review notes",
            created: date(2026, 8, 3, 9, 0), duration: 3725),
        recording(
            id: "20260807 181500.m4a", name: "Shopping list",
            created: date(2026, 8, 7, 18, 15), duration: 42),
        recording(
            id: "Ideas/20260808 220000.m4a", name: "Half-asleep idea",
            created: date(2026, 8, 8, 22, 0), duration: 18, folder: "Ideas"),
    ]
}
