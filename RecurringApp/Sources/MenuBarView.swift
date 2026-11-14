import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var reminders: Reminders
    @Environment(\.isSnapshotRender) private var isSnapshotRender

    /// Off for snapshots: ImageRenderer draws full unscrolled height unless `viewportHeight` is set.
    var scrollable = true
    var viewportHeight: CGFloat? = nil
    var onOpenDashboard: (DashboardTab) -> Void = { _ in }

    @State private var quickFilter = ""
    @State private var showEnded = false
    @State private var showUnverified = false
    @State private var showDomains = false
    @AppStorage("collapsedCategoriesPipe") private var collapsedPipe = ""

    private func inspectService(_ s: Service) {
        store.explorer.focusService(s, scroll: true)
        onOpenDashboard(.ledger)
    }

    private func openLedgerWithFilter(_ filter: LedgerTypeFilter) {
        store.explorer.resetLedgerFilters()
        store.explorer.typeFilter = filter
        store.explorer.scrollRequestID &+= 1
        onOpenDashboard(.ledger)
    }

    var body: some View {
        VStack(spacing: 0) {
            telemetryBar
            Rectangle().fill(DS.border).frame(height: 1)
            heroHeader
            Rectangle().fill(DS.border).frame(height: 1)
            quickSearchStrip
            Rectangle().fill(DS.borderSubtle).frame(height: 1)
            if scrollable {
                ScrollView(.vertical, showsIndicators: true) {
                    content
                        .padding(.top, 4)
                        .padding(.bottom, 20)
                }
                .overlay(alignment: .bottom) {
                    LinearGradient(
                        colors: [DS.canvas.opacity(0), DS.canvas],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 14)
                    .allowsHitTesting(false)
                }
            } else if viewportHeight != nil {
                GeometryReader { geo in
                    content
                        .padding(.top, 4)
                        .padding(.bottom, 20)
                        .frame(width: geo.size.width, alignment: .top)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .clipped()
                .overlay(alignment: .bottom) {
                    LinearGradient(
                        colors: [DS.canvas.opacity(0), DS.canvas],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 18)
                    .allowsHitTesting(false)
                }
            } else {
                content
                    .padding(.top, 4)
                    .padding(.bottom, 18)
            }
            Rectangle().fill(DS.border).frame(height: 1)
            footer
        }
        .frame(width: 420, height: viewportHeight)
        .background(DS.canvas)
        .clipShape(RoundedRectangle(cornerRadius: viewportHeight != nil ? 14 : 0))
        .overlay {
            if viewportHeight != nil {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(DS.border, lineWidth: 1)
            }
        }
        .environment(\.colorScheme, .dark)
    }

    // MARK: Top Telemetry Bar

    private var telemetryBar: some View {
        let age = store.dataAgeDays ?? 0
        let liveDotColor: Color = store.isSyncingNow ? DS.amber : (age <= 1 ? DS.mint : DS.amber)
        let syncLabel: String = {
            if store.isSyncingNow { return "SYNCING INBOXES…" }
            if let asOf = store.ledger?.asOf, let d = Schedule.parseDay(asOf) {
                let live = store.syncState.reachableMailboxes
                let mboxPart = live > 0 ? " · \(live)/\(store.syncState.totalMailboxes) INBOXES" : ""
                return "SYNCED \(DayText.short(d).uppercased())\(mboxPart)"
            }
            return "LEDGER READY"
        }()

        return HStack(spacing: 8) {
            DSLiveDot(color: liveDotColor, size: 6)
            Text(syncLabel)
                .font(DS.mono(9.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(DS.ink2)
                .lineLimit(1)

            Spacer(minLength: 4)

            // Quick Vault pill → jumps straight to Vault tab
            PopoverTopPill(
                icon: store.vault.unlocked ? "lock.open.fill" : "lock.shield.fill",
                text: "Vault · \(store.vault.activeKeys.count)",
                tint: store.vault.leakedCount > 0 ? DS.coral : (store.vault.unlocked ? DS.mint : DS.amber)
            ) {
                onOpenDashboard(.vault)
            }

            // One-click live invoice sync
            PopoverTopPill(
                icon: "arrow.triangle.2.circlepath",
                text: store.isSyncingNow ? "…" : "Sync",
                tint: DS.ink2
            ) {
                Task { await store.syncInvoicesNow() }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(DS.surface)
    }

    // MARK: Hero Spend Readout

    private var heroHeader: some View {
        let d = store.derived
        let monthly = d?.monthlyTotal ?? store.monthlyTotal
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("$")
                    .font(DS.mono(20, weight: .bold))
                    .foregroundStyle(DS.amber)
                Text(Money.bareExact(monthly))
                    .font(DS.display(30, weight: .bold))
                    .foregroundStyle(DS.ink)
                Text("/mo")
                    .font(DS.mono(12, weight: .medium))
                    .foregroundStyle(DS.ink3)

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(Money.whole(monthly * 12))/yr")
                        .font(DS.mono(11.5, weight: .semibold))
                        .foregroundStyle(DS.ink2)
                    Text("\(d?.activeCount ?? (store.ledger?.active.count ?? 0)) active plans")
                        .font(DS.display(10.5, weight: .medium))
                        .foregroundStyle(DS.ink3)
                }
            }

            if let ledger = store.ledger {
                let back = d?.totalMoneyBack ?? 0
                let closingCount = d?.typeFilterCounts[.closing] ?? ledger.closing.count
                let checkCount = max(0, (d?.typeFilterCounts[.needsCheck] ?? ledger.needsLook.count) - (d?.typeFilterCounts[.unverified] ?? ledger.unverified.count))
                let cutMo = d?.savings.monthly ?? 0

                HStack(spacing: 6) {
                    if closingCount > 0 {
                        Button {
                            openLedgerWithFilter(.closing)
                        } label: {
                            DSStatusPill(text: "\(closingCount) closing", tint: DS.cyan)
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                    }
                    if back > 0 {
                        Button {
                            onOpenDashboard(.ledger)
                        } label: {
                            DSStatusPill(text: "\(Money.whole(back)) back", tint: DS.coral)
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                    }
                    if cutMo > 0 {
                        DSStatusPill(text: "−\(Money.whole(cutMo))/mo saved", tint: DS.mint)
                    }
                    if checkCount > 0 {
                        Button {
                            openLedgerWithFilter(.needsCheck)
                        } label: {
                            DSStatusPill(text: "\(checkCount) check", tint: DS.amber)
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                    }
                    if let age = store.dataAgeDays, age > 7 {
                        DSStatusPill(text: "\(age)d old", tint: DS.amber)
                    }
                }
            }

            if let banner = store.statusBanner {
                HStack(spacing: 6) {
                    Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 10.5, weight: .bold))
                    Text(banner.message)
                        .font(DS.display(11, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(banner.isError ? DS.coral : DS.mint)
            } else if !store.issues.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .font(.system(size: 10.5))
                    Text("\(store.issues.count) schema issue\(store.issues.count == 1 ? "" : "s") in ledger")
                        .font(DS.display(11, weight: .medium))
                }
                .foregroundStyle(DS.coral)
                .help(store.issues.prefix(12).joined(separator: "\n"))
            } else if let err = store.loadError {
                Text(err)
                    .font(DS.display(11, weight: .medium))
                    .foregroundStyle(DS.coral)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(DS.surface.opacity(0.65))
    }

    // MARK: Instant Quick Filter Strip

    private var quickSearchStrip: some View {
        let count = store.derived?.activeCount ?? (store.ledger?.active.count ?? 0)
        return HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(quickFilter.isEmpty ? DS.ink3 : DS.amber)
            if isSnapshotRender || !scrollable {
                Text("Quick filter \(count) plans, accounts, cards…")
                    .font(DS.display(11.5))
                    .foregroundStyle(DS.ink3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("Quick filter \(count) plans, accounts, cards…", text: $quickFilter)
                    .textFieldStyle(.plain)
                    .focusEffectDisabled()
                    .font(DS.display(11.5))
                    .foregroundStyle(DS.ink)
                if !quickFilter.isEmpty {
                    Button {
                        quickFilter = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(DS.ink3)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(DS.well.opacity(0.65))
    }

    // MARK: Scrollable Body

    @ViewBuilder
    private var content: some View {
        if let ledger = store.ledger, let d = store.derived {
            let trimmedQuery = quickFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !trimmedQuery.isEmpty {
                quickSearchResultsSection(query: trimmedQuery, ledger: ledger, derived: d)
            } else {
                let collapsed = collapsedCategoriesSet
                VStack(alignment: .leading, spacing: 2) {
                    upcomingSection(derived: d)
                    laterSection(derived: d)
                    moneyBackSection(derived: d)
                    if !ledger.closing.isEmpty {
                        closingSection(ledger.closing, derived: d)
                    }
                    cutSection(derived: d)
                    ForEach(d.popoverCategories) { group in
                        categorySection(group, collapsed: collapsed.contains(group.category), derived: d)
                    }
                    if !ledger.unverified.isEmpty {
                        collapsible("Unverified · excluded", count: ledger.unverified.count, isOpen: $showUnverified) {
                            ForEach(ledger.unverified) { s in
                                ServiceRow(
                                    service: s,
                                    meta: d.rowMeta[s.id],
                                    dimmed: true,
                                    onInspect: { inspectService(s) },
                                    onToggleStatus: {}
                                )
                            }
                        }
                    }
                    if !ledger.cancelled.isEmpty {
                        collapsible("Ended", count: ledger.cancelled.count, isOpen: $showEnded) {
                            ForEach(ledger.cancelled) { s in
                                ServiceRow(
                                    service: s,
                                    meta: d.rowMeta[s.id],
                                    dimmed: true,
                                    onInspect: { inspectService(s) },
                                    onToggleStatus: { store.setStatus(s.id, cancelled: false) }
                                )
                            }
                        }
                    }
                }
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "tray.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(DS.ink3)
                Text("No subscriptions in ledger")
                    .font(DS.display(14, weight: .semibold))
                    .foregroundStyle(DS.ink)
                Text("Run `recurring sync` or `recurring add` to populate \(store.fileURL.path).")
                    .font(DS.display(11.5))
                    .foregroundStyle(DS.ink3)
                    .multilineTextAlignment(.center)
            }
            .padding(32)
            .frame(maxWidth: .infinity)
        }
    }

    private func quickSearchResultsSection(query: String, ledger: Ledger, derived d: Store.Derived) -> some View {
        let matches = ledger.services
            .filter { s in d.rowMeta[s.id]?.searchHaystack.contains(query) ?? s.name.lowercased().contains(query) }
            .sorted { a, b in
                let rankA = a.status == .active ? 0 : (a.status == .unverified ? 1 : 2)
                let rankB = b.status == .active ? 0 : (b.status == .unverified ? 1 : 2)
                if rankA != rankB { return rankA < rankB }
                return (d.rowMeta[a.id]?.monthlySortKey ?? 0) > (d.rowMeta[b.id]?.monthlySortKey ?? 0)
            }
        let activeSum = matches.compactMap { d.rowMeta[$0.id]?.monthlyEquiv }.reduce(0, +)

        return VStack(alignment: .leading, spacing: 0) {
            PopoverSectionHeader(
                title: "\(matches.count) match\(matches.count == 1 ? "" : "es")",
                trailing: activeSum > 0 ? "\(Money.exact(activeSum))/mo" : nil,
                icon: "sparkle.magnifyingglass",
                accent: DS.amber
            )
            if matches.isEmpty {
                Text("No plans match “\(quickFilter)”.")
                    .font(DS.display(12))
                    .foregroundStyle(DS.ink3)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            } else {
                ForEach(matches) { s in
                    ServiceRow(
                        service: s,
                        meta: d.rowMeta[s.id],
                        dimmed: s.status != .active,
                        onInspect: { inspectService(s) },
                        onToggleStatus: {
                            if s.status != .unverified {
                                store.setStatus(s.id, cancelled: s.status == .active)
                            }
                        }
                    )
                }
            }
        }
    }

    private func upcomingSection(derived d: Store.Derived) -> some View {
        let items = d.upcoming
        let total = d.upcoming7dTotal
        return VStack(alignment: .leading, spacing: 0) {
            PopoverSectionHeader(
                title: "Next \(Store.upcomingDays) days",
                trailing: total > 0 ? Money.exact(total) : nil,
                accent: DS.amber
            )
            if items.isEmpty {
                Text("Nothing scheduled in the next week.")
                    .font(DS.display(12))
                    .foregroundStyle(DS.ink3)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }
            ForEach(items, id: \.self) { e in
                UpcomingRow(
                    event: e,
                    displayName: d.displayNames[e.service.id] ?? e.service.name,
                    days: Schedule.daysUntil(e.date, from: store.today),
                    today: store.today,
                    onTap: { inspectService(e.service) }
                )
            }
        }
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private func laterSection(derived d: Store.Derived) -> some View {
        let later = d.renewalRadar.bigRenewals.filter { $0.daysLeft > Store.upcomingDays }
        if !later.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                PopoverSectionHeader(
                    title: "Big renewals · next \(Store.renewalDays)d",
                    trailing: Money.exact(later.compactMap(\.amount).reduce(0, +)),
                    icon: "calendar.badge.exclamationmark"
                )
                ForEach(later, id: \.self) { r in
                    RenewalRow(
                        renewal: r,
                        displayName: d.displayNames[r.service.id] ?? r.service.name,
                        today: store.today,
                        onTap: { inspectService(r.service) }
                    )
                }
            }
            .padding(.bottom, 6)
        }
    }

    @ViewBuilder
    private func moneyBackSection(derived d: Store.Derived) -> some View {
        let claims = d.refundClaims.filter(\.claim.isPending)
        let late = d.lateWatch
        let watching = d.watchingItems.filter { w in
            w.wouldCharge.map { Schedule.daysUntil($0, from: store.today) <= Store.upcomingDays } ?? false
        }
        if !claims.isEmpty || !late.isEmpty || !watching.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                PopoverSectionHeader(
                    title: "Money back & watch",
                    trailing: Money.exact(d.totalMoneyBack),
                    icon: "arrow.uturn.backward.circle",
                    accent: DS.coral
                )
                ForEach(claims, id: \.service.id) { c in
                    MiniRow(
                        title: d.displayNames[c.service.id] ?? c.service.name,
                        detail: "refund \(c.claim.status.rawValue)",
                        amount: Money.exact(c.claim.amount),
                        tint: DS.coral,
                        help: c.claim.note,
                        onTap: { inspectService(c.service) }
                    )
                }
                ForEach(late, id: \.self) { w in
                    MiniRow(
                        title: d.displayNames[w.service.id] ?? w.service.name,
                        detail: "charged after cancel — claim refund",
                        amount: Money.exact(w.lateTotal),
                        tint: DS.coral,
                        help: w.lateCharges.map { "\($0.date) \(Money.exact($0.amount))" }.joined(separator: "\n"),
                        onTap: { inspectService(w.service) }
                    )
                }
                ForEach(watching, id: \.self) { w in
                    MiniRow(
                        title: d.displayNames[w.service.id] ?? w.service.name,
                        detail: MoneyBackPanel.watchText(w, days: w.wouldCharge.map { Schedule.daysUntil($0, from: store.today) })
                            .replacingOccurrences(of: " — a charge then = refund", with: " · watch card"),
                        amount: d.rowMeta[w.service.id]?.cycleText ?? Money.row(w.service),
                        tint: DS.amber,
                        help: nil,
                        onTap: { inspectService(w.service) }
                    )
                }
            }
            .padding(.bottom, 6)
        }
    }

    @ViewBuilder
    private var cutSectionBodyPlaceholder: EmptyView { EmptyView() }

    @ViewBuilder
    private func cutSection(derived d: Store.Derived) -> some View {
        let groups = d.cutGroups
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                PopoverSectionHeader(
                    title: "Overlap · where to cut",
                    trailing: "save ≥ \(Money.exact(groups.map(\.saveMin).reduce(0, +)))/mo",
                    icon: "scissors",
                    accent: DS.mint
                )
                ForEach(groups, id: \.self) { g in
                    MiniRow(
                        title: g.name,
                        detail: "\(g.members.count) \(g.auto ? "accounts" : "plans") · keep one → save \(Money.exact(g.saveMin))/mo",
                        amount: Money.exact(g.monthly),
                        tint: DS.mint,
                        help: g.members.map { "\($0.name) — \(Money.row($0)) · \($0.accountShort)" }.joined(separator: "\n"),
                        onTap: {
                            store.explorer.toggleOverlap(g, scroll: true)
                            onOpenDashboard(.ledger)
                        }
                    )
                }
            }
            .padding(.bottom, 6)
        }
    }

    private func closingSection(_ services: [Service], derived d: Store.Derived) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            PopoverSectionHeader(title: "Closing", trailing: "\(services.count)", icon: "xmark.circle", accent: DS.cyan)
            ForEach(services) { s in
                ServiceRow(
                    service: s,
                    meta: d.rowMeta[s.id],
                    dimmed: false,
                    onInspect: { inspectService(s) },
                    onToggleStatus: { store.setStatus(s.id, cancelled: true) }
                )
            }
        }
        .padding(.bottom, 6)
    }

    private func categorySection(_ group: PopoverCategoryGroup, collapsed: Bool, derived d: Store.Derived) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.14)) { toggleCollapsed(group.category) }
            } label: {
                PopoverSectionHeader(
                    title: group.category,
                    trailing: "\(group.totalCount) · \(Money.exact(group.monthlyTotal))/mo",
                    color: DS.categoryColor(group.category),
                    chevron: collapsed ? "chevron.right" : "chevron.down"
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()

            if !collapsed {
                ForEach(group.others) { s in
                    ServiceRow(
                        service: s,
                        meta: d.rowMeta[s.id],
                        dimmed: false,
                        onInspect: { inspectService(s) },
                        onToggleStatus: { store.setStatus(s.id, cancelled: true) }
                    )
                }
                if !group.domains.isEmpty {
                    DomainGroupRow(domains: group.domains, rollup: d.domainRollup, today: store.today, isOpen: $showDomains)
                    if showDomains {
                        ForEach(group.domains) { s in
                            ServiceRow(
                                service: s,
                                meta: d.rowMeta[s.id],
                                dimmed: false,
                                indent: 14,
                                onInspect: { inspectService(s) },
                                onToggleStatus: { store.setStatus(s.id, cancelled: true) }
                            )
                        }
                    }
                }
            }
        }
        .padding(.bottom, collapsed ? 0 : 6)
    }

    private var collapsedCategoriesSet: Set<String> {
        guard !collapsedPipe.isEmpty else { return [] }
        return Set(collapsedPipe.split(separator: "|").map(String.init))
    }

    private func toggleCollapsed(_ cat: String) {
        var s = collapsedCategoriesSet
        if s.contains(cat) { s.remove(cat) } else { s.insert(cat) }
        collapsedPipe = s.sorted().joined(separator: "|")
    }

    private func collapsible<C: View>(_ title: String, count: Int, isOpen: Binding<Bool>, @ViewBuilder rows: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.14)) { isOpen.wrappedValue.toggle() }
            } label: {
                PopoverSectionHeader(title: title, trailing: "\(count)", chevron: isOpen.wrappedValue ? "chevron.down" : "chevron.right")
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            if isOpen.wrappedValue { rows() }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 6) {
            FooterButton(title: "Dashboard", icon: "square.grid.2x2.fill", prominent: true) {
                onOpenDashboard(.ledger)
            }
            FooterButton(title: "Vault", icon: "key.fill") {
                onOpenDashboard(.vault)
            }
            FooterButton(title: "Sync", icon: "bolt.horizontal.circle") {
                onOpenDashboard(.sync)
            }
            FooterButton(title: "Reimburse", icon: "doc.zipper") {
                onOpenDashboard(.reimburse)
            }
            FooterButton(title: "JSON", icon: "curlybraces") {
                store.openFileInEditor()
            }
            Spacer(minLength: 4)
            if reminders.authorized == false && !isSnapshotRender {
                Image(systemName: "bell.slash.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(DS.ink3)
                    .help("Reminders alerts off")
            }
            FooterButton(title: "Quit", icon: nil) {
                NSApp.terminate(nil)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(DS.surface)
    }
}

// MARK: - Popover Subcomponents

private struct PopoverTopPill: View {
    let icon: String
    let text: String
    let tint: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9.5, weight: .semibold))
                Text(text)
                    .font(DS.mono(9.5, weight: .semibold))
            }
            .foregroundStyle(hovering ? DS.ink : tint)
            .padding(.horizontal, 7.5)
            .padding(.vertical, 3.5)
            .background(RoundedRectangle(cornerRadius: DS.radiusPill).fill(hovering ? DS.elevated : DS.well))
            .overlay(RoundedRectangle(cornerRadius: DS.radiusPill).strokeBorder(DS.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
    }
}

