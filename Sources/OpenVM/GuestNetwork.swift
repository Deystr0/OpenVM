// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 OpenVM contributors
// This file is part of OpenVM, free software under the GNU General Public License v3.0 or later (see LICENSE).

import Foundation
import Network

/// Finds a running VM's NAT address from the host's ARP table, matching on the VM's fixed MAC.
enum GuestNetwork {
    /// MAC octets in `arp` output have no leading zeros ("4a:89:5:81"), so compare normalized forms.
    private static func normalized(_ mac: String) -> String {
        mac.lowercased().split(separator: ":").map { String(Int($0, radix: 16) ?? 0, radix: 16) }.joined(separator: ":")
    }

    /// The NAT's DHCP server records each lease here as soon as the guest gets an address, so this
    /// works even before the host has exchanged any traffic with the guest. The newest lease wins.
    private static func leasedIP(forMAC mac: String) -> String? {
        guard let text = try? String(contentsOfFile: "/var/db/dhcpd_leases", encoding: .utf8) else { return nil }
        let wanted = normalized(mac)
        var best: (ip: String, expiry: UInt64)?
        for block in text.components(separatedBy: "}") {
            var ip: String?, hardware: String?, expiry: UInt64 = 0
            for line in block.split(separator: "\n") {
                let pair = line.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1).map(String.init)
                guard pair.count == 2 else { continue }
                switch pair[0] {
                case "ip_address": ip = pair[1]
                case "hw_address": hardware = pair[1]
                case "lease": expiry = UInt64(pair[1].dropFirst(2), radix: 16) ?? 0
                default: break
                }
            }
            // Installed systems send a DUID client id ("ff,<iaid>:<duid>...") that ends with the MAC.
            // Expired leases stay in the file after the address is reassigned; never use them.
            if let ip, let hardware, expiry > UInt64(Date().timeIntervalSince1970), expiry >= (best?.expiry ?? 0) {
                if Self.identifierMatches(hardware, wanted: wanted) { best = (ip, expiry) }
            }
        }
        return best?.ip
    }

    /// `1,<mac>` exactly, or a DHCPv6-style DUID client id (`ff,<iaid>:0:1:0:1:<time>:<mac>` or `...:0:3:0:1:<mac>`)
    /// that ends in the MAC. Anything else is ignored, so a guest cannot claim another VM's address by
    /// choosing a client id that merely ends with that VM's MAC.
    private static func identifierMatches(_ raw: String, wanted: String) -> Bool {
        let parts = raw.split(separator: ",", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return false }
        let body = normalized(parts[1])
        if parts[0] == "1" { return body == wanted }
        guard parts[0] == "ff", body.hasSuffix(":" + wanted) else { return false }
        let fields = body.split(separator: ":").map(String.init)           // iaid(4) duid-type(2) hw-type(2) [time(4)] mac(6)
        guard fields.count == 4 + 4 + 4 + 6 || fields.count == 4 + 4 + 6 else { return false }
        let tail = fields[4...].prefix(4).joined(separator: ":")
        return tail == "0:1:0:1" || tail == "0:3:0:1"
    }

    static func ip(forMAC mac: String) async -> String? {
        await Task.detached(priority: .utility) { () -> String? in
            if let leased = leasedIP(forMAC: mac) { return leased }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
            process.arguments = ["-an"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let wanted = normalized(mac)
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                // "? (192.168.64.5) at 36:51:84:3f:18:a6 on bridge100 ifscope [ethernet]"
                let parts = line.split(separator: " ")
                guard parts.count > 3, parts[2] == "at", normalized(String(parts[3])) == wanted else { continue }
                return parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            }
            return nil
        }.value
    }
}

/// Relays TCP from 127.0.0.1:hostPort on the Mac to a port on the VM.
/// VZ's NAT has no built-in forwarding, so this is a small userspace proxy.
@MainActor
final class PortForwarder {
    private var listeners: [NWListener] = []
    /// Maps a VM's MAC to its address. Injectable so the relay can be tested against a local server.
    private let resolve: @Sendable (String) async -> String?

    private let onFailure: @MainActor (String) -> Void
    /// Concurrent relayed connections across all forwards; beyond this new ones are refused.
    private nonisolated static let maxConnections = 128
    private nonisolated static let active = ConnectionCounter()
    /// Each relayed connection holds two descriptors and macOS starts GUI processes at 256, so lift the
    /// soft limit once (never above the hard limit) before the first forward starts.
    private nonisolated static let raiseDescriptorLimit: Void = {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
        let wanted = min(rlim_t(4096), limit.rlim_max)
        if limit.rlim_cur < wanted { limit.rlim_cur = wanted; _ = setrlimit(RLIMIT_NOFILE, &limit) }
    }()

    init(resolve: @escaping @Sendable (String) async -> String? = { await GuestNetwork.ip(forMAC: $0) },
         onFailure: @escaping @MainActor (String) -> Void = { _ in }) {
        self.resolve = resolve
        self.onFailure = onFailure
    }

