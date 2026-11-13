import AppKit
import Charts
import SwiftUI

// MARK: - Renewals (30-Day Observatory Timeline)

struct RenewalsPanel: View {
    let radar: RenewalRadarData
    let displayNames: [String: String]
    let today: Date
    var onSelectService: (Service) -> Void = { _ in }

    @State private var selectedDayISO: String?

    var body: some View {
        let selRenewals: [Renewal] = selectedDayISO.flatMap { radar.byDayISO[$0] } ?? []
        let selDate: Date? = selectedDayISO.flatMap(Schedule.parseDay)

        DSPanel(
            eyebrow: "RENEWAL RADAR · 30D",
            title: "Upcoming renewals & cancel deadlines",
            subtitle: "Every scheduled charge stacked by category · click any \(Money.whole(Insights.bigRenewal))+ plan on the right to inspect or act",
            accentBar: DS.amber
        ) {
            HStack(spacing: 6) {
                DSStatusPill(text: "7D · \(Money.whole(radar.total7d))", tint: radar.total7d > 0 ? DS.amber : DS.ink3)
                DSStatusPill(text: "30D · \(radar.count30d) · \(Money.whole(radar.total30d))", tint: DS.amber)
            }
        } content: {
            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    Chart {
                        ForEach(radar.buckets) { b in
                            BarMark(x: .value("Day", b.day, unit: .day), y: .value("USD", b.amount))
                                .foregroundStyle(by: .value("Category", b.category))
                                .opacity(selectedDayISO == nil || selectedDayISO == b.dayISO ? 1 : 0.48)
                        }
                        RuleMark(y: .value("Big", Insights.bigRenewal))
                            .foregroundStyle(DS.ink3.opacity(0.6))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
                            .annotation(position: .top, alignment: .trailing) {
                                Text(Money.whole(Insights.bigRenewal))
                                    .font(DS.mono(9.5))
                                    .foregroundStyle(DS.ink3)
                            }
                        if let selDate {
                            RuleMark(x: .value("Selected", selDate, unit: .day))
                                .foregroundStyle(DS.amber.opacity(0.35))
                                .lineStyle(StrokeStyle(lineWidth: 1))
                        }
                    }
                    .chartXScale(domain: today...radar.endDay)
                    .chartForegroundStyleScale(domain: radar.categories, range: radar.categories.map(DS.categoryColor))
                    .chartLegend(.hidden)
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: 5)) { _ in
                            AxisGridLine().foregroundStyle(DS.borderSubtle)
                            AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                                .font(DS.mono(9.5))
                                .foregroundStyle(DS.ink3)
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { v in
                            AxisGridLine().foregroundStyle(DS.borderSubtle)
                            AxisValueLabel {
                                if let d = v.as(Double.self) {
                                    Text(Money.whole(d))
                                        .font(DS.mono(9.5))
                                        .foregroundStyle(DS.ink3)
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
                                            if selectedDayISO != nil { selectedDayISO = nil }
                                            return
                                        }
                                        let key = Schedule.isoDay(Schedule.calendar.startOfDay(for: d))
                                        if selectedDayISO != key {
                                            selectedDayISO = key
                                        }
                                    case .ended:
                                        if selectedDayISO != nil { selectedDayISO = nil }
                                    }
                                }
                        }
                    }
                    .frame(height: 360)

                    HStack(spacing: 14) {
                        if let selDate, !selRenewals.isEmpty {
                            let daySum = selRenewals.compactMap(\.amount).reduce(0, +)
                            Text("\(DayText.short(selDate)) · \(Money.exact(daySum))")
                                .font(DS.mono(11.5, weight: .semibold))
                                .foregroundStyle(DS.amber)
                            Text(selRenewals.map { r in
                                "\(displayNames[r.service.id] ?? r.service.name) \(Money.row(r.service))"
                            }.joined(separator: " · "))
                                .font(DS.display(11.5))
                                .foregroundStyle(DS.ink2)
                                .lineLimit(1)
                        } else if let selDate {
                            Text(DayText.short(selDate))
                                .font(DS.mono(11.5, weight: .semibold))
                                .foregroundStyle(DS.ink2)
                            Text("No scheduled renewals")
                                .font(DS.display(11.5))
                                .foregroundStyle(DS.ink3)
                        } else {
                            Stat(label: "7d cash", value: Money.exact(radar.total7d))
                            Stat(label: "30d total", value: Money.exact(radar.total30d))
                            Stat(label: "\(Money.whole(Insights.bigRenewal))+", value: "\(radar.bigRenewals.count) · \(Money.whole(radar.bigTotal))")
                            if let peak = radar.peakDayLabel {
                                Stat(label: "peak", value: peak)
                            }
                        }
                        Spacer(minLength: 4)
                        Text("hover day")
                            .font(DS.mono(10))
                            .foregroundStyle(DS.ink3)
                    }
                    .frame(height: 18)
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 0) {
                    DSEyebrow(text: "Cancel before renewal (\(Money.whole(Insights.bigRenewal))+)", color: DS.amber)
                        .padding(.bottom, 8)
                    if radar.bigRenewals.isEmpty {
                        Text("No \(Money.whole(Insights.bigRenewal))+ charges in the next 30 days.")
                            .font(DS.display(11.5))
                            .foregroundStyle(DS.ink3)
                    }
                    ForEach(radar.bigRenewals, id: \.self) { r in
                        BigRenewalRow(
                            renewal: r,
                            displayName: displayNames[r.service.id] ?? r.service.name,
                            today: today,
                            onSelect: { onSelectService(r.service) }
                        )
                        Rectangle().fill(DS.borderSubtle).frame(height: 1)
                    }
                }
                .frame(width: 416)
            }
        }
    }
}

