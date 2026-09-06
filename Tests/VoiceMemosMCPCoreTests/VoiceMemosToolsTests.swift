import Foundation
import MCP
import Testing

@testable import VoiceMemosMCPCore

/// Drives the tool layer end to end against `FakeRecordingStore`. No test in this file
/// opens a recording, asks for a permission or starts a recogniser — which is the point.
@Suite("Tool dispatch")
struct VoiceMemosToolsTests {

    private func call(
        _ name: String, _ arguments: [String: Value] = [:],
        store: FakeRecordingStore = FakeRecordingStore(),
        configuration: Configuration = Configuration(),
        // A fresh directory per call by default, so tests that do not care about the
        // cache cannot see each other's entries — the production server uses one fixed
        // path under $TMPDIR instead; see VoiceMemosTools.defaultCacheDirectory.
        cacheDirectory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicememos-cache-\(UUID().uuidString)", isDirectory: true)
    ) async -> (text: String, isError: Bool) {
        let tools = VoiceMemosTools(
            store: store, calendar: Fixtures.calendar, configuration: configuration,
            cacheDirectory: cacheDirectory, now: { Fixtures.now })
        let result = await tools.handle(.init(name: name, arguments: arguments))
        guard case .text(let text, _, _) = result.content.first else {
            return ("(no text content)", true)
        }
        return (text, result.isError ?? false)
    }

    // MARK: Catalogue

    @Test("Every tool has a unique name, title and description")
    func catalogueIsWellFormed() {
        let names = ToolCatalog.all().map(\.name)
        #expect(names.count == Set(names).count)
        #expect(names.count == 5)
        for tool in ToolCatalog.all() {
            #expect(tool.description?.isEmpty == false, "\(tool.name) has no description")
            #expect(tool.title?.isEmpty == false, "\(tool.name) has no title")
        }
    }

    /// The sibling servers put a create_/update_/delete_ prefix on writes. This server has
    /// no such tool: it cannot change the recording library at all, and recording_export
    /// only copies out of it. The convention is kept by having nothing to prefix — checked
    /// here alongside the annotations, so a future write tool cannot arrive unnamed or
    /// mismarked.
    @Test("Annotations and naming both say nothing here modifies the library")
    func annotationsAreHonest() {
        let reads = [
            "recordings_status", "recordings_list", "recording_get", "recording_transcribe",
        ]
        for tool in ToolCatalog.all() {
            #expect(tool.annotations.readOnlyHint == reads.contains(tool.name), "\(tool.name)")
            // Nothing here destroys anything: the recording library is only ever read,
            // and the one tool that writes writes a copy elsewhere.
            #expect(tool.annotations.destructiveHint == false, "\(tool.name)")
            let hasVerb = ["create_", "update_", "delete_"].contains { tool.name.hasPrefix($0) }
            #expect(!hasVerb, "\(tool.name) implies a write this server does not do")
        }
    }