private struct PopoverSectionHeader: View {
    let title: String
    var trailing: String? = nil
    var color: Color? = nil
    var icon: String? = nil
    var chevron: String? = nil
    var accent: Color? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let chevron {
                Image(systemName: chevron)
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(DS.ink3)
                    .frame(width: 10)
            }
            if let color {
                Circle().fill(color).frame(width: 6.5, height: 6.5)
            }
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(accent ?? DS.ink3)
            }
            Text(title.uppercased())
                .font(DS.mono(9.5, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(accent ?? DS.ink2)
                .lineLimit(1)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(DS.mono(10.5, weight: .semibold))
                    .foregroundStyle(DS.ink2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5.5)
        .background(DS.well.opacity(0.32))
        .overlay(alignment: .top) { Rectangle().fill(DS.borderSubtle).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(DS.borderSubtle).frame(height: 1) }
        .padding(.bottom, 2)
    }
}

private struct UpcomingRow: View {
    let event: ScheduledEvent
    let displayName: String
    let days: Int
    let today: Date
    let onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        let soon = days <= Store.dueSoonDays
        Button(action: onTap) {
            HStack(spacing: 10) {
                Text(days == 0 ? "Today" : days == 1 ? "Tomorrow" : DayText.relative(event.date, from: today))
                    .font(DS.mono(10, weight: .semibold))
                    .foregroundStyle(soon ? DS.canvas : DS.ink2)
                    .frame(width: 72)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: DS.radiusPill)
                            .fill(soon ? DS.amber : DS.well)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.radiusPill)
                            .strokeBorder(soon ? DS.amber : DS.border, lineWidth: 1)
                    )

                Circle()
                    .fill(DS.categoryColor(event.service.category))
                    .frame(width: 6, height: 6)

                VStack(alignment: .leading, spacing: 1.5) {
                    HStack(spacing: 5) {
                        Text(displayName)
                            .font(DS.display(12.5, weight: .medium))
                            .foregroundStyle(DS.ink)
                            .lineLimit(1)
                        if event.service.isClosing {
                            Text("CLOSING")
                                .font(DS.mono(8.5, weight: .bold))
                                .foregroundStyle(DS.cyan)
                        }
                    }
                    if event.kind == .charge, (event.amount ?? 0) >= Insights.bigRenewal, days >= 1,
                       let by = Schedule.calendar.date(byAdding: .day, value: -1, to: event.date) {
                        Text(DayText.cancelBy(by, from: today))
                            .font(DS.display(10.5, weight: days <= 2 ? .semibold : .regular))
                            .foregroundStyle(days <= 2 ? DS.amber : DS.ink3)
                    }
                }
                Spacer(minLength: 6)

                switch event.kind {
                case .charge:
                    Text(Money.row(event.service))
                        .font(DS.mono(12.5, weight: .semibold))
                        .foregroundStyle(soon ? DS.amber : DS.ink)
                case .expiry:
                    Text("prepaid ends")
                        .font(DS.mono(10.5, weight: .medium))
                        .foregroundStyle(DS.amber)
                case .ending:
                    Text("ends")
                        .font(DS.mono(10.5))
                        .foregroundStyle(DS.ink3)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4.5)
            .background(hovering ? DS.rowHover : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
    }
}