private struct BigRenewalRow: View {
    let renewal: Renewal
    let displayName: String
    let today: Date
    let onSelect: () -> Void
    @State private var hovering = false

    var body: some View {
        let r = renewal
        let urgent = r.daysLeft <= 3
        HStack(spacing: 10) {
            Button(action: onSelect) {
                HStack(spacing: 10) {
                    CountdownPill(days: r.daysLeft)
                    Circle()
                        .fill(DS.categoryColor(r.service.category))
                        .frame(width: 6.5, height: 6.5)
                    VStack(alignment: .leading, spacing: 1.5) {
                        HStack(spacing: 5) {
                            Text(displayName)
                                .font(DS.display(12.5, weight: .medium))
                                .foregroundStyle(hovering ? DS.amber : DS.ink)
                                .lineLimit(1)
                            if r.service.isClosing {
                                Text("CLOSING")
                                    .font(DS.mono(8.5, weight: .bold))
                                    .foregroundStyle(DS.cyan)
                            }
                        }
                        Text(r.cancelBy.map { DayText.cancelBy($0, from: today) } ?? "charges today — too late to cancel")
                            .font(DS.display(10.5, weight: urgent ? .semibold : .regular))
                            .foregroundStyle(urgent ? DS.amber : DS.ink3)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    Text(Money.row(r.service))
                        .font(DS.mono(12.5, weight: .semibold))
                        .foregroundStyle(urgent ? DS.amber : DS.ink)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()

            if hovering, let u = r.service.safeManageURL {
                Button {
                    NSWorkspace.shared.open(u)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DS.amber)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("Open billing page: \(r.service.manageHost ?? "")")
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? DS.rowHover : Color.clear))
        .onHover { hovering = $0 }
        .help([r.service.account, r.service.card.map { "card \($0)" }, "Click to inspect in Ledger"]
            .compactMap { $0 }.joined(separator: " · "))
    }
}

struct CountdownPill: View {
    let days: Int

    var body: some View {
        let urgent = days <= 3
        Text(days == 0 ? "today" : days == 1 ? "1d" : "\(days)d")
            .font(DS.mono(10, weight: .bold))
            .foregroundStyle(urgent ? DS.canvas : DS.ink2)
            .frame(width: 50)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: DS.radiusPill).fill(urgent ? DS.amber : DS.well))
            .overlay(RoundedRectangle(cornerRadius: DS.radiusPill).strokeBorder(urgent ? DS.amber : DS.border, lineWidth: 1))
    }
}

struct Stat: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 5) {
            Text(label)
                .font(DS.display(11))
                .foregroundStyle(DS.ink3)
            Text(value)
                .font(DS.mono(11, weight: .semibold))
                .foregroundStyle(DS.ink)
        }
        .lineLimit(1)
        .fixedSize()
    }
}

// MARK: - Money Back & Watchlist

struct MoneyBackPanel: View {
    let claims: [(service: Service, claim: RefundClaim)]
    let pendingTotal: Double
    let wonTotal: Double
    let late: [WatchItem]
    let watching: [WatchItem]
    let clearedCount: Int
    let clearedNames: String
    let displayNames: [String: String]
    let today: Date
    var onSelectService: (Service) -> Void = { _ in }

