// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 OpenVM contributors
// This file is part of OpenVM, free software under the GNU General Public License v3.0 or later (see LICENSE).

import Foundation

/// Administrator policy, granular control for managed Macs.
///
/// A JSON file at `/Library/Application Support/OpenVM/policy.json` restricts what VMs may do. It is
/// honoured only when owned by root and not writable by group or others, so a standard user cannot
/// loosen it. MDM tools (Jamf, Intune, Kandji, ...) can deploy that file like any other.
/// Absent keys mean "no restriction". Example:
///
///     { "allowSharedFolders": false, "allowClipboardSharing": false, "maxMemoryGB": 8 }
struct Policy: Codable, Equatable {
    var allowSharedFolders: Bool?
    var allowClipboardSharing: Bool?
    var allowMicrophone: Bool?
    var allowPortForwarding: Bool?
    var allowUSBImages: Bool?
    var allowNestedVirtualization: Bool?
    var allowRosetta: Bool?
    var allowSnapshots: Bool?
    var allowCreatingVMs: Bool?
    var allowDownloads: Bool?
    var allowExport: Bool?
    var maxCPUCount: Int?
    var maxMemoryGB: Int?

    static let systemPath = "/Library/Application Support/OpenVM/policy.json"
    /// Where administrators deployed it while the app was still called FreeVM.
    static let legacySystemPath = "/Library/Application Support/FreeVM/policy.json"

    /// Where the active policy came from, for the UI. nil when no policy applies.
    private(set) static var source: String?

    /// Re-read on every access of `current` older than 5 seconds, so edits apply without a restart.
    private static var cached: (policy: Policy, at: Date)?

    static var current: Policy {
        if let cached, Date().timeIntervalSince(cached.at) < 5 { return cached.policy }
        let loaded = load()
        cached = (loaded, Date())
        return loaded
    }

    var isRestricted: Bool { self != Policy() }

    func permits(_ flag: Bool?) -> Bool { flag ?? true }

    /// Everything off and tiny limits: applied when a policy file is present but cannot be trusted or read.
    /// An administrator's mistake (wrong owner, group-writable, a typo) must restrict, never silently unlock.
    static let denyAll = Policy(allowSharedFolders: false, allowClipboardSharing: false, allowMicrophone: false,
                                allowPortForwarding: false, allowUSBImages: false, allowNestedVirtualization: false,
                                allowRosetta: false, allowSnapshots: false, allowCreatingVMs: false, allowDownloads: false,
                                allowExport: false, maxCPUCount: 1, maxMemoryGB: 1)

    private static func load() -> Policy {
        source = nil
        var installed = false
        for path in [systemPath, legacySystemPath] where exists(path) {
            installed = true
            if let policy = readTrusted(path) { source = path; return policy.clamped() }
        }
        if installed {
            source = "INVALID policy file (not root-owned, writable by others, or unreadable): all restrictions applied"
            return denyAll
        }
        // Developer/test override, honoured only when no system policy is installed.
        let environment = ProcessInfo.processInfo.environment
        if let name = ["OPENVM_POLICY_FILE", "FREEVM_POLICY_FILE"].first(where: { environment[$0] != nil }),
           let path = environment[name] {
            guard let data = FileManager.default.contents(atPath: path), let policy = decodeStrict(data) else {
                source = path + " (\(name)): unreadable or has unknown keys; all restrictions applied"
                return denyAll
            }
            source = path + " (\(name))"
            return policy.clamped()
        }
        return Policy()
    }

    /// lstat, not fileExists: a dangling symlink at the policy path is still "a policy is installed".
    private static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    private static let knownKeys: Set<String> = [
        "allowSharedFolders", "allowClipboardSharing", "allowMicrophone", "allowPortForwarding", "allowUSBImages",
        "allowNestedVirtualization", "allowRosetta", "allowSnapshots", "allowCreatingVMs", "allowDownloads",
        "allowExport", "maxCPUCount", "maxMemoryGB",
    ]

    /// Negative or absurd limits would trap in arithmetic later.
    private func clamped() -> Policy {
        var copy = self
        copy.maxCPUCount = maxCPUCount.map { Validation.clamp($0, Validation.cpus) }
        copy.maxMemoryGB = maxMemoryGB.map { Validation.clamp($0, Validation.memoryGB) }
        return copy
    }

    /// Reads through one descriptor: it must be a regular file, owned by root, not writable by group or
    /// others, in a root-owned directory that others cannot write. Checking and reading the same open
    /// file means the file cannot be swapped in between.
    private static func readTrusted(_ path: String) -> Policy? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == 0,
              (info.st_mode & (S_IWGRP | S_IWOTH)) == 0 else { return nil }
        var parent = stat()
        let directory = (path as NSString).deletingLastPathComponent
        guard stat(directory, &parent) == 0, parent.st_uid == 0, (parent.st_mode & (S_IWGRP | S_IWOTH)) == 0 else { return nil }
        let data = FileHandle(fileDescriptor: fd, closeOnDealloc: false).readDataToEndOfFile()
        return decodeStrict(data)
    }

    /// A misspelled key ("allowSharedFolder") would otherwise be ignored and silently leave the feature open.
    private static func decodeStrict(_ data: Data) -> Policy? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Set(object.keys).isSubset(of: knownKeys) else { return nil }
        return try? JSONDecoder().decode(Policy.self, from: data)
    }
}
