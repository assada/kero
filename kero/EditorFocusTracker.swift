//
//  EditorFocusTracker.swift
//  kero
//

import AppKit

/// Combines focus reports from every mounted view of one file into a single
/// editor focus state. A set of sources avoids a false loss while SwiftUI is
/// replacing one editor view with another.
struct EditorFocusState {
    struct Suspension {
        fileprivate let focusedSources: Set<UUID>
    }

    private var focusedSources: Set<UUID> = []

    /// Returns true only for the effective focused → unfocused transition.
    mutating func update(source: UUID, isFocused: Bool) -> Bool {
        let wasFocused = !focusedSources.isEmpty
        if isFocused {
            focusedSources.insert(source)
        } else {
            focusedSources.remove(source)
        }
        return wasFocused && focusedSources.isEmpty
    }

    /// Closing an editor ends its focus session before SwiftUI unmounts the
    /// view. The suspension can be restored if a close confirmation is
    /// cancelled.
    mutating func suspend() -> (Suspension, didLoseFocus: Bool) {
        let suspension = Suspension(focusedSources: focusedSources)
        let didLoseFocus = !focusedSources.isEmpty
        focusedSources.removeAll()
        return (suspension, didLoseFocus)
    }

    mutating func restore(_ suspension: Suspension) {
        focusedSources.formUnion(suspension.focusedSources)
    }
}

/// Tracks the editor's effective AppKit focus. First-responder status alone is
/// not enough: a text view can remain first responder while its window or the
/// whole application is inactive.
@MainActor
final class EditorFocusTracker {
    private weak var view: NSView?
    private weak var window: NSWindow?
    private let onFocusChanged: (Bool) -> Void

    private var applicationObservers: [any NSObjectProtocol] = []
    private var windowObservers: [any NSObjectProtocol] = []
    private var isFirstResponder = false
    private var isWindowKey = false
    private var isApplicationActive = false
    private var reportedFocus = false

    init(onFocusChanged: @escaping (Bool) -> Void) {
        self.onFocusChanged = onFocusChanged
    }

    func attach(to view: NSView) {
        self.view = view
        startObservingApplication()
        move(to: view.window)
    }

    func viewDidMoveToWindow() {
        move(to: view?.window)
    }

    func didBecomeFirstResponder() {
        isFirstResponder = true
        reportIfChanged()
    }

    func didResignFirstResponder() {
        isFirstResponder = false
        reportIfChanged()
    }

    func detach() {
        isFirstResponder = false
        move(to: nil)
        view = nil
        isApplicationActive = false
        reportIfChanged()
        stopObservingApplication()
    }

    private func startObservingApplication() {
        guard applicationObservers.isEmpty else { return }
        let center = NotificationCenter.default
        applicationObservers = [
            center.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: NSApp,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isApplicationActive = true
                    self?.reportIfChanged()
                }
            },
            center.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: NSApp,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isApplicationActive = false
                    self?.reportIfChanged()
                }
            },
        ]
        isApplicationActive = NSApp.isActive
    }

    private func stopObservingApplication() {
        let center = NotificationCenter.default
        applicationObservers.forEach(center.removeObserver)
        applicationObservers.removeAll()
    }

    private func move(to newWindow: NSWindow?) {
        if window !== newWindow {
            stopObservingWindow()
            window = newWindow
            startObservingWindow()
        }
        isWindowKey = newWindow?.isKeyWindow ?? false
        isFirstResponder = newWindow?.firstResponder === view
        reportIfChanged()
    }

    private func startObservingWindow() {
        guard let window else { return }
        let center = NotificationCenter.default
        windowObservers = [
            center.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isWindowKey = true
                    self?.reportIfChanged()
                }
            },
            center.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isWindowKey = false
                    self?.reportIfChanged()
                }
            },
        ]
    }

    private func stopObservingWindow() {
        let center = NotificationCenter.default
        windowObservers.forEach(center.removeObserver)
        windowObservers.removeAll()
    }

    private func reportIfChanged() {
        let hasFocus = view != nil
            && window != nil
            && isFirstResponder
            && isWindowKey
            && isApplicationActive
        guard hasFocus != reportedFocus else { return }
        reportedFocus = hasFocus
        onFocusChanged(hasFocus)
    }

    deinit {
        let center = NotificationCenter.default
        applicationObservers.forEach(center.removeObserver)
        windowObservers.forEach(center.removeObserver)
    }
}
