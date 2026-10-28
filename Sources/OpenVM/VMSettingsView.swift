// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 OpenVM contributors
// This file is part of OpenVM, free software under the GNU General Public License v3.0 or later (see LICENSE).

import SwiftUI
import Virtualization

/// Everything editable about a stopped VM.
struct VMSettingsView: View {
    @EnvironmentObject private var store: VMStore
    @Environment(\.dismiss) private var dismiss

    @State private var draft: VMConfig
    @State private var growTo: Int
    @State private var newDiskGB = 16
    @State private var newHostPort = ""
    @State private var newGuestPort = ""
    @State private var autostart: Bool
    @State private var pickingFolder = false
    @State private var error: String?
    @State private var removingDisk: ExtraDisk?

    private let maxCPU = min(VZVirtualMachineConfiguration.maximumAllowedCPUCount, ProcessInfo.processInfo.processorCount)
    private let maxMemoryGB = max(1, Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)) - 2)

    init(config: VMConfig) {
        _draft = State(initialValue: config)
        _growTo = State(initialValue: config.diskGB)
        _autostart = State(initialValue: config.autoStartDelay != nil)
    }

    /// Disk edits apply immediately, so always read them from the store, not the draft.
    private var live: VMConfig { store.config(for: draft.id) ?? draft }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                general
                hardware
                disks
                devices
                folders
                network
                startup
                safety
            }
            .formStyle(.grouped)

            if let error { Text(error).foregroundStyle(.red).font(.footnote).padding(.horizontal) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 560, height: 520)
        .confirmationDialog("Delete this \(removingDisk?.gb ?? 0) GB disk and everything on it?", isPresented: Binding(
            get: { removingDisk != nil }, set: { if !$0 { removingDisk = nil } })) {
            Button("Delete Disk", role: .destructive) {
                if let removingDisk { store.removeDisk(removingDisk, from: draft.id) }
                removingDisk = nil
            }
        } message: {
            Text("This cannot be undone and takes effect immediately.")
        }
        .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { draft.sharedFolders = draft.folders + [SharedFolder(path: url.path)] }
        }
    }

    // MARK: Sections

    private var general: some View {
        Section("General") {
            TextField("Name", text: $draft.name)
            LabeledContent("Icon") {
                HStack {
                    ForEach(Appearance.symbols, id: \.self) { symbol in
                        Button { draft.iconSymbol = symbol } label: {
                            Image(systemName: symbol)
                                .frame(width: 26, height: 26)
                                .background((draft.iconSymbol ?? Appearance.defaultSymbol) == symbol ? Color.accentColor.opacity(0.3) : .clear,
                                            in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            LabeledContent("Color") {
                HStack {
                    ForEach(Appearance.colors, id: \.hex) { entry in
                        Button { draft.colorHex = entry.hex } label: {
                            Circle().fill(Color(hex: entry.hex)).frame(width: 18, height: 18)
                                .overlay(Circle().stroke(.white, lineWidth: (draft.colorHex ?? Appearance.defaultColor) == entry.hex ? 2 : 0))
                        }
                        .buttonStyle(.plain)
                        .help(entry.name)
                    }
                }
            }
        }
    }

    private var hardware: some View {
        Section("Hardware") {
            Stepper("CPU cores: \(min(draft.cpuCount, maxCPU))", value: $draft.cpuCount, in: 1...maxCPU)
            Stepper("Memory: \(min(draft.memoryGB, maxMemoryGB)) GB", value: $draft.memoryGB, in: 1...maxMemoryGB)
            HStack {
                Stepper("Disk: \(live.diskGB) GB, grow to \(growTo) GB", value: $growTo, in: live.diskGB...max(live.diskGB, 4096), step: 8)
                Button("Grow") {
                    do { try store.growDisk(of: draft.id, toGB: growTo) } catch { self.error = error.localizedDescription }
                }
                .disabled(growTo <= live.diskGB)
            }
            Text("After growing, extend the partition inside the guest.").font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var disks: some View {
        Section("Additional disks") {
            ForEach(live.extraDisks ?? []) { disk in
                HStack {
                    Label("\(disk.gb) GB", systemImage: "externaldrive")
                    Spacer()
                    Button("Remove", role: .destructive) { removingDisk = disk }
                }
            }
            HStack {
                Stepper("New disk: \(newDiskGB) GB", value: $newDiskGB, in: 1...2048, step: 8)
                Button("Add") {
                    do { try store.addDisk(to: draft.id, gb: newDiskGB) } catch { self.error = error.localizedDescription }
                }
            }
        }
    }

    private var devices: some View {
        Section("Devices and integration") {
            let policy = Policy.current
            if policy.isRestricted {
                Label("Some options are restricted by your administrator (\(Policy.source ?? "policy")).", systemImage: "lock.fill")
                    .font(.footnote).foregroundStyle(.orange)
            }
            Toggle("Start in full screen when the VM launches",
                   isOn: Binding(get: { draft.startFullScreen == true }, set: { draft.startFullScreen = $0 ? true : nil }))
            if !draft.isMac {
                Toggle("Share clipboard with the Mac (needs spice-vdagent in the guest)",
                       isOn: Binding(get: { draft.clipboardEnabled }, set: { draft.shareClipboard = $0 }))
                    .disabled(!policy.permits(policy.allowClipboardSharing))
            }
            Toggle("Microphone", isOn: Binding(get: { draft.microphone == true }, set: { draft.microphone = $0 }))
                .disabled(!policy.permits(policy.allowMicrophone))
            if !draft.isMac {
                let nestedOK = VZGenericPlatformConfiguration.isNestedVirtualizationSupported
                Toggle("Nested virtualization (KVM inside the guest)",
                       isOn: Binding(get: { draft.nestedVirtualization == true }, set: { draft.nestedVirtualization = $0 }))
                    .disabled(!nestedOK || !policy.permits(policy.allowNestedVirtualization))
                if !nestedOK {
                    Text("Needs an M3 or newer Mac on macOS 15+.").font(.footnote).foregroundStyle(.secondary)
                }
                let rosetta = VZLinuxRosettaDirectoryShare.availability
                Toggle("Rosetta: run x86-64 programs in Linux",
                       isOn: Binding(get: { draft.rosetta == true }, set: { draft.rosetta = $0 }))
                    .disabled(rosetta != .installed || !policy.permits(policy.allowRosetta))
                if rosetta == .notInstalled {
                    Button("Install Rosetta…") {
                        VZLinuxRosettaDirectoryShare.installRosetta { _ in }
                    }
                } else if rosetta == .notSupported {
                    Text("Rosetta is not supported on this Mac.").font(.footnote).foregroundStyle(.secondary)
                } else if draft.rosetta == true {
                    Text("In the guest: sudo mount -t virtiofs rosetta /mnt/rosetta, then register it with binfmt_misc.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var folders: some View {
        Section("Shared folders") {
            ForEach(draft.folders) { folder in
                HStack {
                    Text(folder.path).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Toggle("Read only", isOn: Binding(
                        get: { folder.readOnly },
                        set: { value in
                            if let i = draft.sharedFolders?.firstIndex(where: { $0.id == folder.id }) { draft.sharedFolders?[i].readOnly = value }
                        }))
                    Button("Remove", role: .destructive) { draft.sharedFolders?.removeAll { $0.id == folder.id } }
                }
            }
            Button("Add folder…") { pickingFolder = true }
                .disabled(!Policy.current.permits(Policy.current.allowSharedFolders))
            Text(draft.isMac ? "Appears in the guest under /Volumes/My Shared Files."
                             : "In the guest: sudo mount -t virtiofs share /mnt (each folder is a sub-directory).")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var network: some View {
        Section("Network (shared/NAT)") {
            TextField("SSH user", text: Binding(get: { draft.sshUser ?? "" }, set: { draft.sshUser = $0.isEmpty ? nil : $0 }))
            ForEach(draft.portForwards ?? []) { forward in
                HStack {
                    Text(verbatim: "127.0.0.1:\(forward.hostPort) → guest :\(forward.guestPort)")
                    Spacer()
                    Button("Remove", role: .destructive) { draft.portForwards?.removeAll { $0.id == forward.id } }
                }
            }
            HStack {
                TextField("Mac port", text: $newHostPort).frame(width: 90)
                Text("→")
                TextField("VM port", text: $newGuestPort).frame(width: 90)
                Button("Add forward") { addForward() }
                    .disabled(!Policy.current.permits(Policy.current.allowPortForwarding))
            }
            Text("Forwards listen on the Mac's loopback only. Bridged and host-only networks need an Apple-granted entitlement and are not available.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var startup: some View {
        Section("Startup") {
            Toggle("Start automatically when OpenVM opens", isOn: $autostart)
            if autostart {
                Stepper("Delay: \(draft.autoStartDelay ?? 10) s", value: Binding(
                    get: { draft.autoStartDelay ?? 10 }, set: { draft.autoStartDelay = $0 }), in: 0...600, step: 5)
            }
        }
    }

    private var safety: some View {
        Section("Safety") {
            Toggle("Rollback mode: discard all changes when the VM shuts down",
                   isOn: Binding(get: { draft.rollbackOnShutdown == true }, set: { draft.rollbackOnShutdown = $0 }))
            Toggle("Use as a template (cannot be started; clone it to create VMs)",
                   isOn: Binding(get: { draft.isTemplate == true }, set: { draft.isTemplate = $0 ? true : nil }))
        }
    }

    // MARK: Actions

    private func addForward() {
        guard let host = Int(newHostPort), let guest = Int(newGuestPort),
              (1...65535).contains(host), (1...65535).contains(guest) else {
            error = "Ports must be numbers between 1 and 65535."
            return
        }
        if store.vms.contains(where: { $0.id != draft.id && ($0.portForwards ?? []).contains { $0.hostPort == host } }) {
            error = "Mac port \(host) is already forwarded by another VM."
            return
        }
        if (draft.portForwards ?? []).contains(where: { $0.hostPort == host }) {
            error = "Mac port \(host) is already forwarded."
            return
        }
        draft.portForwards = (draft.portForwards ?? []) + [PortForward(hostPort: host, guestPort: guest)]
        newHostPort = ""
        newGuestPort = ""
        error = nil
    }

    private func save() {
        if let user = draft.sshUser, !Validation.isValidSSHUser(user) {
            error = "SSH user may only contain letters, digits, dot, dash and underscore."
            return
        }
        guard var latest = store.config(for: draft.id) else { dismiss(); return }
        let name = Validation.cleanName(draft.name)
        if name != latest.name {
            guard !store.nameTaken(name, except: latest.id) else {
                error = "A VM named “\(name)” already exists."
                return
            }
            latest.name = name
        }
        latest.iconSymbol = draft.iconSymbol
        latest.colorHex = draft.colorHex
        // Clamp only what the user changed: a value set elsewhere (CLI, import) must survive an unrelated save.
        if draft.cpuCount != latest.cpuCount { latest.cpuCount = min(draft.cpuCount, maxCPU) }
        if draft.memoryGB != latest.memoryGB { latest.memoryGB = min(draft.memoryGB, maxMemoryGB) }
        latest.sharedFolders = draft.sharedFolders
        latest.portForwards = draft.portForwards
        latest.shareClipboard = draft.shareClipboard
        latest.microphone = draft.microphone
        latest.nestedVirtualization = draft.nestedVirtualization
        latest.rosetta = draft.rosetta
        latest.sshUser = draft.sshUser
        latest.startFullScreen = draft.startFullScreen
        latest.autoStartDelay = autostart ? (draft.autoStartDelay ?? 10) : nil
        latest.isTemplate = draft.isTemplate

        do {
            // Rollback needs a baseline snapshot of the current state.
            if draft.rollbackOnShutdown == true, latest.rollbackBaselineID == nil {
                store.update(latest)
                let baselineID = try store.takeSnapshot(of: latest.id, name: "Rollback baseline")
                latest = store.config(for: latest.id) ?? latest
                latest.rollbackBaselineID = baselineID
            }
            if draft.rollbackOnShutdown != true, let baseline = latest.rollbackBaselineID {
                store.deleteSnapshot(baseline, of: latest.id)
                latest = store.config(for: latest.id) ?? latest
                latest.rollbackBaselineID = nil
            }
            latest.rollbackOnShutdown = draft.rollbackOnShutdown == true ? true : nil
            store.update(latest)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
