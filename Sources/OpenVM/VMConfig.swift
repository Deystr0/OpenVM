// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 OpenVM contributors
// This file is part of OpenVM, free software under the GNU General Public License v3.0 or later (see LICENSE).

import Foundation

enum GuestOS: String, Codable {
    case linux, macOS
}

struct SharedFolder: Codable, Hashable, Identifiable {
    var id = UUID()
    var path: String
    var readOnly = false
}

/// An additional virtual disk stored next to the main one.
struct ExtraDisk: Codable, Hashable, Identifiable {
    var id = UUID()
    var filename: String
    var gb: Int
}

/// Host 127.0.0.1:hostPort relayed to guestPort on the VM's NAT address.
struct PortForward: Codable, Hashable, Identifiable {
    var id = UUID()
    var hostPort: Int
    var guestPort: Int
}

struct SnapshotInfo: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var created: Date
}

/// Persisted description of one virtual machine (config.json in its folder).
struct VMConfig: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var cpuCount: Int
    var memoryGB: Int
    var diskGB: Int
    var isoPath: String?
    /// Legacy single folder from 0.1; migrated into `sharedFolders` on load.
    var sharedFolderPath: String?
    /// Fixed so the guest keeps the same DHCP lease across restarts.
    var macAddress: String
    var created: Date

    // Added in 0.2; all optional so older configs still decode.
    /// nil means Linux.
    var guestOS: GuestOS?
    /// Catalog entry whose installer image is downloaded for this VM ("ubuntu", "macOS", ...).
    var installSourceID: String?
    var restoreImagePath: String?
    var macInstalled: Bool?

    // Added in 0.3.
    var sharedFolders: [SharedFolder]?
    var extraDisks: [ExtraDisk]?
    var portForwards: [PortForward]?
    var snapshots: [SnapshotInfo]?
    /// nil means on.
    var shareClipboard: Bool?
    var microphone: Bool?
    var nestedVirtualization: Bool?
    /// Expose Apple's Rosetta to Linux guests so x86-64 binaries run.
    var rosetta: Bool?
    /// Seconds to wait after OpenVM launches before starting this VM; nil = don't autostart.
    var autoStartDelay: Int?
    var isTemplate: Bool?
    /// Discard all changes at shutdown by restoring `rollbackBaselineID`.
    var rollbackOnShutdown: Bool?
    var rollbackBaselineID: UUID?
    var sshUser: String?
    var iconSymbol: String?
    var colorHex: UInt32?

    // Added in 0.4.
    /// Enter full screen automatically once the VM is running.
    var startFullScreen: Bool?

    var isMac: Bool { guestOS == .macOS }
    var folders: [SharedFolder] { sharedFolders ?? [] }
    /// Off unless the user turns it on: a guest with the SPICE agent can read the Mac's clipboard.
    var clipboardEnabled: Bool { shareClipboard ?? false }
    var template: Bool { isTemplate == true }
}

// MARK: - Validation

/// Limits and checks shared by the app, the CLI and the loader. Everything read from disk (a
/// config.json can come from an imported bundle) is passed through here before it is used in
/// arithmetic, in file paths, or in a shell script.
enum Validation {
    static let cpus = 1...64
    static let memoryGB = 1...512
    static let newDiskGB = 1...4096
    static let storedDiskGB = 1...65536
    static let autoStartSeconds = 0...3600
    static let ports = 1...65535

    static func isValidSSHUser(_ text: String) -> Bool {
        text.range(of: #"^[A-Za-z_][A-Za-z0-9._-]{0,31}$"#, options: .regularExpression) != nil
    }

    /// A single path component, never "." or "..", no separators or NULs.
    static func isPlainFilename(_ text: String) -> Bool {
        !text.isEmpty && text == (text as NSString).lastPathComponent && text != "." && text != ".." && text != "/"
            && !text.hasPrefix("~") && !text.contains("\0") && !text.contains("/")
    }

    /// Extra disks are only ever created by the app as `disk-<8 hex>.img`. Accepting any other name would let a
    /// config point a guest-writable disk at config.json, efi-vars.fd or any other file in the VM folder.
    static func isExtraDiskName(_ text: String) -> Bool {
        text.range(of: #"^disk-[0-9a-f]{8}\.img$"#, options: .regularExpression) != nil
    }

    /// Display name: no control characters (terminal escapes), 1...64 characters.
    static func cleanName(_ text: String) -> String {
        let stripped = text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init)
        let trimmed = String(stripped).trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "VM" : String(trimmed.prefix(64))
    }

    /// Name made safe to use as a file name.
    static func fileComponent(_ text: String) -> String {
        var cleaned = cleanName(text)
        for bad in ["/", ":", "\\"] { cleaned = cleaned.replacingOccurrences(of: bad, with: "-") }
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return cleaned.isEmpty ? "VM" : cleaned
    }

    static func clamp(_ value: Int, _ range: ClosedRange<Int>) -> Int { min(max(value, range.lowerBound), range.upperBound) }
}

extension VMConfig {
    /// Bounds every number and drops unusable entries. Applied to every config loaded from disk.
    func sanitized() -> VMConfig {
        var c = self
        c.name = Validation.cleanName(name)
        c.cpuCount = Validation.clamp(cpuCount, Validation.cpus)
        c.memoryGB = Validation.clamp(memoryGB, Validation.memoryGB)
        c.diskGB = Validation.clamp(diskGB, Validation.storedDiskGB)
        c.autoStartDelay = autoStartDelay.map { Validation.clamp($0, Validation.autoStartSeconds) }
        c.extraDisks = extraDisks?.filter { Validation.isExtraDiskName($0.filename) }
            .map { var d = $0; d.gb = Validation.clamp(d.gb, Validation.storedDiskGB); return d }
        c.portForwards = portForwards?.filter { Validation.ports.contains($0.hostPort) && Validation.ports.contains($0.guestPort) }
        if let user = sshUser, !Validation.isValidSSHUser(user) { c.sshUser = nil }
        return c
    }

    /// Settings that give a guest reach into the host are never taken from an imported bundle: the bundle's
    /// author is not the person importing it. The importer re-enables what they want in Settings.
    func importedUntrusted() -> VMConfig {
        var c = sanitized()
        c.sharedFolders = nil
        c.sharedFolderPath = nil
        c.autoStartDelay = nil
        c.portForwards = nil
        c.microphone = nil
        c.rosetta = nil
        c.nestedVirtualization = nil
        c.shareClipboard = nil
        c.startFullScreen = nil
        c.isoPath = nil
        c.restoreImagePath = nil
        c.installSourceID = nil
        return c
    }
}
