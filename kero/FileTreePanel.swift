//
//  FileTreePanel.swift
//  kero
//

import AppKit
import SwiftUI

struct FileTreePanel: View {
    @ObservedObject var model: FileTreeModel
    let session: TerminalSession?
    let currentFilePath: String?
    let openFile: (String) -> Void
    let openToSide: (String) -> Void
    let onRename: (_ oldPath: String, _ newPath: String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                FileTreeHeader(
                    title: model.rootName,
                    subtitle: model.rootPath,
                    titleColor: rootTitleColor,
                    accessibilityValue: rootAccessibilityValue
                )
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: model.rootPath)]
                    )
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .sidebarFont(size: 11)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Reveal in Finder")
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 8)

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(model.items) { item in
                        FileTreeRow(
                            model: model,
                            item: item,
                            session: session,
                            currentFilePath: currentFilePath,
                            openFile: openFile,
                            openToSide: openToSide,
                            onRename: onRename
                        )
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
        }
    }

    private var rootTitleColor: Color? {
        if let status = model.rootGitStatus {
            return Color(nsColor: Theme.fileTreeGitStatus(status))
        }
        return model.rootIsGitManaged ? .secondary : nil
    }

    private var rootAccessibilityValue: String? {
        if let status = model.rootGitStatus {
            return gitAccessibilityValue(status.accessibilityName)
        }
        return model.rootIsGitManaged
            ? gitAccessibilityValue(String(localized: "Clean"))
            : nil
    }

    private func gitAccessibilityValue(_ status: String) -> String {
        String(
            localized: "Git status: \(status)",
            comment: "Accessibility value for a file-tree item."
        )
    }
}

private struct FileTreeHeader: View {
    let title: String
    let subtitle: String
    let titleColor: Color?
    let accessibilityValue: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .sidebarFont(size: 12, weight: .semibold)
                .foregroundStyle(
                    titleColor.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary)
                )
                .lineLimit(1)
            Text(subtitle)
                .sidebarFont(size: 10)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityValue(accessibilityValue ?? "")
    }
}

private struct FileTreeRow: View {
    @ObservedObject var model: FileTreeModel
    @ObservedObject private var themeChanges = Theme.changes
    let item: FileTreeModel.Item
    let session: TerminalSession?
    let currentFilePath: String?
    let openFile: (String) -> Void
    let openToSide: (String) -> Void
    let onRename: (_ oldPath: String, _ newPath: String) -> Void

    @State private var isHovering = false
    @State private var editingName = ""
    @FocusState private var fieldFocused: Bool

    private var isRenaming: Bool { model.renamingPath == item.path }

    /// The file open in the active tab, so it reads as selected in the tree.
    private var isCurrent: Bool { !item.isDirectory && item.path == currentFilePath }

