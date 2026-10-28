// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 OpenVM contributors
// This file is part of OpenVM, free software under the GNU General Public License v3.0 or later (see LICENSE).

import Darwin
import Foundation
import SwiftUI

struct MonitorSample {
    var hostCPU = 0.0            // percent of all cores
    var hostMemoryUsedGB = 0.0
    var hostMemoryTotalGB = 0.0
    var engineCPU = 0.0          // percent of one core, summed over VM engine processes
    var engineMemoryMB = 0.0
    var engineCount = 0
    var netInPerSecond = 0.0     // bytes/s over the VMs' NAT networks
    var netOutPerSecond = 0.0
}

/// Samples host and virtual-machine load once a second.
/// CPU temperature is not offered: macOS only exposes it to privileged processes.
@MainActor
final class SystemMonitor: ObservableObject {
    @Published private(set) var sample = MonitorSample()
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var vmIPs: [UUID: String] = [:]

    private var previousTicks: [UInt32]?
    private var previousNet: (inBytes: UInt64, outBytes: UInt64, at: Date)?
    private var task: Task<Void, Never>?

    func start(store: VMStore) {
        stop()
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick(store: store)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stop() { task?.cancel(); task = nil }

    private func tick(store: VMStore) async {
        var next = sample
        next.hostCPU = hostCPUPercent()
        let memory = hostMemory()
        next.hostMemoryUsedGB = memory.used
        next.hostMemoryTotalGB = memory.total

        let engine = await Self.vmEngineUsage()
        next.engineCPU = engine.cpu
        next.engineMemoryMB = engine.memoryMB
        next.engineCount = engine.count

        // Network: bytes on the bridge interface that carries each running VM's NAT subnet.
        var ips: [UUID: String] = [:]
        var prefixes = Set<String>()
        for config in store.vms where !store.runner(for: config.id).isIdle {
            if let ip = await GuestNetwork.ip(forMAC: config.macAddress) {
                ips[config.id] = ip
                prefixes.insert(ip.split(separator: ".").prefix(3).joined(separator: "."))
            }
        }
        vmIPs = ips
        let totals = Self.bridgeBytes(matching: prefixes)
        let now = Date()
        if let previous = previousNet {
            let dt = max(now.timeIntervalSince(previous.at), 0.1)
            // Counters can reset (the last VM stopped, an interface vanished): never subtract backwards.
            next.netInPerSecond = totals.inBytes >= previous.inBytes ? Double(totals.inBytes - previous.inBytes) / dt : 0
            next.netOutPerSecond = totals.outBytes >= previous.outBytes ? Double(totals.outBytes - previous.outBytes) / dt : 0
        }
        previousNet = prefixes.isEmpty ? nil : (totals.inBytes, totals.outBytes, now)

        sample = next
        cpuHistory.append(next.hostCPU)
        if cpuHistory.count > 60 { cpuHistory.removeFirst(cpuHistory.count - 60) }
    }

    private func hostCPUPercent() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let ticks = [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]   // user, system, idle, nice
        defer { previousTicks = ticks }
        guard let previous = previousTicks else { return 0 }
        let delta = zip(ticks, previous).map { Double($0 &- $1) }
        let total = delta.reduce(0, +)
        return total > 0 ? (total - delta[2]) / total * 100 : 0
    }

    private func hostMemory() -> (used: Double, total: Double) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let total = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        guard result == KERN_SUCCESS else { return (0, total) }
        let page = Double(vm_kernel_page_size)
        let used = Double(stats.active_count + stats.wire_count + stats.compressor_page_count) * page / 1_073_741_824
        return (used, total)
    }

    /// Sums the framework's per-VM helper processes (they are not children of OpenVM, so they
    /// cannot be attributed to one VM when several run).
    private static func vmEngineUsage() async -> (cpu: Double, memoryMB: Double, count: Int) {
        await Task.detached(priority: .utility) { () -> (Double, Double, Int) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/ps")
            process.arguments = ["-axco", "pcpu=,rss=,comm="]
            let pipe = Pipe()
            process.standardOutput = pipe
            guard (try? process.run()) != nil else { return (0, 0, 0) }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            var cpu = 0.0, rssKB = 0.0, count = 0
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where line.contains("Virtualization.VirtualMachine") {
                let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                guard fields.count >= 2, let c = Double(fields[0]), let r = Double(fields[1]) else { continue }
                cpu += c; rssKB += r; count += 1
            }
            return (cpu, rssKB / 1024, count)
        }.value
    }

    private static func bridgeBytes(matching prefixes: Set<String>) -> (inBytes: UInt64, outBytes: UInt64) {
        guard !prefixes.isEmpty else { return (0, 0) }
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return (0, 0) }
        defer { freeifaddrs(head) }
        var names = Set<String>()
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: host)
            if prefixes.contains(where: { ip.hasPrefix($0 + ".") }) { names.insert(String(cString: entry.ifa_name)) }
        }
        var inBytes: UInt64 = 0, outBytes: UInt64 = 0
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                  names.contains(String(cString: entry.ifa_name)), let data = entry.ifa_data else { continue }
            let counters = data.assumingMemoryBound(to: if_data.self).pointee
            inBytes += UInt64(counters.ifi_ibytes)
            outBytes += UInt64(counters.ifi_obytes)
        }
        return (inBytes, outBytes)
    }
}

