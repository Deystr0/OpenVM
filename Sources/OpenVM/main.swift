// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 OpenVM contributors
// This file is part of OpenVM, free software under the GNU General Public License v3.0 or later (see LICENSE).

import Foundation

// One binary, two front ends: `openvmctl <command>` runs the CLI, anything else opens the app.
// A client that disconnects mid-reply must not kill the process (and every VM in it).
signal(SIGPIPE, SIG_IGN)
let arguments = Array(CommandLine.arguments.dropFirst())
let invokedAsCLI = (CommandLine.arguments.first.map { ($0 as NSString).lastPathComponent } ?? "") == "openvmctl"
if invokedAsCLI || (arguments.first.map(CLI.commands.contains) ?? false) {
    // Run as `openvmctl`, an unknown command prints the usage and fails; it never opens the app.
    if let first = arguments.first, !CLI.commands.contains(first) {
        FileHandle.standardError.write(Data("openvmctl: unknown command “\(first)”. Try: openvmctl help\n".utf8))
        exit(2)
    }
    CLI.run(arguments)
}
OpenVMApp.main()