    var body: some View {
        DSPanel(
            eyebrow: "RECOVERY & GUARDRAILS",
            title: "Money back & cancellation watch",
            subtitle: "Active refund claims · post-cancel charges · cancellations inside their renewal window",
            accentBar: (pendingTotal > 0 || !late.isEmpty) ? DS.coral : nil
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    BigFigure(value: Money.exact(pendingTotal), label: "to get back", color: pendingTotal > 0 ? DS.coral : DS.ink)
                    BigFigure(value: "\(late.count)", label: "charged after cancel", color: late.isEmpty ? DS.ink : DS.coral)
                    BigFigure(value: "\(watching.count)", label: "watching", color: watching.isEmpty ? DS.ink : DS.amber)
                    if wonTotal > 0 {
                        BigFigure(value: Money.exact(wonTotal), label: "refunded", color: DS.mint)
                    }
                    Spacer()
                }

                if !claims.isEmpty {
                    GroupSection(title: "REFUNDS", icon: "arrow.uturn.backward.circle", tint: DS.coral) {
                        ForEach(Array(claims.enumerated()), id: \.offset) { _, c in
                            InteractiveMiniLine(onTap: { onSelectService(c.service) }) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    DSStatusPill(text: c.claim.status.rawValue, tint: Self.color(c.claim.status))
                                    Text(displayNames[c.service.id] ?? c.service.name)
                                        .font(DS.display(12, weight: .medium))
                                        .foregroundStyle(DS.ink)
                                        .lineLimit(1)
                                    Text(c.claim.note ?? "")
                                        .font(DS.display(10.5))
                                        .foregroundStyle(DS.ink3)
                                        .lineLimit(1)
                                        .help(c.claim.note ?? "")
                                    Spacer(minLength: 6)
                                    Text(Money.exact(c.claim.amount))
                                        .font(DS.mono(12, weight: .semibold))
                                        .foregroundStyle(c.claim.isPending ? DS.ink : DS.ink3)
                                }
                            }
                        }
                    }
                }
                if !late.isEmpty {
                    GroupSection(title: "CHARGED AFTER CANCEL — CLAIM REFUND", icon: "exclamationmark.octagon", tint: DS.coral) {
                        ForEach(late, id: \.service.id) { w in
                            InteractiveMiniLine(onTap: { onSelectService(w.service) }) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(displayNames[w.service.id] ?? w.service.name)
                                        .font(DS.display(12, weight: .medium))
                                        .foregroundStyle(DS.ink)
                                        .lineLimit(1)
                                    Text("cancelled \(w.service.cancelledOn.flatMap(Schedule.parseDay).map(DayText.short) ?? "?") · charged "
                                         + w.lateCharges.map { Schedule.parseDay($0.date).map(DayText.short) ?? $0.date }.joined(separator: ", "))
                                        .font(DS.display(10.5))
                                        .foregroundStyle(DS.ink3)
                                        .lineLimit(1)
                                    Spacer(minLength: 6)
                                    Text(Money.exact(w.lateTotal))
                                        .font(DS.mono(12, weight: .semibold))
                                        .foregroundStyle(DS.coral)
                                }
                                .help(w.lateCharges.compactMap(\.note).joined(separator: "\n"))
                            }
                        }
                    }
                }
                if !watching.isEmpty {
                    GroupSection(title: "WATCHING RENEWAL WINDOW", icon: "eye", tint: DS.amber) {
                        ForEach(watching, id: \.service.id) { w in
                            let days = w.wouldCharge.map { Schedule.daysUntil($0, from: today) }
                            InteractiveMiniLine(onTap: { onSelectService(w.service) }) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(displayNames[w.service.id] ?? w.service.name)
                                        .font(DS.display(12, weight: .medium))
                                        .foregroundStyle(DS.ink)
                                        .lineLimit(1)
                                    Text(Self.watchText(w, days: days))
                                        .font(DS.display(10.5))
                                        .foregroundStyle(DS.ink3)
                                        .lineLimit(1)
                                    Spacer(minLength: 6)
                                    Text(Money.row(w.service))
                                        .font(DS.mono(12))
                                        .foregroundStyle(DS.ink2)
                                }
                            }
                        }
                    }
                }
                if clearedCount > 0 {
                    Label("\(clearedCount) recent cancellations cleared their renewal window with zero charges",
                          systemImage: "checkmark.circle.fill")
                        .font(DS.display(11))
                        .foregroundStyle(DS.mint)
                        .help(clearedNames)
                }
                if claims.isEmpty && late.isEmpty && watching.isEmpty && clearedCount == 0 {
                    Text("Nothing to chase, nothing to watch.")
                        .font(DS.display(12))
                        .foregroundStyle(DS.ink3)
                }
            }
        }
    }

    static func watchText(_ w: WatchItem, days: Int?) -> String {
        guard let d = w.wouldCharge, let days else { return "cancelled" }
        if days > 0 { return "would renew \(DayText.short(d)), in \(days) days — a charge then = refund" }
        if days == 0 { return "would renew today — a charge = refund" }
        return "renewal date \(DayText.short(d)) passed — nothing on file yet"
    }

    static func color(_ s: RefundStatus) -> Color {
        switch s {
        case .open: return DS.coral
        case .requested: return DS.amber
        case .won: return DS.mint
        case .lost: return DS.ink3
        }
    }
}

