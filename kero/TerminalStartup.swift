//
//  TerminalStartup.swift
//  kero
//

import Foundation

/// What a newly created terminal starts.
///
/// A selected shell is launched as a login shell. A custom command is stored
/// as an argv so arguments never need to be reparsed by a shell.
enum TerminalStartup: Equatable, Sendable {
    case loginShell
    case shell(path: String)
    case customCommand(program: String, arguments: [String])

    var isDefault: Bool {
        self == .loginShell
    }
}
