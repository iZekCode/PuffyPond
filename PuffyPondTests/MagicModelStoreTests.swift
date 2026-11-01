import Testing
import Foundation
import CryptoKit
import AppleArchive
import System
@testable import PuffyPond

@MainActor
struct MagicModelStoreTests {
    private let version = "test-v1"

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "MagicStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func store(_ root: URL, remote: URL = URL(string: "file:///nonexistent")!, sha256: String = "") -> MagicModelStore {
        MagicModelStore(root: root, version: version, remote: remote, sha256: sha256)
    }

    @Test func readyOnlyWhenFinalFolderExists() throws {
        let root = try makeRoot()
        #expect(store(root).state == .notDownloaded)

        let resources = root.appending(path: "\(version)/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: resources.appending(path: "vocab.json"))
        #expect(store(root).state == .ready(resources))
    }

    @Test func partialDownloadIsNotReady() throws {
        let root = try makeRoot()
        let partial = root.appending(path: "\(version).partial")
        try FileManager.default.createDirectory(at: partial.appending(path: "Resources"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: partial.appending(path: "Resources/vocab.json"))

        #expect(store(root).state == .notDownloaded)
        #expect(!FileManager.default.fileExists(atPath: partial.path))
    }

    @Test func emptyFinalFolderIsNotReady() throws {
        let root = try makeRoot()
        try FileManager.default.createDirectory(at: root.appending(path: version), withIntermediateDirectories: true)
        #expect(store(root).state == .notDownloaded)
    }

    @Test func wrongChecksumFails() async throws {
        let root = try makeRoot()
        let fake = root.appending(path: "fake.aar")
        try Data("not an archive".utf8).write(to: fake)

        let s = store(root, remote: fake, sha256: String(repeating: "0", count: 64))
        await s.download()

        guard case .failed = s.state else {
            Issue.record("expected .failed, got \(s.state)")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: version).path))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "\(version).partial").path))
    }

    @Test func goodArchiveBecomesReady() async throws {
        let root = try makeRoot()
        let source = root.appending(path: "src")
        try FileManager.default.createDirectory(at: source.appending(path: "Resources"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: source.appending(path: "Resources/vocab.json"))
        let archive = root.appending(path: "magic.aar")
        try Self.pack(source, to: archive)
        let sha = SHA256.hash(data: try Data(contentsOf: archive)).map { String(format: "%02x", $0) }.joined()

        let s = store(root, remote: archive, sha256: sha)
        await s.download()

        let resources = root.appending(path: "\(version)/Resources")
        #expect(s.state == .ready(resources))
        #expect(FileManager.default.fileExists(atPath: resources.appending(path: "vocab.json").path))
    }

    @Test func downloadNeverDeletesTheSourceArchive() async throws {
        let root = try makeRoot()
        let source = root.appending(path: "keep.aar")
        try Data("not an archive".utf8).write(to: source)
        await store(root, remote: source, sha256: "00").download()
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func deleteForgetsTheModel() throws {
        let root = try makeRoot()
        let resources = root.appending(path: "\(version)/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: resources.appending(path: "vocab.json"))
        let s = store(root)
        #expect(s.state == .ready(resources))

        s.delete()
        #expect(s.state == .notDownloaded)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: version).path))
    }

    /// Same format as `aa archive -d <dir> -o <file>`.
    private static func pack(_ directory: URL, to file: URL) throws {
        let out = try #require(ArchiveByteStream.fileStream(path: FilePath(file.path), mode: .writeOnly,
                                                            options: [.create], permissions: FilePermissions(rawValue: 0o644)))
        defer { try? out.close() }
        let compress = try #require(ArchiveByteStream.compressionStream(using: .lzfse, writingTo: out))
        defer { try? compress.close() }
        let encode = try #require(ArchiveStream.encodeStream(writingTo: compress))
        defer { try? encode.close() }
        let keys = try #require(ArchiveHeader.FieldKeySet("TYP,PAT,DAT,MOD"))
        try encode.writeDirectoryContents(archiveFrom: FilePath(directory.path), keySet: keys)
    }
}
