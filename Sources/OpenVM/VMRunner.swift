// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 OpenVM contributors
// This file is part of OpenVM, free software under the GNU General Public License v3.0 or later (see LICENSE).

import Foundation
import Virtualization

struct VMError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Builds the Virtualization.framework configuration and drives one VM's lifecycle.
@MainActor
final class VMRunner: NSObject, ObservableObject, VZVirtualMachineDelegate {
    enum State: Equatable {
        case stopped, starting, running, paused, stopping, suspending
        case installing
        case failed(String)
    }

    @Published private(set) var state: State = .stopped
    @Published private(set) var machine: VZVirtualMachine?
    @Published private(set) var installFraction: Double = 0
    /// Non-fatal problem worth showing (for example: suspend is not supported by this VM's devices).
    @Published var notice: String?

    private let id: UUID
    private unowned let store: VMStore
    private var installObservation: NSKeyValueObservation?
    private var lastConfiguration: VZVirtualMachineConfiguration?
    private var lockFD: Int32 = -1
    private lazy var forwarder = PortForwarder(onFailure: { [weak self] message in self?.notice = message })
    private var control: ControlServer?
    private var stopWatchdog: Task<Void, Never>?
    /// When the VM last reached the running state; nil while stopped.
    private(set) var startedAt: Date?
    /// The on-screen console, registered by the SwiftUI view so screenshots can read it.
    weak var consoleView: VZVirtualMachineView?

    init(id: UUID, store: VMStore) {
        self.id = id
        self.store = store
    }

    var isIdle: Bool {
        switch state {
        case .stopped: return true
        case .failed: return machine == nil
        default: return false
        }
    }

    // MARK: Lifecycle
    //
    // Every `await` below can interleave with another action (Force Stop, the guest powering off).
    // After each one the code checks `machine === vm`: if the VM it started with is gone, whoever
    // finished it already cleaned up and this call must not touch the state again.

    func start() async {
        guard isIdle, let config = store.config(for: id) else { return }
        if config.template {
            state = .failed("Templates cannot be started. Create a VM from it instead.")
            return
        }
        if config.isMac, config.macInstalled != true {
            state = .failed("macOS is not installed yet.")
            return
        }
        state = .starting
        notice = nil
        var attempt: VZVirtualMachine?
        do {
            try acquireLock()
            let vzConfig = try makeConfiguration(for: config)
            lastConfiguration = vzConfig
            let vm = VZVirtualMachine(configuration: vzConfig)
            vm.delegate = self
            machine = vm
            attempt = vm

            let savedState = store.savedStateURL(for: id)
            if FileManager.default.fileExists(atPath: savedState.path) {
                do {
                    try await vm.restoreMachineStateFrom(url: savedState)
                    try await vm.resume()
                    try? FileManager.default.removeItem(at: savedState)
                } catch {
                    // Keep the saved session: the user can retry, or discard it in Storage.
                    throw VMError(message: "Could not resume the suspended state (\(error.localizedDescription)). It was kept; try again, or discard it in Storage and start normally.")
                }
            } else {
                try await vm.start()
            }
            guard machine === vm, state == .starting else { return }
            state = .running
            startedAt = Date()
            let policy = Policy.current
            forwarder.start(forwards: policy.permits(policy.allowPortForwarding) ? config.portForwards ?? [] : [],
                            mac: config.macAddress)
            startControlServer()
        } catch {
            // Force Stop may already have cleaned up, and a newer start may own the VM by now.
            guard state == .starting, machine == nil || machine === attempt else { return }
            machine = nil
            releaseLock()
            state = .failed(error.localizedDescription)
        }
    }

    /// ACPI power-button request; the guest decides whether to shut down. Some boots of a guest never
    /// act on the event (observed with Debian 13 under Virtualization.framework), so the request is
    /// repeated and, if the guest stays silent, the user is told to use Force Stop.
    func requestStop() {
        guard let machine, state == .running || state == .stopping else { return }
        do {
            try machine.requestStop()
            state = .stopping
            startStopWatchdog()
        } catch {
            notice = "The shutdown request failed: \(error.localizedDescription)"
        }
    }