private struct RenewalRow: View {
    let renewal: Renewal
    let displayName: String
    let today: Date
    let onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        let r = renewal
        Button(action: onTap) {
            HStack(spacing: 10) {
                Text(DayText.relative(r.date, from: today))
                    .font(DS.mono(10, weight: .semibold))
                    .foregroundStyle(DS.ink2)
                    .frame(width: 72)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: DS.radiusPill).fill(DS.well))
                    .overlay(RoundedRectangle(cornerRadius: DS.radiusPill).strokeBorder(DS.border, lineWidth: 1))

                Circle()
                    .fill(DS.categoryColor(r.service.category))
                    .frame(width: 6, height: 6)

                VStack(alignment: .leading, spacing: 1.5) {
                    Text(displayName)
                        .font(DS.display(12.5, weight: .medium))
                        .foregroundStyle(DS.ink)
                        .lineLimit(1)
                    if let by = r.cancelBy {
                        Text("\(DayText.cancelBy(by, from: today)) · in \(r.daysLeft)d")
                            .font(DS.display(10.5))
                            .foregroundStyle(DS.ink3)
                    }
                }
                Spacer(minLength: 6)
                Text(Money.row(r.service))
                    .font(DS.mono(12.5, weight: .semibold))
                    .foregroundStyle(DS.ink)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .background(hovering ? DS.rowHover : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
    }
}