private struct InteractiveMiniLine<Content: View>: View {
    let onTap: () -> Void
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            content
                .padding(.vertical, 2)
                .padding(.horizontal, 4)
                .background(RoundedRectangle(cornerRadius: 4).fill(hovering ? DS.rowHover : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
    }
}

struct BigFigure: View {
    let value: String
    let label: String
    var color: Color = DS.ink

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(DS.display(22, weight: .bold))
                .foregroundStyle(color)
            Text(label)
                .font(DS.display(10.5))
                .foregroundStyle(DS.ink3)
        }
    }
}

private struct GroupSection<Content: View>: View {
    let title: String
    let icon: String
    let tint: Color
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(title).font(DS.mono(9.5, weight: .semibold)).tracking(0.6)
            }
            .foregroundStyle(tint)
            content
        }
    }
}

// MARK: - Savings

struct SavingsPanel: View {
    let savings: Savings
    let now: Double
    let closingCount: Int
    let cutsByMonth: [(month: String, monthly: Double)]

    private struct Step: Identifiable {
        let id: Int
        let label: String
        let from: Double
        let to: Double
        let kind: Kind
        enum Kind { case total, cut, closing }
    }

    var body: some View {
        let steps = Self.steps(savings, now: now)
        let maxX = (steps.map { max($0.from, $0.to) }.max() ?? 1) * 1.08

        DSPanel(
            eyebrow: "RUN-RATE DELTA",
            title: "Savings from cancellations",
            subtitle: "Cancelled since \(DayText.short(savings.since)) — monthly burn removed and projected floor once closing plans end",
            accentBar: DS.mint
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    BigFigure(value: "−\(Money.exact(savings.monthly))", label: "per month", color: DS.mint)
                    BigFigure(value: "−\(Money.whole(savings.yearly))", label: "per year", color: DS.mint)
                    BigFigure(value: Money.exact(savings.kept), label: "kept so far", color: DS.ink)
                    Spacer()
                }
                Chart(steps) { s in
                    BarMark(
                        xStart: .value("From", min(s.from, s.to)),
                        xEnd: .value("To", max(s.from, s.to)),
                        y: .value("Step", s.label),
                        height: .ratio(0.60)
                    )
                    .foregroundStyle(Self.color(s.kind))
                    .annotation(position: .trailing, alignment: .leading, spacing: 4) {
                        Text(s.kind == .total ? Money.whole(s.to) : "−\(Money.whole(abs(s.from - s.to)))")
                            .font(DS.mono(9.5, weight: .semibold))
                            .foregroundStyle(s.kind == .total ? DS.ink2 : Self.color(s.kind))
                    }
                }
                .chartXScale(domain: 0...maxX)
                .chartYScale(domain: steps.map(\.label))
                .chartXAxis {
                    AxisMarks(position: .bottom) { v in
                        AxisGridLine().foregroundStyle(DS.borderSubtle)
                        AxisValueLabel {
                            if let d = v.as(Double.self) {
                                Text(Money.whole(d)).font(DS.mono(9.5)).foregroundStyle(DS.ink3)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks { _ in
                        AxisValueLabel().font(DS.display(10.5)).foregroundStyle(DS.ink2)
                    }
                }
                .frame(height: CGFloat(steps.count) * 24 + 24)

                VStack(alignment: .leading, spacing: 6) {
                    DSEyebrow(text: "Monthly burn cut by month")
                    Chart(Array(cutsByMonth.enumerated()), id: \.offset) { _, m in
                        BarMark(
                            x: .value("Month", DashboardView.monthDate(m.month), unit: .month),
                            y: .value("USD", m.monthly),
                            width: .ratio(0.55)
                        )
                        .foregroundStyle(DS.mint.opacity(0.85))
                        .annotation(position: .top) {
                            if m.monthly > 0 {
                                Text(Money.whole(m.monthly))
                                    .font(DS.mono(9))
                                    .foregroundStyle(DS.ink3)
                            }
                        }
                    }
                    .chartYAxis(.hidden)
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .month)) { _ in
                            AxisValueLabel(format: .dateTime.month(.abbreviated), centered: true)
                                .font(DS.mono(9.5))
                                .foregroundStyle(DS.ink3)
                        }
                    }
                    .frame(height: 88)
                }
            }
        }
    }

    private static func steps(_ s: Savings, now: Double) -> [Step] {
        var out: [Step] = []
        let before = now + s.monthly
        out.append(Step(id: 0, label: "Before cuts", from: 0, to: before, kind: .total))
        var running = before
        for (i, c) in s.items.prefix(5).enumerated() {
            out.append(Step(id: i + 1, label: Self.short(c.service.name), from: running, to: running - c.monthly, kind: .cut))
            running -= c.monthly
        }
        let rest = s.items.dropFirst(5).map(\.monthly).reduce(0, +)
        if rest > 0 {
            out.append(Step(id: 20, label: "\(s.items.count - 5) more", from: running, to: running - rest, kind: .cut))
            running -= rest
        }
        out.append(Step(id: 30, label: "Current", from: 0, to: now, kind: .total))
        if s.closingMonthly > 0 {
            out.append(Step(id: 31, label: "Closing", from: now, to: now - s.closingMonthly, kind: .closing))
            out.append(Step(id: 32, label: "Target floor", from: 0, to: now - s.closingMonthly, kind: .total))
        }
        return out
    }

    private static func short(_ name: String) -> String {
        let base = name.components(separatedBy: " (").first ?? name
        return base.count > 20 ? String(base.prefix(19)) + "…" : base
    }

    private static func color(_ k: Step.Kind) -> Color {
        switch k {
        case .total: return DS.ink3.opacity(0.45)
        case .cut: return DS.mint
        case .closing: return DS.cyan
        }
    }
}

