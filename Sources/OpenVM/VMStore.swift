// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 OpenVM contributors
// This file is part of OpenVM, free software under the GNU General Public License v3.0 or later (see LICENSE).

import Foundation
import Virtualization

/// Owns the VM library on disk (~/Library/Application Support/OpenVM/<uuid>/)
/// and one `VMRunner` per VM.
@MainActor
final class VMStore: ObservableObject {
    @Published private(set) var vms: [VMConfig] = []
    @Published var selection: UUID?
    @Published var lastError: String?
    @Published private(set) var downloads: [UUID: ISODownload] = [:]

    private var runners: [UUID: VMRunner] = [:]
    let root: URL
    /// Systems the user added to the gallery with the + tile.
    let customOS: CustomOSLibrary
    /// True when driven by the command line (no windows; serial console on stdio).
    var headless = false

    init(autostart: Bool = true) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // OPENVM_LIBRARY points the whole library elsewhere. The test suites use it so that no test can ever
        // touch real VMs.
        if let override = ProcessInfo.processInfo.environment["OPENVM_LIBRARY"], override.hasPrefix("/") {
            root = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            root = support.appendingPathComponent("OpenVM", isDirectory: true)
            Self.migrateLegacyLibrary(into: root, support: support)
        }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        customOS = CustomOSLibrary(root: root)
        load()
        if autostart { startAutostartVMs() }
    }

    // MARK: Migration from the app's former name

    private static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    /// The app used to be called FreeVM and kept its VMs in ~/Library/Application Support/FreeVM.
    /// On first launch under the new name that folder is moved (an instant rename on the same volume),
    /// never copied or deleted, and only when the new folder is empty. Symbolic links are left alone.
    private static func migrateLegacyLibrary(into root: URL, support: URL) {
        let fm = FileManager.default
        let legacy = support.appendingPathComponent("FreeVM", isDirectory: true)
        guard fm.fileExists(atPath: legacy.path), !isSymlink(legacy), !isSymlink(root) else { return }
        let existing = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).filter { $0 != ".DS_Store" }
        guard existing.isEmpty else { return }          // already migrated, or the user has new VMs
        try? fm.removeItem(at: root)                     // only ever an empty folder at this point
        do { try fm.moveItem(at: legacy, to: root) } catch {
            FileHandle.standardError.write(Data("OpenVM: could not move the old library: \(error.localizedDescription)\n".utf8))
        }
    }

    /// Absolute paths stored by older versions point into the old folder name.
    private func repairLegacyPaths(_ config: VMConfig) -> VMConfig {
        var fixed = config
        let old = "/Application Support/FreeVM/", new = "/Application Support/OpenVM/"
        if let path = fixed.isoPath, path.contains(old) { fixed.isoPath = path.replacingOccurrences(of: old, with: new) }
        if let path = fixed.restoreImagePath, path.contains(old) { fixed.restoreImagePath = path.replacingOccurrences(of: old, with: new) }
        return fixed
    }

    // MARK: Paths

    func directory(for id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    func diskURL(for id: UUID) -> URL { directory(for: id).appendingPathComponent("disk.img") }
    func efiURL(for id: UUID) -> URL { directory(for: id).appendingPathComponent("efi-vars.fd") }
    func hardwareModelURL(for id: UUID) -> URL { directory(for: id).appendingPathComponent("hardware-model.bin") }
    func machineIdentifierURL(for id: UUID) -> URL { directory(for: id).appendingPathComponent("machine-identifier.bin") }
    func genericMachineIdentifierURL(for id: UUID) -> URL { directory(for: id).appendingPathComponent("generic-machine-id.bin") }
    func auxStorageURL(for id: UUID) -> URL { directory(for: id).appendingPathComponent("aux-storage.img") }
    func savedStateURL(for id: UUID) -> URL { directory(for: id).appendingPathComponent("suspend.vzvmsave") }
    func lockURL(for id: UUID) -> URL { directory(for: id).appendingPathComponent("running.lock") }
    /// Disk file names are validated when a config is loaded; `lastPathComponent` is a second line of defence.
    func extraDiskURL(for id: UUID, _ disk: ExtraDisk) -> URL {
        guard Validation.isExtraDiskName(disk.filename) else { return directory(for: id).appendingPathComponent("invalid-disk-name") }
        return directory(for: id).appendingPathComponent(disk.filename)
    }
    private func snapshotsDirectory(for id: UUID) -> URL { directory(for: id).appendingPathComponent("snapshots", isDirectory: true) }
    private func configURL(for id: UUID) -> URL { directory(for: id).appendingPathComponent("config.json") }
    /// Downloaded installer images, shared between VMs.
    var imagesDirectory: URL { root.appendingPathComponent("Images", isDirectory: true) }

    /// Files that make up a VM's mutable state; snapshots and clones copy exactly these.
    /// The generic machine identifier is deliberately not copied: a clone must get its own.
    private func stateFiles(of config: VMConfig) -> [String] {
        ["disk.img", "efi-vars.fd", "aux-storage.img"] + (config.extraDisks ?? []).map(\.filename)
    }

    /// Top-level entries an exported bundle may contain. Anything else is refused on import.
    private static let bundleAllowlist: Set<String> = [
        "config.json", "disk.img", "efi-vars.fd", "aux-storage.img", "hardware-model.bin", "machine-identifier.bin",
        "generic-machine-id.bin", "running.lock", "suspend.vzvmsave", "snapshots",
    ]

    // MARK: Library

    private func load(report: Bool = true) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var loaded: [VMConfig] = []
        var problems: [String] = []
        for dir in entries where dir.lastPathComponent != "Images" && !dir.lastPathComponent.hasPrefix(".") {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("config.json")) else { continue }
            do {
                var config = try decoder.decode(VMConfig.self, from: data)
                guard dir.lastPathComponent == config.id.uuidString else {
                    problems.append("\(dir.lastPathComponent): folder name does not match its VM id")
                    continue
                }
                guard !loaded.contains(where: { $0.id == config.id }) else { continue }
                let repaired = repairLegacyPaths(config).sanitized()
                if repaired != config { config = repaired; try? write(config) }
                if let legacy = config.sharedFolderPath {
                    config.sharedFolders = (config.sharedFolders ?? []) + [SharedFolder(path: legacy)]
                    config.sharedFolderPath = nil
                    try? write(config)
                }
                loaded.append(config)
            } catch {
                problems.append("\(dir.lastPathComponent): \(error.localizedDescription)")
            }
        }
        chmod(root.path, 0o700)
        for config in loaded { chmod(directory(for: config.id).path, 0o700) }   // folders migrated from the old name
        vms = loaded.sorted { $0.created < $1.created }
        selection = vms.first?.id
        if report, !problems.isEmpty { lastError = "Some VMs could not be loaded and were skipped (their files are untouched):\n" + problems.joined(separator: "\n") }
    }

    /// Re-reads configs from disk, for when another process (the CLI) may have changed them.
    func reload() {
        let keep = selection
        load(report: false)
        if let keep, vms.contains(where: { $0.id == keep }) { selection = keep }
    }

    private func write(_ config: VMConfig) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: configURL(for: config.id), options: .atomic)
    }

    private func createSparseFile(at url: URL, gb: Int) throws {
        guard Validation.storedDiskGB.contains(gb) else { throw VMError(message: "Disk size must be between 1 and 65536 GB.") }
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        // Sparse raw disk: only blocks the guest writes use real space.
        try handle.truncate(atOffset: UInt64(gb) * 1024 * 1024 * 1024)
    }

    /// Copy-on-write copy on APFS (instant, no extra space until either side changes); plain copy elsewhere.
    private func cloneFile(_ source: URL, to destination: URL) throws {
        if clonefile(source.path, destination.path, 0) == 0 { return }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    func nameTaken(_ name: String, except id: UUID? = nil) -> Bool {
        vms.contains { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    func create(name: String, cpuCount: Int, memoryGB: Int, diskGB: Int,
                isoPath: String?, sharedFolderPath: String?,
                guestOS: GuestOS = .linux, installSourceID: String? = nil) throws -> VMConfig {
        let policy = Policy.current
        guard policy.permits(policy.allowCreatingVMs) else { throw VMError(message: "Creating VMs is disabled by your administrator.") }
        guard Validation.cpus.contains(cpuCount) else { throw VMError(message: "CPU cores must be between 1 and 64.") }
        guard Validation.memoryGB.contains(memoryGB) else { throw VMError(message: "Memory must be between 1 and 512 GB.") }
        guard Validation.newDiskGB.contains(diskGB) else { throw VMError(message: "Disk must be between 1 and 4096 GB.") }
        let cleanName = Validation.cleanName(name)
        guard !nameTaken(cleanName) else { throw VMError(message: "A VM named “\(cleanName)” already exists.") }
        var config = VMConfig(
            id: UUID(), name: cleanName, cpuCount: cpuCount, memoryGB: memoryGB, diskGB: diskGB,
            isoPath: isoPath, sharedFolderPath: nil,
            macAddress: VZMACAddress.randomLocallyAdministered().string, created: Date(),
            guestOS: guestOS, installSourceID: installSourceID)
        config.sharedFolders = sharedFolderPath.map { [SharedFolder(path: $0)] }

        let fm = FileManager.default
        try fm.createDirectory(at: directory(for: config.id), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        do {
            try createSparseFile(at: diskURL(for: config.id), gb: diskGB)
            try write(config)
        } catch {
            try? fm.removeItem(at: directory(for: config.id))
            throw error
        }
        vms.append(config)
        selection = config.id
        return config
    }

    /// Saves a changed config. Returns false (and sets `lastError`) if it could not be written.
    @discardableResult
    func update(_ config: VMConfig) -> Bool {
        guard let index = vms.firstIndex(where: { $0.id == config.id }) else { return false }
        do {
            try write(config)
            vms[index] = config
            return true
        } catch {
            lastError = "Could not save settings: \(error.localizedDescription)"
            return false
        }
    }

    /// True when this VM is running here or in another OpenVM process, so its files must not be touched.
    func isBusy(_ id: UUID) -> Bool {
        !(runners[id]?.isIdle ?? true) || lockOwner(of: id) != nil
    }

    var runningRunners: [VMRunner] { runners.values.filter { !$0.isIdle } }

    func delete(_ id: UUID) {
        if isBusy(id) {
            lastError = "Stop the VM before deleting it."
            return
        }
        downloads[id]?.cancel()
        do {
            try FileManager.default.removeItem(at: directory(for: id))
        } catch {
            lastError = error.localizedDescription
            return
        }
        downloads[id] = nil
        runners[id] = nil
        vms.removeAll { $0.id == id }
        if selection == id { selection = vms.first?.id }
    }

    func runner(for id: UUID) -> VMRunner {
        if let existing = runners[id] { return existing }
        let runner = VMRunner(id: id, store: self)
        runners[id] = runner
        return runner
    }

    func config(for id: UUID) -> VMConfig? { vms.first { $0.id == id } }

    /// Finds a VM for the command line: exact name, then id prefix, then name prefix. A query that matches
    /// more than one VM at a level finds nothing, so `delete` can never hit the wrong machine.
    func find(_ query: String) -> VMConfig? {
        let q = query.lowercased()
        guard !q.isEmpty else { return nil }
        let levels: [() -> [VMConfig]] = [
            { self.vms.filter { $0.name.lowercased() == q } },
            { self.vms.filter { $0.id.uuidString.lowercased().hasPrefix(q) } },
            { self.vms.filter { $0.name.lowercased().hasPrefix(q) } },
        ]
        for level in levels {
            let hits = level()
            if hits.count == 1 { return hits[0] }
            if hits.count > 1 { return nil }
        }
        return nil
    }

    /// Who holds this VM right now (this process, the GUI, or a headless run), from its kernel lock.
    func lockOwner(of id: UUID) -> (pid: Int32, mode: String)? { VMLock.owner(at: lockURL(for: id)) }

    // MARK: Snapshots, rollback

    func hasSavedState(_ id: UUID) -> Bool { FileManager.default.fileExists(atPath: savedStateURL(for: id).path) }

    /// Snapshots copy-on-write the disks, so they are instant and cost space only as the VM diverges.
    /// The VM must be stopped. A suspended session is kept: the disk it belongs to is not changed.
    @discardableResult
    func takeSnapshot(of id: UUID, name: String) throws -> UUID {
        let policy = Policy.current
        guard policy.permits(policy.allowSnapshots) else { throw VMError(message: "Snapshots are disabled by your administrator.") }
        guard var config = config(for: id) else { throw VMError(message: "VM not found.") }
        guard !isBusy(id) else { throw VMError(message: "Shut the VM down before taking a snapshot.") }
        let info = SnapshotInfo(name: Validation.cleanName(name), created: Date())
        let folder = snapshotsDirectory(for: id).appendingPathComponent(info.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            for file in stateFiles(of: config) {
                let source = directory(for: id).appendingPathComponent(file)
                if FileManager.default.fileExists(atPath: source.path) {
                    try cloneFile(source, to: folder.appendingPathComponent(file))
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        config.snapshots = (config.snapshots ?? []) + [info]
        guard update(config) else {
            try? FileManager.default.removeItem(at: folder)
            throw VMError(message: lastError ?? "Could not record the snapshot.")
        }
        return info.id
    }

    /// Two phases: every file is first cloned next to its target, and only then swapped in, so a failure
    /// (full disk, I/O error) leaves the VM's current disks untouched.
    func restoreSnapshot(_ snapshotID: UUID, of id: UUID) throws {
        guard config(for: id) != nil else { throw VMError(message: "VM not found.") }
        guard !isBusy(id) else { throw VMError(message: "Shut the VM down before restoring a snapshot.") }
        let folder = snapshotsDirectory(for: id).appendingPathComponent(snapshotID.uuidString, isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter(Validation.isPlainFilename)
        guard !files.isEmpty else { throw VMError(message: "Snapshot is empty.") }
        let fm = FileManager.default
        var staged: [(temp: URL, target: URL)] = []
        do {
            for file in files {
                let target = directory(for: id).appendingPathComponent(file)
                let temp = directory(for: id).appendingPathComponent(".restoring-\(file)")
                try? fm.removeItem(at: temp)
                try cloneFile(folder.appendingPathComponent(file), to: temp)
                staged.append((temp, target))
            }
        } catch {
            for item in staged { try? fm.removeItem(at: item.temp) }
            throw error
        }
        for item in staged {
            if fm.fileExists(atPath: item.target.path) {
                _ = try fm.replaceItemAt(item.target, withItemAt: item.temp)
            } else {
                try fm.moveItem(at: item.temp, to: item.target)
            }
        }
        try? fm.removeItem(at: savedStateURL(for: id))
    }

    func deleteSnapshot(_ snapshotID: UUID, of id: UUID) {
        guard var config = config(for: id) else { return }
        try? FileManager.default.removeItem(at: snapshotsDirectory(for: id).appendingPathComponent(snapshotID.uuidString))
        config.snapshots?.removeAll { $0.id == snapshotID }
        if config.rollbackBaselineID == snapshotID {
            config.rollbackBaselineID = nil
            config.rollbackOnShutdown = false
        }
        update(config)
    }

    // MARK: Clones and templates

    /// Instant copy-on-write clone (a "linked clone"). Also how a template becomes a new VM.
    @discardableResult
    func clone(_ id: UUID, name: String) throws -> VMConfig {
        let policy = Policy.current
        guard policy.permits(policy.allowCreatingVMs) else { throw VMError(message: "Creating VMs is disabled by your administrator.") }
        guard var copy = config(for: id) else { throw VMError(message: "VM not found.") }
        guard !isBusy(id) else { throw VMError(message: "Shut the VM down before cloning it.") }
        let cleanName = Validation.cleanName(name)
        guard !nameTaken(cleanName) else { throw VMError(message: "A VM named “\(cleanName)” already exists.") }
        let newID = UUID()
        copy.id = newID
        copy.name = cleanName
        copy.macAddress = VZMACAddress.randomLocallyAdministered().string
        copy.created = Date()
        copy.snapshots = nil
        copy.isTemplate = nil
        copy.rollbackOnShutdown = nil
        copy.rollbackBaselineID = nil
        // A clone must not claim the original's host ports or start by itself.
        copy.portForwards = nil
        copy.autoStartDelay = nil

        let fm = FileManager.default
        try fm.createDirectory(at: directory(for: newID), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        do {
            for file in stateFiles(of: copy) + ["hardware-model.bin"] {
                let source = directory(for: id).appendingPathComponent(file)
                if fm.fileExists(atPath: source.path) { try cloneFile(source, to: directory(for: newID).appendingPathComponent(file)) }
            }
            if copy.isMac {
                // Two Macs must never share a machine identifier.
                try VZMacMachineIdentifier().dataRepresentation.write(to: machineIdentifierURL(for: newID), options: .atomic)
            }
            try write(copy)
        } catch {
            try? fm.removeItem(at: directory(for: newID))
            throw error
        }
        vms.append(copy)
        selection = newID
        return copy
    }

    // MARK: Export and import (golden images)

    /// Copies a stopped VM to `<destination>/<name>.openvm`. On the same APFS volume the copy is an
    /// instant copy-on-write clone; across volumes it is a full copy. The RAM image and lock are removed
    /// before the folder appears under its final name, so a sync client never sees guest memory.
    @discardableResult
    func exportVM(_ id: UUID, to folder: URL) throws -> URL {
        let policy = Policy.current
        guard policy.permits(policy.allowExport) else { throw VMError(message: "Exporting VMs is disabled by your administrator.") }
        guard let config = config(for: id) else { throw VMError(message: "VM not found.") }
        guard !isBusy(id) else { throw VMError(message: "Shut the VM down before exporting it.") }
        let fm = FileManager.default
        let target = folder.appendingPathComponent("\(Validation.fileComponent(config.name)).openvm", isDirectory: true)
        guard !fm.fileExists(atPath: target.path) else { throw VMError(message: "\(target.path) already exists.") }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let partial = folder.appendingPathComponent(".\(UUID().uuidString).partial", isDirectory: true)
        do {
            try cloneFile(directory(for: id), to: partial)
            for leftover in ["running.lock", "suspend.vzvmsave"] { try? fm.removeItem(at: partial.appendingPathComponent(leftover)) }
            try fm.moveItem(at: partial, to: target)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
        return target
    }

    /// Refuses bundles that contain symbolic links or unexpected entries.
    private func checkBundle(_ source: URL) throws {
        let fm = FileManager.default
        guard !Self.isSymlink(source), (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw VMError(message: "\(source.path) is not a folder.")
        }
        for name in try fm.contentsOfDirectory(atPath: source.path) where !Self.bundleAllowlist.contains(name) {
            if name == ".DS_Store" { continue }              // Finder adds it as soon as the folder is opened
            if !Validation.isExtraDiskName(name) {
                throw VMError(message: "Bundle contains an unexpected item “\(name)”; refusing to import.")
            }
        }
        let walker = fm.enumerator(at: source, includingPropertiesForKeys: [.isSymbolicLinkKey])
        while let item = walker?.nextObject() as? URL {
            if Self.isSymlink(item) { throw VMError(message: "Bundle contains a symbolic link (\(item.lastPathComponent)); refusing to import.") }
        }
    }

    /// Registers an exported `.openvm` folder as a new VM with its own id, MAC address and machine identity.
    /// The bundle's author is not trusted: shared folders, microphone, autostart, port forwards, installer paths
    /// and similar host-reaching settings are dropped, and symbolic links or unexpected files abort the import.
    @discardableResult
    func importVM(from source: URL) throws -> VMConfig {
        let policy = Policy.current
        guard policy.permits(policy.allowCreatingVMs) else { throw VMError(message: "Creating VMs is disabled by your administrator.") }
        try checkBundle(source)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: source.appendingPathComponent("config.json")),
              let decoded = try? decoder.decode(VMConfig.self, from: data) else {
            throw VMError(message: "\(source.path) is not an OpenVM export (no valid config.json).")
        }
        var imported = decoded.importedUntrusted()
        let newID = UUID()
        imported.id = newID
        imported.macAddress = VZMACAddress.randomLocallyAdministered().string
        imported.created = Date()
        imported.snapshots = nil
        imported.rollbackOnShutdown = nil
        imported.rollbackBaselineID = nil
        var candidate = imported.name, counter = 2
        while nameTaken(candidate) { candidate = "\(imported.name) (imported\(counter > 2 ? " \(counter)" : ""))"; counter += 1 }
        imported.name = candidate

        let destination = directory(for: newID)
        do {
            try cloneFile(source, to: destination)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
            // The source may have changed after the first check (a shared or synced folder): check the copy too.
            try? FileManager.default.removeItem(at: destination.appendingPathComponent(".DS_Store"))
            try checkBundle(destination)
            for leftover in ["running.lock", "suspend.vzvmsave", "snapshots", "generic-machine-id.bin"] {
                try? FileManager.default.removeItem(at: destination.appendingPathComponent(leftover))
            }
            if imported.isMac {
                try VZMacMachineIdentifier().dataRepresentation.write(to: machineIdentifierURL(for: newID), options: .atomic)
            }
            try write(imported)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        vms.append(imported)
        selection = newID
        return imported
    }

    // MARK: Disks

    func addDisk(to id: UUID, gb: Int) throws {
        guard var config = config(for: id) else { return }
        guard !isBusy(id) else { throw VMError(message: "Shut the VM down before adding a disk.") }
        let disk = ExtraDisk(filename: "disk-\(UUID().uuidString.prefix(8).lowercased()).img", gb: gb)
        try createSparseFile(at: extraDiskURL(for: id, disk), gb: gb)
        config.extraDisks = (config.extraDisks ?? []) + [disk]
        guard update(config) else {
            try? FileManager.default.removeItem(at: extraDiskURL(for: id, disk))
            throw VMError(message: lastError ?? "Could not save the new disk.")
        }
    }

    func removeDisk(_ disk: ExtraDisk, from id: UUID) {
        guard var config = config(for: id) else { return }
        guard !isBusy(id) else { lastError = "Shut the VM down before removing a disk."; return }
        let url = extraDiskURL(for: id, disk)
        if FileManager.default.fileExists(atPath: url.path) {
            do { try FileManager.default.removeItem(at: url) } catch {
                lastError = "Could not delete the disk file: \(error.localizedDescription)"
                return
            }
        }
        config.extraDisks?.removeAll { $0.id == disk.id }
        update(config)
    }

    /// Grows the main disk. The guest still has to extend its partition and filesystem.
    func growDisk(of id: UUID, toGB gb: Int) throws {
        guard var config = config(for: id), gb > config.diskGB else { return }
        guard Validation.storedDiskGB.contains(gb) else { throw VMError(message: "Disk size must be between 1 and 65536 GB.") }
        guard !isBusy(id) else { throw VMError(message: "Shut the VM down before resizing its disk.") }
        let handle = try FileHandle(forWritingTo: diskURL(for: id))
        defer { try? handle.close() }
        let target = UInt64(gb) * 1024 * 1024 * 1024
        guard try handle.seekToEnd() < target else { throw VMError(message: "The disk file is already at least that large.") }
        try handle.truncate(atOffset: target)
        config.diskGB = gb
        update(config)
    }

    // MARK: Autostart

    private func startAutostartVMs() {
        for config in vms where config.autoStartDelay != nil && !config.template {
            let id = config.id
            let delay = UInt64(Validation.clamp(config.autoStartDelay ?? 0, Validation.autoStartSeconds))
            Task {
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                await runner(for: id).start()
            }
        }
    }

    // MARK: Installer media

    /// True while the VM still needs its installer image fetched (or macOS installed) before it can start.
    func needsPreparation(_ config: VMConfig) -> Bool {
        if downloads[config.id]?.isActive == true { return true }
        if config.isMac { return config.macInstalled != true }
        return false
    }

    /// A built-in catalog system, or one the user added.
    func installSource(id: String) -> DistroSource? { Catalog.source(id: id) ?? customOS.source(id: id) }

    /// Downloads the installer image for a catalog VM, attaches it, and for macOS runs the installer.
    func prepareMedia(for id: UUID) {
        guard let config = config(for: id), let sourceID = config.installSourceID,
              downloads[id]?.isActive != true else { return }
        let policy = Policy.current
        guard policy.permits(policy.allowDownloads) else {
            lastError = "Downloading installers is disabled by your administrator."
            return
        }

        let resolver: () async throws -> ResolvedImage
        if sourceID == "macOS" {
            resolver = { try await MacGuest.latestRestoreImageSource() }
        } else if let source = installSource(id: sourceID) {
            resolver = source.resolve
        } else {
            lastError = "Unknown install source “\(sourceID)”."
            return
        }

        let download = ISODownload()
        downloads[id] = download
        Task {
            guard let file = await download.fetch(resolve: resolver, into: imagesDirectory),
                  var updated = self.config(for: id) else { return }
            if updated.isMac {
                updated.restoreImagePath = file.path
            } else {
                updated.isoPath = file.path
            }
            update(updated)
            if updated.isMac { await runner(for: id).installMacOS() }
        }
    }

    func cancelDownload(for id: UUID) { downloads[id]?.cancel() }
}

// MARK: - Run lock

/// One VM must never run in two processes: both would write the same disk. The lock is a kernel
/// `flock` held for the life of the process, so there is no race between "check" and "take", and a
/// crash or kill releases it automatically (no stale lock, no pid reuse).
enum VMLock {
    /// Takes the lock and returns the open descriptor, which must stay open while the VM runs.
    static func acquire(at url: URL, mode: String) throws -> Int32 {
        // Retry: the lock file may be unlinked by a releasing process between our open and our flock, or a
        // brief shared-lock probe from `owner()` may collide with us.
        for attempt in 0..<5 {
            let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw VMError(message: "Could not open the VM lock file: \(String(cString: strerror(errno)))") }
            if flock(fd, LOCK_EX | LOCK_NB) != 0 {
                let holder = readHolder(fd)
                close(fd)
                if attempt < 4, holder == nil { usleep(50_000); continue }
                throw VMError(message: "This VM is already running in another OpenVM process" + (holder.map { " (pid \($0.pid))" } ?? "") + ".")
            }
            // We hold a lock, but on the file that is still at this path?
            var opened = stat(), current = stat()
            guard fstat(fd, &opened) == 0, stat(url.path, &current) == 0, opened.st_ino == current.st_ino, opened.st_nlink > 0 else {
                flock(fd, LOCK_UN); close(fd); continue
            }
            ftruncate(fd, 0)
            _ = "\(getpid()) \(mode)".withCString { write(fd, $0, strlen($0)) }
            return fd
        }
        throw VMError(message: "Could not take the VM lock.")
    }

    static func release(_ fd: Int32, at url: URL) {
        unlink(url.path)
        flock(fd, LOCK_UN)
        close(fd)
    }

    /// The current holder, or nil when nobody holds the lock.
    static func owner(at url: URL) -> (pid: Int32, mode: String)? {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 { flock(fd, LOCK_UN); return nil }
        return readHolder(fd) ?? (0, "gui")
    }

    private static func readHolder(_ fd: Int32) -> (pid: Int32, mode: String)? {
        var buffer = [UInt8](repeating: 0, count: 64)
        let count = pread(fd, &buffer, buffer.count - 1, 0)
        guard count > 0 else { return nil }
        let parts = String(decoding: buffer[0..<count], as: UTF8.self).split(separator: " ")
        guard let pid = parts.first.flatMap({ Int32($0) }) else { return nil }
        return (pid, parts.count > 1 ? String(parts[1]) : "gui")
    }
}
