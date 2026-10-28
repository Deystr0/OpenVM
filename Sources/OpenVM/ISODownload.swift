// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 OpenVM contributors
// This file is part of OpenVM, free software under the GNU General Public License v3.0 or later (see LICENSE).

import CryptoKit
import Foundation

/// Receives URLSession callbacks off the main actor and bridges them to async/await.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    /// Redirects (the Fedora and Kali download hosts hand out mirrors) may only go to https.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" ? request : nil)
    }

    let destination: URL
    let onProgress: @Sendable (Double) -> Void
    var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?

    init(destination: URL, onProgress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten written: Int64, totalBytesExpectedToWrite expected: Int64) {
        if expected > 0 { onProgress(Double(written) / Double(expected)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temp file is deleted when this returns, so move it here.
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            failure = VMError(message: "Download failed: HTTP \(http.statusCode)")
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            failure = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation?.resume(throwing: error)
        } else if let failure {
            continuation?.resume(throwing: failure)
        } else {
            continuation?.resume()
        }
        continuation = nil
    }
}

/// Resolve → download → verify one installer image, publishing progress for the UI.
@MainActor
final class ISODownload: ObservableObject {
    enum Phase: Equatable {
        case resolving, downloading, verifying, done
        case failed(String)
        case cancelled
    }

    @Published private(set) var phase: Phase = .resolving
    @Published private(set) var fraction: Double = 0
    @Published private(set) var filename = ""

    private var task: URLSessionDownloadTask?
    private var session: URLSession?

    var isActive: Bool {
        switch phase {
        case .resolving, .downloading, .verifying: return true
        default: return false
        }
    }

    func cancel() {
        task?.cancel()
        if isActive { phase = .cancelled }
    }

    /// Returns the local file on success, nil on failure or cancellation (see `phase`).
    func fetch(resolve: () async throws -> ResolvedImage, into directory: URL) async -> URL? {
        do {
            phase = .resolving
            fraction = 0
            let image = try await resolve()
            try Task.checkCancellation()
            if phase == .cancelled { return nil }
            guard Validation.isPlainFilename(image.filename), !image.filename.hasPrefix(".") else {
                throw VMError(message: "The server sent an unsafe file name; refusing to download.")
            }
            guard image.url.scheme == "https" else { throw VMError(message: "Refusing to download over an unencrypted connection.") }
            // Vendors publish a checksum for every Linux image. Apple's restore image has none, so it is
            // accepted only from Apple's own hosts (the installer then verifies Apple's signature).
            guard image.sha256 != nil || Self.isAppleHost(image.url) else {
                throw VMError(message: "No published checksum for \(image.filename); refusing to download an image that cannot be verified.")
            }
            filename = image.filename
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(image.filename)

            // Reuse an earlier download if it still matches the published checksum. This runs before the
            // free-space check: a cached image needs no extra room.
            if let sha = image.sha256, FileManager.default.fileExists(atPath: destination.path) {
                phase = .verifying
                let cached = try await Self.sha256(of: destination) == sha
                if phase == .cancelled { return nil }
                if cached {
                    phase = .done
                    fraction = 1
                    return destination
                }
            }

            try Self.requireFreeSpace(at: directory, forDownload: image.url)
            phase = .downloading
            let delegate = DownloadDelegate(destination: destination) { [weak self] value in
                Task { @MainActor in self?.fraction = value }
            }
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            self.session = session
            defer { session.finishTasksAndInvalidate() }
            let task = session.downloadTask(with: image.url)
            self.task = task
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.continuation = continuation
                task.resume()
            }
            if phase == .cancelled { return nil }

            if let expected = image.sha256 {
                phase = .verifying
                let actual = try await Self.sha256(of: destination)
                if phase == .cancelled { return nil }
                guard actual == expected else {
                    try? FileManager.default.removeItem(at: destination)
                    throw VMError(message: "Checksum mismatch for \(image.filename); the file was discarded.")
                }
            }
            phase = .done
            fraction = 1
            return destination
        } catch {
            if (error as? URLError)?.code == .cancelled || phase == .cancelled {
                phase = .cancelled
            } else {
                phase = .failed(error.localizedDescription)
            }
            return nil
        }
    }

    private static func isAppleHost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "apple.com" || host.hasSuffix(".apple.com") || host.hasSuffix(".cdn-apple.com")
    }

    /// Refuses to start a download that would fill the disk: the file plus working room for installing it.
    private static func requireFreeSpace(at directory: URL, forDownload url: URL) throws {
        guard let free = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage else { return }
        let isMacRestore = url.pathExtension.lowercased() == "ipsw"
        let needed: Int64 = isMacRestore ? 70 << 30 : 12 << 30      // macOS: image + ~35 GB installed system + headroom
        if free < needed {
            let formatter = ByteCountFormatter()
            throw VMError(message: "Not enough free disk space: \(formatter.string(fromByteCount: free)) free, about \(formatter.string(fromByteCount: needed)) needed. Free some space and try again.")
        }
    }

    nonisolated static func sha256(of url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 8 * 1024 * 1024), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }
}
