import AppKit
import Charts
import SwiftUI

/// Unified Sentinel "Observatory" command center for Recurring v3:
///   01 · Ledger  |  02 · API Vault  |  03 · Invoice Sync  |  04 · Reimburse
struct DashboardView: View {
    @EnvironmentObject var store: Store
    /// Off for --snapshot: ImageRenderer draws full unscrolled content unless `viewportHeight` is set.
    var scrollable = true
    var viewportHeight: CGFloat? = nil
    @State private var splitByCard = false

    var body: some View {
        VStack(spacing: 0) {
            observatoryTopBar
            Rectangle().fill(DS.border).frame(height: 1)
            Group {
                if scrollable {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: true) {
                            activeSurface
                                .padding(26)
                        }
                        .onChange(of: store.explorer.scrollRequestID) { _, _ in
                            withAnimation(.easeOut(duration: 0.22)) {
                                if let sid = store.explorer.expandedServiceID {
                                    proxy.scrollTo("row-\(sid)", anchor: .center)
                                } else {
                                    proxy.scrollTo("ledger-explorer", anchor: .top)
                                }
                            }
                        }
                    }
                } else if viewportHeight != nil {
                    GeometryReader { geo in
                        activeSurface
                            .padding(26)
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
                        .frame(height: 24)
                        .allowsHitTesting(false)
                    }
                } else {
                    activeSurface
                        .padding(26)
                }
            }
        }
        .frame(height: viewportHeight)
        .background(DS.canvas)
        .environment(\.colorScheme, .dark)
    }

    // MARK: Unified Observatory Top Navigation Bar

    private var observatoryTopBar: some View {
        let age = store.dataAgeDays ?? 0
        let syncDot = store.isSyncingNow ? DS.amber : (age <= 1 ? DS.mint : DS.amber)
        let asOfLabel = store.ledger?.asOf.flatMap(Schedule.parseDay).map(DayText.withYear) ?? "—"

        return HStack(spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(DS.amber.opacity(0.16))
                        .frame(width: 32, height: 32)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(DS.amber.opacity(0.45), lineWidth: 1)
                        )
                    Text("↻")
                        .font(.system(size: 17, weight: .black))
                        .foregroundStyle(DS.amber)
                }
                VStack(alignment: .leading, spacing: 1.5) {
                    HStack(spacing: 7) {
                        Text("RECURRING")
                            .font(DS.display(15, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(DS.ink)
                        DSStatusPill(text: "v3 OBSERVATORY", tint: DS.amber)
                    }
                    Text("Checked \(asOfLabel) · \(store.ledger?.active.count ?? 0) active · \(store.vault.activeKeys.count) keys")
                        .font(DS.mono(10))
                        .foregroundStyle(DS.ink3)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            // 4-Mode Observatory Switcher
            HStack(spacing: 4) {
                ForEach(DashboardTab.allCases) { tab in
                    ObservatoryModeTab(
                        tab: tab,
                        selected: store.selectedTab == tab,
                        badge: badgeForTab(tab)
                    ) {
                        store.selectedTab = tab
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(4)
            .background(RoundedRectangle(cornerRadius: DS.radiusWell + 2).fill(DS.well))
            .overlay(RoundedRectangle(cornerRadius: DS.radiusWell + 2).strokeBorder(DS.border, lineWidth: 1))

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                if let banner = store.statusBanner {
                    DSStatusPill(
                        text: banner.message,
                        tint: banner.isError ? DS.coral : DS.mint
                    )
                } else {
                    HStack(spacing: 6) {
                        DSLiveDot(color: syncDot, size: 6)
                        Text(store.syncState.daemonAlive ? "PUSH + HOURLY" : "SYNC READY")
                            .font(DS.mono(9.5, weight: .semibold))
                            .foregroundStyle(DS.ink2)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .fixedSize(horizontal: true, vertical: false)
                    .background(RoundedRectangle(cornerRadius: DS.radiusWell).fill(DS.well))
                    .overlay(RoundedRectangle(cornerRadius: DS.radiusWell).strokeBorder(DS.border, lineWidth: 1))
                }

                DSChipButton(
                    title: store.isSyncingNow ? "Syncing…" : "Sync Now",
                    icon: "arrow.triangle.2.circlepath",
                    disabled: store.isSyncingNow
                ) {
                    Task { await store.syncInvoicesNow() }
                }
                DSChipButton(title: "Edit JSON", icon: "curlybraces") {
                    store.openFileInEditor()
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(DS.surface)
    }

    private func badgeForTab(_ tab: DashboardTab) -> (String, Color)? {
        switch tab {
        case .ledger:
            return ("\(Money.whole(store.monthlyTotal))/mo", DS.amber)
        case .vault:
            if store.vault.leakedCount > 0 {
                return ("\(store.vault.leakedCount) LEAK", DS.coral)
            }
            return ("\(store.vault.activeKeys.count)", store.vault.unlocked ? DS.mint : DS.ink3)
        case .sync:
            return ("\(store.syncState.reachableMailboxes)/\(store.syncState.totalMailboxes)", store.syncState.reachableMailboxes >= 4 ? DS.mint : DS.amber)
        case .reimburse:
            if let pkt = store.reimburse.latestPacket {
                return pkt.gatePassed ? ("PASS", DS.mint) : ("CHECK", DS.coral)
            }
            return ("\(store.reimburse.verifiedApprovalCount) OK", DS.ink3)
        }
    }

    // MARK: Active Surface Router

    @ViewBuilder
    private var activeSurface: some View {
        switch store.selectedTab {
        case .ledger:
            ledgerSurface
        case .vault:
            VaultView(scrollable: scrollable)
        case .sync:
            SyncCenterView()
        case .reimburse:
            ReimburseView()
        }
    }

    // MARK: 01 · Ledger & Insights Surface

    @ViewBuilder
    private var ledgerSurface: some View {
        if let ledger = store.ledger, let d = store.derived {
            VStack(alignment: .leading, spacing: 18) {
                kpis(ledger, derived: d)
                BurnAllocationBar(burn: d.burn, explorer: store.explorer)
                RenewalsPanel(
                    radar: d.renewalRadar,
                    displayNames: d.displayNames,
                    today: store.today,
                    onSelectService: { store.explorer.focusService($0) }
                )
                HStack(alignment: .top, spacing: 18) {
                    MoneyBackPanel(
                        claims: d.refundClaims,
                        pendingTotal: d.pendingRefunds,
                        wonTotal: d.wonRefunds,
                        late: d.lateWatch,
                        watching: d.watchingItems,
                        clearedCount: d.clearedWatchCount,
                        clearedNames: d.clearedWatchNames,
                        displayNames: d.displayNames,
                        today: store.today,
                        onSelectService: { store.explorer.focusService($0) }
                    )
                    SavingsPanel(
                        savings: d.savings,
                        now: d.monthlyTotal,
                        closingCount: ledger.closing.count,
                        cutsByMonth: d.cutsByMonth
                    )
                }
                HStack(alignment: .top, spacing: 18) {
                    CutPanel(
                        groups: d.cutGroups,
                        rowMeta: d.rowMeta,
                        explorer: store.explorer
                    )
                    SpendShapePanel(
                        burn: d.burn,
                        explorer: store.explorer
                    )
                }
                CashOutPanel(
                    cashFlow: d.cashFlow,
                    monthlyRunRate: d.monthlyTotal,
                    today: store.today
                )
                HStack(alignment: .top, spacing: 18) {
                    ChargeCalendarPanel(
                        heatmap: d.calendarHeatmap,
                        onSelectServiceID: { sid in
                            if let svc = d.servicesByID[sid] {
                                store.explorer.focusService(svc)
                            }
                        }
                    )
                    PaymentAttributionPanel(
                        burn: d.burn,
                        splitByCard: $splitByCard,
                        explorer: store.explorer
                    )
                }
                HStack(alignment: .top, spacing: 18) {
                    TermsPanel(
                        items: d.termWindows,
                        domainRollup: d.domainRollup,
                        onSelectService: { store.explorer.focusService($0) }
                    )
                    NeedsLookPanel(
                        ledger: ledger,
                        displayNames: d.displayNames,
                        scrollable: scrollable,
                        onSelectService: { store.explorer.focusService($0) },
                        onClearCheck: { store.clearCheck($0.id) }
                    )
                }
                LedgerExplorerPanel(
                    ledger: ledger,
                    derived: d,
                    vaultKeysByServiceID: store.vault.keysByServiceID,
                    scrollable: scrollable,
                    explorer: store.explorer
                )
                .id("ledger-explorer")
            }
        } else {
            Text(store.loadError ?? "No ledger loaded")
                .font(DS.display(13))
                .foregroundStyle(DS.ink2)
                .padding(40)
        }
    }

    private func kpis(_ ledger: Ledger, derived d: Store.Derived) -> some View {
        let radar = d.renewalRadar
        let sv = d.savings
        let since = DayText.short(sv.since)
        let cutMin = d.cutGroups.map(\.saveMin).reduce(0, +)
        let committedMo = d.burn.multiMonthMonthly + d.burn.prepaidTermMonthly

        return HStack(spacing: 12) {
            KPI(
                label: "Monthly burn",
                value: Money.exact(d.monthlyTotal),
                caption: "Fixed \(Money.whole(d.burn.fixedMonthly)) · Usage \(Money.whole(d.burn.usageMonthly)) · Term \(Money.whole(committedMo))",
                delta: sv.monthly > 0 ? "▼ \(Money.exact(sv.monthly)) since \(since)" : nil,
                accent: DS.amber
            )
            KPI(
                label: "Annualized",
                value: Money.whole(d.monthlyTotal * 12),
                caption: "\(ledger.active.count) active · \(ledger.closing.count) closing",
                delta: sv.monthly > 0 ? "▼ \(Money.whole(sv.yearly))/yr saved" : nil
            )
            KPI(
                label: "Next 30 days",
                value: Money.exact(radar.total30d),
                caption: "7d: \(Money.whole(radar.total7d)) (\(radar.count7d)) · \(radar.bigRenewals.count) of \(Money.whole(Insights.bigRenewal))+",
                delta: radar.bigRenewals.first.map {
                    "next: \(d.displayNames[$0.service.id] ?? $0.service.name) · \(DayText.short($0.date))"
                },
                deltaColor: DS.amber
            )
            KPI(
                label: "Money back",
                value: Money.exact(d.totalMoneyBack),
                caption: "\(Self.plural(d.refundClaims.filter(\.claim.isPending).count, "refund")) · \(d.lateWatch.count) late · \(d.watchingItems.count) watching",
                valueColor: d.totalMoneyBack > 0 ? DS.coral : DS.ink
            )
            KPI(
                label: "Kept & cuttable",
                value: Money.exact(sv.kept),
                caption: "avoided charges since \(since)",
                delta: cutMin > 0 ? "✂ \(Money.whole(cutMin))/mo across \(d.cutGroups.count) overlaps" : nil,
                deltaColor: DS.mint,
                valueColor: sv.kept > 0 ? DS.mint : DS.ink
            )
        }
    }

    static func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }

    static func monthDate(_ key: String) -> Date {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 2 else { return Date() }
        return Schedule.clampedDate(year: p[0], month: p[1], day: 1) ?? Date()
    }

    static func monthStart(_ d: Date) -> Date {
        let c = Schedule.calendar.dateComponents([.year, .month], from: d)
        return Schedule.clampedDate(year: c.year ?? 2000, month: c.month ?? 1, day: 1) ?? d
    }
}

// MARK: - Interactive Category & Burn Allocation Bar

private struct BurnAllocationBar: View {
    let burn: Insights.BurnBreakdown
    @ObservedObject var explorer: ExplorerState

    var body: some View {
        let total = max(burn.totalMonthly, 0.01)
        VStack(alignment: .leading, spacing: 9) {
            GeometryReader { geo in
                HStack(spacing: 2.5) {
                    ForEach(burn.byCategory) { c in
                        let selected = explorer.categoryFilter == nil || explorer.categoryFilter == c.label
                        RoundedRectangle(cornerRadius: 3)
                            .fill(DS.categoryColor(c.label).opacity(selected ? 0.92 : 0.26))
                            .frame(width: max(5, (geo.size.width - CGFloat(max(0, burn.byCategory.count - 1)) * 2.5) * c.monthly / total))
                            .onTapGesture {
                                explorer.toggleCategory(c.label, scroll: true)
                            }
                            .help("\(c.label): \(Money.exact(c.monthly))/mo (\(SpendShapePanel.percent(c.share))) — click to filter Ledger")
                    }
                }
            }
            .frame(height: 7)

            HStack(spacing: 8) {
                DSEyebrow(text: "ALLOCATION", color: DS.ink3)
                ForEach(burn.byCategory) { c in
                    AllocationPill(
                        slice: c,
                        selected: explorer.categoryFilter == c.label
                    ) {
                        explorer.toggleCategory(c.label, scroll: true)
                    }
                }
                Spacer(minLength: 4)
                if explorer.hasActiveLedgerFilters {
                    Button {
                        explorer.resetLedgerFilters()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                                .font(.system(size: 10))
                            Text("Reset filters")
                                .font(DS.mono(9.5, weight: .semibold))
                        }
                        .foregroundStyle(DS.amber)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: DS.radiusCard).fill(DS.surface))
        .overlay(RoundedRectangle(cornerRadius: DS.radiusCard).strokeBorder(DS.border, lineWidth: 1))
    }
}

private struct AllocationPill: View {
    let slice: Insights.BurnSlice
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Circle().fill(DS.categoryColor(slice.label)).frame(width: 6, height: 6)
                Text(slice.label)
                    .font(DS.display(11, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? DS.canvas : (hovering ? DS.ink : DS.ink2))
                Text(SpendShapePanel.percent(slice.share))
                    .font(DS.mono(10, weight: .semibold))
                    .foregroundStyle(selected ? DS.canvas.opacity(0.8) : DS.ink3)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(
                RoundedRectangle(cornerRadius: DS.radiusPill)
                    .fill(selected ? DS.amber : (hovering ? DS.elevated : DS.well))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusPill)
                    .strokeBorder(selected ? DS.amber : DS.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
    }
}

// MARK: - Observatory Mode Switcher Tab

private struct ObservatoryModeTab: View {
    let tab: DashboardTab
    let selected: Bool
    let badge: (String, Color)?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(tab.indexLabel)
                    .font(DS.mono(9.5, weight: .bold))
                    .foregroundStyle(selected ? DS.amber : DS.ink3)
                Text(tab.title)
                    .font(DS.display(12, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? DS.ink : (hovering ? DS.ink2 : DS.ink3))
                    .lineLimit(1)
                if let badge {
                    Text(badge.0)
                        .font(DS.mono(9.5, weight: .semibold))
                        .foregroundStyle(selected ? badge.1 : DS.ink3)
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(RoundedRectangle(cornerRadius: 4).fill(badge.1.opacity(selected ? 0.16 : 0.08)))
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 9.5)
            .padding(.vertical, 6.5)
            .background(
                RoundedRectangle(cornerRadius: DS.radiusWell)
                    .fill(selected ? DS.elevated : (hovering ? DS.surface : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusWell)
                    .strokeBorder(selected ? DS.border : Color.clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.radiusWell))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
    }
}

// MARK: - Cash Out by Month (Precomputed + Month-Quantized Hover)

struct CashOutPanel: View {
    let cashFlow: CashFlowData
    let monthlyRunRate: Double
    let today: Date
    @State private var selectedMonthKey: String?

    var body: some View {
        let key = selectedMonthKey ?? cashFlow.thisMonthKey
        let selDate = cashFlow.monthDates[key] ?? DashboardView.monthDate(key)
        let total = cashFlow.monthTotals[key] ?? 0
        let charged = cashFlow.settledByMonth[key] ?? 0
        let sched = cashFlow.scheduledByMonth[key] ?? 0
        let deltaVsRunRate = total - monthlyRunRate

        DSPanel(
            eyebrow: "CASHFLOW TRAJECTORY",
            title: "Cash out by month (settled vs scheduled)",
            subtitle: "Left of today = verified receipts, invoices & alerts · right of today = scheduled from plan cadences"
        ) {
            DSStatusPill(text: "RUN-RATE · \(Money.whole(monthlyRunRate))/MO", tint: DS.ink2)
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                Chart {
                    RectangleMark(
                        xStart: .value("From", today),
                        xEnd: .value("To", cashFlow.horizonEnd)
                    )
                    .foregroundStyle(DS.well.opacity(0.45))

                    ForEach(cashFlow.buckets) { b in
                        BarMark(
                            x: .value("Month", cashFlow.monthDates[b.month] ?? DashboardView.monthDate(b.month), unit: .month),
                            y: .value("USD", b.amount),
                            width: .ratio(0.62)
                        )
                        .foregroundStyle(by: .value("Category", b.category))
                        .opacity(selectedMonthKey == nil || selectedMonthKey == b.month ? (b.projected ? 0.72 : 1) : 0.36)
                    }

                    RuleMark(x: .value("Today", today))
                        .foregroundStyle(DS.amber)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .annotation(position: .top, alignment: .leading) {
                            Text("TODAY")
                                .font(DS.mono(9, weight: .bold))
                                .foregroundStyle(DS.amber)
                        }

                    if selectedMonthKey != nil {
                        RuleMark(x: .value("Selected", selDate, unit: .month))
                            .foregroundStyle(DS.ink.opacity(0.06))
                            .lineStyle(StrokeStyle(lineWidth: 34))
                    }
                }
                .chartForegroundStyleScale(domain: cashFlow.categories, range: cashFlow.categories.map(DS.categoryColor))
                .chartLegend(position: .bottom, alignment: .leading, spacing: 10)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .month)) { _ in
                        AxisValueLabel(format: .dateTime.month(.abbreviated), centered: true)
                            .font(DS.mono(9.5))
                            .foregroundStyle(DS.ink2)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { v in
                        AxisGridLine().foregroundStyle(DS.borderSubtle)
                        AxisValueLabel {
                            if let d = v.as(Double.self) {
                                Text(Money.whole(d)).font(DS.mono(9.5)).foregroundStyle(DS.ink3)
                            }
                        }
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        Color.clear
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let loc):
                                    guard let plotFrame = proxy.plotFrame else { return }
                                    let x = loc.x - geo[plotFrame].origin.x
                                    guard x >= 0, x <= geo[plotFrame].width,
                                          let d: Date = proxy.value(atX: x) else {
                                        if selectedMonthKey != nil { selectedMonthKey = nil }
                                        return
                                    }
                                    let mKey = Schedule.monthKey(d)
                                    if cashFlow.monthTotals[mKey] != nil, selectedMonthKey != mKey {
                                        selectedMonthKey = mKey
                                    }
                                case .ended:
                                    if selectedMonthKey != nil { selectedMonthKey = nil }
                                }
                            }
                    }
                }
                .frame(height: 250)

                HStack(spacing: 16) {
                    Text(DayText.month(selDate))
                        .font(DS.display(12, weight: .semibold))
                        .foregroundStyle(DS.ink)
                    Text(Money.exact(total))
                        .font(DS.mono(12, weight: .semibold))
                        .foregroundStyle(DS.amber)
                    if charged > 0 {
                        Text("settled \(Money.exact(charged))")
                            .font(DS.mono(11))
                            .foregroundStyle(DS.ink2)
                    }
                    if sched > 0 {
                        Text("scheduled \(Money.exact(sched))")
                            .font(DS.mono(11))
                            .foregroundStyle(DS.ink3)
                    }
                    if abs(deltaVsRunRate) >= 25 {
                        Text(deltaVsRunRate > 0
                             ? "+\(Money.whole(deltaVsRunRate)) vs avg mo (annual/term spike)"
                             : "−\(Money.whole(abs(deltaVsRunRate))) below avg mo")
                            .font(DS.mono(10.5))
                            .foregroundStyle(deltaVsRunRate > 0 ? DS.amber : DS.mint)
                    }
                    Spacer()
                    Text("hover month")
                        .font(DS.mono(10))
                        .foregroundStyle(DS.ink3)
                }
                .frame(height: 18)
            }
        }
    }
}

// MARK: - Payment Attribution (Interactive Account / Card Filter + Concentration Risk)

private struct PaymentAttributionPanel: View {
    let burn: Insights.BurnBreakdown
    @Binding var splitByCard: Bool
    @ObservedObject var explorer: ExplorerState

    var body: some View {
        let slices = splitByCard ? burn.byCard : burn.byAccount
        let maxVal = slices.map(\.monthly).max() ?? 1
        let topCard = burn.byCard.first(where: { $0.key != "unknown" })

        DSPanel(
            eyebrow: "PAYMENT ATTRIBUTION",
            title: splitByCard ? "Monthly spend by payment card" : "Monthly spend by account",
            subtitle: splitByCard
                ? "Click any card or wallet rail to filter its plans in the Ledger"
                : "Click any login / mailbox to filter its plans in the Ledger"
        ) {
            HStack(spacing: 6) {
                DSFilterChip(title: "By account", selected: !splitByCard) { splitByCard = false }
                DSFilterChip(title: "By card", selected: splitByCard) { splitByCard = true }
            }
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(slices) { s in
                    let target: AttributionFilter = splitByCard
                        ? .card(key: s.key, label: s.label)
                        : .account(s.key)
                    AttributionBarRow(
                        slice: s,
                        maxValue: maxVal,
                        selected: explorer.attributionFilter == target
                    ) {
                        explorer.toggleAttribution(target, scroll: true)
                    }
                }

                Rectangle().fill(DS.borderSubtle).frame(height: 1).padding(.top, 4)

                HStack(spacing: 14) {
                    if let topCard {
                        Stat(
                            label: "top rail",
                            value: "\(topCard.label) (\(SpendShapePanel.percent(topCard.share)))"
                        )
                    }
                    if burn.unmappedCardCount > 0 {
                        Stat(
                            label: "card unknown",
                            value: "\(burn.unmappedCardCount) active"
                        )
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

private struct AttributionBarRow: View {
    let slice: Insights.BurnSlice
    let maxValue: Double
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(slice.label)
                    .font(DS.mono(11, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? DS.amber : (hovering ? DS.ink : DS.ink2))
                    .lineLimit(1)
                    .frame(width: 196, alignment: .leading)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3).fill(DS.well).frame(height: 10)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(selected ? DS.mint : DS.amber)
                            .frame(width: max(3, geo.size.width * slice.monthly / max(maxValue, 0.01)), height: 10)
                    }
                    .frame(maxHeight: .infinity, alignment: .center)
                }
                .frame(height: 16)
                Text(SpendShapePanel.percent(slice.share))
                    .font(DS.mono(10.5))
                    .foregroundStyle(DS.ink3)
                    .frame(width: 34, alignment: .trailing)
                Text(Money.exact(slice.monthly))
                    .font(DS.mono(11.5, weight: .semibold))
                    .foregroundStyle(DS.ink)
                    .frame(width: 84, alignment: .trailing)
                Text("\(slice.count)")
                    .font(DS.mono(10.5))
                    .foregroundStyle(DS.ink3)
                    .frame(width: 22, alignment: .trailing)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(selected ? DS.amber.opacity(0.12) : (hovering ? DS.rowHover : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
    }
}

// MARK: - Multi-Month & Prepaid Term Windows

private struct TermsPanel: View {
    let items: [TermWindowItem]
    let domainRollup: DomainRollupData?
    let onSelectService: (Service) -> Void

    var body: some View {
        DSPanel(
            eyebrow: "PREPAID & ANNUAL",
            title: "Multi-month & yearly windows",
            subtitle: "Upfront commitments and elapsed runway · click any row to inspect"
        ) {
            VStack(spacing: 10) {
                ForEach(items) { item in
                    TermRow(item: item) {
                        onSelectService(item.service)
                    }
                }
                if let rollup = domainRollup {
                    DomainSummaryRow(rollup: rollup)
                }
            }
        }
    }
}

private struct TermRow: View {
    let item: TermWindowItem
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Circle().fill(DS.categoryColor(item.service.category)).frame(width: 6.5, height: 6.5)
                    Text(item.displayName)
                        .font(DS.display(12.5, weight: .medium))
                        .foregroundStyle(hovering ? DS.amber : DS.ink)
                        .lineLimit(1)
                    Spacer()
                    Text(Money.exact(item.service.amount ?? 0))
                        .font(DS.mono(12, weight: .semibold))
                        .foregroundStyle(DS.ink)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3).fill(DS.well)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(DS.categoryColor(item.service.category).opacity(0.88))
                            .frame(width: geo.size.width * item.fractionUsed)
                    }
                }
                .frame(height: 6)
                HStack {
                    Text("\(DayText.withYear(item.start)) → \(DayText.withYear(item.end))")
                        .font(DS.mono(10))
                        .foregroundStyle(DS.ink3)
                    Spacer()
                    Text(item.renews ? "renews in \(item.daysLeft)d" : "expires in \(item.daysLeft)d")
                        .font(DS.mono(10, weight: item.daysLeft <= 30 ? .semibold : .regular))
                        .foregroundStyle(item.daysLeft <= 30 ? DS.amber : DS.ink3)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? DS.rowHover : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
    }
}

private struct DomainSummaryRow: View {
    let rollup: DomainRollupData

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Circle().fill(DS.categoryColor(rollup.domains.first?.category ?? "")).frame(width: 6.5, height: 6.5)
                Text("Domains · \(rollup.domains.count)")
                    .font(DS.display(12.5, weight: .medium))
                    .foregroundStyle(DS.ink)
                Spacer()
                Text("\(Money.exact(rollup.yearlyTotal))/yr")
                    .font(DS.mono(12, weight: .semibold))
                    .foregroundStyle(DS.ink)
            }
            Text(rollup.sortedNames)
                .font(DS.display(10.5))
                .foregroundStyle(DS.ink3)
                .lineLimit(2)
            HStack {
                Text(rollup.missingPriceCount > 0 ? "\(rollup.missingPriceCount) without matched price" : "all prices matched")
                    .font(DS.mono(10))
                    .foregroundStyle(DS.ink3)
                Spacer()
                if let left = rollup.nextRenewalDays {
                    Text("next renewal in \(left)d")
                        .font(DS.mono(10))
                        .foregroundStyle(DS.ink3)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
    }
}

// MARK: - Actionable Triage Queue (Needs a Look)

private struct NeedsLookPanel: View {
    let ledger: Ledger
    let displayNames: [String: String]
    let scrollable: Bool
    let onSelectService: (Service) -> Void
    let onClearCheck: (Service) -> Void

    @State private var bucket: Bucket = .toCheck

    enum Bucket: String, CaseIterable {
        case toCheck = "To check"
        case unverified = "Unverified"
        case closing = "Closing"
        case all = "All"
    }

    var body: some View {
        let closing = ledger.closing
        let toCheck = ledger.needsLook.filter { $0.status != .unverified }
        let unverified = ledger.unverified
        let activeBucket: Bucket = {
            if bucket == .toCheck && toCheck.isEmpty && !closing.isEmpty { return .closing }
            if bucket == .toCheck && toCheck.isEmpty && !unverified.isEmpty { return .unverified }
            return bucket
        }()

        let items: [(service: Service, tint: Color, reason: String, canClearCheck: Bool)] = {
            switch activeBucket {
            case .toCheck:
                return toCheck.map { ($0, DS.amber, $0.check ?? "", true) }
            case .unverified:
                return unverified.map { ($0, DS.ink3, $0.check ?? "not confirmed still billing", $0.check != nil) }
            case .closing:
                return closing.map { ($0, DS.cyan, $0.note ?? $0.check ?? "closing", false) }
            case .all:
                return closing.map { ($0, DS.cyan, $0.note ?? $0.check ?? "closing", false) }
                    + toCheck.map { ($0, DS.amber, $0.check ?? "", true) }
                    + unverified.map { ($0, DS.ink3, $0.check ?? "not confirmed still billing", $0.check != nil) }
            }
        }()

        let visibleItems = scrollable ? items : Array(items.prefix(14))

        DSPanel(
            eyebrow: "TRIAGE QUEUE",
            title: "Needs a look",
            subtitle: "Click any item to inspect in Ledger · click ✓ once an audit note is resolved"
        ) {
            DSStatusPill(text: "\(closing.count + toCheck.count + unverified.count) ITEMS", tint: toCheck.isEmpty ? DS.ink3 : DS.amber)
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    DSFilterChip(title: "To check", selected: activeBucket == .toCheck, count: toCheck.count) { bucket = .toCheck }
                    DSFilterChip(title: "Unverified", selected: activeBucket == .unverified, count: unverified.count) { bucket = .unverified }
                    if !closing.isEmpty {
                        DSFilterChip(title: "Closing", selected: activeBucket == .closing, count: closing.count) { bucket = .closing }
                    }
                    DSFilterChip(title: "All", selected: activeBucket == .all, count: closing.count + toCheck.count + unverified.count) { bucket = .all }
                }

                if items.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(DS.mint)
                        Text("Zero items in this triage queue.")
                            .font(DS.display(12))
                            .foregroundStyle(DS.ink2)
                    }
                    .padding(.vertical, 16)
                } else if scrollable {
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(spacing: 2) {
                            ForEach(visibleItems, id: \.service.id) { entry in
                                TriageRow(
                                    service: entry.service,
                                    displayName: displayNames[entry.service.id] ?? entry.service.name,
                                    tint: entry.tint,
                                    reason: entry.reason,
                                    canClearCheck: entry.canClearCheck,
                                    onSelect: { onSelectService(entry.service) },
                                    onClear: { onClearCheck(entry.service) }
                                )
                            }
                        }
                    }
                    .frame(maxHeight: 330)
                } else {
                    VStack(spacing: 2) {
                        ForEach(visibleItems, id: \.service.id) { entry in
                            TriageRow(
                                service: entry.service,
                                displayName: displayNames[entry.service.id] ?? entry.service.name,
                                tint: entry.tint,
                                reason: entry.reason,
                                canClearCheck: entry.canClearCheck,
                                onSelect: { onSelectService(entry.service) },
                                onClear: { onClearCheck(entry.service) }
                            )
                        }
                        if items.count > visibleItems.count {
                            Text("+\(items.count - visibleItems.count) more in triage queue")
                                .font(DS.mono(10))
                                .foregroundStyle(DS.ink3)
                                .padding(.top, 4)
                        }
                    }
                }
            }
        }
    }
}