    private func startStopWatchdog() {
        stopWatchdog?.cancel()
        stopWatchdog = Task { @MainActor [weak self] in
            for _ in 0..<2 {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self, !Task.isCancelled, self.state == .stopping else { return }
                try? self.machine?.requestStop()   // the first event may have been missed
            }
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self, !Task.isCancelled, self.state == .stopping else { return }
            self.notice = "The guest has not responded to the shutdown request for 30 seconds. Use Force Stop if it stays stuck."
        }
    }

    /// Immediate power-off, like pulling the plug.
    func forceStop() async {
        guard let vm = machine, state != .stopped else { return }
        let wasSuspending = state == .suspending
        do {
            try await vm.stop()
        } catch {
            notice = "Force stop failed: \(error.localizedDescription)"
            return
        }
        guard machine === vm else { return }
        // An interrupted suspend may have left a half-written state file.
        if wasSuspending { try? FileManager.default.removeItem(at: store.savedStateURL(for: id)) }
        finishStopped(rollback: !wasSuspending)
    }

    func pause() async {
        guard let vm = machine, state == .running else { return }
        do {
            try await vm.pause()
            if machine === vm, state == .running || state == .stopping { state = .paused }
        } catch {
            notice = "Pause failed: \(error.localizedDescription)"
        }
    }

    func resume() async {
        guard let vm = machine, state == .paused else { return }
        do {
            try await vm.resume()
            if machine === vm, state == .paused { state = .running }
        } catch {
            notice = "Resume failed: \(error.localizedDescription)"
        }
    }

    /// Saves RAM and device state to disk and powers off; the next start continues exactly where it left off.
    func suspend() async {
        guard let vm = machine, state == .running || state == .paused, let configuration = lastConfiguration else { return }
        let wasPaused = state == .paused
        do {
            try configuration.validateSaveRestoreSupport()
        } catch {
            notice = "This VM's devices do not support suspend: \(error.localizedDescription)"
            return
        }
        state = .suspending
        let stateFile = store.savedStateURL(for: id)
        do {
            if !wasPaused { try await vm.pause() }
            guard machine === vm, state == .suspending else { return }
            do {
                try await vm.saveMachineStateTo(url: stateFile)
            } catch {
                try? FileManager.default.removeItem(at: stateFile)
                if !wasPaused { try? await vm.resume() }
                if machine === vm { state = vm.state == .paused ? .paused : .running }
                notice = "Suspend failed: \(error.localizedDescription)"
                return
            }
            guard machine === vm, state == .suspending else { return }
            try await vm.stop()
            guard machine === vm else { return }
            finishStopped(rollback: false)
        } catch {
            guard machine === vm else { return }
            // Pause or stop failed: the guest is still alive, so the saved state (if any) is stale.
            try? FileManager.default.removeItem(at: stateFile)
            state = vm.state == .paused ? .paused : .running
            notice = "Suspend failed: \(error.localizedDescription)"
        }
    }

    private func finishStopped(rollback: Bool = true) {
        stopWatchdog?.cancel()
        stopWatchdog = nil
        forwarder.stop()
        control?.stop()
        control = nil
        startedAt = nil
        machine = nil
        lastConfiguration = nil
        notice = nil
        releaseLock()
        state = .stopped
        if rollback, let config = store.config(for: id), config.rollbackOnShutdown == true,
           let baseline = config.rollbackBaselineID {
            do { try store.restoreSnapshot(baseline, of: id) } catch {
                let message = "Rollback failed: \(error.localizedDescription)"
                notice = message
                if store.headless { FileHandle.standardError.write(Data("openvmctl: \(message)\n".utf8)) }
            }
        }
    }

    // MARK: Screenshots, control

