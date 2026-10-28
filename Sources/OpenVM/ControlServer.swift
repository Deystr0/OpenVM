// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 OpenVM contributors
// This file is part of OpenVM, free software under the GNU General Public License v3.0 or later (see LICENSE).

import Foundation

/// Per-VM control channel: a Unix socket the running process listens on so `openvmctl` can stop,
/// suspend or inspect a VM that the app (or another headless process) owns, like prlctl does.
/// One command per connection: a text line in, a text reply out, then close.
/// Sockets live in ~/.openvm (mode 0700) because Unix socket paths are limited to ~100 bytes.
final class ControlServer: @unchecked Sendable {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".openvm", isDirectory: true)
    }

    static func socketPath(for id: UUID) -> String {
        directory.appendingPathComponent(String(id.uuidString.prefix(8).lowercased()) + ".sock").path
    }

    private let path: String
    private var fd: Int32 = -1
    private var running = false
    private let handler: @Sendable (String) async -> String

    init(id: UUID, handler: @escaping @Sendable (String) async -> String) {
        path = Self.socketPath(for: id)
        self.handler = handler
    }

    @discardableResult
    func start() -> Bool {
        stop()
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        // The directory may pre-exist with a looser mode, or be a symlink planted by someone else.
        var info = stat()
        guard lstat(Self.directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == geteuid() else { return false }
        chmod(Self.directory.path, 0o700)
        unlink(path)
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { return false }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { close(listener); return false }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (i, byte) in bytes.enumerated() { raw[i] = UInt8(bitPattern: byte) }
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, length) }
        }
        guard bound == 0, listen(listener, 64) == 0 else { close(listener); return false }
        chmod(path, 0o600)
        fd = listener
        running = true
        let handler = self.handler
        let listenerFD = listener
        Thread.detachNewThread { [weak self] in
            while self?.running == true {
                let client = accept(listenerFD, nil, nil)
                if client < 0 {
                    if errno == EINTR || errno == ECONNABORTED { continue }
                    // Out of descriptors or memory is temporary: back off and keep listening.
                    if errno == EMFILE || errno == ENFILE || errno == ENOBUFS || errno == ENOMEM {
                        usleep(100_000)
                        continue
                    }
                    return
                }
                // Only the same user may talk to the VM, whatever the socket's file mode says.
                var uid: uid_t = 0, gid: gid_t = 0
                guard getpeereid(client, &uid, &gid) == 0, uid == geteuid() else { close(client); continue }
                var one: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                var timeout = timeval(tv_sec: 5, tv_usec: 0)   // a client that never sends must not hold a thread forever
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                // Each connection is read on its own thread, so one silent client cannot hold up the others.
                DispatchQueue.global(qos: .utility).async {
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    let count = read(client, &buffer, buffer.count - 1)
                    guard count > 0 else { close(client); return }
                    let command = String(decoding: buffer[0..<count], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    Task.detached { await Self.reply(client, to: command, handler: handler) }
                }
            }
        }
        return true
    }

    func stop() {
        running = false
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)   // wakes the thread blocked in accept
            close(fd)
            fd = -1
        }
        unlink(path)
    }

    private static func reply(_ client: Int32, to command: String, handler: @Sendable (String) async -> String) async {
        defer { close(client) }
        let text = await handler(command) + "\n"
        _ = text.withCString { write(client, $0, strlen($0)) }
    }

    /// Sends one command to the process that owns the VM. Returns nil if nothing is listening.
    static func send(_ command: String, to id: UUID, timeout: TimeInterval = 60) -> String? {
        let client = socket(AF_UNIX, SOCK_STREAM, 0)
        guard client >= 0 else { return nil }
        defer { close(client) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath(for: id).utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (i, byte) in bytes.enumerated() { raw[i] = UInt8(bitPattern: byte) }
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, length) }
        }
        guard connected == 0 else { return nil }
        var one: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = command.withCString { write(client, $0, strlen($0)) }
        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(client, &buffer, buffer.count)
            if count <= 0 { break }
            reply.append(buffer, count: count)
            if reply.count > 1_000_000 { break }
        }
        guard !reply.isEmpty else { return nil }
        return String(decoding: reply, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
