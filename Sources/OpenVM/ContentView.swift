// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 OpenVM contributors
// This file is part of OpenVM, free software under the GNU General Public License v3.0 or later (see LICENSE).

import AppKit
import SwiftUI

enum SortOrder: String, CaseIterable, Identifiable {
    case name = "Name", created = "Date created", state = "Running first"
    var id: String { rawValue }
}

struct ContentView: View {
    @EnvironmentObject private var store: VMStore
    @AppStorage("sortOrder") private var sortOrder: SortOrder = .created
    /// Hidden while the window is full screen so the VM gets the whole display; restored on exit.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var visibilityBeforeFullScreen: NavigationSplitViewVisibility = .all
    @State private var showingNewVM = false
    @State private var showingMonitor = false
    @State private var showingStorage = false
    @State private var pendingDelete: VMConfig?

    private var sortedVMs: [VMConfig] {
        switch sortOrder {
        case .name: return store.vms.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .created: return store.vms.sorted { $0.created < $1.created }
        case .state:
            return store.vms.sorted {
                let a = !store.runner(for: $0.id).isIdle, b = !store.runner(for: $1.id).isIdle
                return a != b ? a : $0.created < $1.created
            }
        }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $store.selection) {
                ForEach(sortedVMs) { vm in
                    SidebarRow(config: vm, runner: store.runner(for: vm.id))
                        .tag(vm.id)
                        .contextMenu {
                            Button(vm.template ? "New VM from Template" : "Clone") { clone(vm) }
                            Divider()
                            Button("Delete…", role: .destructive) { pendingDelete = vm }
                        }
                }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 250)
            .toolbar {
                ToolbarItem {
                    Menu {
                        Picker("Sort by", selection: $sortOrder) {
                            ForEach(SortOrder.allCases) { Text($0.rawValue).tag($0) }
                        }
                    } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }
                }
                ToolbarItem {
                    Menu {
                        Button("Performance…") { showingMonitor = true }
                        Button("Storage and Cleanup…") { showingStorage = true }
                    } label: { Label("Monitor", systemImage: "gauge.with.dots.needle.67percent") }
                }
                ToolbarItem {
                    Button { showingNewVM = true } label: { Label("New VM", systemImage: "plus") }
                        .disabled(!Policy.current.permits(Policy.current.allowCreatingVMs))
                }
            }
        } detail: {
            if let id = store.selection, let config = store.config(for: id) {
                VMDetailView(config: config, runner: store.runner(for: id))
                    .id(id)
            } else {
                ContentUnavailableView("No virtual machine", systemImage: "desktopcomputer",
                                       description: Text("Create one with the + button."))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { _ in
            visibilityBeforeFullScreen = columnVisibility
            columnVisibility = .detailOnly
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { _ in
            columnVisibility = visibilityBeforeFullScreen
        }
        .task {
            // A window restored into full screen never sends "will enter"; apply the same rule.
            try? await Task.sleep(nanoseconds: 400_000_000)
            if WindowFullScreen.isActive, columnVisibility != .detailOnly {
                visibilityBeforeFullScreen = columnVisibility
                columnVisibility = .detailOnly
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newVirtualMachine)) { _ in
            if Policy.current.permits(Policy.current.allowCreatingVMs) { showingNewVM = true }
        }
        .sheet(isPresented: $showingNewVM) { NewVMSheet() }
        .sheet(isPresented: $showingMonitor) { MonitorView() }
        .sheet(isPresented: $showingStorage) { StorageView() }
        .confirmationDialog("Delete “\(pendingDelete?.name ?? "")” and its disk?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let pendingDelete { store.delete(pendingDelete.id) }
                pendingDelete = nil
            }
        } message: {
            Text("This permanently removes the virtual disk and its snapshots.")
        }
        .alert("Error", isPresented: Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.lastError ?? "")
        }
    }

    private func clone(_ vm: VMConfig) {
        do {
            try store.clone(vm.id, name: vm.template ? vm.name.replacingOccurrences(of: " Template", with: "") + " Copy" : "\(vm.name) Clone")
        } catch {
            store.lastError = error.localizedDescription
        }
    }
}

private struct SidebarRow: View {
    let config: VMConfig
    @ObservedObject var runner: VMRunner

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: config.iconSymbol ?? Appearance.defaultSymbol)
                .foregroundStyle(Color(hex: config.colorHex ?? Appearance.defaultColor))
                .frame(width: 20)
            Text(config.name).lineLimit(1)
            Spacer()
            if config.template {
                Text("Template").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            } else if runner.state == .running {
                Circle().fill(.green).frame(width: 8, height: 8)
            } else if runner.state == .paused {
                Circle().fill(.orange).frame(width: 8, height: 8)
            }
        }
    }
}
