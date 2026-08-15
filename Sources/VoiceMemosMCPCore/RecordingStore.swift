import Foundation

/// The seam between the tool layer and everything Apple owns — the filesystem the
/// recordings sit on, and the Speech framework that reads them aloud back into text.
///
/// Everything above this protocol is exercised by the tests against an in-memory double;
/// only `SystemRecordingStore` touches a real file or a real recogniser. Keeping the
/// boundary this thin is what makes the untested surface small enough to check by hand.
public protocol RecordingStore: Sendable {
    func speechAuthorization() -> SpeechAuthorization

    @discardableResult
    func requestSpeechAccess() async -> SpeechAuthorization

    /// Every candidate root, in the order they are tried. Never throws: this is the
    /// diagnostic that has to survive a completely unreachable library.
    func libraries() -> [LibraryLocation]

    /// On-device capability for a locale, asked before a transcription is started.
    func onDeviceSupport(locale: String?) -> OnDeviceSupport

    func list(_ query: RecordingQuery) async throws -> RecordingPage

    /// Resolves ids to records in one pass, in the order given, silently dropping ids
    /// that match nothing — the caller reports those, because it knows what was asked
    /// for. Bulk so that transcribing five recordings scans the library once.
    func fetch(ids: [String]) async throws -> [RecordingDetail]

    /// Takes an already-resolved recording so the library is not walked again, and so a
    /// transcription can never be pointed at a path that was not enumerated.
    func transcribe(_ recording: RecordingDetail, locale: String?) async throws -> Transcript

    /// Copies the audio. `destination` has already been checked against the configured
    /// write root by the caller; the store does not decide policy.
    func copy(_ recording: RecordingDetail, to destination: URL) async throws -> ExportedFile
}