private struct TriageRow: View {
    let service: Service
    let displayName: String
    let tint: Color
    let reason: String
    let canClearCheck: Bool
    let onSelect: () -> Void
    let onClear: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onSelect) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle().fill(tint).frame(width: 6, height: 6)
                    Text(displayName)
                        .font(DS.display(12, weight: .medium))
                        .foregroundStyle(hovering ? DS.amber : DS.ink)
                        .lineLimit(1)
                        .frame(width: 185, alignment: .leading)
                    Text(Money.row(service))
                        .font(DS.mono(11.5, weight: .semibold))
                        .foregroundStyle(DS.ink2)
                        .frame(width: 68, alignment: .trailing)
                    Text(reason)
                        .font(DS.display(11))
                        .foregroundStyle(DS.ink3)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()

            if hovering {
                HStack(spacing: 4) {
                    if let u = service.safeManageURL {
                        Button {
                            NSWorkspace.shared.open(u)
                        } label: {
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(DS.ink2)
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .help("Open billing page")
                    }
                    if canClearCheck {
                        Button(action: onClear) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(DS.mint)
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .help("Mark reviewed & clear check flag")
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 5)
        .background(RoundedRectangle(cornerRadius: 4).fill(hovering ? DS.rowHover : Color.clear))
        .onHover { hovering = $0 }
        .help(reason)
    }
}

// MARK: - Complete Interactive Ledger Explorer

struct LedgerExplorerPanel: View {
    @EnvironmentObject var store: Store
    @Environment(\.isSnapshotRender) private var isSnapshotRender

    let ledger: Ledger
    let derived: Store.Derived
    let vaultKeysByServiceID: [String: [VaultKeyItem]]
    let scrollable: Bool
    @ObservedObject var explorer: ExplorerState

    private func computeFilteredRows() -> (rows: [Service], monthlySubtotal: Double) {
        let q = explorer.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let metaMap = derived.rowMeta
        let tf = explorer.typeFilter
        let cf = explorer.categoryFilter
        let af = explorer.attributionFilter
        let of = explorer.overlapFilter
        let hideDoms = explorer.hideDomains

        var matched: [Service] = []
        matched.reserveCapacity(ledger.services.count)
        var subtotal = 0.0

        for s in ledger.services {
            if hideDoms && s.isDomain { continue }
            if let cf, s.category != cf { continue }
            if let af, !af.matches(s) { continue }
            if let of, !of.memberIDs.contains(s.id) { continue }

            let m = metaMap[s.id]
            switch tf {
            case .all:
                if s.status == .cancelled { continue }
            case .dueSoon:
                if !(m?.isDueWithin7d ?? false) { continue }
            case .needsCheck:
                if !(s.status == .unverified || (s.status == .active && s.check != nil && !s.isClosing)) { continue }
            case .closing:
                if !s.isClosing { continue }
            case .monthly:
                if !(s.status == .active && [.monthly, .biweekly].contains(s.cadence)) { continue }
            case .yearly:
                if !(s.status == .active && (s.cadence.months ?? 0) >= 3) { continue }
            case .prepaid:
                if !(s.status == .active && s.cadence == .term) { continue }
            case .usage:
                if !(s.status == .active && s.cadence == .usage) { continue }
            case .unverified:
                if s.status != .unverified { continue }
            case .ended:
                if s.status != .cancelled { continue }
            }

            if !q.isEmpty {
                guard let hay = m?.searchHaystack, hay.contains(q) else { continue }
            }

            matched.append(s)
            subtotal += m?.monthlyEquiv ?? 0
        }

        let col = explorer.sortColumn
        let asc = explorer.sortAscending
        matched.sort { a, b in
            let ma = metaMap[a.id]
            let mb = metaMap[b.id]
            let cmp: Bool
            switch col {
            case .service:
                let na = ma?.displayName ?? a.name
                let nb = mb?.displayName ?? b.name
                if na == nb { return a.id < b.id }
                cmp = na.localizedCaseInsensitiveCompare(nb) == .orderedAscending
            case .type:
                let ta = ma?.typeLabel ?? a.typeLabel
                let tb = mb?.typeLabel ?? b.typeLabel
                if ta == tb { return (ma?.monthlySortKey ?? -1) > (mb?.monthlySortKey ?? -1) }
                cmp = ta < tb
            case .account:
                let aa = ma?.accountCardText ?? ""
                let ab = mb?.accountCardText ?? ""
                if aa == ab { return (ma?.monthlySortKey ?? -1) > (mb?.monthlySortKey ?? -1) }
                cmp = aa < ab
            case .cycle:
                let ca = ma?.cycleSortKey ?? -1
                let cb = mb?.cycleSortKey ?? -1
                if ca == cb { return a.name < b.name }
                cmp = ca < cb
            case .monthly:
                let va = ma?.monthlySortKey ?? -1
                let vb = mb?.monthlySortKey ?? -1
                if va == vb { return a.name < b.name }
                cmp = va < vb
            case .next:
                let na = ma?.nextSortTimestamp ?? 9e12
                let nb = mb?.nextSortTimestamp ?? 9e12
                if na == nb { return a.name < b.name }
                cmp = na < nb
            case .lastCharged:
                let la = ma?.lastChargedSortKey ?? ""
                let lb = mb?.lastChargedSortKey ?? ""
                if la == lb { return a.name < b.name }
                cmp = la < lb
            }
            return asc ? cmp : !cmp
        }

        return (matched, (subtotal * 100).rounded() / 100)
    }

    var body: some View {
        let (rows, subtotal) = computeFilteredRows()
        let sharePct = derived.monthlyTotal > 0 ? Int((subtotal / derived.monthlyTotal * 100).rounded()) : 0
        let domainCount = derived.domainRollup?.domains.count ?? 0

        DSPanel(
            eyebrow: "COMPLETE LEDGER EXPLORER",
            title: "All recurring items",
            subtitle: "\(rows.count) shown · click any column header to sort · click any row to inspect receipts, notes, Vault keys & actions"
        ) {
            HStack(spacing: 6) {
                if explorer.hasActiveLedgerFilters && subtotal > 0 {
                    DSStatusPill(text: "\(sharePct)% OF BURN", tint: DS.cyan)
                }
                DSStatusPill(
                    text: "\(rows.count) · \(Money.exact(subtotal))/MO · \(Money.whole(subtotal * 12))/YR",
                    tint: DS.amber
                )
            }
        } content: {
            VStack(alignment: .leading, spacing: 11) {
                // Row 1: Search bar + active cross-filters + domain collapse toggle
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(DS.ink3)
                        if isSnapshotRender {
                            Text("Search service, account, card, plan, note…")
                                .font(DS.display(11.5))
                                .foregroundStyle(DS.ink3)
                                .frame(width: 270, alignment: .leading)
                        } else {
                            TextField("Search service, account, card, plan, note…", text: $explorer.searchQuery)
                                .textFieldStyle(.plain)
                                .focusEffectDisabled()
                                .font(DS.display(11.5))
                                .foregroundStyle(DS.ink)
                                .frame(width: 270)
                            if !explorer.searchQuery.isEmpty {
                                Button {
                                    explorer.searchQuery = ""
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
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5.5)
                    .background(RoundedRectangle(cornerRadius: DS.radiusWell).fill(DS.well))
                    .overlay(RoundedRectangle(cornerRadius: DS.radiusWell).strokeBorder(DS.border, lineWidth: 1))

                    if let ov = explorer.overlapFilter {
                        ActiveCrossFilterChip(label: "Overlap: \(ov.name)") {
                            explorer.overlapFilter = nil
                        }
                    }
                    if let af = explorer.attributionFilter {
                        ActiveCrossFilterChip(label: af.pillLabel) {
                            explorer.attributionFilter = nil
                        }
                    }

                    Spacer(minLength: 4)

                    if domainCount > 0 {
                        DSFilterChip(
                            title: explorer.hideDomains ? "Domains hidden" : "Hide domains",
                            selected: explorer.hideDomains,
                            count: domainCount
                        ) {
                            explorer.hideDomains.toggle()
                        }
                    }

                    if explorer.hasActiveLedgerFilters {
                        DSChipButton(title: "Reset", icon: "arrow.counterclockwise") {
                            explorer.resetLedgerFilters()
                        }
                    }
                }

                // Row 2: Type / Triage filter chips with live counts
                horizontalChipStrip {
                    ForEach(LedgerTypeFilter.allCases, id: \.self) { f in
                        let cnt = derived.typeFilterCounts[f] ?? 0
                        if cnt > 0 || f == .all || explorer.typeFilter == f {
                            DSFilterChip(
                                title: f.rawValue,
                                selected: explorer.typeFilter == f,
                                count: cnt
                            ) {
                                explorer.typeFilter = f
                            }
                        }
                    }
                }

                // Row 3: Category filter chips with dots & counts
                horizontalChipStrip {
                    DSFilterChip(
                        title: "All categories",
                        selected: explorer.categoryFilter == nil
                    ) {
                        explorer.categoryFilter = nil
                    }
                    ForEach(derived.orderedCategories, id: \.self) { c in
                        DSFilterChip(
                            title: c,
                            selected: explorer.categoryFilter == c,
                            count: derived.categoryCounts[c],
                            dot: DS.categoryColor(c)
                        ) {
                            explorer.toggleCategory(c)
                        }
                    }
                }

                // Table Header + Rows (LazyVStack in live interactive mode; VStack in snapshot mode)
                VStack(spacing: 0) {
                    SortableTableHeader(
                        sortColumn: explorer.sortColumn,
                        ascending: explorer.sortAscending,
                        onSort: { explorer.toggleSort($0) }
                    )
                    Rectangle().fill(DS.border).frame(height: 1)

                    if rows.isEmpty {
                        VStack(spacing: 6) {
                            Text("No recurring items match the active filters.")
                                .font(DS.display(12.5, weight: .medium))
                                .foregroundStyle(DS.ink2)
                            if explorer.hasActiveLedgerFilters {
                                Button("Clear all filters") {
                                    explorer.resetLedgerFilters()
                                }
                                .buttonStyle(.plain)
                                .font(DS.mono(11, weight: .semibold))
                                .foregroundStyle(DS.amber)
                            }
                        }
                        .padding(.vertical, 28)
                        .frame(maxWidth: .infinity)
                    } else if scrollable {
                        LazyVStack(spacing: 0) {
                            ForEach(rows) { s in
                                ledgerRowBlock(for: s)
                            }
                        }
                    } else {
                        VStack(spacing: 0) {
                            ForEach(rows) { s in
                                ledgerRowBlock(for: s)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func horizontalChipStrip<C: View>(@ViewBuilder _ chips: () -> C) -> some View {
        if isSnapshotRender || !scrollable {
            HStack(spacing: 6) {
                chips()
                Spacer(minLength: 0)
            }
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chips()
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func ledgerRowBlock(for s: Service) -> some View {
        let meta = derived.rowMeta[s.id]
        let linkedKeys = vaultKeysByServiceID[s.id] ?? []
        let isExpanded = explorer.expandedServiceID == s.id

        VStack(spacing: 0) {
            if let meta {
                LedgerTableRow(
                    service: s,
                    meta: meta,
                    vaultKeyCount: linkedKeys.count,
                    isExpanded: isExpanded,
                    onToggleExpand: {
                        explorer.expandedServiceID = isExpanded ? nil : s.id
                    }
                )
            }
            if isExpanded {
                ServiceInspectorDrawer(
                    service: s,
                    displayName: meta?.displayName ?? s.name,
                    linkedKeys: linkedKeys,
                    onOpenVault: { store.openVaultForService(s) },
                    onToggleClosing: { store.setClosing(s.id, closing: !s.isClosing) },
                    onToggleCancelled: { store.setStatus(s.id, cancelled: s.status != .cancelled) },
                    onClearCheck: { store.clearCheck(s.id) },
                    onCopyID: { store.copyText(s.id, banner: "Copied service ID '\(s.id)'") }
                )
            }
            Rectangle().fill(DS.borderSubtle).frame(height: 1)
        }
        .id("row-\(s.id)")
    }
}

private struct ActiveCrossFilterChip: View {
    let label: String
    let onClear: () -> Void

    var body: some View {
        Button(action: onClear) {
            HStack(spacing: 5) {
                Text(label)
                    .font(DS.mono(10, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
            }
            .foregroundStyle(DS.cyan)
            .padding(.horizontal, 8.5)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: DS.radiusPill).fill(DS.cyan.opacity(0.14)))
            .overlay(RoundedRectangle(cornerRadius: DS.radiusPill).strokeBorder(DS.cyan.opacity(0.45), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }
}

private struct SortableTableHeader: View {
    let sortColumn: LedgerSortColumn
    let ascending: Bool
    let onSort: (LedgerSortColumn) -> Void

    var body: some View {
        HStack(spacing: 10) {
            headerCell(.service, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            headerCell(.type, width: 112, alignment: .leading)
            headerCell(.account, width: 182, alignment: .leading)
            headerCell(.cycle, width: 92, alignment: .trailing)
            headerCell(.monthly, width: 92, alignment: .trailing)
            headerCell(.next, width: 124, alignment: .leading)
            headerCell(.lastCharged, width: 100, alignment: .leading)
        }
        .padding(.vertical, 6.5)
        .padding(.horizontal, 4)
    }

    private func headerCell(_ col: LedgerSortColumn, width: CGFloat? = nil, alignment: Alignment) -> some View {
        let active = sortColumn == col
        let arrow = active ? (ascending ? " ▲" : " ▼") : ""
        return Button {
            onSort(col)
        } label: {
            Text(col.rawValue + arrow)
                .font(DS.mono(9.5, weight: active ? .bold : .semibold))
                .tracking(0.6)
                .foregroundStyle(active ? DS.amber : DS.ink3)
                .lineLimit(1)
                .frame(width: width, alignment: alignment)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }
}

private struct LedgerTableRow: View {
    let service: Service
    let meta: ServiceRowMeta
    let vaultKeyCount: Int
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    @State private var hovering = false

    var body: some View {
        let s = service
        let dim = s.status != .active
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(isExpanded ? DS.amber : DS.ink3.opacity(hovering ? 1 : 0.55))
                    .frame(width: 9)

                Circle()
                    .fill(DS.categoryColor(s.category))
                    .frame(width: 6.5, height: 6.5)

                VStack(alignment: .leading, spacing: 1.5) {
                    HStack(spacing: 5) {
                        Text(meta.displayName)
                            .font(DS.display(12.5, weight: .medium))
                            .foregroundStyle(isExpanded ? DS.amber : DS.ink)
                            .lineLimit(1)
                        if s.isClosing {
                            Text("CLOSING")
                                .font(DS.mono(8.5, weight: .bold))
                                .foregroundStyle(DS.cyan)
                        }
                        if meta.hasWarning {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(DS.amber)
                        }
                        if vaultKeyCount > 0 {
                            HStack(spacing: 2.5) {
                                Image(systemName: "key.fill")
                                    .font(.system(size: 8))
                                Text("\(vaultKeyCount)")
                                    .font(DS.mono(8.5, weight: .semibold))
                            }
                            .foregroundStyle(DS.mint)
                            .padding(.horizontal, 4.5)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 3).fill(DS.mint.opacity(0.12)))
                        }
                    }
                    if let sub = meta.subtitle {
                        Text(sub)
                            .font(DS.display(10.5))
                            .foregroundStyle(DS.ink3)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(meta.typeLabel)
                .font(DS.mono(10.5))
                .foregroundStyle(DS.ink2)
                .frame(width: 112, alignment: .leading)
                .lineLimit(1)

            Text(meta.accountCardText)
                .font(DS.mono(10.5))
                .foregroundStyle(DS.ink2)
                .frame(width: 182, alignment: .leading)
                .lineLimit(1)

            Text(meta.cycleText)
                .font(DS.mono(12, weight: .semibold))
                .foregroundStyle(DS.ink)
                .frame(width: 92, alignment: .trailing)

            Text(meta.monthlyText)
                .font(DS.mono(11.5))
                .foregroundStyle(DS.ink2)
                .frame(width: 92, alignment: .trailing)

            Text(meta.nextText)
                .font(DS.mono(11, weight: meta.nextUrgent ? .semibold : .regular))
                .foregroundStyle(meta.nextUrgent ? DS.amber : DS.ink2)
                .frame(width: 124, alignment: .leading)
                .lineLimit(1)

            Text(meta.lastChargedText)
                .font(DS.mono(11))
                .foregroundStyle(DS.ink3)
                .frame(width: 100, alignment: .leading)
        }
        .opacity(dim && !isExpanded ? 0.58 : 1)
        .padding(.vertical, 7.5)
        .padding(.horizontal, 4)
        .background(isExpanded ? DS.elevated : (hovering ? DS.rowHover : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggleExpand)
        .onHover { hovering = $0 }
        .contextMenu {
            Button(isExpanded ? "Collapse inspector" : "Inspect receipts & details") {
                onToggleExpand()
            }
            if let host = s.manageHost, let u = s.safeManageURL {
                Button("Open billing page — \(host)") { NSWorkspace.shared.open(u) }
            }
        }
    }
}

// MARK: - Inline Expandable Service Inspector Drawer

private struct ServiceInspectorDrawer: View {
    let service: Service
    let displayName: String
    let linkedKeys: [VaultKeyItem]
    let onOpenVault: () -> Void
    let onToggleClosing: () -> Void
    let onToggleCancelled: () -> Void
    let onClearCheck: () -> Void
    let onCopyID: () -> Void

    var body: some View {
        let s = service
        let sortedCharges = s.charges.sorted { $0.date > $1.date }
        let totalSettled = s.charges.map(\.amount).reduce(0, +)

        HStack(alignment: .top, spacing: 20) {
            // Column 1: Charge History & Sparkline
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    DSEyebrow(text: "RECEIPT TIMELINE (\(s.charges.count))", color: DS.amber)
                    Spacer()
                    if !s.charges.isEmpty {
                        Text("Net settled \(Money.exact(totalSettled))")
                            .font(DS.mono(10, weight: .semibold))
                            .foregroundStyle(DS.ink2)
                    }
                }

                if sortedCharges.isEmpty {
                    Text("No individual charges recorded on file yet.")
                        .font(DS.display(11.5))
                        .foregroundStyle(DS.ink3)
                        .padding(.vertical, 6)
                } else {
                    VStack(spacing: 4) {
                        ForEach(Array(sortedCharges.prefix(6).enumerated()), id: \.offset) { _, ch in
                            HStack(spacing: 8) {
                                Text(Schedule.parseDay(ch.date).map(DayText.withYear) ?? ch.date)
                                    .font(DS.mono(10.5))
                                    .foregroundStyle(DS.ink2)
                                    .frame(width: 92, alignment: .leading)
                                Text(ch.note ?? "settled")
                                    .font(DS.display(10.5))
                                    .foregroundStyle(DS.ink3)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(Money.exact(ch.amount))
                                    .font(DS.mono(11, weight: .semibold))
                                    .foregroundStyle(ch.amount < 0 ? DS.mint : DS.ink)
                            }
                        }
                        if sortedCharges.count > 6 {
                            Text("+\(sortedCharges.count - 6) earlier receipts on file")
                                .font(DS.mono(9.5))
                                .foregroundStyle(DS.ink3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .frame(width: 340, alignment: .topLeading)

            Rectangle().fill(DS.border).frame(width: 1)

            // Column 2: Provenance, Audit Notes, & Linked Vault API Keys
            VStack(alignment: .leading, spacing: 8) {
                DSEyebrow(text: "PROVENANCE & AUDIT", color: DS.ink3)

                HStack(spacing: 16) {
                    InspectorKV(label: "ID", value: s.id)
                    InspectorKV(label: "Account", value: s.account ?? "—")
                    InspectorKV(label: "Payment", value: s.card ?? "—")
                    if let nr = s.nextRenewal {
                        InspectorKV(label: "Next renewal floor", value: nr)
                    } else if let te = s.termEnd {
                        InspectorKV(label: "Term window", value: "\(s.termStart ?? "?") → \(te)")
                    }
                }

                if let check = s.check {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(DS.amber)
                        Text(check)
                            .font(DS.display(11.5))
                            .foregroundStyle(DS.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 6)
                        DSChipButton(title: "Clear flag", icon: "checkmark", tint: DS.mint) {
                            onClearCheck()
                        }
                    }
                    .padding(9)
                    .background(RoundedRectangle(cornerRadius: DS.radiusWell).fill(DS.amber.opacity(0.10)))
                    .overlay(RoundedRectangle(cornerRadius: DS.radiusWell).strokeBorder(DS.amber.opacity(0.35), lineWidth: 1))
                }

                if let note = s.note {
                    Text(note)
                        .font(DS.display(11))
                        .foregroundStyle(DS.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !linkedKeys.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(DS.mint)
                        Text("\(linkedKeys.count) linked Vault API key\(linkedKeys.count == 1 ? "" : "s"): "
                             + linkedKeys.map { "\($0.label) (\($0.tierLabel))" }.joined(separator: ", "))
                            .font(DS.display(11, weight: .medium))
                            .foregroundStyle(DS.ink2)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Button(action: onOpenVault) {
                            Text("Open in Vault →")
                                .font(DS.mono(10, weight: .semibold))
                                .foregroundStyle(DS.amber)
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                    }
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

            Rectangle().fill(DS.border).frame(width: 1)

            // Column 3: 1-Click Actions
            VStack(alignment: .leading, spacing: 7) {
                DSEyebrow(text: "ACTIONS", color: DS.ink3)

                if let u = s.safeManageURL {
                    DSChipButton(title: "Billing page ↗", icon: "safari", prominent: true) {
                        NSWorkspace.shared.open(u)
                    }
                }
                if s.status == .active {
                    DSChipButton(
                        title: s.isClosing ? "Clear closing" : "Mark closing",
                        icon: "hourglass",
                        tint: DS.cyan
                    ) {
                        onToggleClosing()
                    }
                }
                DSChipButton(
                    title: s.status == .cancelled ? "Reactivate plan" : "Mark ended",
                    icon: s.status == .cancelled ? "arrow.uturn.backward" : "xmark.circle",
                    tint: s.status == .cancelled ? DS.mint : DS.coral
                ) {
                    onToggleCancelled()
                }
                DSChipButton(title: "Copy CLI ID", icon: "doc.on.doc") {
                    onCopyID()
                }
            }
            .frame(width: 148, alignment: .topLeading)
        }
        .padding(14)
        .background(DS.well.opacity(0.65))
    }
}

private struct InspectorKV: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1.5) {
            Text(label.uppercased())
                .font(DS.mono(8.5, weight: .semibold))
                .foregroundStyle(DS.ink3)
            Text(value)
                .font(DS.mono(10.5, weight: .medium))
                .foregroundStyle(DS.ink)
                .lineLimit(1)
        }
    }
}

// MARK: - Executive KPI Card

struct KPI: View {
    let label: String
    let value: String
    let caption: String
    var delta: String? = nil
    var deltaColor: Color = DS.mint
    var valueColor: Color = DS.ink
    var accent: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            DSEyebrow(text: label, color: accent ?? DS.ink3)
            Text(value)
                .font(DS.display(26, weight: .bold))
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            if let delta {
                Text(delta)
                    .font(DS.mono(10.5, weight: .semibold))
                    .foregroundStyle(deltaColor)
                    .lineLimit(1)
            }
            Text(caption)
                .font(DS.display(11))
                .foregroundStyle(DS.ink3)
                .lineLimit(2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.radiusCard).fill(DS.surface))
        .overlay(alignment: .top) {
            if let accent {
                UnevenRoundedRectangle(
                    topLeadingRadius: DS.radiusCard,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: DS.radiusCard
                )
                .fill(accent)
                .frame(height: 2)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: DS.radiusCard).strokeBorder(DS.border, lineWidth: 1))
    }
}
