//
//  FileTreeGitStatus.swift
//  kero
//

import Foundation

/// Semantic source-control state used by the file tree. Raw values encode the
/// dominance order for directory aggregation.
nonisolated enum FileTreeGitStatus: Int, Equatable, Sendable {
    case ignored = 1
    case created = 2
    case modified = 3
    case deleted = 4
    case conflict = 5

    var accessibilityName: String {
        switch self {
        case .conflict: return String(localized: "Conflict")
        case .deleted: return String(localized: "Deleted")
        case .modified: return String(localized: "Modified")
        case .created: return String(localized: "Created")
        case .ignored: return String(localized: "Ignored")
        }
    }
}

/// Immutable result of one repository-status refresh. Paths are absolute and
/// standardized so visible tree rows can perform constant-time direct lookup.
nonisolated struct FileTreeGitSnapshot: Equatable, Sendable {
    static let empty = FileTreeGitSnapshot(
        statusesByPath: [:],
        repositoryRoots: [],
        ignoredDirectoryOwners: [:]
    )

    let statusesByPath: [String: FileTreeGitStatus]
    /// Deepest roots first, making nested repositories own their subtrees.
    let repositoryRoots: [String]
    /// Ignored directories inherit downwards, but never upwards or across a
    /// nested repository boundary.
    let ignoredDirectoryOwners: [String: String]

    func status(for path: String) -> FileTreeGitStatus? {
        let path = Self.standardize(path)
        if let direct = statusesByPath[path] {
            return direct
        }
        guard let owner = repositoryRoot(containing: path) else { return nil }

        var candidate = path
        while Self.contains(candidate, inside: owner) {
            if ignoredDirectoryOwners[candidate] == owner {
                return .ignored
            }
            if candidate == owner { break }
            let parent = (candidate as NSString).deletingLastPathComponent
            if parent == candidate { break }
            candidate = parent
        }
        return nil
    }

    func isGitManaged(_ path: String) -> Bool {
        repositoryRoot(containing: Self.standardize(path)) != nil
    }

    private func repositoryRoot(containing path: String) -> String? {
        repositoryRoots.first { Self.contains(path, inside: $0) }
    }

    static func standardize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    static func contains(_ path: String, inside root: String) -> Bool {
        path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }
}
