//
//  ShellConfiguration.swift
//  kero
//

import Darwin
import Foundation

/// Resolves the shell used by new terminal sessions.
///
/// An empty custom path follows the user's macOS login shell. Invalid custom
/// paths also fall back to it, so a half-edited setting cannot create a broken
/// terminal.
enum ShellConfiguration {
    nonisolated static var defaultPath: String {
        let passwordDatabasePath: String? = if let entry = getpwuid(getuid()),
                                               let shell = entry.pointee.pw_shell {
            String(cString: shell)
        } else {
            nil
        }

        let candidates = [
            passwordDatabasePath,
            ProcessInfo.processInfo.environment["SHELL"],
            "/bin/zsh",
            "/bin/sh",
        ]
        return candidates.compactMap { $0 }.first(where: isExecutableFile) ?? "/bin/sh"
    }

    nonisolated static func resolvedPath(customPath: String) -> String {
        guard let path = expandedCustomPath(customPath),
              path.hasPrefix("/"),
              isExecutableFile(path)
        else {
            return defaultPath
        }
        return path
    }

    nonisolated static func validationMessage(for customPath: String) -> String? {
        guard let path = expandedCustomPath(customPath) else { return nil }
        guard path.hasPrefix("/") else {
            return String(
                localized: "Enter an absolute path to a shell.",
                comment: "Validation error for the custom shell setting."
            )
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return String(
                localized: "Shell not found. New terminals will use \(defaultPath).",
                comment: "Validation error for the custom shell setting."
            )
        }
        guard !isDirectory.boolValue else {
            return String(
                localized: "Choose an executable file, not a folder.",
                comment: "Validation error for the custom shell setting."
            )
        }
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return String(
                localized: "Shell is not executable. New terminals will use \(defaultPath).",
                comment: "Validation error for the custom shell setting."
            )
        }
        return nil
    }

    nonisolated static func hasCustomPath(_ value: String) -> Bool {
        expandedCustomPath(value) != nil
    }

    private nonisolated static func expandedCustomPath(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return (trimmed as NSString).expandingTildeInPath
    }

    private nonisolated static func isExecutableFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }
}
