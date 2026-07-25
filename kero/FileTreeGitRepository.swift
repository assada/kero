//
//  FileTreeGitRepository.swift
//  kero
//

import Foundation

nonisolated struct FileTreeGitRepositoryDescriptor: Equatable, Sendable {
    let root: String
    let gitDirectory: String
    let commonGitDirectory: String

    static func resolve(at directory: String) -> Self? {
        let topLevel = GitCommandRunner.run(
            ["rev-parse", "--show-toplevel"],
            in: directory
        )
        guard topLevel.status == 0,
              let root = outputPath(topLevel.stdoutString, relativeTo: directory)
        else { return nil }

        let gitDirectoryResult = GitCommandRunner.run(
            ["rev-parse", "--absolute-git-dir"],
            in: root
        )
        guard gitDirectoryResult.status == 0,
              let gitDirectory = outputPath(
                gitDirectoryResult.stdoutString,
                relativeTo: root
              )
        else { return nil }

        let commonDirectoryResult = GitCommandRunner.run(
            ["rev-parse", "--git-common-dir"],
            in: root
        )
        let commonGitDirectory =
            commonDirectoryResult.status == 0
            ? outputPath(commonDirectoryResult.stdoutString, relativeTo: root)
                ?? gitDirectory
            : gitDirectory

        return Self(
            root: root,
            gitDirectory: gitDirectory,
            commonGitDirectory: commonGitDirectory
        )
    }

    private static func outputPath(
        _ output: String,
        relativeTo directory: String
    ) -> String? {
        let raw = output.trimmingCharacters(in: .newlines)
        guard !raw.isEmpty else { return nil }
        let path = (raw as NSString).isAbsolutePath
            ? raw
            : (directory as NSString).appendingPathComponent(raw)
        return FileTreeGitSnapshot.standardize(path)
    }
}

nonisolated struct FileTreeGitRepositoryState: Equatable, Sendable {
    let descriptor: FileTreeGitRepositoryDescriptor
    var directStatuses: [String: FileTreeGitStatus] = [:]
    var ignoredPaths: Set<String> = []
}

/// Parser for the stable NUL-delimited porcelain-v1 format used by the
/// file-tree status worker.
nonisolated enum FileTreeGitPorcelainParser {
    static func parse(_ data: Data) -> [String: FileTreeGitStatus] {
        var statuses: [String: FileTreeGitStatus] = [:]
        for record in data.split(separator: 0, omittingEmptySubsequences: true) {
            guard record.count >= 4 else { continue }
            let bytes = Array(record.prefix(2))
            guard let status = semanticStatus(x: bytes[0], y: bytes[1]),
                  let path = String(
                    data: Data(record.dropFirst(3)),
                    encoding: .utf8
                  ),
                  !path.isEmpty
            else { continue }
            merge(status, at: normalizeRelativePath(path), into: &statuses)
        }
        return statuses
    }

    private static func semanticStatus(
        x: UInt8,
        y: UInt8
    ) -> FileTreeGitStatus? {
        let pair = [x, y]
        let conflicts: Set<[UInt8]> = [
            [ascii("D"), ascii("D")],
            [ascii("A"), ascii("U")],
            [ascii("U"), ascii("D")],
            [ascii("U"), ascii("A")],
            [ascii("D"), ascii("U")],
            [ascii("A"), ascii("A")],
            [ascii("U"), ascii("U")],
        ]
        if conflicts.contains(pair) || pair.contains(ascii("U")) {
            return .conflict
        }
        if pair.contains(ascii("D")) { return .deleted }
        if pair.contains(ascii("M")) || pair.contains(ascii("T")) {
            return .modified
        }
        if pair.contains(ascii("A")) || pair.contains(ascii("?")) {
            return .created
        }
        return nil
    }

    private static func ascii(_ character: Character) -> UInt8 {
        character.asciiValue!
    }

    private static func merge(
        _ status: FileTreeGitStatus,
        at path: String,
        into statuses: inout [String: FileTreeGitStatus]
    ) {
        guard statuses[path, default: .ignored].rawValue < status.rawValue
        else { return }
        statuses[path] = status
    }

    static func normalizeRelativePath(_ path: String) -> String {
        var path = path
        while path.hasPrefix("./") {
            path.removeFirst(2)
        }
        while path.hasSuffix("/") {
            path.removeLast()
        }
        return path.isEmpty ? "." : path
    }
}