private struct MiniRow: View {
    let title: String
    let detail: String
    let amount: String
    let tint: Color
    let help: String?
    var onTap: (() -> Void)? = nil
    @State private var hovering = false

    var body: some View {
        Button {
            onTap?()
        } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(tint)
                    .frame(width: 2.5, height: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(DS.display(12.5, weight: .medium))
                        .foregroundStyle(DS.ink)
                        .lineLimit(1)
                    Text(detail)
                        .font(DS.display(10.5))
                        .foregroundStyle(DS.ink3)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(amount)
                    .font(DS.mono(12.5, weight: .semibold))
                    .foregroundStyle(DS.ink)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 3.5)
            .background(hovering && onTap != nil ? DS.rowHover : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        .help(help ?? "")
    }
}

private struct FooterButton: View {
    let title: String
    let icon: String?
    var prominent: Bool = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(title)
                    .font(DS.display(11.5, weight: prominent ? .semibold : .medium))
                    .lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(prominent ? (hovering ? DS.ink : DS.amber) : (hovering ? DS.ink : DS.ink2))
            .padding(.horizontal, prominent ? 7.5 : 3.5)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: DS.radiusPill)
                    .fill(prominent ? DS.amber.opacity(0.14) : (hovering ? DS.well : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
    }
}

private struct DomainGroupRow: View {
    let domains: [Service]
    let rollup: DomainRollupData?
    let today: Date
    @Binding var isOpen: Bool

