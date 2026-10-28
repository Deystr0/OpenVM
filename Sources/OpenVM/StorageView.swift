// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 OpenVM contributors
// This file is part of OpenVM, free software under the GNU General Public License v3.0 or later (see LICENSE).

import SwiftUI

/// Disk usage per VM and one-click cleanup, reclaiming space from stopped VMs, snapshots and cached installers.
/// Sizes are allocated bytes (sparse disks count only written blocks). Clones and snapshots share
/// blocks copy-on-write, so rows can add up to more than the real total.
struct StorageView: View {
    @EnvironmentObject private var store: VMStore
    @Environment(\.dismiss) private var dismiss
    @State private var report = StorageReport()
    @State private var message: String?
    @State private var discarding: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Storage").font(.title2.bold())
            Text("Free on this Mac: \(bytes(report.freeBytes))  ·  Used by OpenVM: \(bytes(report.totalBytes))")
                .foregroundStyle(.secondary)

            List {
                Section("Virtual machines") {
                    ForEach(report.vms) { row in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(row.name)
                                Text("disk \(bytes(row.diskBytes)) of \(row.configuredGB) GB · snapshots \(bytes(row.snapshotBytes))"
                                     + (row.savedStateBytes > 0 ? " · suspended state \(bytes(row.savedStateBytes))" : ""))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(bytes(row.totalBytes)).monospacedDigit()
                            if row.savedStateBytes > 0 {
                                Button("Discard suspended state") { discarding = row.id }
                            }
                        }
                    }
                }
                Section("Downloaded installers") {
                    if report.images.isEmpty { Text("None").foregroundStyle(.secondary) }
                    ForEach(report.images) { image in
                        HStack {
                            Text(image.name).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(bytes(image.bytes)).monospacedDigit()
                            Button("Delete", role: .destructive) { delete(image) }
                        }
                    }
                }
            }
            .frame(minHeight: 260)

            if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            HStack {
                Button("Delete all downloaded installers", role: .destructive) { deleteAllImages() }
                    .disabled(report.images.isEmpty)
                Button("Refresh") { refresh() }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 600, height: 480)
        .onAppear { refresh() }
        .confirmationDialog("Discard the suspended session?", isPresented: Binding(
            get: { discarding != nil }, set: { if !$0 { discarding = nil } })) {
            Button("Discard Session", role: .destructive) {
                if let discarding { discardState(discarding) }
                discarding = nil
            }
        } message: {
            Text("Unsaved work inside the VM is lost. The VM will boot normally next time.")
        }
    }

    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }

    private func refresh() { report = StorageReport.scan(store: store) }

    private func delete(_ image: StorageReport.ImageRow) {
        // Installers attached to a VM are still needed until the VM is installed and ejected.
        let inUse = store.vms.contains { $0.isoPath == image.url.path || $0.restoreImagePath == image.url.path }
        if inUse { message = "\(image.name) is attached to a VM. Eject it in that VM first."; return }
        try? FileManager.default.removeItem(at: image.url)
        message = "Deleted \(image.name)."
        refresh()
    }

    private func deleteAllImages() {
        var kept = 0
        for image in report.images {
            if store.vms.contains(where: { $0.isoPath == image.url.path || $0.restoreImagePath == image.url.path }) { kept += 1; continue }
            try? FileManager.default.removeItem(at: image.url)
        }
        message = kept > 0 ? "Kept \(kept) installer(s) still attached to a VM." : "Deleted all downloaded installers."
        refresh()
    }

    private func discardState(_ id: UUID) {
        guard store.runner(for: id).isIdle else { return }
        try? FileManager.default.removeItem(at: store.savedStateURL(for: id))
        message = "Discarded the suspended state; the VM will boot normally next time."
        refresh()
    }
}

struct StorageReport {
    struct VMRow: Identifiable { let id: UUID; let name: String; let configuredGB: Int; let diskBytes: Int64; let snapshotBytes: Int64; let savedStateBytes: Int64
        var totalBytes: Int64 { diskBytes + snapshotBytes + savedStateBytes } }
    struct ImageRow: Identifiable { let url: URL; let name: String; let bytes: Int64; var id: URL { url } }

    var vms: [VMRow] = []
    var images: [ImageRow] = []
    var freeBytes: Int64 = 0
    var totalBytes: Int64 { vms.reduce(0) { $0 + $1.totalBytes } + images.reduce(0) { $0 + $1.bytes } }

    @MainActor
    static func scan(store: VMStore) -> StorageReport {
        var report = StorageReport()
        for config in store.vms {
            let dir = store.directory(for: config.id)
            let snapshots = allocated(dir.appendingPathComponent("snapshots"))
            let state = allocated(store.savedStateURL(for: config.id))
            let whole = allocated(dir)
            report.vms.append(VMRow(id: config.id, name: config.name, configuredGB: config.diskGB,
                                    diskBytes: max(whole - snapshots - state, 0), snapshotBytes: snapshots, savedStateBytes: state))
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: store.imagesDirectory, includingPropertiesForKeys: nil)) ?? []
        report.images = files.map { ImageRow(url: $0, name: $0.lastPathComponent, bytes: allocated($0)) }.sorted { $0.bytes > $1.bytes }
        if let values = try? store.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let free = values.volumeAvailableCapacityForImportantUsage { report.freeBytes = free }
        return report
    }

    /// Allocated (not apparent) size of a file or directory tree.
    static func allocated(_ url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return 0 }
        if values.isDirectory != true { return Int64(values.totalFileAllocatedSize ?? 0) }
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys)
        while let item = enumerator?.nextObject() as? URL {
            if let v = try? item.resourceValues(forKeys: Set(keys)), v.isDirectory != true {
                total += Int64(v.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }
}
