// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 OpenVM contributors
// This file is part of OpenVM, free software under the GNU General Public License v3.0 or later (see LICENSE).

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Virtualization

struct VMDetailView: View {
    @EnvironmentObject private var store: VMStore
    let config: VMConfig
    @ObservedObject var runner: VMRunner
    @State private var confirmingDelete = false
    @State private var showingSettings = false
    @State private var showingSnapshots = false
    @State private var pickingImage = false
    @State private var guestIP: String?
    @State private var enterFullScreenOnStart = false

    var body: some View {
        Group {
            if let machine = runner.machine, showsConsole {
                VMConsoleView(machine: machine, runner: runner)
                    .overlay(alignment: .top) {
                        if let notice = runner.notice {
                            Text(notice)
                                .font(.callout)
                                .padding(10)
                                .frame(maxWidth: .infinity)
                                .background(.orange.opacity(0.9))
                                .foregroundStyle(.black)
                                .onTapGesture { runner.notice = nil }
                        }
                    }
            } else {
                infoPane
            }
        }
        .navigationTitle(config.name)
        .navigationSubtitle(statusText)
        .toolbar { controls }
        .task(id: runner.state) { await pollIP() }
        .onChange(of: runner.state) { _, newState in
            // "Start in full screen": enter once the guest is up and the console is on screen.
            if newState == .running, config.startFullScreen == true || enterFullScreenOnStart {
                enterFullScreenOnStart = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { WindowFullScreen.enter() }
            }
        }
        .sheet(isPresented: $showingSettings) { VMSettingsView(config: config) }
        .sheet(isPresented: $showingSnapshots) { SnapshotsView(runner: runner, id: config.id) }
        .fileImporter(isPresented: $pickingImage, allowedContentTypes: [UTType(filenameExtension: "iso") ?? .data,
                                                                        UTType(filenameExtension: "img") ?? .data]) { result in
            if case .success(let url) = result { Task { await runner.connectImage(url) } }
        }
        .confirmationDialog("Delete “\(config.name)” and its disk?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { store.delete(config.id) }
        } message: {
            Text("This permanently removes the virtual disk and its snapshots.")
        }
    }

    private var showsConsole: Bool {
        switch runner.state {
        case .running, .paused, .stopping, .starting, .suspending: return true
        default: return false
        }
    }

    private var download: ISODownload? { store.downloads[config.id] }
    private var suspended: Bool { store.hasSavedState(config.id) }

    private var statusText: String {
        switch runner.state {
        case .installing: return "Installing macOS… \(Int(runner.installFraction * 100))%"
        case .stopped:
            if download?.isActive == true { return "Downloading installer…" }
            if config.isMac && config.macInstalled != true { return "macOS not installed" }
            if config.template { return "Template" }
            return suspended ? "Suspended" : "Stopped"
        case .starting: return "Starting…"
        case .running: return guestIP.map { "Running · \($0)" } ?? "Running"
        case .paused: return "Paused"
        case .stopping: return "Shutting down…"
        case .suspending: return "Suspending…"
        case .failed(let message): return "Failed: \(message)"
        }
    }

    // MARK: Toolbar

    private var controls: some ToolbarContent {
        ToolbarItemGroup { controlButtons }
    }

