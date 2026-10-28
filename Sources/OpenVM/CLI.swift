// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 OpenVM contributors
// This file is part of OpenVM, free software under the GNU General Public License v3.0 or later (see LICENSE).

import Foundation

/// `openvmctl`: scripting, automation and headless runs.
/// The same binary serves the app and the CLI; main.swift routes by first argument.
/// Exit status: 0 success, 1 failure (message on stderr). `--json` gives machine-readable output.
enum CLI {
    static let commands: Set<String> = [
        "list", "info", "run", "start", "status", "stop", "kill", "pause", "resume", "suspend",
        "screenshot", "ip", "ssh", "snapshot", "clone", "create", "set", "template", "export", "import",
        "delete", "policy", "help", "--help", "-h",
    ]

    static let usage = """
    openvmctl: manage OpenVM virtual machines from the terminal

    Lifecycle
      list [--json]                     all VMs with state
      info <vm> [--json]                configuration details
      run <vm>                          start headless in the foreground (Ctrl-C shuts down)
      status <vm> [--json]              state of a running VM
      stop <vm> [--wait SECONDS] [--force-after SECONDS]
                                        graceful shutdown (ACPI power button). --wait polls until the
                                        VM is off (exit 1 on timeout); --force-after powers it off
                                        if the guest has not stopped by then
      kill <vm>                         immediate power-off
      pause <vm> | resume <vm>
      suspend <vm>                      save state to disk and power off
      screenshot <vm> [file.png]        capture the console (needs the app's window open)
      ip <vm> | ssh <vm> [user]

    Provisioning
      create <name> [--cpus N] [--memory GB] [--disk GB] [--iso file.iso] [--from <template-or-vm>]
      set <vm> key=value ...            cpus, memory, name, ssh-user, fullscreen, clipboard,
                                        microphone, rosetta, nested (on|off), autostart (seconds|off),
                                        forward-add=HOST:GUEST, forward-clear
      template <vm> on|off              mark/unmark as a template (golden image)
      clone <vm> [new name]             instant copy-on-write clone
      export <vm> <folder>              write <folder>/<name>.openvm (VM must be stopped)
      import <path.openvm>              register an exported VM under a new identity
      snapshot list|create|restore|delete <vm> [name]
      delete <vm>

    Administration
      policy [--json]                   show the active administrator policy

    <vm> is a name, a unique name prefix, or the start of its id. Headless VMs print their serial
    console on the terminal (guest needs console=hvc0) and are reachable over SSH.
    """

