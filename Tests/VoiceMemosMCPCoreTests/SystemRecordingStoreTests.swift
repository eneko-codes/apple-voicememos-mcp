import Foundation
import Testing

@testable import VoiceMemosMCPCore

/// Exercises `SystemRecordingStore.libraries()` below the `RecordingStore` seam, against
/// synthetic directories under `$TMPDIR` — never against Voice Memos' own store. The point
/// is the distinction `FileManager.fileExists` cannot make: a path that is truly absent
/// (`ENOENT`) versus one that exists but denied the `stat` call itself (`EACCES`), which is
/// exactly what the sandboxed Voice Memos container does without Full Disk Access.
@Suite("SystemRecordingStore library probing")
struct SystemRecordingStoreTests {

    private func configuration(libraryPath: String) -> Configuration {
        var configuration = Configuration()
        configuration.libraryPath = libraryPath
        return configuration
    }

    private func withScratchRoot(_ body: (URL) throws -> Void) rethrows {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicememos-probe-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            // Restore traversal permission before removal — an unreadable parent would
            // otherwise make the cleanup itself fail.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        try body(root)
    }

    @Test("A readable directory reports exists and readable")
    func readableDirectory() throws {
        try withScratchRoot { root in
            let configuration = self.configuration(libraryPath: root.path)
            let location = SystemRecordingStore(configuration: configuration).libraries()[0]
            #expect(location.exists)
            #expect(location.isReadable)
        }
    }

    @Test("A path with no such component reports missing, not unreadable")
    func genuinelyAbsentPath() throws {
        try withScratchRoot { root in
            let missing = root.appendingPathComponent("does-not-exist").path
            let configuration = self.configuration(libraryPath: missing)
            let location = SystemRecordingStore(configuration: configuration).libraries()[0]
            #expect(!location.exists)
            #expect(!location.isReadable)
        }
    }

    @Test("A path behind a non-traversable parent reports unreadable, not missing")
    func deniedAtStat() throws {
        try withScratchRoot { root in
            let parent = root.appendingPathComponent("locked", isDirectory: true)
            let child = parent.appendingPathComponent("Recordings", isDirectory: true)
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
            // Removing search (x) permission on the parent is what makes `stat` on the
            // child fail with EACCES — chmod-ing the child itself would not, since `stat`
            // needs no permission on its own target.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o000], ofItemAtPath: parent.path)

            let configuration = self.configuration(libraryPath: child.path)
            let location = SystemRecordingStore(configuration: configuration).libraries()[0]
            #expect(location.exists)
            #expect(!location.isReadable)
        }
    }
}