    func start(forwards: [PortForward], mac: String) {
        stop()
        _ = Self.raiseDescriptorLimit
        let resolve = self.resolve
        for forward in forwards {
            guard Validation.ports.contains(forward.hostPort), Validation.ports.contains(forward.guestPort),
                  let hostPort = NWEndpoint.Port(rawValue: UInt16(clamping: forward.hostPort)),
                  let guestPort = NWEndpoint.Port(rawValue: UInt16(clamping: forward.guestPort)) else { continue }
            let parameters = NWParameters.tcp
            // Loopback only: never expose a guest service to the local network by accident.
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: hostPort)
            guard let listener = try? NWListener(using: parameters) else {
                onFailure("Port \(forward.hostPort) cannot be forwarded.")
                continue
            }
            let report = onFailure
            // A bind failure (the port is already in use) only shows up here, asynchronously.
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    Task { @MainActor in report("Port forward \(forward.hostPort) failed: \(error.localizedDescription). Another program may be using it.") }
                }
            }
            listener.newConnectionHandler = { inbound in
                guard Self.active.tryAcquire(limit: Self.maxConnections) else { inbound.cancel(); return }
                Task.detached {
                    await Self.relay(inbound, toGuestPort: guestPort, mac: mac, resolve: resolve,
                                     onClose: { Self.active.release() })
                }
            }
            listener.start(queue: .global(qos: .utility))
            listeners.append(listener)
        }
    }

    func stop() {
        listeners.forEach { $0.cancel() }
        listeners = []
    }

    private nonisolated static func relay(_ inbound: NWConnection, toGuestPort port: NWEndpoint.Port, mac: String,
                                          resolve: @Sendable (String) async -> String?,
                                          onClose: @escaping @Sendable () -> Void) async {
        var address: String?
        for _ in 0..<6 {
            address = await resolve(mac)
            if address != nil { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        guard let address else { inbound.cancel(); onClose(); return }
        let outbound = NWConnection(host: NWEndpoint.Host(address), port: port, using: .tcp)
        let pair = RelayPair(inbound, outbound, onClose: onClose)
        let queue = DispatchQueue.global(qos: .utility)
        // A new connection passes through a transient `waiting` ("network is down") state while the
        // path to the VM's bridge settles, so only give up on failure or after a deadline.
        outbound.stateUpdateHandler = { state in
            if case .failed = state { pair.abort() }
        }
        inbound.stateUpdateHandler = { state in
            if case .failed = state { pair.abort() }
        }
        queue.asyncAfter(deadline: .now() + 10) {
            if outbound.state != .ready { pair.abort() }
        }
        queue.asyncAfter(deadline: .now() + 3600) { pair.abort() }   // nothing stays open forever
        inbound.start(queue: queue)
        outbound.start(queue: queue)
        pump(inbound, outbound, pair)
        pump(outbound, inbound, pair)
    }

    /// Copies one direction. End-of-stream is forwarded as a half-close (FIN) so the other direction
    /// can still finish, which matters for protocols where the client shuts down its write side first.
    private nonisolated static func pump(_ from: NWConnection, _ to: NWConnection, _ pair: RelayPair) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            if error != nil { pair.abort(); return }
            if let data, !data.isEmpty {
                to.send(content: data, completion: .contentProcessed { sendError in
                    if sendError != nil { pair.abort() }
                    else if isComplete { pair.finish(closing: to) }
                    else { pump(from, to, pair) }
                })
            } else if isComplete {
                pair.finish(closing: to)
            } else {
                pump(from, to, pair)
            }
        }
    }
}

/// Two connections relayed to each other; both are torn down once both directions have ended.
private final class RelayPair: @unchecked Sendable {
    private let a: NWConnection
    private let b: NWConnection
    private let lock = NSLock()
    private var finishedDirections = 0
    private var aborted = false

    private let onClose: @Sendable () -> Void

    init(_ a: NWConnection, _ b: NWConnection, onClose: @escaping @Sendable () -> Void) {
        self.a = a; self.b = b; self.onClose = onClose
    }

    /// The single teardown point: every path ends here exactly once, so the connection count stays exact.
    func abort() {
        lock.lock(); let already = aborted; aborted = true; lock.unlock()
        if !already { a.cancel(); b.cancel(); onClose() }
    }

    func finish(closing destination: NWConnection) {
        destination.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [self] _ in
            lock.lock(); finishedDirections += 1; let done = finishedDirections == 2; lock.unlock()
            if done { abort() }
        })
    }
}

/// Counts relayed connections that are still in flight.
private final class ConnectionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func tryAcquire(limit: Int) -> Bool { lock.lock(); defer { lock.unlock() }; guard count < limit else { return false }; count += 1; return true }
    func release() { lock.lock(); count -= 1; lock.unlock() }
}
