// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 OpenVM contributors
// This file is part of OpenVM, free software under the GNU General Public License v3.0 or later (see LICENSE).

import SwiftUI
import UniformTypeIdentifiers
import Virtualization

/// What the user picked in the gallery.
private enum Choice: Identifiable {
    case distro(DistroSource)
    case custom(CustomOS)
    case macOS
    case imageFile
    case addOS

    var id: String {
        switch self {
        case .distro(let source): return source.id
        case .custom(let item): return item.sourceID
        case .macOS: return "macOS"
        case .imageFile: return "image"
        case .addOS: return "add"
        }
    }
}

struct NewVMSheet: View {
    @EnvironmentObject private var store: VMStore
    @State private var choice: Choice?

    var body: some View {
        Group {
            if case .addOS = choice {
                AddOSView(done: { self.choice = nil })
            } else if let choice {
                ConfigureVMView(choice: choice, back: { self.choice = nil })
            } else {
                GalleryView(pick: { choice = $0 }, library: store.customOS)
            }
        }
        .frame(width: 600)
    }
}

// MARK: - Gallery

private struct GalleryView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: VMStore
    @ObservedObject var library: CustomOSLibrary
    let pick: (Choice) -> Void

    init(pick: @escaping (Choice) -> Void, library: CustomOSLibrary) {
        self.pick = pick
        self.library = library
    }

    private let columns = [GridItem(.adaptive(minimum: 120), spacing: 14)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create a Virtual Machine").font(.title2.bold())
            Text("Pick a system to download and install, or add your own.")
                .foregroundStyle(.secondary)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(Catalog.all) { source in
                        Tile(source: source, title: source.name, subtitle: source.blurb) { pick(.distro(source)) }
                    }
                    Tile(symbol: "apple.logo", color: .gray, title: "macOS",
                         subtitle: "Latest release from Apple (~15 GB)") { pick(.macOS) }
                    ForEach(library.items) { item in
                        Tile(source: item.distroSource(logo: library.logoURL(for: item)), title: item.name,
                             subtitle: item.version.isEmpty ? "Added by you" : item.version) { pick(.custom(item)) }
                            .contextMenu { Button("Remove from this list", role: .destructive) { library.remove(item) } }
                    }
                    Tile(symbol: "plus", color: .indigo, title: "Add OS",
                         subtitle: "Any ARM64 system or version, installed by hand") { pick(.addOS) }
                    Tile(symbol: "externaldrive", color: .teal, title: "Image file",
                         subtitle: "Install Linux from an ARM64 .iso") { pick(.imageFile) }
                    Tile(symbol: "clock", color: .gray, title: "Windows",
                         subtitle: "Coming soon in v2",
                         disabled: true) {}
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 460)

            Text("Downloads come straight from the vendors' official servers and are checked against the published SHA-256. Logos belong to their owners and are used only to identify the systems.")
                .font(.footnote).foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
            }
        }
        .padding(20)
    }
}

private struct Tile: View {
    var letter: String?
    var symbol: String?
    var logo: NSImage?
    let color: Color
    let title: String
    let subtitle: String
    var disabled = false
    let action: () -> Void

    /// A system with a logo (the vendor's own, or the user's picture); falls back to its first letter.
    init(source: DistroSource, title: String, subtitle: String, action: @escaping () -> Void) {
        self.letter = source.letter; self.symbol = nil; self.logo = OSLogo.image(for: source)
        self.color = Color(hex: source.colorHex)
        self.title = title; self.subtitle = subtitle; self.action = action
    }