    /// The VM controls, shared by the window toolbar and the full-screen hover bar.
    @ViewBuilder
    private var controlButtons: some View {
        Group {
            if runner.isIdle {
                Menu {
                    Button("Start in Full Screen") {
                        enterFullScreenOnStart = true
                        Task { await runner.start() }
                    }
                } label: {
                    Label(suspended ? "Resume" : "Start", systemImage: "play.fill")
                } primaryAction: {
                    Task { await runner.start() }
                }
                .disabled(store.needsPreparation(config) || config.template)
                Button { showingSnapshots = true } label: { Label("Snapshots", systemImage: "camera.on.rectangle") }
                Button { showingSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                Button { confirmingDelete = true } label: { Label("Delete", systemImage: "trash") }
            } else if runner.state == .installing {
                EmptyView()
            } else {
                if runner.state == .paused {
                    Button { Task { await runner.resume() } } label: { Label("Resume", systemImage: "play.fill") }
                } else {
                    Button { Task { await runner.pause() } } label: { Label("Pause", systemImage: "pause.fill") }
                        .disabled(runner.state != .running)
                }
                Button { Task { await runner.suspend() } } label: { Label("Suspend", systemImage: "moon.zzz") }
                    .disabled(runner.state != .running)
                    .help("Save the VM's exact state to disk and power off")
                Button { WindowFullScreen.toggle() } label: {
                    Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .help("Full screen (also Control-Command-F)")
                Menu {
                    Button("Take Screenshot") { takeScreenshot() }
                    Divider()
                    Button("Connect Disk Image…") { pickingImage = true }
                    Button("Eject Images") { Task { await runner.ejectImages() } }
                    Divider()
                    Button("Start SSH Session") { openSSH() }.disabled(guestIP == nil)
                    Button("Open in Browser") { openBrowser() }.disabled(guestIP == nil)
                    Button("Copy IP Address") { copyToPasteboard(guestIP) }.disabled(guestIP == nil)
                    Button("Copy SSH Command") { copyToPasteboard(guestIP.flatMap(sshTarget).map { "ssh \($0)" }) }
                        .disabled(guestIP == nil)
                } label: { Label("Tools", systemImage: "wrench.and.screwdriver") }
                    .disabled(runner.state != .running)
                Button { runner.requestStop() } label: { Label("Shut Down", systemImage: "power") }
                    .disabled(runner.state != .running && runner.state != .stopping)
                Button { Task { await runner.forceStop() } } label: { Label("Force Stop", systemImage: "xmark.octagon") }
            }
        }
    }

    // MARK: Guest address and SSH

    private func pollIP() async {
        guard runner.state == .running else { guestIP = nil; return }
        while !Task.isCancelled, runner.state == .running {
            guestIP = await GuestNetwork.ip(forMAC: config.macAddress)
            try? await Task.sleep(nanoseconds: guestIP == nil ? 2_000_000_000 : 10_000_000_000)
        }
    }

    /// The ssh target, or nil when the stored user name is not a plain account name.
    private func sshTarget(_ ip: String) -> String? {
        if let user = config.sshUser {
            guard Validation.isValidSSHUser(user) else { return nil }
            return "\(user)@\(ip)"
        }
        return ip
    }

    private func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Opens Terminal with an ssh session to the VM. Every value is single-quoted and the user name is
    /// validated, because config.json (which can come from an imported bundle) must never become shell code.
    private func openSSH() {
        guard let ip = guestIP, let target = sshTarget(ip) else {
            runner.notice = "The SSH user name in this VM's settings is not valid."
            return
        }
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("openvm-ssh-\(UUID().uuidString).command")
        let body = "#!/bin/zsh\nexec /usr/bin/ssh -o StrictHostKeyChecking=accept-new -- \(shellQuote(target))\n"
        guard FileManager.default.createFile(atPath: script.path, contents: Data(body.utf8), attributes: [.posixPermissions: 0o700]) else {
            runner.notice = "Could not open Terminal."
            return
        }
        NSWorkspace.shared.open(script)
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { try? FileManager.default.removeItem(at: script) }
    }

    private func takeScreenshot() {
        if let file = runner.screenshot() {
            runner.notice = "Screenshot saved to \(file.path) and copied to the clipboard."
        }
    }

    private func openBrowser() {
        guard let ip = guestIP, let url = URL(string: "http://\(ip)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func copyToPasteboard(_ text: String?) {
        guard let text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Info

    private var infoPane: some View {
        Form {
            installSection

            if let notice = runner.notice {
                Section { Text(notice).foregroundStyle(.orange) }
            }
            if suspended {
                Section { Label("Suspended. Resume restores the exact running state.", systemImage: "moon.zzz") }
            }

            Section("Hardware") {
                LabeledContent("CPU cores", value: "\(config.cpuCount)")
                LabeledContent("Memory", value: "\(config.memoryGB) GB")
                LabeledContent("Disk", value: "\(config.diskGB) GB (sparse)")
                ForEach(config.extraDisks ?? []) { LabeledContent("Extra disk", value: "\($0.gb) GB") }
                LabeledContent("Network", value: "NAT · \(config.macAddress)")
                ForEach(config.portForwards ?? []) {
                    LabeledContent("Port forward", value: "127.0.0.1:\($0.hostPort) → :\($0.guestPort)")
                }
            }
            Section("Media and sharing") {
                if !config.isMac {
                    LabeledContent("Installer image", value: config.isoPath.map { ($0 as NSString).lastPathComponent } ?? "None")
                    if config.isoPath != nil {
                        Button("Eject installer image (after installation)") {
                            var updated = config
                            updated.isoPath = nil
                            updated.installSourceID = nil   // installed: stop offering to download the installer again
                            store.update(updated)
                        }
                    }
                }
                if config.folders.isEmpty {
                    LabeledContent("Shared folders", value: "None")
                } else {
                    ForEach(config.folders) { LabeledContent($0.readOnly ? "Shared (read only)" : "Shared", value: $0.path) }
                }
            }
            Section("Features") {
                LabeledContent("Snapshots", value: "\((config.snapshots ?? []).count)")
                if config.rollbackOnShutdown == true { LabeledContent("Rollback mode", value: "On") }
                if config.nestedVirtualization == true { LabeledContent("Nested virtualization", value: "On") }
                if config.rosetta == true { LabeledContent("Rosetta (x86-64)", value: "On") }
                if let delay = config.autoStartDelay { LabeledContent("Autostart", value: "after \(delay) s") }
            }
            if case .failed(let message) = runner.state {
                Section("Last error") { Text(message).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
    }

    /// Download progress, macOS install progress, or the button that resumes either.
    @ViewBuilder
    private var installSection: some View {
        if runner.state == .installing {
            Section("Installing macOS") {
                ProgressView(value: runner.installFraction)
                Text("This takes several minutes. Keep OpenVM open.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } else if let download, download.phase != .done {
            DownloadCard(download: download, cancel: { store.cancelDownload(for: config.id) },
                         retry: { store.prepareMedia(for: config.id) })
        } else if config.isMac && config.macInstalled != true {
            Section("macOS") {
                if let path = config.restoreImagePath, FileManager.default.fileExists(atPath: path) {
                    Button("Install macOS") { Task { await runner.installMacOS() } }
                } else {
                    Button("Download and install macOS") { store.prepareMedia(for: config.id) }
                }
            }
        } else if let sourceID = config.installSourceID, !config.isMac, config.isoPath == nil,
                  let source = store.installSource(id: sourceID) {
            Section(source.name) {
                Button("Download installer again") { store.prepareMedia(for: config.id) }
            }
        }
    }
}

private struct DownloadCard: View {
    @ObservedObject var download: ISODownload
    let cancel: () -> Void
    let retry: () -> Void

    var body: some View {
        Section("Installer download") {
            switch download.phase {
            case .resolving:
                HStack { ProgressView().controlSize(.small); Text("Finding the latest official image…") }
            case .downloading:
                VStack(alignment: .leading, spacing: 6) {
                    Text(download.filename).font(.callout)
                    ProgressView(value: download.fraction)
                    Text("\(Int(download.fraction * 100))%").font(.footnote).foregroundStyle(.secondary)
                }
                Button("Cancel download", role: .cancel, action: cancel)
            case .verifying:
                HStack { ProgressView().controlSize(.small); Text("Verifying SHA-256…") }
            case .failed(let message):
                Text(message).foregroundStyle(.red)
                Button("Try again", action: retry)
            case .cancelled:
                Text("Download cancelled.")
                Button("Download again", action: retry)
            case .done:
                EmptyView()
            }
        }
    }
}
