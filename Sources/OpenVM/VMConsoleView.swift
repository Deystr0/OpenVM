// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 OpenVM contributors
// This file is part of OpenVM, free software under the GNU General Public License v3.0 or later (see LICENSE).

import AppKit
import SwiftUI
import Virtualization

/// Hosts the framework's display/input view for a running VM.
struct VMConsoleView: NSViewRepresentable {
    let machine: VZVirtualMachine
    let runner: VMRunner

    func makeNSView(context: Context) -> VZVirtualMachineView {
        let view = VZVirtualMachineView()
        view.virtualMachine = machine
        // Leave macOS shortcuts (Ctrl-Cmd-F full screen, Cmd-Tab) to macOS so the user is never trapped in the guest.
        view.capturesSystemKeys = false
        view.automaticallyReconfiguresDisplay = true
        runner.consoleView = view
        return view
    }

    func updateNSView(_ view: VZVirtualMachineView, context: Context) {
        if view.virtualMachine !== machine { view.virtualMachine = machine }
        runner.consoleView = view
    }
}

/// Full-screen control for the window that shows the VM.
@MainActor
enum WindowFullScreen {
    private static var window: NSWindow? {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
    }

    static var isActive: Bool { window?.styleMask.contains(.fullScreen) == true }

    static func toggle() { window?.toggleFullScreen(nil) }

    static func enter() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        window.toggleFullScreen(nil)
    }
}
