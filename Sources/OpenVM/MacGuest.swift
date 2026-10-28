// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 OpenVM contributors
// This file is part of OpenVM, free software under the GNU General Public License v3.0 or later (see LICENSE).

import Foundation
import Virtualization

/// macOS guest support: Apple's restore image, platform identity files and device set.
enum MacGuest {
    static func latestRestoreImageSource() async throws -> ResolvedImage {
        let image = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<VZMacOSRestoreImage, Error>) in
            VZMacOSRestoreImage.fetchLatestSupported { continuation.resume(with: $0) }
        }
        return ResolvedImage(url: image.url, filename: image.url.lastPathComponent, sha256: nil)
    }

    static func loadRestoreImage(at url: URL) async throws -> VZMacOSRestoreImage {
        try await withCheckedThrowingContinuation { continuation in
            VZMacOSRestoreImage.load(from: url) { continuation.resume(with: $0) }
        }
    }

    /// Writes hardware model, machine identifier and auxiliary storage for a new Mac VM.
    @MainActor
    static func prepare(id: UUID, store: VMStore, image: VZMacOSRestoreImage) throws -> VZMacOSConfigurationRequirements {
        guard let requirements = image.mostFeaturefulSupportedConfiguration else {
            throw VMError(message: "This Mac cannot run the downloaded macOS release.")
        }
        guard requirements.hardwareModel.isSupported else {
            throw VMError(message: "The macOS hardware model is not supported on this host.")
        }
        try requirements.hardwareModel.dataRepresentation.write(to: store.hardwareModelURL(for: id))
        try VZMacMachineIdentifier().dataRepresentation.write(to: store.machineIdentifierURL(for: id))
        let aux = store.auxStorageURL(for: id)
        try? FileManager.default.removeItem(at: aux)
        _ = try VZMacAuxiliaryStorage(creatingStorageAt: aux, hardwareModel: requirements.hardwareModel, options: [])
        return requirements
    }

    /// Mac-specific devices; shared devices (disk, network, audio) are added by the caller.
    @MainActor
    static func configure(_ vz: VZVirtualMachineConfiguration, id: UUID, store: VMStore) throws {
        guard let modelData = try? Data(contentsOf: store.hardwareModelURL(for: id)),
              let model = VZMacHardwareModel(dataRepresentation: modelData),
              let idData = try? Data(contentsOf: store.machineIdentifierURL(for: id)),
              let machineID = VZMacMachineIdentifier(dataRepresentation: idData)
        else {
            throw VMError(message: "macOS platform files are missing; reinstall the VM.")
        }
        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = model
        platform.machineIdentifier = machineID
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: store.auxStorageURL(for: id))
        vz.platform = platform
        vz.bootLoader = VZMacOSBootLoader()

        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: 1920, heightInPixels: 1200, pixelsPerInch: 144)]
        vz.graphicsDevices = [graphics]
        vz.keyboards = [VZMacKeyboardConfiguration()]
        vz.pointingDevices = [VZMacTrackpadConfiguration()]
    }
}