    init(symbol: String, color: Color, title: String, subtitle: String, disabled: Bool = false, action: @escaping () -> Void) {
        self.letter = nil; self.symbol = symbol; self.logo = nil; self.color = color
        self.title = title; self.subtitle = subtitle; self.disabled = disabled; self.action = action
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    Circle().fill(color.gradient).frame(width: 52, height: 52)
                        .overlay(Circle().strokeBorder(.primary.opacity(0.12), lineWidth: 1))
                    if let logo {
                        Image(nsImage: logo).resizable().scaledToFit().frame(width: 32, height: 32)
                    } else if let letter {
                        Text(letter).font(.title2.bold()).foregroundStyle(.white)
                    } else if let symbol {
                        Image(systemName: symbol).font(.title2).foregroundStyle(.white)
                    }
                }
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).lineLimit(3, reservesSpace: true)
            }
            .frame(maxWidth: .infinity)
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            .opacity(disabled ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

// MARK: - Configure

private struct ConfigureVMView: View {
    @EnvironmentObject private var store: VMStore
    @Environment(\.dismiss) private var dismiss

    let choice: Choice
    let back: () -> Void

    @State private var name: String
    @State private var cpuCount: Int
    @State private var memoryGB: Int
    @State private var diskGB: Int
    @State private var isoPath: String?
    @State private var sharedFolderPath: String?
    @State private var pickingISO = false
    @State private var pickingFolder = false
    @State private var error: String?

    private let maxCPU = min(VZVirtualMachineConfiguration.maximumAllowedCPUCount, ProcessInfo.processInfo.processorCount)
    private let maxMemoryGB = max(1, Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)) - 2)

    init(choice: Choice, back: @escaping () -> Void) {
        self.choice = choice
        self.back = back
        switch choice {
        case .distro(let source):
            _name = State(initialValue: source.name)
            _cpuCount = State(initialValue: source.defaultCPU)
            _memoryGB = State(initialValue: source.defaultMemoryGB)
            _diskGB = State(initialValue: source.defaultDiskGB)
        case .macOS:
            _name = State(initialValue: "macOS")
            _cpuCount = State(initialValue: 4)
            _memoryGB = State(initialValue: 8)
            _diskGB = State(initialValue: 80)
        case .custom(let item):
            _name = State(initialValue: item.name)
            _cpuCount = State(initialValue: item.cpu)
            _memoryGB = State(initialValue: item.memoryGB)
            _diskGB = State(initialValue: item.diskGB)
        case .imageFile, .addOS:
            _name = State(initialValue: "Linux")
            _cpuCount = State(initialValue: 4)
            _memoryGB = State(initialValue: 4)
            _diskGB = State(initialValue: 64)
        }
    }

    /// Installs from an .iso the user picks: the plain image tile, or a custom system without a download address.
    private var isImageFile: Bool {
        switch choice {
        case .imageFile: return true
        case .custom(let item): return item.downloadURL == nil
        default: return false
        }
    }
    private var createLabel: String { isImageFile ? "Create" : "Download & Install" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(name).font(.title2.bold())

            Form {
                TextField("Name", text: $name)
                Stepper("CPU cores: \(min(cpuCount, maxCPU))", value: $cpuCount, in: 1...maxCPU)
                Stepper("Memory: \(min(memoryGB, maxMemoryGB)) GB", value: $memoryGB, in: 1...maxMemoryGB)
                Stepper("Disk: \(diskGB) GB", value: $diskGB, in: 8...1024, step: 8)

                if isImageFile {
                    LabeledContent("Installer image") {
                        HStack {
                            Text(isoPath.map { ($0 as NSString).lastPathComponent } ?? "None")
                                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Button("Choose…") { pickingISO = true }
                        }
                    }
                }
                LabeledContent("Shared folder") {
                    HStack {
                        Text(sharedFolderPath.map { ($0 as NSString).lastPathComponent } ?? "None")
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("Choose…") { pickingFolder = true }
                        if sharedFolderPath != nil { Button("Clear") { sharedFolderPath = nil } }
                    }
                }
            }
            .formStyle(.grouped)

            if case .macOS = choice {
                Text("Downloads Apple's latest supported macOS restore image, then installs it. Apple's license limits you to two macOS VMs per Mac.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red).font(.footnote) }

            HStack {
                Button("Back") { back() }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button(createLabel) { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .fileImporter(isPresented: $pickingISO, allowedContentTypes: [UTType(filenameExtension: "iso") ?? .data]) { result in
            if case .success(let url) = result { isoPath = url.path }
        }
        .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { sharedFolderPath = url.path }
        }
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        do {
            switch choice {
            case .imageFile, .addOS:
                _ = try store.create(name: trimmed, cpuCount: min(cpuCount, maxCPU), memoryGB: min(memoryGB, maxMemoryGB),
                                     diskGB: diskGB, isoPath: isoPath, sharedFolderPath: sharedFolderPath)
            case .distro(let source):
                let config = try store.create(name: trimmed, cpuCount: min(cpuCount, maxCPU), memoryGB: min(memoryGB, maxMemoryGB),
                                              diskGB: diskGB, isoPath: nil, sharedFolderPath: sharedFolderPath,
                                              installSourceID: source.id)
                store.prepareMedia(for: config.id)
            case .custom(let item):
                if item.downloadURL == nil {
                    _ = try store.create(name: trimmed, cpuCount: min(cpuCount, maxCPU), memoryGB: min(memoryGB, maxMemoryGB),
                                         diskGB: diskGB, isoPath: isoPath, sharedFolderPath: sharedFolderPath)
                } else {
                    let config = try store.create(name: trimmed, cpuCount: min(cpuCount, maxCPU), memoryGB: min(memoryGB, maxMemoryGB),
                                                  diskGB: diskGB, isoPath: nil, sharedFolderPath: sharedFolderPath,
                                                  installSourceID: item.sourceID)
                    store.prepareMedia(for: config.id)
                }
            case .macOS:
                let config = try store.create(name: trimmed, cpuCount: min(cpuCount, maxCPU), memoryGB: min(memoryGB, maxMemoryGB),
                                              diskGB: diskGB, isoPath: nil, sharedFolderPath: sharedFolderPath,
                                              guestOS: .macOS, installSourceID: "macOS")
                store.prepareMedia(for: config.id)
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Add OS

/// Adds a system of the user's own to the gallery: a name, optional picture, default sizes, and either a local
/// .iso chosen at install time or an https download with its published SHA-256.
private struct AddOSView: View {
    @EnvironmentObject private var store: VMStore
    let done: () -> Void

    @State private var name = ""
    @State private var version = ""
    @State private var color = Color.indigo
    @State private var logo: NSImage?
    @State private var cpu = 4
    @State private var memoryGB = 4
    @State private var diskGB = 64
    @State private var downloads = false
    @State private var address = ""
    @State private var checksum = ""
    @State private var pickingLogo = false
    @State private var error: String?

    private let maxCPU = min(VZVirtualMachineConfiguration.maximumAllowedCPUCount, ProcessInfo.processInfo.processorCount)
    private let maxMemoryGB = max(1, Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)) - 2)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(color.gradient).frame(width: 52, height: 52)
                    if let logo {
                        Image(nsImage: logo).resizable().scaledToFit().frame(width: 32, height: 32)
                    } else {
                        Text(String(name.trimmingCharacters(in: .whitespaces).first.map { Character($0.uppercased()) } ?? "+"))
                            .font(.title2.bold()).foregroundStyle(.white)
                    }
                }
                Text("Add OS").font(.title2.bold())
            }

            Form {
                TextField("Name", text: $name, prompt: Text("e.g. Alpine Linux"))
                TextField("Version or note", text: $version, prompt: Text("e.g. 3.21 (optional)"))
                ColorPicker("Color", selection: $color, supportsOpacity: false)
                LabeledContent("Logo") {
                    HStack {
                        Text(logo == nil ? "First letter" : "Your picture").foregroundStyle(.secondary)
                        Button("Choose…") { pickingLogo = true }
                        if logo != nil { Button("Clear") { logo = nil } }
                    }
                }
                Stepper("CPU cores: \(min(cpu, maxCPU))", value: $cpu, in: 1...maxCPU)
                Stepper("Memory: \(min(memoryGB, maxMemoryGB)) GB", value: $memoryGB, in: 1...maxMemoryGB)
                Stepper("Disk: \(diskGB) GB", value: $diskGB, in: 8...1024, step: 8)
                Toggle("Download the installer from a link", isOn: $downloads)
                if downloads {
                    TextField("https:// link to an .iso", text: $address)
                    TextField("SHA-256 from the vendor", text: $checksum)
                }
            }
            .formStyle(.grouped)

            Text(downloads
                 ? "The file is checked against this SHA-256 and discarded if it does not match."
                 : "You will pick the installer .iso when you create the machine, then install it by hand. ARM64 images only.")
                .font(.footnote).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.footnote) }

            HStack {
                Button("Back") { done() }
                Spacer()
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .fileImporter(isPresented: $pickingLogo, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let image = NSImage(contentsOf: url) { logo = image } else { error = "That picture could not be read." }
        }
    }

    private func add() {
        let hex = NSColor(color).usingColorSpace(.sRGB).map {
            (UInt32($0.redComponent * 255) << 16) | (UInt32($0.greenComponent * 255) << 8) | UInt32($0.blueComponent * 255)
        } ?? 0x5856D6
        let draft = CustomOS(id: UUID(), name: name, version: version, colorHex: hex,
                             cpu: min(cpu, maxCPU), memoryGB: min(memoryGB, maxMemoryGB), diskGB: diskGB,
                             downloadURL: downloads ? address : nil, sha256: downloads ? checksum : nil, hasLogo: false)
        do {
            try store.customOS.add(draft, logo: logo)
            done()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
