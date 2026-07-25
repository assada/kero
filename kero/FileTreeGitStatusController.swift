//
//  FileTreeGitStatusController.swift
//  kero
//

import CoreServices
import Foundation

/// Coordinates repository discovery, filesystem events, per-repository
/// workers, and the immutable snapshot consumed by the file-tree UI.
@MainActor
final class FileTreeGitStatusController {
    typealias SnapshotHandler = (FileTreeGitSnapshot) -> Void
    typealias WorktreeHandler = () -> Void

    private let onSnapshot: SnapshotHandler
    private let onWorktreeChange: WorktreeHandler

    private var workspaceRoot = ""
    private var visiblePaths: [String] = []
    private var generation: UInt = 0
    private var workers: [String: FileTreeGitRepositoryWorker] = [:]
    private var states: [String: FileTreeGitRepositoryState] = [:]
    private var watcher: FileSystemEventWatcher?
    private var watchedPaths: Set<String> = []
    private var lastSnapshot = FileTreeGitSnapshot.empty

    private var isDiscovering = false
    private var pendingDiscoveryCandidates: Set<String> = []
    private var pendingDiscoveryPrune = false

    init(
        onSnapshot: @escaping SnapshotHandler,
        onWorktreeChange: @escaping WorktreeHandler
    ) {
        self.onSnapshot = onSnapshot
        self.onWorktreeChange = onWorktreeChange
    }

    deinit {
        watcher?.stop()
        workers.values.forEach { $0.stop() }
    }

    func configure(workspaceRoot: String, visiblePaths: [String]) {
        let root = FileTreeGitSnapshot.standardize(workspaceRoot)
        let paths = visiblePaths.map(FileTreeGitSnapshot.standardize)
        guard root != self.workspaceRoot else {
            updateVisiblePaths(paths)
            return
        }

        reset()
        generation &+= 1
        self.workspaceRoot = root
        self.visiblePaths = paths
        installWatcher()
        publishSnapshot()

        var candidates = Set([root])
        candidates.formUnion(paths.filter(Self.hasGitMetadata))
        requestDiscovery(candidates: candidates, pruneInvalid: false)
    }

    func updateVisiblePaths(_ paths: [String]) {
        let standardized = paths.map(FileTreeGitSnapshot.standardize)
        guard standardized != visiblePaths else { return }
        visiblePaths = standardized
        workers.values.forEach { $0.updateVisiblePaths(standardized) }
        requestDiscovery(
            candidates: Set(standardized.filter {
                states[$0] == nil && Self.hasGitMetadata($0)
            }),
            pruneInvalid: false
        )
    }

    private func reset() {
        watcher?.stop()
        watcher = nil
        watchedPaths.removeAll()
        workers.values.forEach { $0.stop() }
        workers.removeAll()
        states.removeAll()
        workspaceRoot = ""
        visiblePaths = []
        lastSnapshot = .empty
        isDiscovering = false
        pendingDiscoveryCandidates.removeAll()
        pendingDiscoveryPrune = false
    }

    // MARK: - Filesystem events

    private func installWatcher() {
        guard !workspaceRoot.isEmpty else { return }
        var paths = Set([workspaceRoot])
        for state in states.values {
            paths.insert(state.descriptor.gitDirectory)
            paths.insert(state.descriptor.commonGitDirectory)
        }
        guard paths != watchedPaths else { return }

        watcher?.stop()
        watchedPaths = paths
        watcher = FileSystemEventWatcher(paths: Array(paths)) {
            [weak self] events in
            Task { @MainActor [weak self] in
                self?.handle(events)
            }
        }
    }

