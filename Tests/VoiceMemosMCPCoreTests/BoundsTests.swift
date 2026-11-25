import Foundation
import Testing

@testable import VoiceMemosMCPCore

/// The edges of the tool standard for this server's tools: each bound and one past it, the
/// text of each notice, pages and windows that chain, the longest result, the deadline, and
/// the texts the model reads. Every recording, name and transcript in here is invented.
@Suite("Bounds")
struct BoundsTests {

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func call(
        _ name: String, _ arguments: [String: Value] = [:], store: FakeRecordingStore,
        configuration: Configuration = Configuration(),
        transcribeTimeout: Duration = Configuration.transcribeTimeout
    ) async -> (text: String, isError: Bool) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicememos-bounds-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tools = VoiceMemosTools(
            store: store, calendar: Fixtures.calendar, configuration: configuration,
            cacheDirectory: directory, now: { Fixtures.now }, transcribeTimeout: transcribeTimeout)
        let result = await tools.handle(.init(name: name, arguments: arguments))
        guard case .text(let text) = result.content.first else { return ("(no text)", true) }
        return (text, result.isError)
    }

    /// `count` recordings, each recorded a minute after the one before, with ids 100
    /// characters long and names 300 characters long: wider than any ordinary row.
    private static func library(_ count: Int) -> [RecordingDetail] {
        (0..<count).map { index in
            let stem = String(format: "%04d ", index)
            let id = "Invented folder/" + stem + String(repeating: "i", count: 79 - stem.count) + ".m4a"
            return Fixtures.recording(
                id: id, name: stem + String(repeating: "n", count: 300 - stem.count),
                created: Fixtures.date(2026, 1, 1).addingTimeInterval(Double(index) * 60),
                folder: "Invented folder")
        }
    }

    private func ids(_ recordings: [RecordingDetail]) -> Value {
        .array(recordings.map { .string($0.id) })
    }

    private func utf16(_ text: String) -> Int { text.utf16.count }

    // MARK: Listing

    @Test("The default page is about one usual page and holds the newest rows")
    func defaultListing() async {
        let store = FakeRecordingStore(recordings: Self.library(300))
        let result = await call("recordings_list", store: store)
        #expect(!result.isError)
        #expect(result.text.hasPrefix("Showing 1–50 of 300 recordings. Pass offset=50 for the next page."))
        #expect(utf16(result.text) <= ToolStandard.usualPage * 2)
    }

    @Test("The longest page fits the longest result, however wide its rows")
    func longestListing() async {
        let store = FakeRecordingStore(recordings: Self.library(300))
        for limit in [Configuration.listLimitRange.upperBound, 5000] {
            let result = await call("recordings_list", ["limit": .int(limit)], store: store)
            #expect(utf16(result.text) <= ToolStandard.longestResult, "limit=\(limit)")
        }
        let past = await call("recordings_list", ["limit": .int(5000)], store: store)
        #expect(past.text.hasPrefix("limit=5000 is outside 1–100; 100 was used.\n"))
    }

    @Test("A page below the range is moved up and says so")
    func limitBelowRange() async {
        let store = FakeRecordingStore(recordings: Self.library(5))
        let result = await call("recordings_list", ["limit": .int(0), "offset": .int(-3)], store: store)
        #expect(result.text.hasPrefix("limit=0 is outside 1–100; 1 was used.\noffset=-3 is outside 0–10000000; 0 was used.\n"))
        #expect(result.text.contains("Showing 1–1 of 5 recordings. Pass offset=1 for the next page."))
    }

    @Test("The second page starts where the first ended and the last says that is all")
    func pagesChain() async {
        let library = Self.library(7)
        let store = FakeRecordingStore(recordings: library)
        // Newest first: the last recorded has the highest index.
        let newestFirst = library.reversed().map(\.id)
        for offset in [0, 3, 6] {
            let page = await call(
                "recordings_list", ["limit": .int(3), "offset": .int(offset)], store: store)
            let shown = library.map(\.id).filter { page.text.contains($0) }
            #expect(Set(shown) == Set(newestFirst.dropFirst(offset).prefix(3)), "offset=\(offset)")
            if offset == 3 {
                #expect(page.text.hasPrefix("Showing 4–6 of 7 recordings. Pass offset=6 for the next page."))
            }
            if offset == 6 {
                #expect(page.text.hasPrefix("Showing 7–7 of 7 recordings. That is all."))
            }
        }
    }

    @Test("Recordings made at the same instant are ordered by id")
    func noTies() async {
        let same = Fixtures.date(2026, 3, 3, 10, 0)
        let store = FakeRecordingStore(
            recordings: ["b.m4a", "c.m4a", "a.m4a"].map {
                Fixtures.recording(id: $0, name: $0, created: same)
            })
        let result = await call("recordings_list", store: store)
        let positions = ["a.m4a", "b.m4a", "c.m4a"].map { result.text.range(of: "  \($0)")!.lowerBound }
        #expect(positions == positions.sorted())
    }

    @Test("A clipped name is announced only when one was clipped, and recording_get reads it whole")
    func clippedName() async throws {
        let long = await call("recordings_list", ["limit": .int(2)], store: FakeRecordingStore(recordings: Self.library(3)))
        #expect(long.text.contains(
            "Name is clipped to 80 characters in each row. Read one in full with recording_get."))
        #expect(!long.text.contains(String(repeating: "n", count: 81)))

        let short = await call("recordings_list", store: FakeRecordingStore())
        #expect(!short.text.contains("clipped"))

        let library = Self.library(1)
        let whole = await call("recording_get", ["ids": ids(library)], store: FakeRecordingStore(recordings: library))
        #expect(whole.text.contains(library[0].name))
    }

    @Test("A scan that stopped early is announced before the data")
    func scanStopped() async {
        let store = FakeRecordingStore()
        store.scanStoppedAfter = 3
        let result = await call("recordings_list", store: store)
        #expect(result.text.hasPrefix(
            "The scan stopped after 3 recordings; more may exist. Narrow by folder, name_contains, from_date or to_date."))
    }

    @Test("The date filters are inclusive, refuse what does not exist and an end before the start")
    func dateEdges() async {
        let store = FakeRecordingStore()
        // 18:15 on the 7th: to_date written to the minute includes it, one minute earlier does not.
        let included = await call("recordings_list", ["from_date": .string("2026-08-07"), "to_date": .string("2026-08-07T18:15")], store: store)
        #expect(included.text.contains("Shopping list"))
        let excluded = await call("recordings_list", ["from_date": .string("2026-08-07"), "to_date": .string("2026-08-07T18:14")], store: store)
        #expect(!excluded.text.contains("Shopping list"))

        let onlyFrom = await call("recordings_list", ["from_date": .string("2026-08-08")], store: store)
        #expect(onlyFrom.text.contains("Half-asleep idea") && !onlyFrom.text.contains("Quarterly"))

        let impossible = await call("recordings_list", ["to_date": .string("2026-02-30")], store: store)
        #expect(impossible.isError && impossible.text.contains("not a date this server accepts"))

        let backwards = await call("recordings_list", ["from_date": .string("2026-08-08"), "to_date": .string("2026-08-07")], store: store)
        #expect(backwards.isError)
        #expect(backwards.text == "to_date is before from_date. A date range cannot end before it begins.")
    }

    @Test("A renamed argument fails clearly and a wrong type is refused")
    func refusals() async {
        let store = FakeRecordingStore()
        let old = await call("recordings_list", ["created_after": .string("2026-08-01")], store: store)
        #expect(old.isError)
        #expect(old.text.hasPrefix("Not an argument of this tool: 'created_after'. Allowed: folder, from_date, limit, name_contains, offset, to_date."))

        let wrongType = await call("recordings_list", ["limit": .string("ten")], store: store)
        #expect(wrongType.isError)
        #expect(wrongType.text == "Argument 'limit' is not valid: a whole number was expected")

        let wrongText = await call("recordings_list", ["folder": .int(4)], store: store)
        #expect(wrongText.text == "Argument 'folder' is not valid: text was expected")

        let longName = String(repeating: "x", count: 500)
        let tool = await call(longName, store: store)
        #expect(tool.isError && utf16(tool.text) < 200)
        let argument = await call("recordings_status", [longName: .bool(true)], store: store)
        #expect(argument.isError && utf16(argument.text) < 300)
    }

    // MARK: recording_get

    @Test("recording_get takes the most ids it advertises and refuses one more")
    func getBound() async {
        let library = Self.library(Configuration.maximumGetIDs + 1)
        let store = FakeRecordingStore(recordings: library)
        let atMaximum = await call("recording_get", ["ids": ids(Array(library.prefix(Configuration.maximumGetIDs)))], store: store)
        #expect(!atMaximum.isError)
        #expect(utf16(atMaximum.text) <= ToolStandard.longestResult)

        let past = await call("recording_get", ["ids": ids(library)], store: store)
        #expect(past.isError)
        #expect(past.text.hasPrefix("11 ids were given; this tool takes at most 10 per call."))
    }

    @Test("A long list of missing ids is cut to a few with the count of the others")
    func missingIDsAreCut() async {
        let asked = (0..<10).map { Value.string("missing-\($0)-" + String(repeating: "z", count: 200) + ".m4a") }
        let result = await call("recording_get", ["ids": .array(asked)], store: FakeRecordingStore())
        #expect(result.isError)
        #expect(result.text.contains("and 5 more"))
        #expect(utf16(result.text) < 1500)
    }

    // MARK: recording_transcribe

    private static let longText = String((0..<50_000).map { Character(UnicodeScalar(97 + $0 % 26)!) })

    @Test("A long transcript comes through a window and the next window starts where it ended")
    func transcriptWindows() async {
        let store = FakeRecordingStore()
        store.transcriptText = Self.longText
        let id = "20260807 181500.m4a"

        let first = await call("recording_transcribe", ["ids": .array([.string(id)])], store: store)
        #expect(first.text.hasPrefix(
            "id=\(id): characters 1–10000 of 50000. Pass character_offset=10000 for the rest."))
        #expect(utf16(first.text) <= ToolStandard.usualPage + 1000)

        let second = await call(
            "recording_transcribe",
            ["ids": .array([.string(id)]), "character_offset": .int(10_000), "max_characters": .int(20_000)],
            store: store)
        #expect(second.text.hasPrefix(
            "id=\(id): characters 10001–30000 of 50000. Pass character_offset=30000 for the rest."))
        #expect(utf16(second.text) <= ToolStandard.longestResult)
        let third = await call(
            "recording_transcribe",
            ["ids": .array([.string(id)]), "character_offset": .int(30_000), "max_characters": .int(20_000)],
            store: store)
        #expect(third.text.hasPrefix("id=\(id): characters 30001–50000 of 50000. That is all."))
        // 20,000 is the most one window may hold.
        let clamped = await call(
            "recording_transcribe",
            ["ids": .array([.string(id)]), "max_characters": .int(30_000)], store: store)
        #expect(clamped.text.hasPrefix("max_characters=30000 is outside 1–20000; 20000 was used.\n"))
        #expect(utf16(clamped.text) <= ToolStandard.longestResult)

        let pastEnd = await call(
            "recording_transcribe",
            ["ids": .array([.string(id)]), "character_offset": .int(60_000)], store: store)
        #expect(pastEnd.text.hasPrefix(
            "id=\(id): characters 0 of 50000: character_offset=60000 is past the end. That is all."))
    }

    @Test("Several transcripts share one usual page, and the largest batch at the largest window fits")
    func transcriptBatches() async {
        let library = Self.library(Configuration.transcribeCountRange.upperBound)
        let store = FakeRecordingStore(recordings: library)
        store.transcriptText = Self.longText
        var configuration = Configuration()
        configuration.maximumTranscribeCount = Configuration.transcribeCountRange.upperBound

        let shared = await call("recording_transcribe", ["ids": ids(Array(library.prefix(4)))], store: store, configuration: configuration)
        #expect(shared.text.contains("(ask for it alone): characters 1–2500 of 50000. Pass character_offset=2500 for the rest."))
        #expect(shared.text.contains("Name is clipped to 80 characters in each row. Read one in full with recording_get."))

        let largest = await call(
            "recording_transcribe",
            ["ids": ids(library), "max_characters": .int(Configuration.maxCharactersRange.upperBound)],
            store: store, configuration: configuration)
        #expect(!largest.isError)
        #expect(utf16(largest.text) <= ToolStandard.longestResult)
        // Windows that had to shrink say where each one ends, so nothing is lost.
        #expect(largest.text.contains("Pass character_offset="))
    }

    @Test("A transcript of characters that take several UTF-16 units still fits")
    func wideCharacters() async {
        let store = FakeRecordingStore()
        store.transcriptText = String(repeating: "👩‍👩‍👧‍👧", count: 20_000)
        let result = await call(
            "recording_transcribe",
            ["ids": .array([.string("20260807 181500.m4a")]), "max_characters": .int(20_000)], store: store)
        #expect(utf16(result.text) <= ToolStandard.longestResult)
    }

    @Test("Asking for more ids than the setting allows is refused, and no setting exceeds its range")
    func transcribeBound() async {
        var configuration = Configuration()
        configuration.maximumTranscribeCount = 2
        let library = Self.library(3)
        let result = await call(
            "recording_transcribe", ["ids": ids(library)],
            store: FakeRecordingStore(recordings: library), configuration: configuration)
        #expect(result.isError)
        #expect(result.text.hasPrefix("3 ids were given; this tool takes at most 2 per call."))

        let parsed = Configuration.parse(["--list-limit", "5000", "--max-transcribe", "99"])
        #expect(parsed.listLimit == Configuration.listLimitRange.upperBound)
        #expect(parsed.maximumTranscribeCount == Configuration.transcribeCountRange.upperBound)
        let low = Configuration.parse(["--list-limit", "0", "--max-transcribe", "-4"])
        #expect(low.listLimit == 1 && low.maximumTranscribeCount == 1)
    }

    @Test("At the deadline the transcripts finished so far come back, marked partial")
    func partialTranscripts() async {
        let store = FakeRecordingStore()
        store.stalled = ["Ideas/20260808 220000.m4a"]
        let started = ContinuousClock.now
        let result = await call(
            "recording_transcribe",
            ["ids": .array([.string("20260807 181500.m4a"), .string("Ideas/20260808 220000.m4a"), .string("20260803 090000.m4a")])],
            store: store, transcribeTimeout: .seconds(1))
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(!result.isError)
        #expect(result.text.hasPrefix(
            "Partial: the time limit was reached after 1 recordings. Narrow by ids."))
        #expect(result.text.contains("This is the invented transcript."))
        #expect(result.text.contains("Not transcribed before the time limit:\n  Ideas/20260808 220000.m4a\n  20260803 090000.m4a"))
        // The recording after the stalled one was never started.
        #expect(store.transcribed == ["20260807 181500.m4a"])
    }

    @Test("A deadline with nothing finished is an error that says how to ask for less")
    func nothingFinished() async {
        let store = FakeRecordingStore()
        store.stalled = ["20260807 181500.m4a"]
        let result = await call(
            "recording_transcribe", ["ids": .array([.string("20260807 181500.m4a")])],
            store: store, transcribeTimeout: .seconds(1))
        #expect(result.isError)
        #expect(result.text.contains("did not finish within 1 seconds"))
        #expect(result.text.contains("only reads"))
    }

    @Test("The timeout error of a copy says the file may still have been written")
    func exportTimeoutMessage() {
        let message = ToolError.timedOut(seconds: 45, mayHaveWritten: true).message
        #expect(message.contains("may still have been written"))
        #expect(!ToolError.timedOut(seconds: 45, mayHaveWritten: false).message.contains("may still"))
    }

    @Test("Every deadline sits inside the time limit a call may take")
    func deadlines() {
        #expect(Configuration.timeout < ToolStandard.timeLimit)
        #expect(Configuration.transcribeTimeout < ToolStandard.timeLimit)
        #expect(Configuration.scanTime < Configuration.timeout)
    }

    // MARK: The texts the model reads

    @Test("No instructions or description is longer than a client reads")
    func textsAreShortEnough() {
        var widest = Configuration()
        widest.maximumTranscribeCount = Configuration.transcribeCountRange.upperBound
        widest.listLimit = Configuration.listLimitRange.upperBound
        widest.exportRoot = String(repeating: "/very-long-folder", count: 20)
        for configuration in [Configuration(), widest] {
            #expect(
                ToolStandard.overlongTexts(
                    instructions: VoiceMemosMCPServer.instructions,
                    catalog: ToolCatalog.all(configuration)).isEmpty)
        }
    }

    @Test("Descriptions lead with what a call returns and state the bounds the code enforces")
    func descriptionsStateTheBounds() throws {
        let tools = ToolCatalog.all()
        let list = try #require(tools.first { $0.name == "recordings_list" }?.description)
        #expect(list.contains("newest first (ties by id), 50 to a page"))
        #expect(list.contains("limit goes up to \(Configuration.listLimitRange.upperBound)"))
        let transcribe = try #require(tools.first { $0.name == "recording_transcribe" }?.description)
        #expect(transcribe.contains("up to \(Configuration.maxCharactersRange.upperBound)"))
        for tool in tools {
            let properties = tool.inputSchema.objectValue?["properties"]?.objectValue ?? [:]
            for (name, schema) in properties where schema.objectValue?["maximum"] != nil {
                let range = (schema.objectValue?["minimum"]?.intValue)!...(schema.objectValue?["maximum"]?.intValue)!
                #expect(range.lowerBound <= range.upperBound, "\(tool.name).\(name)")
            }
        }
        let instructions = VoiceMemosMCPServer.instructions
        #expect(instructions.contains("\(Configuration.transcribeTimeout.components.seconds)-second limit"))
    }

    @Test("The manifest, the server constant and Info.plist carry the same version")
    func versionsAgree() throws {
        let manifest = try manifestJSON()
        #expect(manifest["version"] as? String == VoiceMemosMCPServer.version)
        let data = try Data(contentsOf: Self.root.appendingPathComponent("Resources/Info.plist"))
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["CFBundleShortVersionString"] as? String == VoiceMemosMCPServer.version)
    }

    @Test("The manifest lists exactly the tools the server offers")
    func manifestListsEveryTool() throws {
        let listed = try #require(try manifestJSON()["tools"] as? [[String: Any]])
        #expect(Set(listed.compactMap { $0["name"] as? String }) == Set(ToolCatalog.all().map(\.name)))
    }

    /// The manifest and the README are plain text and cannot take a figure from a constant,
    /// so this holds the figures they state to the ones the code enforces, and the names of
    /// the arguments to the schemas.
    @Test("The manifest and the README state the figures and argument names the code enforces")
    func prosePointsAtTheCode() throws {
        let manifest = try manifestJSON()
        // Prose wraps, so a figure and the words round it may sit on two lines.
        let readme = try String(
            contentsOf: Self.root.appendingPathComponent("README.md"), encoding: .utf8
        ).replacingOccurrences(of: "\n", with: " ")
        let configuration = try #require(manifest["user_config"] as? [String: [String: Any]])
        let page = try #require(configuration["list_limit"]?["description"] as? String)
        #expect(page.contains("from \(Configuration.listLimitRange.lowerBound) to \(Configuration.listLimitRange.upperBound)"))
        let transcriptions = try #require(configuration["max_transcribe"]?["description"] as? String)
        #expect(transcriptions.contains("from \(Configuration.transcribeCountRange.lowerBound) to \(Configuration.transcribeCountRange.upperBound)"))
        let tools = try #require(manifest["tools"] as? [[String: Any]])
        let get = try #require(tools.first { $0["name"] as? String == "recording_get" }?["description"] as? String)
        #expect(get.contains("1 to \(Configuration.maximumGetIDs) recordings"))

        #expect(readme.contains("(at most \(Configuration.maximumGetIDs))"))
        #expect(readme.contains("about \(Self.grouped(Configuration.defaultMaxCharacters)) characters"))
        #expect(readme.contains("clips a name to \(Configuration.listNameWidth) characters"))
        #expect(readme.contains("after \(Configuration.timeout.components.seconds) seconds"))
        #expect(readme.contains("within \(Configuration.scanTime.components.seconds) seconds"))
        #expect(readme.contains("reaches \(Self.grouped(Configuration.scanLimit)) matches"))
        #expect(readme.contains("has \(Configuration.transcribeTimeout.components.seconds) seconds"))
        #expect(readme.contains("configurable 1–\(Configuration.transcribeCountRange.upperBound)"))

        for tool in ToolCatalog.all() {
            for name in ToolCatalog.argumentNames(of: tool.name) {
                #expect(readme.contains("`\(name)`"), "\(tool.name).\(name) is not in the README")
            }
        }
        let text = readme + (manifest["long_description"] as? String ?? "")
        #expect(!text.contains("`created_after`, `created_before`") || text.contains("is now `from_date`"))
        #expect(!(manifest["long_description"] as? String ?? "").contains("created_"))
    }

    /// 10000 as the README writes it, whatever the machine's locale.
    private static func grouped(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: number))!
    }

    private func manifestJSON() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("extension/manifest.json"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: The walk of a real folder, of invented empty files

    private func withLibrary(_ names: [String], _ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicememos-walk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in names {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        try body(root)
    }

    @Test("A walk stops at its ceiling, says so, and orders what it found without ties")
    func walkCeiling() throws {
        try withLibrary(["c.m4a", "a.m4a", "b.m4a", "d.m4a", "notes.txt"]) { root in
            let store = SystemRecordingStore()
            let all = try store.walk(root, limit: 10, budget: .seconds(60)) { _, _ in true }
            #expect(all.stop == nil)
            #expect(all.entries.count == 4)
            let again = try store.walk(root, limit: 10, budget: .seconds(60)) { _, _ in true }
            #expect(all.entries.map(\.relativePath) == again.entries.map(\.relativePath))

            let capped = try store.walk(root, limit: 3, budget: .seconds(60)) { _, _ in true }
            #expect(capped.stop == .ceiling)
            #expect(capped.entries.count == 3)

            // Exactly the ceiling is not a stop: nothing more exists.
            let exact = try store.walk(root, limit: 4, budget: .seconds(60)) { _, _ in true }
            #expect(exact.stop == nil)

            // A filter narrows what counts towards the ceiling.
            let narrowed = try store.walk(root, limit: 1, budget: .seconds(60)) { path, _ in path == "a.m4a" }
            #expect(narrowed.stop == nil && narrowed.entries.map(\.relativePath) == ["a.m4a"])
        }
    }

    @Test("A walk that runs out of time says so, and one asked for ids ends when it has them")
    func walkTime() throws {
        try withLibrary(["a.m4a", "b.m4a", "sub/c.m4a"]) { root in
            let store = SystemRecordingStore()
            let late = try store.walk(root, limit: 10, budget: .zero) { _, _ in true }
            #expect(late.stop == .time)

            let found = try store.walk(root, limit: .max, budget: .seconds(60), stopAfter: 1) { path, _ in
                path == "sub/c.m4a"
            }
            #expect(found.stop == nil && found.entries.count == 1)
        }
    }
}