    /// Saves the console as a PNG. Returns the file, or nil with `notice` explaining why.
    /// The VM's display is GPU-rendered, so `cacheDisplay` yields black; the window server's own
    /// composited image of the window is cropped to the console instead.
    func screenshot(to destination: URL? = nil, copyToClipboard: Bool = true) -> URL? {
        guard let view = consoleView, let window = view.window, state == .running || state == .paused else {
            notice = "Open the VM's console first; screenshots capture what is on screen."
            return nil
        }
        guard let image = Self.windowImage(of: window, cropping: view) else {
            notice = "Could not capture the window. macOS may need Screen Recording permission for OpenVM."
            return nil
        }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            notice = "Could not encode the screenshot."
            return nil
        }
        let name = store.config(for: id)?.name ?? "VM"
        let folder = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenVM Screenshots", isDirectory: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let file = destination ?? folder.appendingPathComponent("\(Validation.fileComponent(name)) \(stamp).png")
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            // An explicit destination is never overwritten (it may arrive over the control socket).
            try png.write(to: file, options: destination == nil ? [] : .withoutOverwriting)
            if copyToClipboard {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setData(png, forType: .png)
            }
            return file
        } catch {
            notice = "Could not save the screenshot: \(error.localizedDescription)"
            return nil
        }
    }

    /// CGWindowListCreateImage is marked unavailable in recent SDKs but still exists at runtime, so it is
    /// looked up dynamically. Capturing an app's own window needs no Screen Recording permission.
    private static func windowImage(of window: NSWindow, cropping view: NSView) -> CGImage? {
        typealias Capture = @convention(c) (CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }   // RTLD_DEFAULT
        let capture = unsafeBitCast(symbol, to: Capture.self)
        guard let full = capture(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                 [.boundsIgnoreFraming, .bestResolution])?.takeRetainedValue() else { return nil }
        let scale = CGFloat(full.width) / window.frame.width
        let inWindow = view.convert(view.bounds, to: nil)                       // origin bottom-left
        let crop = CGRect(x: inWindow.minX * scale,
                          y: (window.frame.height - inWindow.maxY) * scale,     // flip to top-left origin
                          width: inWindow.width * scale, height: inWindow.height * scale).integral
        return full.cropping(to: crop) ?? full
    }

    private func startControlServer() {
        let server = ControlServer(id: id) { [weak self] command in
            await self?.handleControl(command) ?? "error: VM is gone"
        }
        if !server.start() {
            notice = "The control socket could not be created, so openvmctl cannot manage this VM. The VM itself runs normally."
        }
        control = server
    }

    /// Commands accepted on the control socket (see openvmctl).
    private func handleControl(_ command: String) async -> String {
        let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
        switch parts.first ?? "" {
        case "status":
            let uptime = startedAt.map { Int(Date().timeIntervalSince($0)) } ?? 0
            let name: String
            switch state {
            case .stopped: name = "stopped"
            case .starting: name = "starting"
            case .running: name = "running"
            case .paused: name = "paused"
            case .stopping: name = "stopping"
            case .suspending: name = "suspending"
            case .installing: name = "installing"
            case .failed: name = "failed"
            }
            return "state=\(name) uptime=\(uptime)"
        case "stop":
            if state == .paused { await resume() }
            guard state == .running || state == .stopping else { return "error: VM is not running" }
            requestStop(); return "ok: shutdown requested"
        case "kill":
            guard machine != nil else { return "error: VM is not running" }
            await forceStop(); return state == .stopped ? "ok: stopped" : "error: \(notice ?? "could not stop")"
        case "pause":
            guard state == .running else { return "error: VM is not running" }
            await pause(); return state == .paused ? "ok: paused" : "error: could not pause"
        case "resume":
            guard state == .paused else { return "error: VM is not paused" }
            await resume(); return state == .running ? "ok: resumed" : "error: could not resume"
        case "suspend":
            guard state == .running else { return "error: VM is not running" }
            await suspend()
            return isIdle && store.hasSavedState(id) ? "ok: suspended" : "error: \(notice ?? "could not suspend")"
        case "screenshot":
            var target: URL?
            if parts.count > 1 {
                let url = URL(fileURLWithPath: (parts[1] as NSString).expandingTildeInPath)
                guard url.pathExtension.lowercased() == "png" else { return "error: the screenshot file must end in .png" }
                target = url
            }
            if let file = screenshot(to: target, copyToClipboard: false) { return "ok: \(file.path)" }
            return "error: \(notice ?? "no console available")"
        default:
            return "error: unknown command"
        }
    }

    // MARK: USB images

    /// Plugs a disk image into the running VM as a USB drive, like inserting a stick.
    func connectImage(_ url: URL) async {
        let policy = Policy.current
        guard policy.permits(policy.allowUSBImages) else {
            notice = "Connecting disk images is disabled by your administrator."
            return
        }
        guard let controller = machine?.usbControllers.first else {
            notice = "This VM has no USB controller."
            return
        }
        do {
            let attachment = try VZDiskImageStorageDeviceAttachment(url: url, readOnly: true)
            try await controller.attach(device: VZUSBMassStorageDevice(configuration: VZUSBMassStorageDeviceConfiguration(attachment: attachment)))
        } catch {
            notice = "Could not connect the image: \(error.localizedDescription)"
        }
    }

    func ejectImages() async {
        guard let controller = machine?.usbControllers.first else { return }
        for device in controller.usbDevices {
            do { try await controller.detach(device: device) } catch { notice = "Could not eject: \(error.localizedDescription)" }
        }
    }

    // MARK: Locking

    /// One VM must never run in two processes (GUI and CLI): both would write the same disk.
    /// Uses a kernel flock (see VMLock), so there is no race and a crash releases it.
    private func acquireLock() throws {
        guard lockFD < 0 else { return }
        lockFD = try VMLock.acquire(at: store.lockURL(for: id), mode: store.headless ? "headless" : "gui")
    }

    private func releaseLock() {
        guard lockFD >= 0 else { return }
        VMLock.release(lockFD, at: store.lockURL(for: id))
        lockFD = -1
    }

    // MARK: macOS installation

    /// Prepares the Mac platform files from the downloaded restore image, then runs Apple's installer.
    func installMacOS() async {
        guard isIdle, let config = store.config(for: id), config.isMac, config.macInstalled != true,
              let imagePath = config.restoreImagePath else { return }
        state = .installing
        installFraction = 0
        do {
            try acquireLock()
            defer { releaseLock() }
            let imageURL = URL(fileURLWithPath: imagePath)
            let image = try await MacGuest.loadRestoreImage(at: imageURL)
            let requirements = try MacGuest.prepare(id: id, store: store, image: image)

            // Raise the VM's size to what this macOS release requires.
            var updated = config
            updated.cpuCount = max(config.cpuCount, requirements.minimumSupportedCPUCount)
            let minGB = Int((requirements.minimumSupportedMemorySize + (1 << 30) - 1) >> 30)
            updated.memoryGB = max(config.memoryGB, minGB)
            store.update(updated)

            let vm = VZVirtualMachine(configuration: try makeConfiguration(for: updated))
            let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: imageURL)
            installObservation = installer.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
                let value = progress.fractionCompleted
                Task { @MainActor in self?.installFraction = value }
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                installer.install { continuation.resume(with: $0) }
            }
            installObservation = nil

            updated.macInstalled = true
            store.update(updated)
            state = .stopped
        } catch {
            installObservation = nil
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: VZVirtualMachineDelegate

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        Task { @MainActor in
            guard virtualMachine === self.machine else { return }   // a late event from an old instance
            self.finishStopped()
        }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in
            guard virtualMachine === self.machine else { return }
            self.notice = nil
            self.lastConfiguration = nil
            self.stopWatchdog?.cancel()
            self.forwarder.stop()
            self.control?.stop()
            self.control = nil
            self.startedAt = nil
            self.machine = nil
            self.releaseLock()
            self.state = .failed(message)
        }
    }

    // MARK: Configuration

    private func makeConfiguration(for config: VMConfig) throws -> VZVirtualMachineConfiguration {
        let vz = VZVirtualMachineConfiguration()

        let policy = Policy.current
        let cpuWanted = min(config.cpuCount, policy.maxCPUCount ?? .max)
        vz.cpuCount = min(max(cpuWanted, VZVirtualMachineConfiguration.minimumAllowedCPUCount),
                          VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        let requested = UInt64(min(config.memoryGB, policy.maxMemoryGB ?? .max)) * 1024 * 1024 * 1024
        let hostCap = ProcessInfo.processInfo.physicalMemory / 4 * 3          // leave the Mac a quarter of its RAM
        vz.memorySize = min(max(min(requested, hostCap), VZVirtualMachineConfiguration.minimumAllowedMemorySize),
                            VZVirtualMachineConfiguration.maximumAllowedMemorySize)

        var storage: [VZStorageDeviceConfiguration] = []
        let disk = try VZDiskImageStorageDeviceAttachment(url: store.diskURL(for: id), readOnly: false)
        storage.append(VZVirtioBlockDeviceConfiguration(attachment: disk))
        for extra in config.extraDisks ?? [] {
            let attachment = try VZDiskImageStorageDeviceAttachment(url: store.extraDiskURL(for: id, extra), readOnly: false)
            storage.append(VZVirtioBlockDeviceConfiguration(attachment: attachment))
        }

        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        if let mac = VZMACAddress(string: config.macAddress) { network.macAddress = mac }
        vz.networkDevices = [network]

        let sound = VZVirtioSoundDeviceConfiguration()
        let output = VZVirtioSoundDeviceOutputStreamConfiguration()
        output.sink = VZHostAudioOutputStreamSink()
        sound.streams = [output]
        if config.microphone == true, policy.permits(policy.allowMicrophone) {
            let input = VZVirtioSoundDeviceInputStreamConfiguration()
            input.source = VZHostAudioInputStreamSource()
            sound.streams.append(input)
        }
        vz.audioDevices = [sound]

        if !config.isMac { vz.entropyDevices = [VZVirtioEntropyDeviceConfiguration()] }
        vz.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        vz.usbControllers = [VZXHCIControllerConfiguration()]

        var directoryDevices: [VZDirectorySharingDeviceConfiguration] = []
        if config.isMac {
            try MacGuest.configure(vz, id: id, store: store)
        } else {
            try configureLinux(vz, config: config, storage: &storage, directoryDevices: &directoryDevices)
        }
        vz.storageDevices = storage

        if policy.permits(policy.allowSharedFolders), let share = try makeFolderShare(config) {
            directoryDevices.append(share)
        }
        vz.directorySharingDevices = directoryDevices

        try vz.validate()
        return vz
    }

    /// All shared folders appear as sub-directories of one virtiofs share.
    /// Linux: `mount -t virtiofs share /mnt`; macOS guests automount it under /Volumes/My Shared Files.
    private func makeFolderShare(_ config: VMConfig) throws -> VZVirtioFileSystemDeviceConfiguration? {
        guard !config.folders.isEmpty else { return nil }
        var directories: [String: VZSharedDirectory] = [:]
        for folder in config.folders {
            guard FileManager.default.fileExists(atPath: folder.path) else {
                throw VMError(message: "Shared folder not found: \(folder.path)")
            }
            var base = (folder.path as NSString).lastPathComponent
            if (try? VZMultipleDirectoryShare.validateName(base)) == nil { base = "share" }   // "/" and similar are not valid names
            var name = base
            var suffix = 2
            while directories[name] != nil { name = "\(base)-\(suffix)"; suffix += 1 }
            directories[name] = VZSharedDirectory(url: URL(fileURLWithPath: folder.path), readOnly: folder.readOnly)
        }
        let tag = config.isMac ? VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag : "share"
        try VZVirtioFileSystemDeviceConfiguration.validateTag(tag)
        let device = VZVirtioFileSystemDeviceConfiguration(tag: tag)
        device.share = VZMultipleDirectoryShare(directories: directories)
        return device
    }

    private func configureLinux(_ vz: VZVirtualMachineConfiguration, config: VMConfig,
                                storage: inout [VZStorageDeviceConfiguration],
                                directoryDevices: inout [VZDirectorySharingDeviceConfiguration]) throws {
        let platform = VZGenericPlatformConfiguration()
        // A saved (suspended) state only restores onto the same machine identifier, so keep it stable.
        let identifierURL = store.genericMachineIdentifierURL(for: id)
        if let data = try? Data(contentsOf: identifierURL), let identifier = VZGenericMachineIdentifier(dataRepresentation: data) {
            platform.machineIdentifier = identifier
        } else {
            let identifier = VZGenericMachineIdentifier()
            try identifier.dataRepresentation.write(to: identifierURL)
            platform.machineIdentifier = identifier
        }
        let policy = Policy.current
        if config.nestedVirtualization == true, policy.permits(policy.allowNestedVirtualization),
           VZGenericPlatformConfiguration.isNestedVirtualizationSupported {
            platform.isNestedVirtualizationEnabled = true
        }
        vz.platform = platform

        // UEFI boot with persistent NVRAM, so the guest's boot entries survive reboots.
        let efiURL = store.efiURL(for: id)
        let bootLoader = VZEFIBootLoader()
        if FileManager.default.fileExists(atPath: efiURL.path) {
            bootLoader.variableStore = VZEFIVariableStore(url: efiURL)
        } else {
            bootLoader.variableStore = try VZEFIVariableStore(creatingVariableStoreAt: efiURL)
        }
        vz.bootLoader = bootLoader

        // Installer image as a USB stick, if one is attached.
        if let isoPath = config.isoPath, policy.permits(policy.allowUSBImages) || config.installSourceID != nil {
            guard FileManager.default.fileExists(atPath: isoPath) else {
                throw VMError(message: "Installer image not found: \(isoPath)")
            }
            let iso = try VZDiskImageStorageDeviceAttachment(url: URL(fileURLWithPath: isoPath), readOnly: true)
            storage.append(VZUSBMassStorageDeviceConfiguration(attachment: iso))
        }

        let graphics = VZVirtioGraphicsDeviceConfiguration()
        graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1920, heightInPixels: 1200)]
        vz.graphicsDevices = [graphics]
        vz.keyboards = [VZUSBKeyboardConfiguration()]
        vz.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]

        // Clipboard sharing; needs spice-vdagent running in the guest.
        let spicePort = VZVirtioConsolePortConfiguration()
        spicePort.name = VZSpiceAgentPortAttachment.spiceAgentPortName
        let spice = VZSpiceAgentPortAttachment()
        spice.sharesClipboard = config.clipboardEnabled && policy.permits(policy.allowClipboardSharing)
        spicePort.attachment = spice
        let console = VZVirtioConsoleDeviceConfiguration()
        console.ports[0] = spicePort
        vz.consoleDevices = [console]

        // Headless runs get a serial console on the terminal (guest needs console=hvc0).
        if store.headless {
            let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
            serial.attachment = VZFileHandleSerialPortAttachment(
                fileHandleForReading: FileHandle.standardInput, fileHandleForWriting: FileHandle.standardOutput)
            vz.serialPorts = [serial]
        }

        // Rosetta lets ARM64 Linux run x86-64 binaries (and x86 Docker images).
        if config.rosetta == true, policy.permits(policy.allowRosetta),
           VZLinuxRosettaDirectoryShare.availability == .installed {
            let device = VZVirtioFileSystemDeviceConfiguration(tag: "rosetta")
            device.share = try VZLinuxRosettaDirectoryShare()
            directoryDevices.append(device)
        }
    }
}