// MARK: - Where to Cut (Interactive Overlap Filter)

struct CutPanel: View {
    let groups: [CutGroup]
    let rowMeta: [String: ServiceRowMeta]
    @ObservedObject var explorer: ExplorerState

    var body: some View {
        let atLeast = groups.map(\.saveMin).reduce(0, +)
        DSPanel(
            eyebrow: "OVERLAP CONSOLIDATION",
            title: "Where to cut",
            subtitle: "Duplicate accounts or overlapping plans · click any group to compare & trim in Ledger"
        ) {
            if explorer.overlapFilter != nil {
                DSChipButton(title: "Clear filter", icon: "xmark") {
                    explorer.overlapFilter = nil
                }
            }
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                if groups.isEmpty {
                    Text("No overlaps detected. Assign `recurring set ID group=\"AI assistants\"` to compare substitutes.")
                        .font(DS.display(11.5))
                        .foregroundStyle(DS.ink3)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 18) {
                        BigFigure(value: "−\(Money.exact(atLeast))", label: "a month keeping one per group", color: DS.mint)
                        BigFigure(value: "−\(Money.whole(atLeast * 12))", label: "a year", color: DS.mint)
                        Spacer()
                    }
                }
                ForEach(groups, id: \.name) { g in
                    CutGroupRow(
                        group: g,
                        rowMeta: rowMeta,
                        selected: explorer.overlapFilter?.name == g.name
                    ) {
                        explorer.toggleOverlap(g, scroll: true)
                    }
                }
            }
        }
    }
}

