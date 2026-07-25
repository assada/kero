//
//  FileTreeGitSnapshotBuilder.swift
//  kero
//

import Foundation

nonisolated enum FileTreeGitSnapshotBuilder {
    static func build(
        states: [FileTreeGitRepositoryState],
        workspaceRoot: String
    ) -> FileTreeGitSnapshot {
        let workspaceRoot = FileTreeGitSnapshot.standardize(workspaceRoot)
        let repositoryRoots = Set(states.map(\.descriptor.root))
        var statuses: [String: FileTreeGitStatus] = [:]
        var ignoredDirectoryOwners: [String: String] = [:]
        let fileManager = FileManager.default

        for state in states {
            let root = state.descriptor.root
            let nestedRoots = repositoryRoots.filter {
                $0 != root && FileTreeGitSnapshot.contains($0, inside: root)
            }

            for (relativePath, status) in state.directStatuses {
                let path = absolute(relativePath, in: root)
                guard FileTreeGitSnapshot.contains(path, inside: workspaceRoot),
                      !isInside(path, repositoryRoots: nestedRoots)
                else { continue }

                merge(status, at: path, into: &statuses)
                propagate(
                    status,
                    from: path,
                    repositoryRoot: root,
                    workspaceRoot: workspaceRoot,
                    into: &statuses
                )
            }

            for relativePath in state.ignoredPaths {
                let path = absolute(relativePath, in: root)
                guard FileTreeGitSnapshot.contains(path, inside: workspaceRoot),
                      !isInside(path, repositoryRoots: nestedRoots)
                else { continue }

                merge(.ignored, at: path, into: &statuses)
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
                   isDirectory.boolValue {
                    ignoredDirectoryOwners[path] = root
                }
            }
        }

        return FileTreeGitSnapshot(
            statusesByPath: statuses,
            repositoryRoots: repositoryRoots.sorted {
                $0.count == $1.count ? $0 < $1 : $0.count > $1.count
            },
            ignoredDirectoryOwners: ignoredDirectoryOwners
        )
    }

    private static func propagate(
        _ status: FileTreeGitStatus,
        from path: String,
        repositoryRoot: String,
        workspaceRoot: String,
        into statuses: inout [String: FileTreeGitStatus]
    ) {
        var directory = (path as NSString).deletingLastPathComponent
        while FileTreeGitSnapshot.contains(directory, inside: repositoryRoot) {
            if FileTreeGitSnapshot.contains(directory, inside: workspaceRoot) {
                merge(status, at: directory, into: &statuses)
            }
            if directory == repositoryRoot { break }
            let parent = (directory as NSString).deletingLastPathComponent
            if parent == directory { break }
            directory = parent
        }
    }

    private static func merge(
        _ status: FileTreeGitStatus,
        at path: String,
        into statuses: inout [String: FileTreeGitStatus]
    ) {
        if let current = statuses[path], current.rawValue >= status.rawValue {
            return
        }
        statuses[path] = status
    }

    private static func isInside(
        _ path: String,
        repositoryRoots: Set<String>
    ) -> Bool {
        repositoryRoots.contains {
            FileTreeGitSnapshot.contains(path, inside: $0)
        }
    }

    private static func absolute(_ relativePath: String, in root: String) -> String {
        FileTreeGitSnapshot.standardize(
            (root as NSString).appendingPathComponent(relativePath)
        )
    }
}