    /// Regression guard inherited from the sibling servers, where a union type made every
    /// list field of a tool unusable.
    ///
    /// Claude Desktop's schema sanitiser drops a property whose `type` is a union such as
    /// `["array", "null"]`, replacing the whole subtree with `{}`. The model then
    /// serialises an array argument to a string and `Arguments` rejects it. Nothing
    /// downstream of the client can catch this, so it is caught here.
    @Test("No property declares its type as a union")
    func schemasDeclareScalarTypes() {
        func walk(_ value: Value, path: String) {
            guard let node = value.objectValue else { return }
            if let declared = node["type"] {
                #expect(
                    declared.stringValue != nil,
                    "\(path): type must be a single string, not a union")
            }
            for (key, child) in node["properties"]?.objectValue ?? [:] {
                walk(child, path: "\(path).\(key)")
            }
            if let items = node["items"] { walk(items, path: "\(path)[]") }
        }
        for tool in ToolCatalog.all() { walk(tool.inputSchema, path: tool.name) }
    }

    @Test("Advertised limits come from the live configuration")
    func catalogueReflectsConfiguration() throws {
        var configuration = Configuration()
        configuration.maximumTranscribeCount = 3
        configuration.exportRoot = "/invented/Exports"

        let tools = ToolCatalog.all(configuration)
        let transcribe = try #require(tools.first { $0.name == "recording_transcribe" })
        #expect(transcribe.description?.contains("3 recordings per call") == true)

        let export = try #require(tools.first { $0.name == "recording_export" })
        #expect(export.description?.contains("/invented/Exports") == true)
    }

    // MARK: Status

    @Test("Status reports every candidate library and never needs a permission")
    func statusListsCandidates() async {
        let store = FakeRecordingStore()
        let result = await call("recordings_status", store: store)
        #expect(!result.isError)
        #expect(result.text.contains(Fixtures.libraryPath))
        #expect(result.text.contains("/invented/Containers/Recordings"))
        #expect(result.text.contains("needs Full Disk Access"))
        #expect(store.accessRequests == 0)
    }

    @Test("Status says when nothing is reachable")
    func statusReportsUnreachableLibrary() async {
        let store = FakeRecordingStore(locations: Fixtures.unreachableLocations)
        let result = await call("recordings_status", store: store)
        #expect(result.text.contains("No library is reachable"))
    }

    @Test("Status names the missing on-device model rather than hiding it")
    func statusReportsMissingModel() async {
        let store = FakeRecordingStore(
            onDevice: OnDeviceSupport(
                localeIdentifier: "es-ES", recognizerExists: true, supportsOnDevice: false))
        let result = await call("recordings_status", store: store)
        #expect(result.text.contains("on-device model NOT installed"))
    }

    @Test("Status reports an unconfigured export folder as refused")
    func statusReportsNoExportRoot() async {
        let result = await call("recordings_status")
        #expect(result.text.contains("recording_export is refused"))
        // Unlike the export folder, the transcript cache is never "unconfigured" — it
        // always has a path, fixed under $TMPDIR, whether or not anything has used it yet.
        #expect(result.text.contains("0 transcript(s)"))
    }

    // MARK: Listing

    @Test("Listing returns one line per recording, newest first")
    func listReturnsRows() async {
        let result = await call("recordings_list")
        #expect(!result.isError)
        let ideaLine = result.text.range(of: "Half-asleep idea")
        let quarterlyLine = result.text.range(of: "Quarterly review notes")
        #expect(ideaLine != nil && quarterlyLine != nil)
        #expect(ideaLine!.lowerBound < quarterlyLine!.lowerBound)
        #expect(result.text.contains("1:02:05"))
        #expect(result.text.contains("3 recording(s)"))
        // A recording at the library root prints its folder as "(root)"; one filed under
        // a real folder prints that folder's name.
        #expect(result.text.contains("(root)"))
        #expect(result.text.contains("Ideas"))
    }

    @Test("Filters narrow the listing")
    func listFilters() async {
        let byName = await call("recordings_list", ["name_contains": .string("shopping")])
        #expect(byName.text.contains("Shopping list"))
        #expect(!byName.text.contains("Quarterly"))

        let byFolder = await call("recordings_list", ["folder": .string("Ideas")])
        #expect(byFolder.text.contains("Half-asleep idea"))
        #expect(!byFolder.text.contains("Shopping list"))

        // Both bounds name the same day on purpose. A plain day as `created_before`
        // covers that whole day — see the next test — so naming the 8th here would
        // include the recording made at 22:00 on the 8th rather than excluding it.
        let byDate = await call(
            "recordings_list",
            ["created_after": .string("2026-08-07"), "created_before": .string("2026-08-07")])
        #expect(byDate.text.contains("Shopping list"))
        #expect(!byDate.text.contains("Half-asleep idea"))
        #expect(!byDate.text.contains("Quarterly"))
    }

    /// A plain day read literally would exclude the whole of that day, so a one-day
    /// window would always be empty.
    @Test("created_before given as a plain day includes that whole day")
    func rangeEndCoversTheDay() async {
        let result = await call(
            "recordings_list",
            ["created_after": .string("2026-08-08"), "created_before": .string("2026-08-08")])
        #expect(result.text.contains("Half-asleep idea"))
    }

    @Test("A truncated listing says what it withheld")
    func listReportsTruncation() async {
        let result = await call("recordings_list", ["limit": .int(1)])
        #expect(result.text.contains("Showing 1–1 of 3"))
    }

    @Test("A page past the end says so instead of looking empty")
    func listReportsEmptyPage() async {
        let result = await call("recordings_list", ["offset": .int(99)])
        #expect(result.text.contains("3 match in total"))
    }

    @Test("An unreachable library explains Full Disk Access and the alternative")
    func listReportsUnreachableLibrary() async {
        let store = FakeRecordingStore(locations: Fixtures.unreachableLocations)
        let result = await call("recordings_list", store: store)
        #expect(result.isError)
        #expect(result.text.contains("Full Disk Access"))
        #expect(result.text.contains("Recording library folder"))
    }

    @Test("A bad date names all three accepted forms")
    func listRejectsBadDate() async {
        let result = await call("recordings_list", ["created_after": .string("last tuesday")])
        #expect(result.isError)
        #expect(result.text.contains("2026-08-12T09:00:00+02:00"))
    }

    // MARK: Detail

    @Test("Get returns the full record for several ids at once")
    func getReturnsDetails() async {
        let result = await call(
            "recording_get",
            ["ids": .array([.string("Ideas/20260808 220000.m4a"), .string("20260807 181500.m4a")])]
        )
        #expect(!result.isError)
        #expect(result.text.contains("/invented/Recordings/Ideas/20260808 220000.m4a"))
        #expect(result.text.contains("com.apple.m4a-audio"))
        #expect(result.text.contains("512 kB"))
    }

    @Test("Get reports ids that matched nothing alongside the ones that did")
    func getReportsMissing() async {
        let result = await call(
            "recording_get",
            ["ids": .array([.string("20260807 181500.m4a"), .string("nope.m4a")])])
        #expect(!result.isError)
        #expect(result.text.contains("Shopping list"))
        #expect(result.text.contains("Not found: nope.m4a"))
    }

    @Test("Get with no match at all is an error that explains what an id is")
    func getWithNoMatchesFails() async {
        let result = await call("recording_get", ["ids": .array([.string("nope.m4a")])])
        #expect(result.isError)
        #expect(result.text.contains("path relative to the library root"))
    }

    @Test("Get requires at least one id")
    func getRequiresIDs() async {
        let result = await call("recording_get", ["ids": .array([])])
        #expect(result.isError)
        #expect(result.text.contains("Missing required argument 'ids'"))
    }

    @Test("A single string where an array is expected is accepted")
    func getAcceptsASingleString() async {
        let result = await call("recording_get", ["ids": .string("20260807 181500.m4a")])
        #expect(!result.isError)
        #expect(result.text.contains("Shopping list"))
    }

    // MARK: Transcription

    @Test("Transcribing several recordings returns one block each")
    func transcribeReturnsBlocks() async {
        let store = FakeRecordingStore()
        let result = await call(
            "recording_transcribe",
            ["ids": .array([.string("20260807 181500.m4a"), .string("Ideas/20260808 220000.m4a")])],
            store: store)
        #expect(!result.isError)
        #expect(store.transcribed.count == 2)
        #expect(result.text.contains("transcribed on-device"))
        #expect(result.text.contains("This is the invented transcript."))
    }

    @Test("A repeated id is only transcribed once")
    func transcribeDeduplicates() async {
        let store = FakeRecordingStore()
        _ = await call(
            "recording_transcribe",
            ["ids": .array([.string("20260807 181500.m4a"), .string("20260807 181500.m4a")])],
            store: store)
        #expect(store.transcribed == ["20260807 181500.m4a"])
    }

    @Test("The batch cap is enforced and says how to raise it")
    func transcribeEnforcesCap() async {
        var configuration = Configuration()
        configuration.maximumTranscribeCount = 1
        let result = await call(
            "recording_transcribe",
            ["ids": .array([.string("20260807 181500.m4a"), .string("Ideas/20260808 220000.m4a")])],
            configuration: configuration)
        #expect(result.isError)
        #expect(result.text.contains("the maximum is 1"))
    }

    @Test("A locale with a recogniser but no model installed yet still transcribes")
    func transcribeProceedsWithUninstalledModel() async {
        // The real store downloads a missing model on demand rather than refusing outright
        // — see `TranscriptionEngine.ensureInstalled`. `supportsOnDevice: false` here must
        // not block the call before it reaches the store.
        let store = FakeRecordingStore(
            onDevice: OnDeviceSupport(
                localeIdentifier: "es-ES", recognizerExists: true, supportsOnDevice: false))
        let result = await call(
            "recording_transcribe", ["ids": .array([.string("20260807 181500.m4a")])],
            store: store)
        #expect(!result.isError)
        #expect(store.transcribed == ["20260807 181500.m4a"])
    }

    @Test("A locale with no recogniser at all is named as such")
    func transcribeRefusesUnknownLocale() async {
        let store = FakeRecordingStore(
            onDevice: OnDeviceSupport(
                localeIdentifier: "en-US", recognizerExists: false, supportsOnDevice: false))
        let result = await call(
            "recording_transcribe",
            ["ids": .array([.string("20260807 181500.m4a")]), "locale": .string("xx-XX")],
            store: store)
        #expect(result.isError)
        #expect(result.text.contains("no recogniser for 'xx-XX'"))
    }

    @Test("Denied speech permission gives the System Settings path")
    func transcribeRefusesWithoutPermission() async {
        let store = FakeRecordingStore(speechStatus: .denied)
        let result = await call(
            "recording_transcribe", ["ids": .array([.string("20260807 181500.m4a")])],
            store: store)
        #expect(result.isError)
        #expect(result.text.contains("Privacy & Security → Speech Recognition"))
        #expect(result.text.contains("Reconocimiento de voz"))
    }

    @Test("An undetermined permission is requested once, then used")
    func transcribeRequestsPermissionOnce() async {
        let store = FakeRecordingStore(speechStatus: .notDetermined)
        let result = await call(
            "recording_transcribe", ["ids": .array([.string("20260807 181500.m4a")])],
            store: store)
        #expect(!result.isError)
        #expect(store.accessRequests == 1)
    }

    /// A transcript costs minutes. One unreadable file in a batch must not throw away the
    /// ones that already succeeded.
    @Test("One failure in a batch does not lose the other transcripts")
    func transcribeSurvivesOneFailure() async {
        let store = FakeRecordingStore()
        store.unreadable = ["Ideas/20260808 220000.m4a"]
        let result = await call(
            "recording_transcribe",
            ["ids": .array([.string("20260807 181500.m4a"), .string("Ideas/20260808 220000.m4a")])],
            store: store)
        #expect(!result.isError)
        #expect(result.text.contains("This is the invented transcript."))
        #expect(result.text.contains("Failed: Ideas/20260808 220000.m4a"))
    }

    @Test("A batch where everything fails is an error, not an empty answer")
    func transcribeFailsWhenNothingSucceeds() async {
        let store = FakeRecordingStore()
        store.unreadable = ["20260807 181500.m4a"]
        let result = await call(
            "recording_transcribe", ["ids": .array([.string("20260807 181500.m4a")])],
            store: store)
        #expect(result.isError)
        #expect(result.text.contains("unreadable"))
    }

    @Test("Empty recognised speech is reported rather than looking like a blank answer")
    func transcribeReportsSilence() async {
        let store = FakeRecordingStore()
        store.transcriptText = ""
        let result = await call(
            "recording_transcribe", ["ids": .array([.string("20260807 181500.m4a")])],
            store: store)
        #expect(result.text.contains("(no speech recognised)"))
    }

    // MARK: Transcript cache

    @Test("A cached transcript is reused instead of transcribed again")
    func cacheAvoidsASecondPass() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicememos-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = FakeRecordingStore()
        let first = await call(
            "recording_transcribe", ["ids": .array([.string("20260807 181500.m4a")])],
            store: store, cacheDirectory: directory)
        #expect(first.text.contains("transcribed on-device"))

        let second = await call(
            "recording_transcribe", ["ids": .array([.string("20260807 181500.m4a")])],
            store: store, cacheDirectory: directory)
        #expect(second.text.contains("from cache"))
        #expect(store.transcribed.count == 1)
    }

    /// A recording replaced under the same name is a different recording. Serving the old
    /// text for it would be a lie no caller could detect.
    @Test("A changed file misses the cache")
    func cacheChecksTheFileItCached() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicememos-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = FakeRecordingStore()
        _ = await call(
            "recording_transcribe", ["ids": .array([.string("20260807 181500.m4a")])],
            store: store, cacheDirectory: directory)

        store.recordings = store.recordings.map { recording in
            guard recording.id == "20260807 181500.m4a" else { return recording }
            return Fixtures.recording(
                id: recording.id, name: recording.name, created: recording.created,
                byteSize: recording.byteSize + 1)
        }
        let second = await call(
            "recording_transcribe", ["ids": .array([.string("20260807 181500.m4a")])],
            store: store, cacheDirectory: directory)
        #expect(second.text.contains("transcribed on-device"))
        #expect(store.transcribed.count == 2)
    }

    @Test("A transcript cached for one locale is not served for another")
    func cacheIsKeyedByLocale() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicememos-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = FakeRecordingStore()
        _ = await call(
            "recording_transcribe",
            ["ids": .array([.string("20260807 181500.m4a")]), "locale": .string("en-US")],
            store: store, cacheDirectory: directory)
        let other = await call(
            "recording_transcribe",
            ["ids": .array([.string("20260807 181500.m4a")]), "locale": .string("es-ES")],
            store: store, cacheDirectory: directory)
        #expect(other.text.contains("transcribed on-device"))
        #expect(store.transcribed.count == 2)
    }

    @Test("Status counts what the cache holds")
    func statusCountsCacheEntries() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicememos-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = await call(
            "recording_transcribe", ["ids": .array([.string("20260807 181500.m4a")])],
            cacheDirectory: directory)
        let status = await call("recordings_status", cacheDirectory: directory)
        #expect(status.text.contains("1 transcript(s)"))
    }

    // MARK: Export

    @Test("Export copies into the configured folder and leaves the original alone")
    func exportCopies() async {
        var configuration = Configuration()
        configuration.exportRoot = "/invented/Exports"
        let store = FakeRecordingStore()

        let result = await call(
            "recording_export",
            ["id": .string("20260807 181500.m4a"), "destination": .string("notes/list.m4a")],
            store: store, configuration: configuration)
        #expect(!result.isError)
        #expect(store.copied.first?.destination.path == "/invented/Exports/notes/list.m4a")
        #expect(result.text.contains("The original is untouched"))
    }

    @Test("Export without a destination reuses the recording's own file name")
    func exportDefaultsToTheFileName() async {
        var configuration = Configuration()
        configuration.exportRoot = "/invented/Exports"
        let store = FakeRecordingStore()

        _ = await call(
            "recording_export", ["id": .string("Ideas/20260808 220000.m4a")],
            store: store, configuration: configuration)
        #expect(store.copied.first?.destination.path == "/invented/Exports/20260808 220000.m4a")
    }

    @Test("Export is refused outright when no folder is configured")
    func exportRefusesWithoutRoot() async {
        let store = FakeRecordingStore()
        let result = await call(
            "recording_export", ["id": .string("20260807 181500.m4a")], store: store)
        #expect(result.isError)
        #expect(result.text.contains("No export folder is configured"))
        #expect(store.copied.isEmpty)
    }

    @Test("Export refuses a destination that climbs out of the folder")
    func exportRefusesEscape() async {
        var configuration = Configuration()
        configuration.exportRoot = "/invented/Exports"
        let store = FakeRecordingStore()

        for escape in ["../secrets.m4a", "a/../../secrets.m4a", "/etc/secrets.m4a"] {
            let result = await call(
                "recording_export",
                ["id": .string("20260807 181500.m4a"), "destination": .string(escape)],
                store: store, configuration: configuration)
            #expect(result.isError, "\(escape) was not refused")
            #expect(result.text.contains("outside the configured export folder"))
        }
        #expect(store.copied.isEmpty)
    }

    /// The check has to be on the resolved path, not on the text: `a/../b` is inside the
    /// root and `a/../../b` is not, and neither of them looks different at a glance.
    @Test("Destination resolution normalises before it decides")
    func destinationResolutionNormalises() throws {
        let inside = try VoiceMemosTools.resolveDestination(
            "a/../b.m4a", inside: "/invented/Exports")
        #expect(inside.path == "/invented/Exports/b.m4a")

        #expect(throws: ToolError.self) {
            try VoiceMemosTools.resolveDestination("a/../../b.m4a", inside: "/invented/Exports")
        }
        // A root whose name is a prefix of a sibling must not be confused with it.
        #expect(throws: ToolError.self) {
            try VoiceMemosTools.resolveDestination("../Exports-other/b.m4a", inside: "/invented/Exports")
        }
    }

    @Test("Export of an unknown id fails before anything is copied")
    func exportRejectsUnknownID() async {
        var configuration = Configuration()
        configuration.exportRoot = "/invented/Exports"
        let store = FakeRecordingStore()

        let result = await call(
            "recording_export", ["id": .string("nope.m4a")],
            store: store, configuration: configuration)
        #expect(result.isError)
        #expect(store.copied.isEmpty)
    }

    // MARK: Routing

    @Test("An unknown tool name is refused by name")
    func unknownToolIsRefused() async {
        let result = await call("recordings_summarise")
        #expect(result.isError)
        #expect(result.text.contains("is not a tool of this server"))
    }
}
