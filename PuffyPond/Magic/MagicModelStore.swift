import Foundation
import Observation
import CryptoKit
import AppleArchive
import System

/// Which model download this build of the app expects. The files are never bundled in the app.
enum MagicModelRelease {
    static let version = "lcm-dreamshaper7-scribble-640x384-v1"
    /// Placeholder until the converted models are hosted (see docs/superpowers/plans/2026-11-01-ai-magic-spike-results.md).
    static let url = URL(string: "https://example.invalid/puffypond/magic-v1.aar")!
    /// SHA-256 of the archive, lowercase hex. Empty until the archive is published: every download then fails safely.
    static let sha256 = ""
}

/// Downloads, verifies and unpacks the Magic models into `<root>/<version>/Resources`.
/// A half-finished download only ever lives in `<version>.partial`, which is thrown away.
@Observable
final class MagicModelStore {
    enum State: Equatable {
        case notDownloaded
        case downloading(progress: Double)
        case ready(URL)
        case failed(String)
    }

    private(set) var state: State

    @ObservationIgnored private let root: URL
    @ObservationIgnored private let version: String
    @ObservationIgnored private let remote: URL
    @ObservationIgnored private let sha256: String

    init(root: URL = .applicationSupportDirectory.appending(path: "MagicModels"),
         version: String = MagicModelRelease.version,
         remote: URL = MagicModelRelease.url,
         sha256: String = MagicModelRelease.sha256) {
        self.root = root
        self.version = version
        self.remote = remote
        self.sha256 = sha256
        try? FileManager.default.removeItem(at: root.appending(path: "\(version).partial"))
        state = Self.readyState(root.appending(path: version)) ?? .notDownloaded
    }

    private var finalFolder: URL { root.appending(path: version) }
    private var partialFolder: URL { root.appending(path: "\(version).partial") }

    private static func readyState(_ folder: URL) -> State? {
        let resources = folder.appending(path: "Resources")
        return FileManager.default.fileExists(atPath: resources.appending(path: "vocab.json").path)
            ? .ready(resources) : nil
    }

    func download() async {
        switch state {
        case .downloading, .ready: return
        case .notDownloaded, .failed: break
        }
        state = .downloading(progress: 0)
        let archiveURL: URL
        do {
            let progress = ProgressReporter { [weak self] fraction in
                Task { @MainActor in
                    guard let self, case .downloading = self.state else { return }
                    self.state = .downloading(progress: fraction)
                }
            }
            let (file, _) = try await URLSession.shared.download(from: remote, delegate: progress)
            archiveURL = file
        } catch {
            state = .failed("Couldn't download: \(error.localizedDescription)")
            return
        }

        let (root, final, partial, sha) = (root, finalFolder, partialFolder, sha256)
        do {
            try await Task.detached {
                try Self.install(archive: archiveURL, sha256: sha, root: root, partial: partial, final: final)
            }.value
            state = Self.readyState(final) ?? .failed("The model files are incomplete")
        } catch {
            try? FileManager.default.removeItem(at: partial)
            state = .failed(error.localizedDescription)
        }
    }

    func delete() {
        try? FileManager.default.removeItem(at: finalFolder)
        try? FileManager.default.removeItem(at: partialFolder)
        state = .notDownloaded
    }

    // MARK: Install

    private enum Failure: LocalizedError {
        case checksum, extraction, incomplete
        var errorDescription: String? {
            switch self {
            case .checksum: return "The download is damaged (checksum mismatch)"
            case .extraction: return "Couldn't unpack the download"
            case .incomplete: return "The download is missing model files"
            }
        }
    }

    private nonisolated static func install(archive: URL, sha256 expected: String, root: URL,
                                            partial: URL, final: URL) throws {
        let fm = FileManager.default
        guard try checksum(of: archive) == expected.lowercased() else { throw Failure.checksum }

        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try? fm.removeItem(at: partial)
        try fm.createDirectory(at: partial, withIntermediateDirectories: true)
        try extract(archive, to: partial)
        guard fm.fileExists(atPath: partial.appending(path: "Resources/vocab.json").path) else { throw Failure.incomplete }

        try? fm.removeItem(at: final)
        try fm.moveItem(at: partial, to: final)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true            // a re-downloadable 1+ GB model
        var mutable = final
        try? mutable.setResourceValues(values)
    }

    private nonisolated static func checksum(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func extract(_ archive: URL, to folder: URL) throws {
        guard let source = ArchiveByteStream.fileStream(path: FilePath(archive.path), mode: .readOnly,
                                                        options: [], permissions: FilePermissions(rawValue: 0)),
              let decompress = ArchiveByteStream.decompressionStream(readingFrom: source),
              let decode = ArchiveStream.decodeStream(readingFrom: decompress),
              let extractor = ArchiveStream.extractStream(extractingTo: FilePath(folder.path),
                                                          flags: [.ignoreOperationNotPermitted])
        else { throw Failure.extraction }
        defer {
            try? extractor.close()
            try? decode.close()
            try? decompress.close()
            try? source.close()
        }
        do {
            _ = try ArchiveStream.process(readingFrom: decode, writingTo: extractor)
        } catch {
            throw Failure.extraction
        }
    }
}

/// Reports download progress for one `URLSession.download` call.
private final class ProgressReporter: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let report: @Sendable (Double) -> Void
    init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        report(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
