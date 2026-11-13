import AppKit
import Combine
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@main
struct RecurringApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var store: Store!
    private let reminders = Reminders()
    private var cancellables = Set<AnyCancellable>()
    private var reminderTimer: Timer?
    private var dashboardWindow: NSWindow?
    private var lastIconSignature: IconSignature?

    private struct IconSignature: Equatable {
        let label: String
        let dueSoon: Bool
        let missing: Bool
        let leaks: Int
        let tooltip: String
    }

    private static let nsAmber = NSColor(calibratedRed: 1.0, green: 0.69, blue: 0.125, alpha: 1)    // #FFB020
    private static let nsMint  = NSColor(calibratedRed: 0.239, green: 0.831, blue: 0.655, alpha: 1) // #3DD4A7
    private static let nsCoral = NSColor(calibratedRed: 1.0, green: 0.361, blue: 0.424, alpha: 1)   // #FF5C6C
    private static let nsPaper = NSColor(calibratedRed: 0.957, green: 0.965, blue: 0.973, alpha: 1) // #F4F6F8
    private static let nsCanvas = NSColor(calibratedRed: 10.0 / 255.0, green: 11.0 / 255.0, blue: 13.0 / 255.0, alpha: 1) // #0A0B0D

    private static let iconLabelFont: NSFont = {
        NSFont(name: "JetBrainsMono-SemiBold", size: 12.5)
            ?? NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold)
    }()

    private static let iconGlyphFont = NSFont.systemFont(ofSize: 11, weight: .black)

    func applicationDidFinishLaunching(_ notification: Notification) {
        DS.registerFontsOnce()

        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            writeSnapshot(to: URL(fileURLWithPath: args[i + 1]))
            exit(0)
        }

        store = Store()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.target = self
            btn.action = #selector(togglePopover(_:))
            btn.imagePosition = .imageOnly
        }

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.contentSize = NSSize(width: 420, height: 640)
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView(onOpenDashboard: { [weak self] tab in self?.openDashboard(tab: tab) })
                .environmentObject(store)
                .environmentObject(reminders)
                .frame(width: 420, height: 640)
        )

        store.$derived
            .combineLatest(store.$vault)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.refreshIcon() }
            .store(in: &cancellables)

        reminders.start { [weak self] in
            guard let self else { return }
            self.reminders.check(self.store)
        }
        reminderTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.reminders.check(self.store)
            }
        }
        reminderTimer?.tolerance = 60
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let btn = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            store.reload(force: false)
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: btn.bounds, of: btn, preferredEdge: .minY)
        }
    }

    func openDashboard(tab: DashboardTab = .ledger) {
        popover.performClose(nil)
        store.selectedTab = tab
        if dashboardWindow == nil {
            let host = NSHostingController(rootView: DashboardView().environmentObject(store))
            let w = NSWindow(contentViewController: host)
            w.title = "Recurring v3"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.appearance = NSAppearance(named: .darkAqua)
            w.backgroundColor = Self.nsCanvas
            w.setContentSize(NSSize(width: 1280, height: 880))
            w.minSize = NSSize(width: 1140, height: 640)
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            dashboardWindow = w
        }
        store.reload(force: false)
        NSApp.activate(ignoringOtherApps: true)
        dashboardWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, w === dashboardWindow else { return }
        w.contentViewController = nil
        dashboardWindow = nil
    }

    private func refreshIcon() {
        let missing = store.ledger == nil
        let total = store.monthlyTotal
        let wholeLabel = missing ? "—" : Money.whole(total)
        let dueSoon = store.hasDueSoon
        let leaks = store.vault.leakedCount
        let next = store.upcoming.first(where: { $0.kind == .charge }).map {
            "Next: \(store.displayName(for: $0.service)), \(Money.row($0.service))"
        } ?? ""
        let vaultNote = "Vault: \(store.vault.activeKeys.count) keys"
        let tooltip = "Recurring v3 · \(wholeLabel)/mo · \(vaultNote). \(next)"

        let sig = IconSignature(
            label: wholeLabel,
            dueSoon: dueSoon,
            missing: missing,
            leaks: leaks,
            tooltip: tooltip
        )
        guard sig != lastIconSignature else { return }
        if lastIconSignature?.label != sig.label
            || lastIconSignature?.dueSoon != sig.dueSoon
            || lastIconSignature?.missing != sig.missing
            || lastIconSignature?.leaks != sig.leaks
            || statusItem.button?.image == nil {
            statusItem.button?.image = Self.renderIcon(
                total: total,
                dueSoon: dueSoon,
                missing: missing,
                leaks: leaks
            )
        }
        statusItem.button?.toolTip = tooltip
        lastIconSignature = sig
    }

    /// Observatory menu-bar status badge: signal-amber (or coral on leak / mint when clear)
    /// precision disc + tabular JetBrains Mono monthly readout.
    static func renderIcon(total: Double, dueSoon: Bool, missing: Bool, leaks: Int = 0) -> NSImage {
        let accent: NSColor = leaks > 0 ? nsCoral : (dueSoon ? nsAmber : nsMint)
        let textColor: NSColor = leaks > 0 ? nsCoral : (dueSoon ? nsAmber : nsPaper)
        let label = missing ? "—" : Money.whole(total)
        let labelAttrs: [NSAttributedString.Key: Any] = [.font: iconLabelFont, .foregroundColor: textColor]
        let labelSize = (label as NSString).size(withAttributes: labelAttrs)

        let circleD: CGFloat = 15, gap: CGFloat = 5, leftPad: CGFloat = 4, rightPad: CGFloat = 4
        let totalW = leftPad + circleD + gap + ceil(labelSize.width) + rightPad
        let totalH: CGFloat = 22

        let img = NSImage(size: NSSize(width: totalW, height: totalH))
        img.lockFocus()

        let circleRect = NSRect(x: leftPad, y: (totalH - circleD) / 2, width: circleD, height: circleD)
        accent.setFill()
        NSBezierPath(ovalIn: circleRect).fill()

        let glyph = "↻" as NSString
        let glyphAttrs: [NSAttributedString.Key: Any] = [
            .font: iconGlyphFont,
            .foregroundColor: nsCanvas,
        ]
        let g = glyph.size(withAttributes: glyphAttrs)
        glyph.draw(
            at: NSPoint(x: circleRect.midX - g.width / 2, y: circleRect.midY - g.height / 2 + 0.5),
            withAttributes: glyphAttrs
        )

        (label as NSString).draw(
            at: NSPoint(x: leftPad + circleD + gap, y: (totalH - labelSize.height) / 2),
            withAttributes: labelAttrs
        )
        img.unlockFocus()
        img.isTemplate = false
        return img
    }

    /// Headless proof path: renders the popover, all 3 dashboard tabs (Ledger, Vault, Sync),
    /// and the menu-bar icon from real live data to 0600 PNGs without opening any window.
    private func writeSnapshot(to dir: URL) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: dir.path, isDirectory: &isDir) {
            let attrs = (try? fm.attributesOfItem(atPath: dir.path)) ?? [:]
            guard isDir.boolValue, attrs[.type] as? FileAttributeType == .typeDirectory,
                  (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
                FileHandle.standardError.write("snapshot dir must be a directory you own (not a symlink)\n".data(using: .utf8)!)
                exit(1)
            }
        } else {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }

        NSApp.appearance = NSAppearance(named: .darkAqua)
        let snapStore = Store(poll: false)
        var jobs: [(CGImage, URL)] = []

        // 1a. Menu-bar popover (exact 420x640 viewport card)
        let popCardView = MenuBarView(scrollable: false, viewportHeight: 640)
            .environmentObject(snapStore)
            .environmentObject(reminders)
            .environment(\.colorScheme, .dark)
            .environment(\.isSnapshotRender, true)
            .padding(12)
            .background(DS.canvas)
        let popCardRenderer = ImageRenderer(content: popCardView)
        popCardRenderer.scale = 2
        if let cg = popCardRenderer.cgImage {
            jobs.append((cg, dir.appendingPathComponent("popover_card.png")))
        }

        // 1b. Menu-bar popover (full unscrolled list)
        let popView = MenuBarView(scrollable: false)
            .environmentObject(snapStore)
            .environmentObject(reminders)
            .environment(\.colorScheme, .dark)
            .environment(\.isSnapshotRender, true)
        let popRenderer = ImageRenderer(content: popView)
        popRenderer.scale = 2
        if let cg = popRenderer.cgImage {
            jobs.append((cg, dir.appendingPathComponent("popover.png")))
        }

        // 2. Dashboard — 01 · Ledger & Insights (full unscrolled + 1280x960 viewport card slice)
        snapStore.selectedTab = .ledger
        let ledgerDash = DashboardView(scrollable: false)
            .environmentObject(snapStore)
            .environment(\.colorScheme, .dark)
            .environment(\.isSnapshotRender, true)
            .frame(width: 1280)
        let ledgerRenderer = ImageRenderer(content: ledgerDash)
        ledgerRenderer.scale = 2
        if let cg = ledgerRenderer.cgImage {
            jobs.append((cg, dir.appendingPathComponent("dashboard.png")))
            if let card = Self.viewportCard(from: cg) {
                jobs.append((card, dir.appendingPathComponent("dashboard_card.png")))
            }
        }

        // 3. Dashboard — 02 · Vault · API Keys (full unscrolled + 1280x960 viewport card slice)
        snapStore.selectedTab = .vault
        let vaultDash = DashboardView(scrollable: false)
            .environmentObject(snapStore)
            .environment(\.colorScheme, .dark)
            .environment(\.isSnapshotRender, true)
            .frame(width: 1280)
        let vaultRenderer = ImageRenderer(content: vaultDash)
        vaultRenderer.scale = 2
        if let cg = vaultRenderer.cgImage {
            jobs.append((cg, dir.appendingPathComponent("vault.png")))
            if let card = Self.viewportCard(from: cg) {
                jobs.append((card, dir.appendingPathComponent("vault_card.png")))
            }
        }

        // 4. Dashboard — 03 · Invoice Sync
        snapStore.selectedTab = .sync
        let syncDash = DashboardView(scrollable: false)
            .environmentObject(snapStore)
            .environment(\.colorScheme, .dark)
            .environment(\.isSnapshotRender, true)
            .frame(width: 1280)
        let syncRenderer = ImageRenderer(content: syncDash)
        syncRenderer.scale = 2
        if let cg = syncRenderer.cgImage {
            jobs.append((cg, dir.appendingPathComponent("sync.png")))
        }

        // 5. Dashboard — 04 · Reimburse (full unscrolled + 1280x960 viewport card slice)
        snapStore.selectedTab = .reimburse
        let reimburseDash = DashboardView(scrollable: false)
            .environmentObject(snapStore)
            .environment(\.colorScheme, .dark)
            .environment(\.isSnapshotRender, true)
            .frame(width: 1280)
        let reimburseRenderer = ImageRenderer(content: reimburseDash)
        reimburseRenderer.scale = 2
        if let cg = reimburseRenderer.cgImage {
            jobs.append((cg, dir.appendingPathComponent("reimburse.png")))
            if let card = Self.viewportCard(from: cg) {
                jobs.append((card, dir.appendingPathComponent("reimburse_card.png")))
            }
        }

        // 6. Menu-bar icon
        let icon = Self.renderIcon(
            total: snapStore.monthlyTotal,
            dueSoon: snapStore.hasDueSoon,
            missing: snapStore.ledger == nil,
            leaks: snapStore.vault.leakedCount
        )
        if let tiff = icon.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let cg = rep.cgImage {
            jobs.append((cg, dir.appendingPathComponent("icon.png")))
        }

        // Encode PNGs and write 0600 atomic files concurrently across CPU cores.
        try? LedgerFile.ensurePrivateDirectory(dir)
        let frozenJobs = jobs
        DispatchQueue.concurrentPerform(iterations: frozenJobs.count) { idx in
            let (cg, url) = frozenJobs[idx]
            Self.encodeAndWritePNG(cg, to: url)
        }

        let summary: [String: Any] = [
            "file": snapStore.fileURL.path,
            "as_of": snapStore.ledger?.asOf ?? NSNull(),
            "active": snapStore.ledger?.active.count ?? 0,
            "monthly_total": (snapStore.monthlyTotal * 100).rounded() / 100,
            "due_soon": snapStore.hasDueSoon,
            "upcoming": snapStore.upcoming.map {
                "\(Schedule.isoDay($0.date)) \($0.kind.rawValue) \(snapStore.displayName(for: $0.service))"
            },
            "needs_look": snapStore.ledger?.needsLook.count ?? 0,
            "vault_active_keys": snapStore.vault.activeKeys.count,
            "vault_admin_keys": snapStore.vault.adminCount,
            "vault_org_keys": snapStore.vault.orgCount,
            "vault_unvaulted_env": snapStore.vault.strayFindings.count,
            "sync_reachable_mailboxes": snapStore.syncState.reachableMailboxes,
            "reimburse_gate_passed": snapStore.reimburse.latestPacket?.gatePassed ?? false,
            "reimburse_total_usd": snapStore.reimburse.latestPacket?.totalUSD ?? 0,
            "error": snapStore.loadError ?? NSNull(),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write("\n".data(using: .utf8)!)
        }
    }

    /// Slices the top 1280x960 (@2x = 2560x1920) viewport from an unscrolled dashboard
    /// render and applies the 24pt (@2x = 48px) bottom canvas gradient fade, avoiding a
    /// duplicate full-tree SwiftUI layout/chart pass.
    nonisolated private static func viewportCard(
        from cg: CGImage,
        viewportPixelHeight: Int = 1920,
        fadePixelHeight: Int = 48
    ) -> CGImage? {
        let w = cg.width
        let cropH = min(viewportPixelHeight, cg.height)
        guard let topCrop = cg.cropping(to: CGRect(x: 0, y: 0, width: w, height: cropH)) else { return nil }
        let space = cg.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: viewportPixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let canvasOpaque = CGColor(srgbRed: 10.0 / 255.0, green: 11.0 / 255.0, blue: 13.0 / 255.0, alpha: 1.0)
        ctx.setFillColor(canvasOpaque)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: viewportPixelHeight))
        ctx.draw(topCrop, in: CGRect(x: 0, y: viewportPixelHeight - cropH, width: w, height: cropH))
        if cg.height > viewportPixelHeight {
            let canvasClear = CGColor(srgbRed: 10.0 / 255.0, green: 11.0 / 255.0, blue: 13.0 / 255.0, alpha: 0.0)
            if let grad = CGGradient(
                colorsSpace: space,
                colors: [canvasClear, canvasOpaque] as CFArray,
                locations: [0.0, 1.0]
            ) {
                ctx.saveGState()
                ctx.clip(to: CGRect(x: 0, y: 0, width: w, height: fadePixelHeight))
                ctx.drawLinearGradient(
                    grad,
                    start: CGPoint(x: 0, y: CGFloat(fadePixelHeight)),
                    end: CGPoint(x: 0, y: 0),
                    options: []
                )
                ctx.restoreGState()
            }
        }
        return ctx.makeImage()
    }

    nonisolated private static func encodeAndWritePNG(_ cg: CGImage, to url: URL) {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { return }
        try? LedgerFile.writeSecurely(data as Data, to: url, durableSync: false)
    }
}
