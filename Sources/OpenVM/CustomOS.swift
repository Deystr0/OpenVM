// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 OpenVM contributors
// This file is part of OpenVM, free software under the GNU General Public License v3.0 or later (see LICENSE).

import AppKit
import Foundation

/// A system the user added to the gallery themselves: any ARM64 operating system or version, installed by hand.
/// It either asks for a local .iso each time, or downloads one from an https address, in which case a
/// SHA-256 is mandatory (the same rule as the built-in catalog).
struct CustomOS: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var version: String
    var colorHex: UInt32
    var cpu: Int
    var memoryGB: Int
    var diskGB: Int
    var downloadURL: String?
    var sha256: String?
    var hasLogo: Bool

    var sourceID: String { "custom-" + id.uuidString.lowercased() }
    var letter: String { String(name.trimmingCharacters(in: .whitespaces).first.map { Character($0.uppercased()) } ?? "?") }

    /// Checks everything that came from a form or from the JSON file. Returns a cleaned copy or the reason it is unusable.
    func validated() throws -> CustomOS {
        var copy = self
        copy.name = Validation.cleanName(name)
        copy.version = String(version.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init)
            .prefix(60)).trimmingCharacters(in: .whitespaces)
        copy.colorHex = colorHex & 0xFFFFFF
        guard Validation.cpus.contains(cpu) else { throw VMError(message: "CPU cores must be between 1 and 64.") }
        guard Validation.memoryGB.contains(memoryGB) else { throw VMError(message: "Memory must be between 1 and 512 GB.") }
        guard Validation.newDiskGB.contains(diskGB) else { throw VMError(message: "Disk must be between 1 and 4096 GB.") }
        let text = (downloadURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            copy.downloadURL = nil; copy.sha256 = nil
        } else {
            guard let url = URL(string: text), url.scheme == "https", let host = url.host, !host.isEmpty,
                  url.user == nil, url.password == nil else {
                throw VMError(message: "The download address must be a plain https:// link.")
            }
            let file = url.lastPathComponent
            guard Validation.isPlainFilename(file), !file.hasPrefix("."), file.lowercased().hasSuffix(".iso") else {
                throw VMError(message: "The link must point straight to an .iso file.")
            }
            let sum = (sha256 ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard sum.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
                throw VMError(message: "A download needs the SHA-256 published by the vendor (64 hex characters), so the file can be verified.")
            }
            copy.downloadURL = url.absoluteString; copy.sha256 = sum
        }
        return copy
    }

    /// The gallery entry that drives the same download and install path as the built-in systems.
    func distroSource(logo: URL?) -> DistroSource {
        let address = downloadURL.flatMap(URL.init(string:))
        let checksum = sha256
        return DistroSource(id: sourceID, name: name, letter: letter, colorHex: colorHex,
                            blurb: version.isEmpty ? "Added by you" : version,
                            defaultCPU: cpu, defaultMemoryGB: memoryGB, defaultDiskGB: diskGB, customLogo: logo) {
            guard let address else { throw VMError(message: "This system has no download address.") }
            return ResolvedImage(url: address, filename: address.lastPathComponent, sha256: checksum)
        }
    }
}

/// The user's own gallery entries, stored in `<library>/custom-os.json` with optional 256 px logos in `<library>/CustomOS/`.
@MainActor
final class CustomOSLibrary: ObservableObject {
    static let limit = 50
    @Published private(set) var items: [CustomOS] = []
    private let file: URL
    private let logos: URL

    init(root: URL) {
        file = root.appendingPathComponent("custom-os.json")
        logos = root.appendingPathComponent("CustomOS", isDirectory: true)
        load()
    }

    func logoURL(for item: CustomOS) -> URL? {
        item.hasLogo ? logos.appendingPathComponent(item.id.uuidString.lowercased() + ".png") : nil
    }

    func source(id: String) -> DistroSource? {
        items.first { $0.sourceID == id }.map { $0.distroSource(logo: logoURL(for: $0)) }
    }

    func sources() -> [DistroSource] { items.map { $0.distroSource(logo: logoURL(for: $0)) } }

    func add(_ draft: CustomOS, logo: NSImage?) throws {
        guard items.count < Self.limit else { throw VMError(message: "You can keep up to \(Self.limit) custom systems.") }
        var item = try draft.validated()
        if items.contains(where: { $0.name.caseInsensitiveCompare(item.name) == .orderedSame }) {
            throw VMError(message: "There is already a system named “\(item.name)”.")
        }
        item.hasLogo = false
        if let logo {
            try FileManager.default.createDirectory(at: logos, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let target = logos.appendingPathComponent(item.id.uuidString.lowercased() + ".png")
            try Self.normalizedPNG(logo).write(to: target, options: .atomic)
            item.hasLogo = true
        }
        items.append(item)
        do { try save() } catch {
            items.removeLast()
            if item.hasLogo { try? FileManager.default.removeItem(at: logos.appendingPathComponent(item.id.uuidString.lowercased() + ".png")) }
            throw error
        }
    }

    func remove(_ item: CustomOS) {
        items.removeAll { $0.id == item.id }
        if let url = logoURL(for: item) { try? FileManager.default.removeItem(at: url) }
        try? save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: file), let decoded = try? JSONDecoder().decode([CustomOS].self, from: data) else { return }
        // The file is plain JSON a user (or another program) could edit: keep only entries that pass validation.
        var seen = Set<UUID>()
        items = decoded.prefix(Self.limit).compactMap { entry in
            guard seen.insert(entry.id).inserted, var clean = try? entry.validated() else { return nil }
            clean.hasLogo = entry.hasLogo && FileManager.default.fileExists(atPath: logos.appendingPathComponent(entry.id.uuidString.lowercased() + ".png").path)
            return clean
        }
    }

    private func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(items).write(to: file, options: .atomic)
        chmod(file.path, 0o600)
    }

    /// Any picked image (png, jpg, svg, ...) becomes a transparent 256 px square PNG.
    static func normalizedPNG(_ image: NSImage) throws -> Data {
        let side = 256
        guard image.size.width > 0, image.size.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { throw VMError(message: "That image could not be read.") }
        let scale = CGFloat(side) / max(image.size.width, image.size.height)
        let target = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: (CGFloat(side) - target.width) / 2, y: (CGFloat(side) - target.height) / 2,
                              width: target.width, height: target.height))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { throw VMError(message: "That image could not be converted.") }
        return data
    }
}

/// Logos shown in the gallery: the vendors' own artwork shipped in the app bundle, or the user's picture.
enum OSLogo {
    private static var cache: [String: NSImage] = [:]

    static func image(for source: DistroSource) -> NSImage? {
        if let url = source.customLogo { return NSImage(contentsOf: url) }
        if let hit = cache[source.id] { return hit }
        guard let url = Bundle.main.url(forResource: source.id, withExtension: "png", subdirectory: "OSLogos"),
              let image = NSImage(contentsOf: url) else { return nil }
        cache[source.id] = image
        return image
    }
}
