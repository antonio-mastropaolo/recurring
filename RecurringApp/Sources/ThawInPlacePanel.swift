//
//  ThawInPlacePanel.swift
//
//  Reference copy: thaw-topbar docs/topbar/in-place/ThawInPlacePanel.swift.
//  Apps embed it unchanged; Thaw's InPlacePanelProtocolTests pin the format.
//
//  Copyright (Topbar) © 2026 Antonio Mastropaolo

import AppKit

/// Lets Thaw open this app's menu bar popover where its item was clicked in
/// the Thaw Bar (or under a Thaw smart built-in), instead of first moving the
/// app's real item into the menu bar.
///
/// Opt in with the Info.plist key `ThawInPlacePanel` set to YES, then create
/// one of these with the popover and call `start()`. Thaw posts the
/// distributed notification `com.stonerl.Thaw.openPanelInPlace` whose object
/// is `"<bundle id>|x|y|width|height"` (screen points, bottom-left origin).
/// This shows the popover below that rectangle and answers with
/// `com.stonerl.Thaw.openPanelInPlace.ack`, object the bundle identifier.
/// Any local process can post the request; all it can do is open the popover,
/// and only at a menu-bar-sized rectangle that lies on a screen.
@MainActor
final class ThawInPlacePanel {
    static let requestName = Notification.Name("com.stonerl.Thaw.openPanelInPlace")
    static let ackName = Notification.Name("com.stonerl.Thaw.openPanelInPlace.ack")
    nonisolated static let maxAnchorSize = CGSize(width: 400, height: 200)

    private let popover: NSPopover
    private let willShow: () -> Void
    private let didShow: () -> Void
    private var anchorWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []

    /// willShow runs before the popover opens (refresh data there); didShow
    /// after (focus tweaks), exactly as the app's own toggle does.
    init(popover: NSPopover, willShow: @escaping () -> Void = {}, didShow: @escaping () -> Void = {}) {
        self.popover = popover
        self.willShow = willShow
        self.didShow = didShow
    }

    func start() {
        guard observers.isEmpty else { return }
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Self.requestName, object: nil, queue: .main
        ) { [weak self] note in
            let object = note.object as? String
            MainActor.assumeIsolated { self?.handle(object) }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSPopover.didCloseNotification, object: popover, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.anchorWindow?.orderOut(nil) }
        })
    }

    /// The anchor a request carries for `bundleID`, or nil when it is for
    /// another app or malformed. Same code as Thaw's
    /// InPlacePanelProtocol.anchor(fromRequestObject:bundleID:).
    nonisolated static func anchor(fromRequestObject object: String?, bundleID: String) -> CGRect? {
        guard let parts = object?.split(separator: "|", omittingEmptySubsequences: false),
              parts.count == 5, parts[0] == bundleID
        else {
            return nil
        }
        let numbers = parts.dropFirst().compactMap { Double($0) }
        guard
            numbers.count == 4, numbers.allSatisfy(\.isFinite),
            numbers[2] > 0, numbers[3] > 0,
            numbers[2] <= maxAnchorSize.width, numbers[3] <= maxAnchorSize.height
        else {
            return nil
        }
        return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }

    private func handle(_ object: String?) {
        guard
            let bundleID = Bundle.main.bundleIdentifier,
            let rect = Self.anchor(fromRequestObject: object, bundleID: bundleID),
            NSScreen.screens.contains(where: { $0.frame.intersects(rect) })
        else {
            return
        }
        let window = anchorWindow ?? makeAnchorWindow()
        anchorWindow = window
        window.setFrame(rect, display: false)
        window.orderFrontRegardless()
        if popover.isShown {
            popover.close()
        }
        willShow()
        NSApp.activate(ignoringOtherApps: true)
        if let view = window.contentView {
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        }
        didShow()
        DistributedNotificationCenter.default().postNotificationName(
            Self.ackName, object: bundleID, userInfo: nil, deliverImmediately: true
        )
    }

    /// An invisible, click-through window the popover hangs from.
    private func makeAnchorWindow() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.contentView = NSView()
        return window
    }
}