    private func handle(_ events: [FileSystemEvent]) {
        guard !workspaceRoot.isEmpty, !events.isEmpty else { return }
        let events = coalesce(events)

        if events.contains(where: \.requiresFullRescan) {
            workers.values.forEach { $0.requestFullRefresh() }
            requestDiscovery(
                candidates: Set([workspaceRoot] + Array(states.keys)),
                pruneInvalid: true
            )
            onWorktreeChange()
            return
        }

        var fullRefreshRoots: Set<String> = []
        var targetedPaths: [String: [String]] = [:]
        var topologyCandidates: Set<String> = []
        var shouldPruneTopology = false
        var hasWorktreeChange = false

        for event in events {
            let path = FileTreeGitSnapshot.standardize(event.path)
            let metadataOwners = states.values.filter {
                Self.isInsideMetadata(path, descriptor: $0.descriptor)
            }
            if !metadataOwners.isEmpty {
                fullRefreshRoots.formUnion(
                    metadataOwners.map(\.descriptor.root)
                )
                if event.flags
                    & FSEventStreamEventFlags(
                        kFSEventStreamEventFlagItemRemoved
                    ) != 0,
                   metadataOwners.contains(where: {
                       path == $0.descriptor.gitDirectory
                           || path == $0.descriptor.commonGitDirectory
                   }) {
                    shouldPruneTopology = true
                }
                continue
            }

            guard FileTreeGitSnapshot.contains(path, inside: workspaceRoot)
            else { continue }
            hasWorktreeChange = true

            if let candidate = Self.repositoryCandidate(fromGitPath: path) {
                topologyCandidates.insert(candidate)
                if event.flags
                    & FSEventStreamEventFlags(
                        kFSEventStreamEventFlagItemRemoved
                    ) != 0 {
                    shouldPruneTopology = true
                }
            }

            guard let owner = deepestRepository(containing: path)
            else { continue }
            if Self.requiresFullStatusRefresh(path) {
                fullRefreshRoots.insert(owner)
            } else {
                targetedPaths[owner, default: []].append(path)
            }
        }

        for root in fullRefreshRoots {
            workers[root]?.requestFullRefresh()
            targetedPaths.removeValue(forKey: root)
        }
        for (root, paths) in targetedPaths {
            workers[root]?.requestRefresh(for: paths)
        }
        if !topologyCandidates.isEmpty || shouldPruneTopology {
            topologyCandidates.formUnion(states.keys)
            requestDiscovery(
                candidates: topologyCandidates,
                pruneInvalid: shouldPruneTopology
            )
        }
        if hasWorktreeChange {
            onWorktreeChange()
        }
    }

    private func coalesce(
        _ events: [FileSystemEvent]
    ) -> [FileSystemEvent] {
        var flagsByPath: [String: FSEventStreamEventFlags] = [:]
        for event in events {
            let path = FileTreeGitSnapshot.standardize(event.path)
            flagsByPath[path, default: 0] |= event.flags
        }
        return flagsByPath.map {
            FileSystemEvent(path: $0.key, flags: $0.value)
        }
    }

    private func deepestRepository(containing path: String) -> String? {
        states.keys
            .filter { FileTreeGitSnapshot.contains(path, inside: $0) }
            .max { $0.count < $1.count }
    }

    // MARK: - Repository discovery

    private func requestDiscovery(
        candidates: Set<String>,
        pruneInvalid: Bool
    ) {
        pendingDiscoveryCandidates.formUnion(candidates)
        pendingDiscoveryPrune = pendingDiscoveryPrune || pruneInvalid
        startDiscoveryIfNeeded()
    }

    private func startDiscoveryIfNeeded() {
        guard !isDiscovering, !pendingDiscoveryCandidates.isEmpty else {
            return
        }
        isDiscovering = true
        let candidates = pendingDiscoveryCandidates
        let pruneInvalid = pendingDiscoveryPrune
        pendingDiscoveryCandidates.removeAll()
        pendingDiscoveryPrune = false
        let operationGeneration = generation

        Task { [weak self] in
            let descriptors = await Task.detached(priority: .utility) {
                candidates.compactMap {
                    FileTreeGitRepositoryDescriptor.resolve(at: $0)
                }
            }.value
            guard let self,
                  self.generation == operationGeneration
            else { return }
            self.finishDiscovery(
                descriptors: descriptors,
                checkedCandidates: candidates,
                pruneInvalid: pruneInvalid
            )
        }
    }