    var body: some View {
        let yearly = rollup.map { domains.count == $0.domains.count ? $0.yearlyTotal : domains.compactMap { $0.yearlyEquivalent(on: today) }.reduce(0, +) }
            ?? domains.compactMap { $0.yearlyEquivalent(on: today) }.reduce(0, +)
        let nextRel = rollup.flatMap { domains.count == $0.domains.count ? $0.nextRenewalRelative : nil }
            ?? domains.compactMap { Schedule.nextCharge(for: $0, from: today) ?? Schedule.parseDay($0.termEnd) }.min().map { DayText.relative($0, from: today) }

        Button {
            withAnimation(.easeOut(duration: 0.14)) { isOpen.toggle() }
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(DS.ink3)
                        Text("Domains")
                            .font(DS.display(12.5, weight: .medium))
                            .foregroundStyle(DS.ink)
                        Text("\(domains.count)")
                            .font(DS.mono(10.5, weight: .semibold))
                            .foregroundStyle(DS.ink3)
                    }
                    Text(nextRel.map { "next renewal \($0)" } ?? "renewal dates unknown")
                        .font(DS.display(10.5))
                        .foregroundStyle(DS.ink3)
                }
                Spacer(minLength: 8)
                Text("per yr")
                    .font(DS.mono(10))
                    .foregroundStyle(DS.ink3)
                Text(Money.exact(yearly))
                    .font(DS.mono(12.5, weight: .semibold))
                    .foregroundStyle(DS.ink)
                    .frame(minWidth: 78, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }
}

private struct ServiceRow: View {
    @EnvironmentObject private var store: Store
    let service: Service
    let meta: ServiceRowMeta?
    let dimmed: Bool
    var indent: CGFloat = 0
    let onInspect: () -> Void
    let onToggleStatus: () -> Void
    @State private var hovering = false

