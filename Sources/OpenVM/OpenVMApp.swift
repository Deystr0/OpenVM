// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 OpenVM contributors
// This file is part of OpenVM, free software under the GNU General Public License v3.0 or later (see LICENSE).

import AppKit
import SwiftUI

struct OpenVMApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = VMStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 1040, minHeight: 600)
                .onAppear { delegate.store = store }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Virtual Machine…") { NotificationCenter.default.post(name: .newVirtualMachine, object: nil) }
                    .keyboardShortcut("n")
            }
        }
    }
}

/// Quitting while a VM runs would cut the guest's power: possible disk damage, rollback and cleanup skipped.
/// Ask first, then suspend or shut the guests down before the app exits.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: VMStore?
    private var terminating = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store, !store.runningRunners.isEmpty else { return .terminateNow }
        // A second Quit while the first is still shutting guests down must not open another dialog or task.
        if terminating { return .terminateLater }
        let running = store.runningRunners
        let installing = running.contains { $0.state == .installing || $0.state == .starting }
        let alert = NSAlert()
        alert.messageText = running.count == 1 ? "A virtual machine is still running" : "\(running.count) virtual machines are still running"
        var info = "Quitting now would cut their power and could damage their disks. Suspend saves their exact state; Shut Down asks each guest to power off (forced after 30 seconds)."
        if installing { info += " A machine that is starting or installing macOS cannot be suspended: it is stopped, and an unfinished install must be started again." }
        alert.informativeText = info
        alert.addButton(withTitle: "Suspend and Quit")
        alert.addButton(withTitle: "Shut Down and Quit")
        alert.addButton(withTitle: "Cancel")
        let choice = alert.runModal()
        guard choice != .alertThirdButtonReturn else { return .terminateCancel }
        terminating = true
        Task { @MainActor in
            for runner in running {
                if choice == .alertFirstButtonReturn {
                    await runner.suspend()
                    if runner.isIdle { continue }                // suspended (or already off)
                }
                await Self.shutDown(runner)
            }
            self.terminating = false
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private static func shutDown(_ runner: VMRunner) async {
        if runner.state == .paused { await runner.resume() }
        runner.requestStop()
        for _ in 0..<60 where !runner.isIdle { try? await Task.sleep(nanoseconds: 500_000_000) }
        if !runner.isIdle { await runner.forceStop() }
    }

    /// Another process (the command line) may have changed configs while the app was in the background.
    func applicationDidBecomeActive(_ notification: Notification) { store?.reload() }
}

extension Notification.Name {
    static let newVirtualMachine = Notification.Name("OpenVM.newVirtualMachine")
}
