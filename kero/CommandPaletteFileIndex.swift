//
//  CommandPaletteFileIndex.swift
//  kero
//

import Foundation

struct CommandPaletteProjectFile: Sendable {
    let name: String
    let relativePath: String
    let absolutePath: String

    var parentPath: String? {
        let parent = (relativePath as NSString).deletingLastPathComponent
        return parent.isEmpty ? nil : parent
    }
}

struct CommandPaletteFileIndex: Sendable {
    let root: String
    let files: [CommandPaletteProjectFile]
    /// Directories with their own `.git`, used to preserve nested-repository
    /// boundaries before file rows become visible.
    let repositoryCandidates: [String]
}

/// Builds the ignore-aware file index off the main actor. Git-backed projects
/// use the repository index; ordinary folders use filesystem enumeration.
enum CommandPaletteFileIndexer {
    nonisolated static func load(in root: String) -> CommandPaletteFileIndex {
        let root = FileTreeGitSnapshot.standardize(root)
        let files: [CommandPaletteProjectFile]
        if let paths = gitProjectFilePaths(in: root) {
            files = projectFiles(for: paths, in: root)
        } else {
            files = enumeratedProjectFiles(in: root)
        }
        return CommandPaletteFileIndex(
            root: root,
            files: files,
            repositoryCandidates: repositoryCandidates(
                for: files,
                in: root
            )
        )
    }

    private nonisolated static func gitProjectFilePaths(
        in root: String
    ) -> Set<String>? {
        var tracked = GitStatusModel.runGit(
            ["ls-files", "--cached", "--recurse-submodules", "-z"],
            in: root
        )
        // A missing or broken submodule should not disable search for the rest
        // of the repository.
        if tracked.status != 0 {
            tracked = GitStatusModel.runGit(
                ["ls-files", "--cached", "-z"],
                in: root
            )
        }
        let untracked = GitStatusModel.runGit(
            ["ls-files", "--others", "--exclude-standard", "-z"],
            in: root
        )
        guard tracked.status == 0, untracked.status == 0 else { return nil }
        return Set(
            nulSeparatedPaths(tracked.stdout)
                + nulSeparatedPaths(untracked.stdout)
        )
    }

    private nonisolated static func nulSeparatedPaths(
        _ output: String
    ) -> [String] {
        output.split(separator: "\0").map(String.init)
    }

    private nonisolated static func projectFiles(
        for relativePaths: Set<String>,
        in root: String
    ) -> [CommandPaletteProjectFile] {
        let fileManager = FileManager.default
        return relativePaths.compactMap { relativePath in
            guard !Task.isCancelled else { return nil }
            let absolutePath = (root as NSString)
                .appendingPathComponent(relativePath)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(
                atPath: absolutePath,
                isDirectory: &isDirectory
            ),
            !isDirectory.boolValue
            else { return nil }
            return CommandPaletteProjectFile(
                name: (relativePath as NSString).lastPathComponent,
                relativePath: relativePath,
                absolutePath: absolutePath
            )
        }
        .sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath)
                == .orderedAscending
        }
    }

    private nonisolated static func enumeratedProjectFiles(
        in root: String
    ) -> [CommandPaletteProjectFile] {
        let rootURL = URL(
            fileURLWithPath: root,
            isDirectory: true
        ).standardizedFileURL
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
        let keySet = Set(keys)
        let rootPrefix = rootURL.path == "/" ? "/" : rootURL.path + "/"
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            errorHandler: { _, _ in true }
        ) else { return [] }

        var files: [CommandPaletteProjectFile] = []
        while let url = enumerator.nextObject() as? URL {
            if Task.isCancelled { break }
            if url.lastPathComponent == ".git" {
                enumerator.skipDescendants()
                continue
            }
            guard let values = try? url.resourceValues(forKeys: keySet),
                  values.isDirectory != true,
                  values.isRegularFile == true,
                  url.path.hasPrefix(rootPrefix)
            else { continue }
            let relativePath = String(url.path.dropFirst(rootPrefix.count))
            files.append(
                CommandPaletteProjectFile(
                    name: url.lastPathComponent,
                    relativePath: relativePath,
                    absolutePath: url.path
                )
            )
        }
        return files.sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath)
                == .orderedAscending
        }
    }

    private nonisolated static func repositoryCandidates(
        for files: [CommandPaletteProjectFile],
        in root: String
    ) -> [String] {
        var directories = Set([root])
        for file in files {
            var directory = (file.absolutePath as NSString)
                .deletingLastPathComponent
            while FileTreeGitSnapshot.contains(directory, inside: root) {
                directories.insert(directory)
                if directory == root { break }
                let parent = (directory as NSString).deletingLastPathComponent
                if parent == directory { break }
                directory = parent
            }
        }

        let fileManager = FileManager.default
        return directories
            .filter {
                fileManager.fileExists(
                    atPath: ($0 as NSString).appendingPathComponent(".git")
                )
            }
            .sorted()
    }
}