private struct CutGroupRow: View {
    let group: CutGroup
    let rowMeta: [String: ServiceRowMeta]
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let g = group
        let costs = g.members.map { rowMeta[$0.id]?.monthlyEquiv ?? 0 }
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(g.name)
                        .font(DS.display(13, weight: .semibold))
                        .foregroundStyle(selected ? DS.amber : DS.ink)
                    Text(g.auto ? "same service ×\(g.members.count)" : "\(g.members.count) plans")
                        .font(DS.mono(10))
                        .foregroundStyle(DS.ink3)
                    if selected {
                        DSStatusPill(text: "FILTERED", tint: DS.amber, filled: true)
                    }
                    Spacer()
                    Text("\(Money.exact(g.monthly))/mo")
                        .font(DS.mono(12, weight: .semibold))
                        .foregroundStyle(DS.ink)
                }
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(Array(g.members.enumerated()), id: \.element.id) { i, s in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(DS.categoryColor(s.category).opacity(i == 0 ? 0.95 : 0.5))
                                .frame(width: max(4, (geo.size.width - CGFloat(g.members.count - 1) * 2) * costs[i] / max(g.monthly, 0.01)))
                        }
                    }
                }
                .frame(height: 10)
                Text(zip(g.members, costs).map {
                    let disp = rowMeta[$0.0.id]?.displayName ?? $0.0.name
                    return "\(disp) \(Money.whole($0.1))"
                }.joined(separator: "   ·   "))
                    .font(DS.display(10.5))
                    .foregroundStyle(DS.ink2)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack {
                    Label(
                        g.saveMin == g.saveMax
                            ? "keep one → save \(Money.exact(g.saveMin))/mo"
                            : "keep one → save \(Money.exact(g.saveMin))–\(Money.exact(g.saveMax))/mo",
                        systemImage: "scissors"
                    )
                    .font(DS.mono(10.5, weight: .semibold))
                    .foregroundStyle(DS.mint)
                    Spacer()
                    Text(hovering || selected ? "inspect in ledger →" : "")
                        .font(DS.mono(9.5))
                        .foregroundStyle(DS.amber)
                }
            }
            .padding(9)
            .background(
                RoundedRectangle(cornerRadius: DS.radiusWell)
                    .fill(selected ? DS.elevated : (hovering ? DS.rowHover : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusWell)
                    .strokeBorder(selected ? DS.amber.opacity(0.6) : (hovering ? DS.border : Color.clear), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.radiusWell))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
    }
}

// MARK: - Spend Shape (Category Donut + Cadence Structure + Interactive Filter)

struct SpendShapePanel: View {
    let burn: Insights.BurnBreakdown
    @ObservedObject var explorer: ExplorerState

    var body: some View {
        let cats = burn.byCategory
        let total = burn.totalMonthly

        DSPanel(
            eyebrow: "ALLOCATION & CADENCE",
            title: "Where the money goes",
            subtitle: "Click any category to filter the Ledger · cadence split shows fixed vs committed vs usage"
        ) {
            if explorer.categoryFilter != nil {
                DSChipButton(title: "All categories", icon: "xmark") {
                    explorer.categoryFilter = nil
                }
            }
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 22) {
                    ZStack {
                        Chart(cats) { c in
                            SectorMark(angle: .value("USD", c.monthly), innerRadius: .ratio(0.66), angularInset: 1.5)
                                .cornerRadius(3)
                                .foregroundStyle(DS.categoryColor(c.label))
                                .opacity(explorer.categoryFilter == nil || explorer.categoryFilter == c.label ? 1 : 0.35)
                        }
                        .frame(width: 178, height: 178)
                        VStack(spacing: 1) {
                            Text(Money.whole(total))
                                .font(DS.display(20, weight: .bold))
                                .foregroundStyle(DS.ink)
                            Text("/month")
                                .font(DS.mono(10))
                                .foregroundStyle(DS.ink3)
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(cats) { c in
                            CategorySliceButton(
                                slice: c,
                                selected: explorer.categoryFilter == c.label
                            ) {
                                explorer.toggleCategory(c.label, scroll: true)
                            }
                        }
                        Rectangle().fill(DS.borderSubtle).frame(height: 1).padding(.vertical, 4)
                        StatLine(
                            label: "Top 5 plans",
                            value: "\(Int((burn.top5Share * 100).rounded()))% of spend",
                            detail: burn.top5Names.joined(separator: ", ")
                        )
                        StatLine(
                            label: "Typical plan",
                            value: "\(Money.exact(burn.medianMonthly)) median · \(Money.exact(burn.averageMonthly)) avg",
                            detail: nil
                        )
                        StatLine(
                            label: "Under $10",
                            value: "\(burn.under10Count) plans = \(Money.exact(burn.under10Monthly))/mo",
                            detail: nil
                        )
                    }
                }

                // Cadence Structure Strip (Fixed Monthly vs Multi-month vs Prepaid vs Usage)
                VStack(alignment: .leading, spacing: 6) {
                    DSEyebrow(text: "Commitment structure")
                    CadenceMixBar(burn: burn)
                }
            }
        }
    }

    static func percent(_ f: Double) -> String {
        f > 0 && f < 0.005 ? "<1%" : "\(Int((f * 100).rounded()))%"
    }
}

