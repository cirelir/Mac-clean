import AppKit
import MacCleanUI
import Observation
import SwiftUI

/// Owns the menu bar status item.
///
/// - Left click: toggles the compact panel (NSPopover hosting MenuBarRootView).
/// - Right click (or control-click): pops up a small menu with "退出 Mac Clean".
///
/// The details window is also owned here (hosted outside the SwiftUI scene
/// hierarchy, where `openWindow` is not available) and is opened through the
/// injected `openDetailsWindow` environment action.
@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let model: AppModel?
    private let initializationFailure: String?
    private let appearanceStore = AppearanceStore()
    private var detailsWindow: NSWindow?

    init(model: AppModel?, initializationFailure: String?) {
        self.model = model
        self.initializationFailure = initializationFailure
        self.statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.squareLength
        )
        self.popover = NSPopover()
        super.init()
        configureStatusItem()
        configurePopover()
        observeActivationRequests()
    }

    /// When a second launch attempt is made, the losing process asks this
    /// (already running) instance to bring its panel to the front.
    private func observeActivationRequests() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleActivateNotification(_:)),
            name: SingleInstance.activateNotificationName,
            object: nil
        )
    }

    @objc
    private func handleActivateNotification(_ notification: Notification) {
        Task { @MainActor in
            self.showPanel()
        }
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(
            systemSymbolName: "externaldrive.badge.checkmark",
            accessibilityDescription: "Mac Clean"
        )
        button.image?.isTemplate = true
        button.target = self
        button.action = #selector(handleStatusItemClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
    }

    @objc
    private func handleStatusItemClick(_ sender: Any?) {
        guard let event = NSApp.currentEvent else { return }
        let isRightClick = event.type == .rightMouseUp
            || (event.type == .leftMouseUp && event.modifierFlags.contains(.control))
        if isRightClick {
            showQuitMenu()
        } else {
            togglePanel()
        }
    }

    private func showQuitMenu() {
        guard let button = statusItem.button else { return }
        let menu = NSMenu()
        let quitItem = NSMenuItem(
            title: "退出 Mac Clean",
            action: #selector(quit(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: button.bounds.height + 4),
            in: button
        )
    }

    private func togglePanel() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let button = statusItem.button else { return }
        if popover.contentViewController == nil {
            popover.contentViewController = makeContentViewController()
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
    }

    private func makeContentViewController() -> NSViewController {
        if let model {
            return NSHostingController(
                rootView: MenuBarRootView(model: model)
                    .environment(appearanceStore)
                    .environment(
                        \.openDetailsWindow,
                        { [weak self] in
                            guard let self else { return }
                            self.openDetails()
                        }
                    )
                    .task {
                        await model.performCatchUpScanIfDue()
                    }
            )
        }
        return NSHostingController(
            rootView: StartupFailureView(message: initializationFailure)
                .padding(16)
                .frame(width: 300)
        )
    }

    @objc
    private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    private func openDetails() {
        guard let model else { return }
        // The details window takes over focus; close the transient panel so
        // nothing competes with the window for the top z-order.
        popover.performClose(nil)

        let window: NSWindow
        if let existing = detailsWindow {
            window = existing
        } else {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Mac Clean 详情"
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 920, height: 640)
            window.setFrameAutosaveName("MacCleanDetailsWindow")
            window.contentViewController = NSHostingController(
                rootView: DetailView(model: model)
                    .environment(appearanceStore)
            )
            detailsWindow = window
            fitWindowToContent(window)
            window.center()
            observeDetailsContentForResizing()
        }

        // Re-fit every time the window is shown so its size follows the
        // current content (e.g. a candidate list grown by a recent scan).
        fitWindowToContent(window)

        NSRunningApplication.current.activate(options: [.activateAllWindows])
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
    }

    /// Sizes the window to the hosted content's fitting size, clamped to the
    /// window minimum and the visible screen frame. The title bar stays put
    /// while the window grows/shrinks downward.
    private func fitWindowToContent(_ window: NSWindow) {
        guard let contentView = window.contentViewController?.view else { return }
        contentView.layoutSubtreeIfNeeded()
        let visibleFrame = window.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let fitted = DetailsWindowSizing.fittedContentSize(
            fitting: contentView.fittingSize,
            minSize: window.minSize,
            visibleFrame: visibleFrame
        )

        let previousHeight = window.frame.height
        var frame = window.frame
        frame.size = fitted
        // Keep the top edge (title bar) stationary when the height changes.
        frame.origin.y += previousHeight - fitted.height
        frame.origin.x = min(
            max(frame.origin.x, visibleFrame.minX),
            visibleFrame.maxX - frame.width
        )
        frame.origin.y = min(
            max(frame.origin.y, visibleFrame.minY),
            visibleFrame.maxY - frame.height
        )
        window.setFrame(frame, display: true)
    }

    /// While the window is visible, only grow it — never shrink it below what
    /// the user has it at. Called when the observed model content changes.
    private func refitDetailsWindowIfVisible() {
        guard let window = detailsWindow, window.isVisible else { return }
        guard let contentView = window.contentViewController?.view else { return }
        contentView.layoutSubtreeIfNeeded()
        let visibleFrame = window.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let fitted = DetailsWindowSizing.fittedContentSize(
            fitting: contentView.fittingSize,
            minSize: window.minSize,
            visibleFrame: visibleFrame
        )
        guard fitted.height > window.frame.height else { return }

        var frame = window.frame
        frame.size.height = fitted.height
        frame.origin.y = min(
            max(frame.origin.y, visibleFrame.minY),
            visibleFrame.maxY - frame.height
        )
        window.setFrame(frame, display: true)
    }

    /// Keeps the details window in sync with content that changes while it is
    /// open (scans, cleanups, failures). Re-arms after every change so the
    /// observation chain stays alive.
    private func observeDetailsContentForResizing() {
        guard let model else { return }
        withObservationTracking {
            _ = model.state.phase
            _ = model.state.candidates.count
            _ = model.state.failures.count
            _ = model.state.lastCleanupOutcomes.count
            _ = model.state.errorMessage
        } onChange: {
            Task { @MainActor [weak self] in
                self?.refitDetailsWindowIfVisible()
                self?.observeDetailsContentForResizing()
            }
        }
    }
}
