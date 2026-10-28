// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 OpenVM contributors
// This file is part of OpenVM, free software under the GNU General Public License v3.0 or later (see LICENSE).

import SwiftUI

/// Take, restore and delete snapshots of a stopped VM.
struct SnapshotsView: View {
    @EnvironmentObject private var store: VMStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var runner: VMRunner
    let id: UUID

    @State private var name = ""
    @State private var error: String?
    @State private var restoring: SnapshotInfo?

    private var snapshots: [SnapshotInfo] { (store.config(for: id)?.snapshots ?? []).sorted { $0.created > $1.created } }
    private var baseline: UUID? { store.config(for: id)?.rollbackBaselineID }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Snapshots").font(.title2.bold())
            Text("Snapshots are instant copy-on-write copies of the VM's disks. Restoring one returns the VM to that moment.")
                .font(.footnote).foregroundStyle(.secondary)

            HStack {
                TextField("Snapshot name", text: $name)
                Button("Take snapshot") { take() }
                    .disabled(!runner.isIdle || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !runner.isIdle {
                Text("Shut the VM down to take or restore snapshots.").font(.footnote).foregroundStyle(.orange)
            }

            List {
                ForEach(snapshots) { snapshot in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(snapshot.name)
                            Text(snapshot.created.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if snapshot.id == baseline { Text("Rollback baseline").font(.caption).foregroundStyle(.secondary) }
                        Button("Restore") { restoring = snapshot }.disabled(!runner.isIdle)
                        Button("Delete", role: .destructive) { store.deleteSnapshot(snapshot.id, of: id) }
                            .disabled(snapshot.id == baseline)
                    }
                }
            }
            .frame(minHeight: 180)
            .overlay { if snapshots.isEmpty { Text("No snapshots yet").foregroundStyle(.secondary) } }

            if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 520, height: 420)
        .confirmationDialog("Restore “\(restoring?.name ?? "")”?", isPresented: Binding(
            get: { restoring != nil }, set: { if !$0 { restoring = nil } })) {
            Button("Restore", role: .destructive) {
                if let restoring {
                    do { try store.restoreSnapshot(restoring.id, of: id) } catch { self.error = error.localizedDescription }
                }
                restoring = nil
            }
        } message: {
            Text("Everything changed since this snapshot is lost.")
        }
    }

    private func take() {
        do {
            try store.takeSnapshot(of: id, name: name.trimmingCharacters(in: .whitespaces))
            name = ""
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
