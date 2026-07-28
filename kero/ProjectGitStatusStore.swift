//
//  ProjectGitStatusStore.swift
//  kero
//

import Combine
import Foundation

/// One event-driven Git snapshot shared by project-facing UI in a window.
///
/// The file tree and command palette contribute independent path sets. Keeping
/// their union here prevents one consumer from evicting ignored-path state or
/// starting a duplicate repository worker.
@MainActor
final class ProjectGitStatusStore: ObservableObject {
    @Published private(set) var snapshot = FileTreeGitSnapshot.empty
    @Published private(set) var isReady = false
    @Published private(set) var worktreeRevision: UInt = 0

    private(set) var workspaceRoot = ""

    private var fileTreePaths: Set<String> = []
    private var searchRepositoryCandidates: Set<String> = []

    private lazy var controller = FileTreeGitStatusController(
        onSnapshot: { [weak self] snapshot in
            self?.snapshot = snapshot
        },
        onWorktreeChange: { [weak self] in
            self?.worktreeRevision &+= 1
        },
        onReadinessChange: { [weak self] isReady in
            self?.isReady = isReady
        }
    )

    func configure(workspaceRoot: String) {
        let root = FileTreeGitSnapshot.standardize(workspaceRoot)
        if root != self.workspaceRoot {
            self.workspaceRoot = root
            snapshot = .empty
            isReady = false
            fileTreePaths = [root]
            searchRepositoryCandidates = []
        }
        controller.configure(
            workspaceRoot: root,
            visiblePaths: observationPaths
        )
    }

    func updateFileTreePaths(_ paths: [String]) {
        fileTreePaths = Set(paths.map(FileTreeGitSnapshot.standardize))
        updateVisiblePaths()
    }

    func updateSearchRepositoryCandidates(_ paths: [String]) {
        searchRepositoryCandidates = Set(
            paths.map(FileTreeGitSnapshot.standardize)
        )
        updateVisiblePaths()
    }

    func status(for path: String) -> FileTreeGitStatus? {
        snapshot.status(for: path)
    }

    private var observationPaths: [String] {
        Array(fileTreePaths.union(searchRepositoryCandidates)).sorted()
    }

    private func updateVisiblePaths() {
        guard !workspaceRoot.isEmpty else { return }
        controller.updateVisiblePaths(observationPaths)
    }
}