    static func run(_ args: [String]) -> Never {
        Task { @MainActor in
            let code = await execute(args)
            exit(code)
        }
        dispatchMain()
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("openvmctl: \(message)\n".utf8))
        return 1
    }

    private static func json(_ object: Any) {
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) { print(text) }
    }

    @MainActor
    private static func state(of config: VMConfig, store: VMStore) -> String {
        if let owner = store.lockOwner(of: config.id) { return "running (\(owner.mode), pid \(owner.pid))" }
        if config.template { return "template" }
        return store.hasSavedState(config.id) ? "suspended" : "stopped"
    }

    @MainActor
    private static func details(_ config: VMConfig, store: VMStore) -> [String: Any] {
        [
            "id": config.id.uuidString, "name": config.name, "os": config.isMac ? "macOS" : "Linux",
            "state": state(of: config, store: store), "cpus": config.cpuCount, "memoryGB": config.memoryGB,
            "diskGB": config.diskGB, "extraDisks": (config.extraDisks ?? []).count, "mac": config.macAddress,
            "template": config.template, "snapshots": (config.snapshots ?? []).map(\.name),
            "portForwards": (config.portForwards ?? []).map { "\($0.hostPort):\($0.guestPort)" },
            "sharedFolders": config.folders.map(\.path), "fullScreen": config.startFullScreen == true,
        ]
    }

    @MainActor
    private static func execute(_ args: [String]) async -> Int32 {
        var args = args
        let wantsJSON = args.contains("--json")
        args.removeAll { $0 == "--json" }
        guard let command = args.first else { print(usage); return 0 }
        if ["help", "--help", "-h"].contains(command) { print(usage); return 0 }

        let store = VMStore(autostart: false)
        store.headless = true
        let rest = Array(args.dropFirst())

        func vm(_ query: String?) -> VMConfig? { query.flatMap { store.find($0) } }   // nil also when a name is ambiguous

        /// Sends a command to whichever process runs the VM (the app or a headless run).
        func control(_ name: String, _ config: VMConfig, extra: String = "", timeout: TimeInterval = 120) -> Int32 {
            guard let reply = ControlServer.send(extra.isEmpty ? name : "\(name) \(extra)", to: config.id, timeout: timeout) else {
                return fail("\(config.name) is not running (or its owner does not respond).")
            }
            if wantsJSON { json(["vm": config.name, "reply": reply]) } else { print(reply) }
            return reply.hasPrefix("error") ? 1 : 0
        }

        switch command {
        case "list":
            if wantsJSON { json(store.vms.map { details($0, store: store) }); return 0 }
            if store.vms.isEmpty { print("No virtual machines."); return 0 }
            for config in store.vms {
                print("\(config.id.uuidString.prefix(8).lowercased())  \(pad(config.name, 24))  \(pad(state(of: config, store: store), 28))  \(config.cpuCount) cpu  \(config.memoryGB) GB")
            }
            return 0

        case "info":
            guard let config = vm(rest.first) else { return fail("no such VM, or the name matches more than one. Try: openvmctl list") }
            if wantsJSON { json(details(config, store: store)); return 0 }
            let d = details(config, store: store)
            print("Name:        \(config.name)")
            print("Id:          \(config.id.uuidString)")
            print("OS:          \(d["os"] ?? "")")
            print("State:       \(d["state"] ?? "")")
            print("CPU/Memory:  \(config.cpuCount) cores, \(config.memoryGB) GB")
            print("Disk:        \(config.diskGB) GB + \((config.extraDisks ?? []).count) extra")
            print("MAC:         \(config.macAddress)")
            print("Snapshots:   \((config.snapshots ?? []).map(\.name).joined(separator: ", "))")
            print("Forwards:    \((config.portForwards ?? []).map { "\($0.hostPort)->\($0.guestPort)" }.joined(separator: ", "))")
            print("Folders:     \(config.folders.map(\.path).joined(separator: ", "))")
            return 0

        case "run", "start":
            guard let config = vm(rest.first) else { return fail("no such VM, or the name matches more than one. Try: openvmctl list") }
            return await runHeadless(config, store: store)

        case "status", "pause", "resume", "suspend", "kill":
            guard let config = vm(rest.first) else { return fail("no such VM.") }
            if command == "status", store.lockOwner(of: config.id) == nil {
                if wantsJSON { json(["vm": config.name, "state": state(of: config, store: store)]) }
                else { print("state=\(state(of: config, store: store).split(separator: " ").first ?? "stopped")") }
                return 0
            }
            if command == "status", wantsJSON, let reply = ControlServer.send("status", to: config.id, timeout: 10) {
                var object: [String: Any] = ["vm": config.name]
                for pair in reply.split(separator: " ") {
                    let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                    if kv.count == 2 { object[kv[0]] = Int(kv[1]) ?? kv[1] }
                }
                json(object)
                return 0
            }
            return control(command, config)

        case "stop":
            guard let config = vm(rest.first) else { return fail("no such VM.") }
            func seconds(_ flag: String) -> Double? {
                guard let i = rest.firstIndex(of: flag), i + 1 < rest.count else { return nil }
                return Double(rest[i + 1])
            }
            var position = 1
            while position < rest.count {
                guard ["--wait", "--force-after"].contains(rest[position]), position + 1 < rest.count,
                      let value = Double(rest[position + 1]), value >= 0, value <= 86_400 else {
                    return fail("usage: stop <vm> [--wait SECONDS] [--force-after SECONDS] (seconds are plain numbers, 0 to 86400)")
                }
                position += 2
            }
            let wait = seconds("--wait"), force = seconds("--force-after")
            let code = control("stop", config)
            guard code == 0, wait != nil || force != nil else { return code }
            let deadline = Date().addingTimeInterval(wait ?? ((force ?? 0) + 10))
            let forceAt = force.map { Date().addingTimeInterval($0) }
            while store.lockOwner(of: config.id) != nil {
                if let forceAt, Date() >= forceAt {
                    FileHandle.standardError.write(Data("openvmctl: guest did not shut down; powering off\n".utf8))
                    _ = control("kill", config)
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    return store.lockOwner(of: config.id) == nil ? 0 : 1
                }
                if Date() >= deadline { return fail("\(config.name) is still running after the wait.") }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            return 0

        case "screenshot":
            guard let config = vm(rest.first) else { return fail("no such VM.") }
            let target = rest.count > 1 ? URL(fileURLWithPath: rest[1]).standardizedFileURL.path : ""
            return control("screenshot", config, extra: target)

        case "ip":
            guard let config = vm(rest.first) else { return fail("no such VM.") }
            guard store.lockOwner(of: config.id) != nil else { return fail("\(config.name) is not running.") }
            guard let address = await GuestNetwork.ip(forMAC: config.macAddress) else { return fail("no address found (is it running and booted?)") }
            if wantsJSON { json(["vm": config.name, "ip": address]) } else { print(address) }
            return 0

        case "ssh":
            guard let config = vm(rest.first) else { return fail("no such VM.") }
            guard store.lockOwner(of: config.id) != nil else { return fail("\(config.name) is not running.") }
            guard let address = await GuestNetwork.ip(forMAC: config.macAddress) else { return fail("no address found (is it running and booted?)") }
            let user = rest.dropFirst().first ?? config.sshUser
            if let user, !Validation.isValidSSHUser(user) { return fail("invalid ssh user name") }
            let target = user.map { "\($0)@\(address)" } ?? address
            let ssh = Process()
            ssh.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            ssh.arguments = ["-o", "StrictHostKeyChecking=accept-new", "--", target]
            do { try ssh.run() } catch { return fail("could not start ssh: \(error.localizedDescription)") }
            ssh.waitUntilExit()
            return ssh.terminationStatus

        case "snapshot":
            guard rest.count >= 2, let config = vm(rest[1]) else { return fail("usage: snapshot list|create|restore|delete <vm> [name]") }
            let name = rest.count > 2 ? rest[2...].joined(separator: " ") : nil
            func snapshot(named name: String?) -> SnapshotInfo? {
                guard let name else { return nil }
                return (store.config(for: config.id)?.snapshots ?? []).first { $0.name == name }
            }
            do {
                switch rest[0] {
                case "list":
                    let list = store.config(for: config.id)?.snapshots ?? []
                    if wantsJSON { json(list.map { ["name": $0.name, "created": ISO8601DateFormatter().string(from: $0.created)] }) }
                    else { for s in list { print("\(s.name)  \(s.created.formatted())") } }
                case "create":
                    guard let name else { return fail("snapshot create needs a name") }
                    try store.takeSnapshot(of: config.id, name: name)
                    print("Snapshot “\(name)” created.")
                case "restore":
                    guard let s = snapshot(named: name) else { return fail("no snapshot with that name") }
                    try store.restoreSnapshot(s.id, of: config.id)
                    print("Restored “\(s.name)”.")
                case "delete":
                    guard let s = snapshot(named: name) else { return fail("no snapshot with that name") }
                    store.deleteSnapshot(s.id, of: config.id)
                    print("Deleted “\(s.name)”.")
                default:
                    return fail("usage: snapshot list|create|restore|delete <vm> [name]")
                }
            } catch {
                return fail(error.localizedDescription)
            }
            return 0

        case "clone":
            guard let config = vm(rest.first) else { return fail("no such VM.") }
            do {
                let copy = try store.clone(config.id, name: rest.count > 1 ? rest[1...].joined(separator: " ") : "\(config.name) Clone")
                if wantsJSON { json(details(copy, store: store)) } else { print("Created “\(copy.name)” (\(copy.id.uuidString.prefix(8).lowercased())).") }
            } catch {
                return fail(error.localizedDescription)
            }
            return 0

        case "create":
            return create(rest, store: store, wantsJSON: wantsJSON)

        case "set":
            guard rest.count >= 2, let config = vm(rest[0]) else { return fail("usage: set <vm> key=value ...") }
            return set(config, assignments: Array(rest.dropFirst()), store: store)

        case "template":
            guard rest.count == 2, let config = vm(rest[0]), ["on", "off"].contains(rest[1]) else { return fail("usage: template <vm> on|off") }
            guard store.lockOwner(of: config.id) == nil else { return fail("\(config.name) is running; stop it first.") }
            var updated = config
            updated.isTemplate = rest[1] == "on" ? true : nil
            store.update(updated)
            print("\(config.name): template \(rest[1])")
            return 0

        case "export":
            guard rest.count == 2, let config = vm(rest[0]) else { return fail("usage: export <vm> <folder>") }
            do {
                let url = try store.exportVM(config.id, to: URL(fileURLWithPath: (rest[1] as NSString).expandingTildeInPath))
                print(url.path)
            } catch { return fail(error.localizedDescription) }
            return 0

        case "import":
            guard let path = rest.first else { return fail("usage: import <path.openvm>") }
            do {
                let imported = try store.importVM(from: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
                if wantsJSON { json(details(imported, store: store)) } else { print("Imported “\(imported.name)” (\(imported.id.uuidString.prefix(8).lowercased())).") }
            } catch { return fail(error.localizedDescription) }
            return 0

        case "delete":
            guard let config = vm(rest.first) else { return fail("no such VM.") }
            if let owner = store.lockOwner(of: config.id) { return fail("\(config.name) is running (pid \(owner.pid)).") }
            store.delete(config.id)
            if let message = store.lastError { return fail(message) }
            print("Deleted “\(config.name)”.")
            return 0

        case "policy":
            let policy = Policy.current
            let data = (try? JSONEncoder().encode(policy)).flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? [:]
            if wantsJSON { json(["source": Policy.source ?? NSNull(), "restricted": policy.isRestricted, "policy": data]); return 0 }
            print("Policy source: \(Policy.source ?? "none (no restrictions)")")
            if let dictionary = data as? [String: Any] { for (k, v) in dictionary.sorted(by: { $0.key < $1.key }) { print("  \(k): \(v)") } }
            return 0

        default:
            print(usage)
            return 1
        }
    }

    @MainActor
    private static func create(_ args: [String], store: VMStore, wantsJSON: Bool) -> Int32 {
        guard let name = args.first, !name.hasPrefix("--") else { return fail("usage: create <name> [--cpus N] [--memory GB] [--disk GB] [--iso file] [--from <template>]") }
        var position = 1
        while position < args.count {
            guard ["--cpus", "--memory", "--disk", "--iso", "--from"].contains(args[position]), position + 1 < args.count else {
                return fail("unknown or incomplete option “\(args[position])”. Usage: create <name> [--cpus N] [--memory GB] [--disk GB] [--iso file] [--from <template>]")
            }
            position += 2
        }
        func option(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        do {
            let created: VMConfig
            if let source = option("--from") {
                guard let base = store.find(source) else { return fail("no such template or VM: \(source)") }
                created = try store.clone(base.id, name: name)
            } else {
                let iso = option("--iso").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).path }
                if let iso, !FileManager.default.fileExists(atPath: iso) { return fail("installer image not found: \(iso)") }
                func number(_ flag: String, _ fallback: Int) -> Int? {
                    guard let text = option(flag) else { return fallback }
                    return Int(text)
                }
                guard let cpus = number("--cpus", 2), let memory = number("--memory", 2), let disk = number("--disk", 32) else {
                    return fail("--cpus, --memory and --disk need whole numbers")
                }
                created = try store.create(name: name, cpuCount: cpus, memoryGB: memory, diskGB: disk,
                                           isoPath: iso, sharedFolderPath: nil)
            }
            if wantsJSON { json(details(created, store: store)) } else { print("Created “\(created.name)” (\(created.id.uuidString.prefix(8).lowercased())).") }
            return 0
        } catch {
            return fail(error.localizedDescription)
        }
    }

    @MainActor
    private static func set(_ config: VMConfig, assignments: [String], store: VMStore) -> Int32 {
        guard store.lockOwner(of: config.id) == nil else { return fail("\(config.name) is running; stop it before changing settings.") }
        var updated = config
        func flag(_ value: String) -> Bool? { ["on": true, "true": true, "1": true, "off": false, "false": false, "0": false][value] }
        for assignment in assignments {
            let pair = assignment.split(separator: "=", maxSplits: 1).map(String.init)
            guard let key = pair.first, !key.isEmpty else { return fail("empty setting; use key=value") }
            let value = pair.count > 1 ? pair[1] : ""
            switch key {
            case "cpus": guard let n = Int(value), Validation.cpus.contains(n) else { return fail("cpus must be 1...64") }; updated.cpuCount = n
            case "memory": guard let n = Int(value), Validation.memoryGB.contains(n) else { return fail("memory must be 1...512 (GB)") }; updated.memoryGB = n
            case "name":
                let clean = Validation.cleanName(value)
                guard !value.isEmpty else { return fail("name cannot be empty") }
                guard !store.vms.contains(where: { $0.id != config.id && $0.name.caseInsensitiveCompare(clean) == .orderedSame }) else {
                    return fail("a VM named “\(clean)” already exists")
                }
                updated.name = clean
            case "ssh-user":
                guard value.isEmpty || Validation.isValidSSHUser(value) else { return fail("ssh-user may only contain letters, digits, . _ -") }
                updated.sshUser = value.isEmpty ? nil : value
            case "fullscreen": guard let f = flag(value) else { return fail("fullscreen needs on|off") }; updated.startFullScreen = f ? true : nil
            case "clipboard": guard let f = flag(value) else { return fail("clipboard needs on|off") }; updated.shareClipboard = f
            case "microphone": guard let f = flag(value) else { return fail("microphone needs on|off") }; updated.microphone = f
            case "rosetta": guard let f = flag(value) else { return fail("rosetta needs on|off") }; updated.rosetta = f
            case "nested": guard let f = flag(value) else { return fail("nested needs on|off") }; updated.nestedVirtualization = f
            case "autostart":
                if value == "off" { updated.autoStartDelay = nil }
                else if let n = Int(value), Validation.autoStartSeconds.contains(n) { updated.autoStartDelay = n }
                else { return fail("autostart needs 0...3600 seconds, or off") }
            case "forward-add":
                let ports = value.split(separator: ":").compactMap { Int($0) }
                guard ports.count == 2, ports.allSatisfy({ Validation.ports.contains($0) }) else { return fail("forward-add needs HOST:GUEST ports (1...65535)") }
                if store.vms.contains(where: { $0.id != config.id && ($0.portForwards ?? []).contains { $0.hostPort == ports[0] } }) {
                    return fail("host port \(ports[0]) is already forwarded by another VM")
                }
                guard Policy.current.permits(Policy.current.allowPortForwarding) else { return fail("port forwarding is disabled by your administrator") }
                updated.portForwards = (updated.portForwards ?? []).filter { $0.hostPort != ports[0] } + [PortForward(hostPort: ports[0], guestPort: ports[1])]
            case "forward-clear": updated.portForwards = nil
            default: return fail("unknown setting “\(key)”")
            }
        }
        store.update(updated)
        print("Updated \(updated.name).")
        return 0
    }

    /// Runs the VM until the guest stops. SIGINT/SIGTERM request a graceful shutdown, then force it after 30 s.
    @MainActor
    private static func runHeadless(_ config: VMConfig, store: VMStore) async -> Int32 {
        let runner = store.runner(for: config.id)

        var sources: [DispatchSourceSignal] = []
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                Task { @MainActor in
                    // A signal during boot waits for the guest to come up; a paused guest must run to see the request.
                    for _ in 0..<120 where runner.state == .starting { try? await Task.sleep(nanoseconds: 500_000_000) }
                    if runner.state == .paused { await runner.resume() }
                    runner.requestStop()
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    if !runner.isIdle { await runner.forceStop() }
                }
            }
            source.resume()
            sources.append(source)
        }

        await runner.start()
        if case .failed(let message) = runner.state { sources.forEach { $0.cancel() }; return fail(message) }
        FileHandle.standardError.write(Data("openvmctl: \(config.name) is running. Ctrl-C to shut down.\n".utf8))

        Task { @MainActor in
            for _ in 0..<60 where !runner.isIdle {
                if let address = await GuestNetwork.ip(forMAC: config.macAddress) {
                    FileHandle.standardError.write(Data("openvmctl: address \(address)\n".utf8))
                    return
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }

        while !runner.isIdle { try? await Task.sleep(nanoseconds: 500_000_000) }
        sources.forEach { $0.cancel() }
        if case .failed(let message) = runner.state { return fail(message) }
        return 0
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }
}