    private func finishDiscovery(
        descriptors: [FileTreeGitRepositoryDescriptor],
        checkedCandidates: Set<String>,
        pruneInvalid: Bool
    ) {
        let resolvedByRoot = Dictionary(
            descriptors.map { ($0.root, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        if pruneInvalid {
            let checkedRoots = Set(checkedCandidates).intersection(states.keys)
            let validRoots = Set(resolvedByRoot.keys)
            for root in checkedRoots.subtracting(validRoots) {
                workers.removeValue(forKey: root)?.stop()
                states.removeValue(forKey: root)
            }
        }

        for descriptor in resolvedByRoot.values {
            guard repositoriesIntersectWorkspace(descriptor.root) else {
                continue
            }
            if states[descriptor.root]?.descriptor == descriptor {
                workers[descriptor.root]?.updateVisiblePaths(visiblePaths)
                continue
            }

            workers.removeValue(forKey: descriptor.root)?.stop()
            let initialState = FileTreeGitRepositoryState(
                descriptor: descriptor
            )
            states[descriptor.root] = initialState
            let worker = FileTreeGitRepositoryWorker(
                descriptor: descriptor,
                visiblePaths: visiblePaths
            ) { [weak self] state in
                Task { @MainActor [weak self] in
                    self?.apply(state)
                }
            }
            workers[descriptor.root] = worker
        }

        isDiscovering = false
        installWatcher()
        publishSnapshot()
        startDiscoveryIfNeeded()
    }

    private func apply(_ state: FileTreeGitRepositoryState) {
        let root = state.descriptor.root
        guard workers[root] != nil,
              states[root]?.descriptor == state.descriptor
        else { return }
        states[root] = state
        publishSnapshot()

        let nestedCandidates = state.directStatuses.keys.compactMap {
            relativePath -> String? in
            let path = FileTreeGitSnapshot.standardize(
                (root as NSString).appendingPathComponent(relativePath)
            )
            return states[path] == nil && Self.hasGitMetadata(path)
                ? path
                : nil
        }
        if !nestedCandidates.isEmpty {
            requestDiscovery(
                candidates: Set(nestedCandidates),
                pruneInvalid: false
            )
        }
    }

    private func publishSnapshot() {
        let snapshot = FileTreeGitSnapshotBuilder.build(
            states: Array(states.values),
            workspaceRoot: workspaceRoot
        )
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        onSnapshot(snapshot)
    }

    private func repositoriesIntersectWorkspace(_ repositoryRoot: String) -> Bool {
        FileTreeGitSnapshot.contains(repositoryRoot, inside: workspaceRoot)
            || FileTreeGitSnapshot.contains(workspaceRoot, inside: repositoryRoot)
    }

    // MARK: - Path classification

    private static func hasGitMetadata(_ path: String) -> Bool {
        FileManager.default.fileExists(
            atPath: (path as NSString).appendingPathComponent(".git")
        )
    }

    private static func isInsideMetadata(
        _ path: String,
        descriptor: FileTreeGitRepositoryDescriptor
    ) -> Bool {
        FileTreeGitSnapshot.contains(path, inside: descriptor.gitDirectory)
            || FileTreeGitSnapshot.contains(
                path,
                inside: descriptor.commonGitDirectory
            )
    }

    private static func requiresFullStatusRefresh(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return name == ".gitignore" || name == ".gitmodules"
    }

    private static func repositoryCandidate(fromGitPath path: String) -> String? {
        let components = URL(fileURLWithPath: path).pathComponents
        guard let index = components.lastIndex(of: ".git"), index > 0 else {
            return nil
        }
        return NSString.path(withComponents: Array(components[..<index]))
    }
}
