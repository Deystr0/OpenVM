// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 OpenVM contributors
// This file is part of OpenVM, free software under the GNU General Public License v3.0 or later (see LICENSE).

import Foundation

struct ResolvedImage {
    let url: URL
    let filename: String
    /// Lowercase hex SHA-256 published by the vendor, when one exists.
    let sha256: String?
}

/// One installable system in the gallery. `resolve` finds the current official
/// ARM64 image at run time so nothing here goes stale when a new release ships.
struct DistroSource: Identifiable {
    let id: String
    let name: String
    let letter: String
    let colorHex: UInt32
    let blurb: String
    let defaultCPU: Int
    let defaultMemoryGB: Int
    let defaultDiskGB: Int
    /// The user's own picture for a custom system; built-in systems use the logo shipped in the bundle (OSLogo).
    var customLogo: URL? = nil
    let resolve: () async throws -> ResolvedImage
}

enum Catalog {
    static let all: [DistroSource] = [ubuntu, fedora, debian, kali]

    static func source(id: String) -> DistroSource? { all.first { $0.id == id } }

    // MARK: Sources

    static let ubuntu = DistroSource(
        id: "ubuntu", name: "Ubuntu", letter: "U", colorHex: 0xE95420,
        blurb: "Latest LTS desktop (ARM64)", defaultCPU: 4, defaultMemoryGB: 4, defaultDiskGB: 64
    ) {
        let (listing, base) = try await Net.text(URL(string: "https://cdimage.ubuntu.com/releases/")!)
        let versions = Net.captures(#"href="(\d[02468]\.04(?:\.\d+)?)/""#, in: listing).map { $0[0] }
            .sorted { versionKey($0).lexicographicallyPrecedes(versionKey($1)) }
            .reversed()
        for version in versions {
            let dir = base.appendingPathComponent("\(version)/release")
            guard let (sums, _) = try? await Net.text(dir.appendingPathComponent("SHA256SUMS")),
                  let hit = checksums(in: sums).first(where: { $0.file.hasSuffix("-desktop-arm64.iso") })
            else { continue }
            return ResolvedImage(url: dir.appendingPathComponent(hit.file), filename: hit.file, sha256: hit.sha)
        }
        throw VMError(message: "No Ubuntu LTS desktop ARM64 image found.")
    }

    static let fedora = DistroSource(
        id: "fedora", name: "Fedora", letter: "F", colorHex: 0xFFFFFF,
        blurb: "Workstation live image (aarch64)", defaultCPU: 4, defaultMemoryGB: 4, defaultDiskGB: 64
    ) {
        let (listing, base) = try await Net.text(URL(string: "https://download.fedoraproject.org/pub/fedora/linux/releases/")!)
        let releases = Net.captures(#"href="(\d{2})/""#, in: listing).compactMap { Int($0[0]) }.sorted(by: >)
        for release in releases {
            let dir = base.appendingPathComponent("\(release)/Workstation/aarch64/iso")
            guard let (page, pageURL0) = try? await Net.text(dir),
                  let iso = Net.captures(#"href="(Fedora-Workstation-Live-[^"]+\.aarch64\.iso)""#, in: page).first?[0]
            else { continue }
            var trimmed = pageURL0.absoluteString
            while trimmed.hasSuffix("/") { trimmed.removeLast() }
            let pageURL = URL(string: trimmed) ?? pageURL0
            var sha: String?
            // The checksum is read from Fedora's own server, not from the mirror that happens to serve the ISO.
            if let sumName = Net.captures(#"href="(Fedora-Workstation-[^"]+-CHECKSUM)""#, in: page).first?[0],
               let primary = URL(string: "https://dl.fedoraproject.org/pub/fedora/linux/releases/\(release)/Workstation/aarch64/iso/\(sumName)"),
               let (sums, _) = try? await Net.text(primary) {
                sha = checksums(in: sums).first { $0.file == iso }?.sha
            }
            return ResolvedImage(url: pageURL.appendingPathComponent(iso), filename: iso, sha256: sha)
        }
        throw VMError(message: "No Fedora Workstation aarch64 image found.")
    }

    static let debian = DistroSource(
        id: "debian", name: "Debian", letter: "D", colorHex: 0xFFFFFF,
        blurb: "Current stable network installer (arm64)", defaultCPU: 2, defaultMemoryGB: 2, defaultDiskGB: 32
    ) {
        let (sums, final) = try await Net.text(URL(string: "https://cdimage.debian.org/debian-cd/current/arm64/iso-cd/SHA256SUMS")!)
        guard let hit = checksums(in: sums).first(where: { $0.file.hasSuffix("-arm64-netinst.iso") }) else {
            throw VMError(message: "No Debian arm64 netinst image found.")
        }
        return ResolvedImage(url: final.deletingLastPathComponent().appendingPathComponent(hit.file),
                             filename: hit.file, sha256: hit.sha)
    }

    static let kali = DistroSource(
        id: "kali", name: "Kali Linux", letter: "K", colorHex: 0x1B2230,
        blurb: "Network installer (arm64)", defaultCPU: 4, defaultMemoryGB: 4, defaultDiskGB: 64
    ) {
        let (sums, final) = try await Net.text(URL(string: "https://cdimage.kali.org/current/SHA256SUMS")!)
        guard let hit = checksums(in: sums).first(where: {
            $0.file.range(of: #"^kali-linux-[\d.]+-installer-netinst-arm64\.iso$"#, options: .regularExpression) != nil
        }) else {
            throw VMError(message: "No Kali arm64 installer image found.")
        }
        return ResolvedImage(url: final.deletingLastPathComponent().appendingPathComponent(hit.file),
                             filename: hit.file, sha256: hit.sha)
    }

    // MARK: Helpers

    private static func versionKey(_ version: String) -> [Int] {
        version.split(separator: ".").compactMap { Int($0) }
    }

    /// Parses both `<sha>  file` (coreutils) and `SHA256 (file) = <sha>` (BSD, Fedora) checksum files.
    private static func checksums(in text: String) -> [(file: String, sha: String)] {
        var out: [(String, String)] = []
        for g in Net.captures(#"(?m)^([0-9a-f]{64})\s+\*?([^/\s]+)\s*$"#, in: text) { out.append((g[1], g[0])) }
        for g in Net.captures(#"(?m)^SHA256 \(([^/\s]+)\) = ([0-9a-f]{64})\s*$"#, in: text) { out.append((g[0], g[1])) }
        return out
    }
}

enum Net {
    /// Fetches a small text resource. Returns the final URL after redirects so
    /// relative links resolve against the mirror that actually answered.
    private final class HTTPSOnly: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(request.url?.scheme == "https" ? request : nil)
        }
    }

    static func text(_ url: URL) async throws -> (String, URL) {
        guard url.scheme == "https" else { throw VMError(message: "Refusing a non-https address: \(url.absoluteString)") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request, delegate: HTTPSOnly())
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw VMError(message: "Could not read \(url.absoluteString)")
        }
        return (String(decoding: data, as: UTF8.self), http.url ?? url)
    }

    /// Regex capture groups (1-based groups, returned 0-based) for every match.
    static func captures(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            (1..<match.numberOfRanges).map { ns.substring(with: match.range(at: $0)) }
        }
    }
}
