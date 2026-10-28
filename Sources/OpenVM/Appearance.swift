// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 OpenVM contributors
// This file is part of OpenVM, free software under the GNU General Public License v3.0 or later (see LICENSE).

import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// Per-VM icon and color choices.
enum Appearance {
    static let colors: [(name: String, hex: UInt32)] = [
        ("Blue", 0x3B82F6), ("Green", 0x22A559), ("Orange", 0xF97316), ("Red", 0xE5484D),
        ("Purple", 0x8B5CF6), ("Teal", 0x14B8A6), ("Pink", 0xEC4899), ("Gray", 0x8A8F98),
    ]
    static let symbols = [
        "desktopcomputer", "laptopcomputer", "server.rack", "terminal", "shield", "hammer",
        "cube", "gamecontroller", "externaldrive", "globe",
    ]
    static let defaultSymbol = "desktopcomputer"
    static let defaultColor: UInt32 = 0x8A8F98
}