private struct CategorySliceButton: View {
    let slice: Insights.BurnSlice
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Circle().fill(DS.categoryColor(slice.label)).frame(width: 7.5, height: 7.5)
                Text(slice.label)
                    .font(DS.display(12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? DS.amber : (hovering ? DS.ink : DS.ink2))
                    .lineLimit(1)
                Text("· \(slice.count)")
                    .font(DS.mono(10))
                    .foregroundStyle(DS.ink3)
                Spacer(minLength: 6)
                Text(SpendShapePanel.percent(slice.share))
                    .font(DS.mono(11, weight: .semibold))
                    .foregroundStyle(DS.ink)
                    .frame(width: 38, alignment: .trailing)
                Text(Money.whole(slice.monthly))
                    .font(DS.mono(11))
                    .foregroundStyle(DS.ink3)
                    .frame(width: 58, alignment: .trailing)
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

private struct CadenceMixBar: View {
    let burn: Insights.BurnBreakdown

    var body: some View {
        let total = max(burn.totalMonthly, 0.01)
        let segments: [(label: String, amount: Double, color: Color)] = [
            ("Fixed monthly", burn.fixedMonthly, DS.amber),
            ("Annual / multi-mo", burn.multiMonthMonthly, DS.cyan),
            ("Prepaid term", burn.prepaidTermMonthly, DS.violet),
            ("Variable usage", burn.usageMonthly, DS.mint),
        ].filter { $0.amount > 0 }

        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(seg.color.opacity(0.88))
                            .frame(width: max(4, (geo.size.width - CGFloat(max(0, segments.count - 1)) * 2) * seg.amount / total))
                    }
                }
            }
            .frame(height: 8)

            HStack(spacing: 14) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                    HStack(spacing: 4.5) {
                        Circle().fill(seg.color).frame(width: 6, height: 6)
                        Text(seg.label)
                            .font(DS.display(10.5))
                            .foregroundStyle(DS.ink3)
                        Text(Money.whole(seg.amount))
                            .font(DS.mono(10.5, weight: .semibold))
                            .foregroundStyle(DS.ink2)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

private struct StatLine: View {
    let label: String
    let value: String
    let detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(DS.display(11))
                .foregroundStyle(DS.ink3)
                .frame(width: 84, alignment: .leading)
            Text(value)
                .font(DS.mono(11, weight: .semibold))
                .foregroundStyle(DS.ink)
            Spacer(minLength: 0)
        }
        .help(detail ?? "")
    }
}

// MARK: - Charge Calendar Heatmap (Precomputed + Interactive Day Settlement Readout)

struct ChargeCalendarPanel: View {
    let heatmap: CalendarHeatmapData
    var onSelectServiceID: (String) -> Void = { _ in }

    @State private var selectedDayISO: String?
    @State private var pinnedDayISO: String?

    static let weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    private var activeDayISO: String? { pinnedDayISO ?? selectedDayISO }

