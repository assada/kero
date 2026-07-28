//
//  FileTreeGitRepositoryWorker.swift
//  kero
//

import Foundation

/// Owns the status queue and cache for one repository. Requests are coalesced
/// on `stateQueue`; the Git process itself runs on a separate serial queue so
/// new filesystem events can continue accumulating while it is active.
nonisolated final class FileTreeGitRepositoryWorker: @unchecked Sendable {
    typealias UpdateHandler =
        @Sendable (FileTreeGitRepositoryState) -> Void

    let descriptor: FileTreeGitRepositoryDescriptor

    private let stateQueue: DispatchQueue
    private let operationQueue: DispatchQueue
    private let onUpdate: UpdateHandler

    // Accessed only from stateQueue.
    private var state: FileTreeGitRepositoryState
    private var visiblePaths: Set<String>
    private var pendingPaths: Set<String> = []
    private var pendingIgnoredPaths: Set<String> = []
    private var pendingFullRefresh = true
    private var pendingFullIgnoredRefresh = true
    private var isRunning = false
    private var revision: UInt = 1
    private var isStopped = false
    private var hasPublishedInitialStatus = false

    init(
        descriptor: FileTreeGitRepositoryDescriptor,
        visiblePaths: [String],
        onUpdate: @escaping UpdateHandler
    ) {
        self.descriptor = descriptor
        self.state = FileTreeGitRepositoryState(descriptor: descriptor)
        self.visiblePaths = Set(
            visiblePaths.compactMap {
                Self.relativePath($0, repositoryRoot: descriptor.root)
            }
        )
        self.onUpdate = onUpdate

        let suffix = String(descriptor.root.hashValue, radix: 16)
        stateQueue = DispatchQueue(
            label: "com.kero.file-tree.git-state.\(suffix)",
            qos: .utility
        )
        operationQueue = DispatchQueue(
            label: "com.kero.file-tree.git-worker.\(suffix)",
            qos: .utility
        )
        stateQueue.async { [weak self] in
            self?.startNextOperation()
        }
    }

    func stop() {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.isStopped = true
            self.revision &+= 1
            self.pendingPaths.removeAll()
            self.pendingIgnoredPaths.removeAll()
        }
    }

    func requestFullRefresh() {
        stateQueue.async { [weak self] in
            guard let self, !self.isStopped else { return }
            self.revision &+= 1
            self.pendingFullRefresh = true
            self.pendingFullIgnoredRefresh = true
            self.pendingPaths.removeAll()
            self.pendingIgnoredPaths.removeAll()
            self.startNextOperation()
        }
    }

    func requestRefresh(for absolutePaths: [String]) {
        let paths = absolutePaths.compactMap {
            Self.relativePath($0, repositoryRoot: descriptor.root)
        }
        guard !paths.isEmpty else { return }

        stateQueue.async { [weak self] in
            guard let self, !self.isStopped else { return }
            if paths.contains(".") {
                self.revision &+= 1
                self.pendingFullRefresh = true
                self.pendingFullIgnoredRefresh = true
                self.pendingPaths.removeAll()
                self.pendingIgnoredPaths.removeAll()
            } else if !self.pendingFullRefresh {
                self.revision &+= 1
                for path in paths {
                    Self.insertCoalescing(path, into: &self.pendingPaths)
                }
            }
            self.startNextOperation()
        }
    }

    func updateVisiblePaths(_ absolutePaths: [String]) {
        let updated = Set(absolutePaths.compactMap {
            Self.relativePath($0, repositoryRoot: descriptor.root)
        })
        stateQueue.async { [weak self] in
            guard let self, !self.isStopped, updated != self.visiblePaths
            else { return }

            let added = updated.subtracting(self.visiblePaths)
            let removed = self.visiblePaths.subtracting(updated)
            self.visiblePaths = updated
            self.state.ignoredPaths.subtract(removed)

            if !added.isEmpty {
                self.revision &+= 1
                for path in added {
                    Self.insertCoalescing(
                        path,
                        into: &self.pendingIgnoredPaths
                    )
                }
                self.startNextOperation()
            }
        }
    }

    private func startNextOperation() {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        guard !isStopped, !isRunning else { return }

        let fullRefresh = pendingFullRefresh
        let statusPaths = fullRefresh ? ["."] : pendingPaths.sorted()
        let fullIgnoredRefresh = pendingFullIgnoredRefresh
        let ignoredPaths = fullIgnoredRefresh
            ? visiblePaths.sorted()
            : pendingIgnoredPaths.sorted()
        guard !statusPaths.isEmpty || !ignoredPaths.isEmpty else { return }

        pendingFullRefresh = false
        pendingPaths.removeAll()
        pendingFullIgnoredRefresh = false
        pendingIgnoredPaths.removeAll()
        isRunning = true
        let operationRevision = revision
        let root = descriptor.root

        operationQueue.async { [weak self] in
            guard let self else { return }
            let statusResult = statusPaths.isEmpty
                ? nil
                : Self.loadStatus(paths: statusPaths, in: root)
            let ignoredResult = ignoredPaths.isEmpty
                ? nil
                : Self.loadIgnored(paths: ignoredPaths, in: root)

            self.stateQueue.async { [weak self] in
                self?.finishOperation(
                    revision: operationRevision,
                    fullRefresh: fullRefresh,
                    statusPaths: statusPaths,
                    statusResult: statusResult,
                    fullIgnoredRefresh: fullIgnoredRefresh,
                    ignoredPaths: ignoredPaths,
                    ignoredResult: ignoredResult
                )
            }
        }
    }

    private func finishOperation(
        revision operationRevision: UInt,
        fullRefresh: Bool,
        statusPaths: [String],
        statusResult: [String: FileTreeGitStatus]?,
        fullIgnoredRefresh: Bool,
        ignoredPaths: [String],
        ignoredResult: Set<String>?
    ) {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        guard !isStopped else { return }

        if let statusResult {
            if fullRefresh {
                state.directStatuses = statusResult
            } else {
                state.directStatuses = state.directStatuses.filter {
                    !Self.isCovered($0.key, byAny: statusPaths)
                }
                for (path, status) in statusResult {
                    state.directStatuses[path] = status
                }
            }
        }

        if let ignoredResult {
            if fullIgnoredRefresh {
                state.ignoredPaths = ignoredResult
            } else {
                state.ignoredPaths = state.ignoredPaths.filter {
                    !Self.isCovered($0, byAny: ignoredPaths)
                }
                state.ignoredPaths.formUnion(ignoredResult)
            }
        }

        isRunning = false
        let hasNewerWork =
            revision != operationRevision
            || pendingFullRefresh
            || !pendingPaths.isEmpty
            || pendingFullIgnoredRefresh
            || !pendingIgnoredPaths.isEmpty
        // Do not make first-paint readiness depend on the worktree becoming
        // completely quiet. A build can continuously enqueue newer paths; the
        // first completed full snapshot is coherent and later operations will
        // reactively bring it forward.
        let publishesInitialStatus =
            fullRefresh && !hasPublishedInitialStatus
        if publishesInitialStatus {
            hasPublishedInitialStatus = true
        }
        if publishesInitialStatus || !hasNewerWork {
            onUpdate(state)
        }
        startNextOperation()
    }

    private static func loadStatus(
        paths: [String],
        in repositoryRoot: String
    ) -> [String: FileTreeGitStatus]? {
        let result = GitCommandRunner.run(
            [
                "-c", "core.fsmonitor=false",
                "status",
                "--porcelain=v1",
                "--untracked-files=all",
                "--no-renames",
                "-z",
                "--",
            ] + paths,
            in: repositoryRoot,
            environmentOverrides: ["GIT_LITERAL_PATHSPECS": "1"]
        )
        guard result.status == 0 else { return nil }
        return FileTreeGitPorcelainParser.parse(result.stdout)
    }

    /// Git status intentionally remains the exact non-ignored status command.
    /// Ignored state for visible rows comes from Git's purpose-built matcher,
    /// equivalent to the worktree scanner's ignore cache in Zed.
    private static func loadIgnored(
        paths: [String],
        in repositoryRoot: String
    ) -> Set<String>? {
        guard !paths.isEmpty else { return [] }
        var input = Data()
        for path in paths {
            input.append(contentsOf: path.utf8)
            input.append(0)
        }
        let result = GitCommandRunner.run(
            ["check-ignore", "-z", "--stdin"],
            in: repositoryRoot,
            standardInput: input
        )
        guard result.status == 0 || result.status == 1 else { return nil }
        return Set(
            result.stdout
                .split(separator: 0, omittingEmptySubsequences: true)
                .compactMap {
                    String(data: Data($0), encoding: .utf8)
                }
                .map(FileTreeGitPorcelainParser.normalizeRelativePath)
        )
    }

    private static func relativePath(
        _ absolutePath: String,
        repositoryRoot: String
    ) -> String? {
        let path = FileTreeGitSnapshot.standardize(absolutePath)
        guard FileTreeGitSnapshot.contains(path, inside: repositoryRoot)
        else { return nil }
        if path == repositoryRoot { return "." }
        return String(path.dropFirst(repositoryRoot.count + 1))
    }

    private static func insertCoalescing(
        _ path: String,
        into paths: inout Set<String>
    ) {
        if paths.contains(where: { isCovered(path, by: $0) }) {
            return
        }
        paths = paths.filter { !isCovered($0, by: path) }
        paths.insert(path)
    }

    private static func isCovered(
        _ path: String,
        byAny parents: [String]
    ) -> Bool {
        parents.contains { isCovered(path, by: $0) }
    }

    private static func isCovered(_ path: String, by parent: String) -> Bool {
        parent == "." || path == parent || path.hasPrefix(parent + "/")
    }
}