    var body: some View {
        if item.isDraft {
            // The transient new-file/folder input row: no hover/menu, no
            // backing file to act on.
            draftRow
                .background(
                    RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.05))
                )
        } else {
            content
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            isCurrent
                                ? Color.primary.opacity(0.09)
                                : (isHovering ? Color.primary.opacity(0.05) : .clear)
                        )
                )
                .onHover { isHovering = $0 }
                .contextMenu { rowMenu }
        }
    }

    @ViewBuilder
    private var rowMenu: some View {
        if !item.isDirectory {
            Button("Open") {
                openFile(item.path)
            }
            Button("Open to the Side") {
                openToSide(item.path)
            }
        }
        Button("Open in Default App") {
            NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
        }
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting(
                [URL(fileURLWithPath: item.path)]
            )
        }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.path, forType: .string)
        }
        if item.isDirectory {
            Button("cd Here") {
                session?.sendCommand("cd " + shellQuote(item.path) + "\n")
            }
            Divider()
            Button("New File…") {
                model.beginNewFile(in: item.path)
            }
            Button("New Folder…") {
                model.beginNewFolder(in: item.path)
            }
        }
        Divider()
        Button("Rename") {
            model.beginRename(item)
        }
        Button("Move to Trash", role: .destructive) {
            model.moveToTrash(item)
        }
    }

    /// Commits an inline rename and, when the file actually moved, tells the
    /// app to follow it in any open tabs. Guarded by `isRenaming` so the
    /// commit-on-blur that fires right after Enter/Escape is a no-op.
    private func commitRename() {
        guard isRenaming else { return }
        let oldPath = item.path
        if let newPath = model.rename(item, to: editingName) {
            onRename(oldPath, newPath)
        }
    }

    /// Commits the inline new-file/folder input, opening a newly created file.
    /// Guarded so the commit-on-blur after Enter/Escape is a no-op.
    private func commitDraft() {
        guard item.isDraft, model.draft != nil else { return }
        if let created = model.commitDraft(name: editingName) {
            openFile(created)
        }
    }

    @ViewBuilder
    private var content: some View {
        if isRenaming {
            renameRow
        } else {
            rowButton
        }
    }

    private var rowButton: some View {
        Button {
            if item.isDirectory {
                model.toggle(item)
            } else {
                openFile(item.path)
            }
        } label: {
            HStack(spacing: 5) {
                leadingGlyphs
                Text(item.name)
                    .sidebarFont(size: 11.5)
                    .foregroundStyle(nameStyle)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(item.depth) * 12 + 6)
            .padding(.trailing, 6)
            .padding(.vertical, 3)
            .contentShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.name)
        .accessibilityValue(gitAccessibilityValue)
        // Drag a row out as a file URL: onto the terminal (which inserts its
        // path) or into Finder and other apps. A click still opens/toggles;
        // the drag only begins once the pointer moves.
        .onDrag {
            NSItemProvider(object: URL(fileURLWithPath: item.path) as NSURL)
        }
    }

    private var renameRow: some View {
        HStack(spacing: 5) {
            leadingGlyphs
            nameField(String(localized: "Name"))
                .onSubmit { commitRename() }
                .onKeyPress(.escape) {
                    model.cancelRename()
                    return .handled
                }
                .onChange(of: fieldFocused) {
                    // Commit on blur (Finder-style); unchanged names no-op.
                    if !fieldFocused { commitRename() }
                }
        }
        .padding(.leading, CGFloat(item.depth) * 12 + 6)
        .padding(.trailing, 6)
        .padding(.vertical, 2)
        .onAppear {
            editingName = item.name
            focusField()
        }
    }

    private var draftRow: some View {
        HStack(spacing: 5) {
            leadingGlyphs
            nameField(item.isDirectory
                ? String(localized: "Folder name")
                : String(localized: "File name"))
                .onSubmit { commitDraft() }
                .onKeyPress(.escape) {
                    model.cancelDraft()
                    return .handled
                }
                .onChange(of: fieldFocused) {
                    // Blur commits a typed name, cancels an empty one (VS Code).
                    if !fieldFocused { commitDraft() }
                }
        }
        .padding(.leading, CGFloat(item.depth) * 12 + 6)
        .padding(.trailing, 6)
        .padding(.vertical, 2)
        .onAppear {
            editingName = ""
            focusField()
        }
    }

    private func nameField(_ placeholder: String) -> some View {
        TextField(placeholder, text: $editingName)
            .textFieldStyle(.plain)
            .sidebarFont(size: 11.5)
            .foregroundStyle(.primary)
            .focused($fieldFocused)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(nsColor: Theme.background))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(
                        Color(nsColor: Theme.accent).opacity(0.7),
                        lineWidth: 1
                    )
            )
    }

    /// Grab focus on the next runloop tick — a context menu is still
    /// dismissing when the input row appears, and a synchronous focus can be
    /// stolen back as it tears down.
    private func focusField() {
        DispatchQueue.main.async { fieldFocused = true }
    }

    private var leadingGlyphs: some View {
        Group {
            if item.isDirectory && !item.isDraft {
                Image(systemName: "chevron.right")
                    .sidebarFont(size: 8, weight: .semibold)
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(model.isExpanded(item) ? 90 : 0))
                    .frame(width: 10)
            } else {
                Spacer().frame(width: 10)
            }
            Image(systemName: item.isDirectory ? "folder.fill" : "doc.text")
                .sidebarFont(size: 10)
                .foregroundStyle(iconStyle)
                .frame(width: 14)
        }
    }

    private var statusColor: Color? {
        item.gitStatus.map { Color(nsColor: Theme.fileTreeGitStatus($0)) }
    }

    private var nameStyle: AnyShapeStyle {
        if let statusColor {
            return AnyShapeStyle(statusColor)
        }
        return item.name.hasPrefix(".")
            ? AnyShapeStyle(.tertiary)
            : AnyShapeStyle(.secondary)
    }

    private var iconStyle: AnyShapeStyle {
        if let statusColor {
            return AnyShapeStyle(statusColor)
        }
        return item.isDirectory
            ? AnyShapeStyle(Color(nsColor: Theme.accent).opacity(0.8))
            : AnyShapeStyle(.secondary)
    }

    private var gitAccessibilityValue: String {
        guard let status = item.gitStatus else { return "" }
        return String(
            localized: "Git status: \(status.accessibilityName)",
            comment: "Accessibility value for a file-tree item."
        )
    }

    private func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
