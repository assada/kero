//
//  ShellCatalog.swift
//  kero
//

import Foundation

/// Finds shells worth offering in Settings.
///
/// `/etc/shells` is authoritative when populated. Common package-manager
/// locations fill the gap for shells installed but not registered there.
enum ShellCatalog {
    nonisolated static func installedPaths(
        excluding excludedPath: String = ShellConfiguration.defaultPath
    ) -> [String] {
        var candidates = registeredShells()
        let prefixes = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]
        let names = ["bash", "zsh", "fish", "nu", "elvish", "xonsh", "pwsh", "dash"]

        for prefix in prefixes {
            candidates.append(contentsOf: names.map { "\(prefix)/\($0)" })
        }

        var seen = Set<String>()
        return candidates.filter { path in
            path != excludedPath
                && seen.insert(path).inserted
                && ShellConfiguration.isExecutableFile(path)
        }
    }

    private nonisolated static func registeredShells() -> [String] {
        guard let text = try? String(
            contentsOfFile: "/etc/shells",
            encoding: .utf8
        ) else {
            return []
        }

        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let path = line.trimmingCharacters(in: .whitespaces)
            return path.isEmpty || path.hasPrefix("#") ? nil : path
        }
    }
}
