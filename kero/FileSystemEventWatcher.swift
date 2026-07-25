//
//  FileSystemEventWatcher.swift
//  kero
//

import CoreServices
import Foundation

nonisolated struct FileSystemEvent: Sendable {
    let path: String
    let flags: FSEventStreamEventFlags

    var requiresFullRescan: Bool {
        let rescanFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagEventIdsWrapped
                | kFSEventStreamEventFlagRootChanged
        )
        return flags & rescanFlags != 0
    }
}

/// Recursive macOS filesystem watcher. FSEvents performs kernel-side
/// coalescing during the configured latency window and invokes `onEvents` on
/// a private serial queue.
nonisolated final class FileSystemEventWatcher: @unchecked Sendable {
    typealias Handler = @Sendable ([FileSystemEvent]) -> Void

    private let queue = DispatchQueue(
        label: "com.kero.file-tree.fsevents",
        qos: .utility
    )
    private let onEvents: Handler
    private var stream: FSEventStreamRef?

    init?(
        paths: [String],
        latency: TimeInterval = 0.1,
        onEvents: @escaping Handler
    ) {
        let watchedPaths = Array(Set(paths.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        })).sorted()
        guard !watchedPaths.isEmpty else { return nil }

        self.onEvents = onEvents
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            fileSystemEventCallback,
            &context,
            watchedPaths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            return nil
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            return nil
        }
    }

    deinit {
        stop()
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    fileprivate func receive(
        paths: UnsafePointer<UnsafePointer<CChar>>,
        flags: UnsafePointer<FSEventStreamEventFlags>,
        count: Int
    ) {
        guard count > 0 else { return }
        var events: [FileSystemEvent] = []
        events.reserveCapacity(count)
        for index in 0..<count {
            events.append(
                FileSystemEvent(
                    path: String(cString: paths[index]),
                    flags: flags[index]
                )
            )
        }
        onEvents(events)
    }
}

nonisolated(unsafe) private let fileSystemEventCallback: FSEventStreamCallback = {
    _, clientInfo, eventCount, eventPaths, eventFlags, _ in
    guard let clientInfo else { return }
    let watcher = Unmanaged<FileSystemEventWatcher>
        .fromOpaque(clientInfo)
        .takeUnretainedValue()
    let paths = eventPaths.assumingMemoryBound(
        to: UnsafePointer<CChar>.self
    )
    watcher.receive(paths: paths, flags: eventFlags, count: eventCount)
}