struct MonitorView: View {
    @EnvironmentObject private var store: VMStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var monitor = SystemMonitor()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Performance").font(.title2.bold())

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                GridRow {
                    Text("Mac CPU")
                    Text(String(format: "%.0f %%", monitor.sample.hostCPU)).monospacedDigit()
                    Sparkline(values: monitor.cpuHistory).frame(height: 28)
                }
                GridRow {
                    Text("Mac memory")
                    Text(String(format: "%.1f / %.0f GB", monitor.sample.hostMemoryUsedGB, monitor.sample.hostMemoryTotalGB)).monospacedDigit()
                    ProgressView(value: monitor.sample.hostMemoryUsedGB, total: max(monitor.sample.hostMemoryTotalGB, 1))
                }
                GridRow {
                    Text("VM engine")
                    Text(String(format: "%.0f %% CPU, %.0f MB", monitor.sample.engineCPU, monitor.sample.engineMemoryMB)).monospacedDigit()
                    Text("\(monitor.sample.engineCount) helper process(es)").foregroundStyle(.secondary)
                }
                GridRow {
                    Text("VM network")
                    Text("↓ \(rate(monitor.sample.netInPerSecond))   ↑ \(rate(monitor.sample.netOutPerSecond))").monospacedDigit()
                    Text("NAT, all running VMs").foregroundStyle(.secondary)
                }
            }

            Divider()
            Text("Virtual machines").font(.headline)
            List {
                ForEach(store.vms) { vm in
                    RunningRow(config: vm, runner: store.runner(for: vm.id), ip: monitor.vmIPs[vm.id])
                }
            }
            .frame(minHeight: 120)

            Text("CPU temperature is not shown: macOS exposes it only to privileged processes.")
                .font(.footnote).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 560, height: 480)
        .onAppear { monitor.start(store: store) }
        .onDisappear { monitor.stop() }
    }

    private func rate(_ bytesPerSecond: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(max(0, min(bytesPerSecond, 9e18))), countStyle: .file) + "/s"
    }
}

private struct RunningRow: View {
    let config: VMConfig
    @ObservedObject var runner: VMRunner
    let ip: String?

    var body: some View {
        HStack {
            Image(systemName: config.iconSymbol ?? Appearance.defaultSymbol)
                .foregroundStyle(Color(hex: config.colorHex ?? Appearance.defaultColor))
            Text(config.name)
            Spacer()
            if runner.state == .running || runner.state == .paused {
                Text(runner.state == .paused ? "paused" : "running").foregroundStyle(.secondary)
                if let started = runner.startedAt {
                    Text(started, style: .relative).foregroundStyle(.secondary)
                }
                Text("\(config.cpuCount) cpu · \(config.memoryGB) GB").foregroundStyle(.secondary)
                if let ip { Text(ip).monospacedDigit() }
            } else {
                Text("stopped").foregroundStyle(.tertiary)
            }
        }
    }
}

private struct Sparkline: View {
    let values: [Double]
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                guard values.count > 1 else { return }
                let step = geometry.size.width / CGFloat(max(values.count - 1, 1))
                for (i, value) in values.enumerated() {
                    let point = CGPoint(x: CGFloat(i) * step, y: geometry.size.height * (1 - CGFloat(min(value, 100) / 100)))
                    i == 0 ? path.move(to: point) : path.addLine(to: point)
                }
            }
            .stroke(Color.accentColor, lineWidth: 1.5)
        }
    }
}