    var body: some View {
        let displayName = meta?.displayName ?? service.name
        let subtitle = meta?.popoverSubtitle
        let sched = meta?.scheduleLabel ?? service.scheduleLabel
        let cycle = meta?.cycleText ?? Money.row(service)

        Button(action: onInspect) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1.5) {
                    HStack(spacing: 4) {
                        Text(displayName)
                            .font(DS.display(12.5, weight: .medium))
                            .foregroundStyle(DS.ink)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if service.check != nil && service.status == .active && !service.isClosing {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(DS.amber)
                        }
                    }
                    if let subtitle {
                        Text(subtitle)
                            .font(DS.display(10.5))
                            .foregroundStyle(DS.ink3)
                            .lineLimit(1)
                    }
                }
                .layoutPriority(1)

                Spacer(minLength: 8)

                Text(sched)
                    .font(DS.mono(10))
                    .foregroundStyle(DS.ink3)
                    .lineLimit(1)
                    .fixedSize()

                Text(cycle)
                    .font(DS.mono(12.5, weight: .semibold))
                    .foregroundStyle(DS.ink)
                    .frame(minWidth: 78, alignment: .trailing)
                    .fixedSize()
            }
            .opacity(dimmed ? 0.55 : 1)
            .padding(.leading, 16 + indent)
            .padding(.trailing, 16)
            .padding(.vertical, 4.5)
            .background(hovering ? DS.rowHover : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        .help([service.plan, service.check ?? service.note, service.manageHost.map { "Billing page: \($0)" }]
            .compactMap { $0 }.joined(separator: "\n"))
        .contextMenu {
            Button("Inspect in Dashboard") { onInspect() }
            if let host = service.manageHost {
                Button("Open billing page — \(host)") { openManage() }
            }
            if service.status == .active {
                Button(service.isClosing ? "Clear closing flag" : "Mark closing (cancelling)") {
                    store.setClosing(service.id, closing: !service.isClosing)
                }
            }
            if service.check != nil {
                Button("Clear check flag") {
                    store.clearCheck(service.id)
                }
            }
            if service.status != .unverified {
                Button(dimmed ? "Mark as active again" : "Mark as cancelled") { onToggleStatus() }
            }
            Button("Copy CLI ID (\(service.id))") {
                store.copyText(service.id, banner: "Copied '\(service.id)'")
            }
        }
    }

    private func openManage() {
        if let url = service.safeManageURL { NSWorkspace.shared.open(url) }
    }
}