    var body: some View {
        let activeISO = activeDayISO
        let activeCharges = activeISO.flatMap { heatmap.byDayISO[$0] } ?? []
        let activeDate = activeISO.flatMap(Schedule.parseDay)

        DSPanel(
            eyebrow: "SETTLEMENT CADENCE",
            title: "Charge calendar",
            subtitle: "Recorded charges over the last 20 weeks · hover or click any day to inspect receipts"
        ) {
            if pinnedDayISO != nil {
                DSChipButton(title: "Unpin day", icon: "xmark") {
                    pinnedDayISO = nil
                }
            }
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 5) {
                    VStack(alignment: .trailing, spacing: 3.5) {
                        ForEach(Self.weekdays, id: \.self) { d in
                            Text(["Mon", "Wed", "Fri"].contains(d) ? d : " ")
                                .font(DS.mono(9))
                                .foregroundStyle(DS.ink3)
                                .frame(height: 19)
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)

                    ForEach(Array(heatmap.weekLabels.enumerated()), id: \.offset) { i, w in
                        let shortWeek = w.components(separatedBy: "#").first ?? w
                        VStack(alignment: .leading, spacing: 3.5) {
                            ForEach(Self.weekdays, id: \.self) { d in
                                let cell = heatmap.byID[w + "|" + d]
                                CalendarDaySquare(
                                    cell: cell,
                                    maxAmount: heatmap.maxAmount,
                                    isSelected: cell != nil && cell?.dayISO == activeISO,
                                    onHover: { inside in
                                        guard let iso = cell?.dayISO else { return }
                                        if inside {
                                            if selectedDayISO != iso { selectedDayISO = iso }
                                        } else if selectedDayISO == iso {
                                            selectedDayISO = nil
                                        }
                                    },
                                    onTap: {
                                        guard let iso = cell?.dayISO else { return }
                                        pinnedDayISO = (pinnedDayISO == iso) ? nil : iso
                                    }
                                )
                            }
                            Text(i % 4 == 0 ? shortWeek : " ")
                                .font(DS.mono(8.5))
                                .foregroundStyle(DS.ink3)
                                .fixedSize()
                                .frame(width: 19, alignment: .leading)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }

                if let activeDate {
                    let sum = activeCharges.map(\.amount).reduce(0, +)
                    HStack(spacing: 8) {
                        Text(DayText.weekdayDate(activeDate))
                            .font(DS.mono(10.5, weight: .semibold))
                            .foregroundStyle(DS.amber)
                        if activeCharges.isEmpty {
                            Text("No charges settled")
                                .font(DS.display(11))
                                .foregroundStyle(DS.ink3)
                        } else {
                            Text(Money.exact(sum))
                                .font(DS.mono(11, weight: .bold))
                                .foregroundStyle(DS.ink)
                            Text("·")
                                .foregroundStyle(DS.ink3)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(activeCharges) { ch in
                                        Button {
                                            onSelectServiceID(ch.serviceID)
                                        } label: {
                                            HStack(spacing: 4) {
                                                Circle().fill(DS.categoryColor(ch.category)).frame(width: 5.5, height: 5.5)
                                                Text(ch.serviceName)
                                                    .font(DS.display(11, weight: .medium))
                                                    .foregroundStyle(DS.ink2)
                                                Text(Money.exact(ch.amount))
                                                    .font(DS.mono(10.5, weight: .semibold))
                                                    .foregroundStyle(DS.ink)
                                            }
                                        }
                                        .buttonStyle(.plain)
                                        .focusEffectDisabled()
                                    }
                                }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(height: 18)
                } else {
                    HStack(spacing: 16) {
                        Stat(label: "settled", value: "\(heatmap.settledDays)d · \(Money.whole(heatmap.totalAmount))")
                        if let peak = heatmap.peakLabel { Stat(label: "peak", value: peak) }
                        if let busiest = heatmap.busiestWeekday { Stat(label: "busiest", value: busiest) }
                        if let fh = heatmap.firstHalfPercent { Stat(label: "1st–15th", value: "\(fh)%") }
                        Spacer(minLength: 0)
                    }
                    .frame(height: 18)
                    .help("\(heatmap.totalChargeCount) charges recorded in total")
                }
            }
        }
    }
}

private struct CalendarDaySquare: View {
    let cell: CalendarCellData?
    let maxAmount: Double
    let isSelected: Bool
    let onHover: (Bool) -> Void
    let onTap: () -> Void

    var body: some View {
        RoundedRectangle(cornerRadius: 3.5)
            .fill(Self.shade(cell?.amount, max: maxAmount))
            .frame(maxWidth: .infinity)
            .frame(height: 19)
            .overlay(
                RoundedRectangle(cornerRadius: 3.5)
                    .strokeBorder(isSelected ? DS.amber : Color.clear, lineWidth: 1.2)
            )
            .opacity(cell == nil ? 0 : 1)
            .onHover { inside in
                guard cell != nil else { return }
                onHover(inside)
            }
            .onTapGesture {
                guard cell != nil else { return }
                onTap()
            }
    }

    private static func shade(_ amount: Double?, max maxA: Double) -> Color {
        guard let a = amount, a > 0 else { return DS.well }
        return DS.amber.opacity(0.22 + 0.78 * log1p(a) / log1p(Swift.max(maxA, 1)))
    }
}
