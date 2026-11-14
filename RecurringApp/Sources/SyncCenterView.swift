import SwiftUI

/// Observatory surface for real-time + hourly multi-mailbox invoice ingestion.
struct SyncCenterView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let s = store.syncState
        VStack(alignment: .leading, spacing: DS.gridGap) {
            daemonStrip(s)
            mailboxesPanel(s)
            HStack(alignment: .top, spacing: DS.gridGap) {
                recentEventsPanel(s)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                VStack(alignment: .leading, spacing: DS.gridGap) {
                    unassignedPanel(s)
                    channelBreakdownPanel(s)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Daemon Telemetry Strip

    private func daemonStrip(_ s: SyncSnapshot) -> some View {
        let liveColor = s.daemonAlive ? DS.mint : DS.amber
        return HStack(spacing: DS.gridGap) {
            SyncMetricCard(
                eyebrow: "ENGINE HEARTBEAT",
                value: s.daemonAlive ? "LIVE PUSH" : "STANDBY",
                caption: s.daemonAlive
                    ? "IMAP IDLE + 20s Gmail delta + hourly (pid \(s.daemonPID ?? 0))"
                    : "LaunchAgent starts automatically on install",
                accent: liveColor,
                showPulse: true
            )
            SyncMetricCard(
                eyebrow: "REACHABLE INBOXES",
                value: "\(s.reachableMailboxes) / \(s.totalMailboxes)",
                caption: "Gmail API · iCloud IMAP · Exchange OWA",
                accent: s.reachableMailboxes >= 4 ? DS.mint : DS.amber,
                showPulse: false
            )
            SyncMetricCard(
                eyebrow: "LAST RECONCILED",
                value: DayText.relativeISO(s.lastSyncAt),
                caption: "ledger as_of \(s.asOf ?? store.ledger?.asOf ?? "—")",
                accent: DS.amber,
                showPulse: false
            )
            SyncMetricCard(
                eyebrow: "INGESTED EVENTS",
                value: "\(s.recentEvents.count)",
                caption: "deduped receipts, Apple bills & card alerts",
                accent: DS.cyan,
                showPulse: false
            )
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: 5-Mailbox Status Grid

    private func mailboxesPanel(_ s: SyncSnapshot) -> some View {
        DSPanel(
            eyebrow: "CONFIGURED MAILBOXES",
            title: "Multi-inbox ingestion channels",
            subtitle: "iCloud runs persistent TLS IMAP IDLE · Gmail accounts run 20s historyId delta + hourly sweep · Exchange uses forwarding / OWA",
            accentBar: DS.mint
        ) {
            DSChipButton(
                title: store.isSyncingNow ? "Syncing…" : "Sync All Mailboxes Now",
                icon: "arrow.triangle.2.circlepath",
                prominent: true,
                disabled: store.isSyncingNow
            ) {
                Task { await store.syncInvoicesNow() }
            }
        } content: {
            if s.mailboxes.isEmpty {
                Text("No sync telemetry recorded yet — click 'Sync All Mailboxes Now' or run `recurring sync`.")
                    .font(DS.display(12))
                    .foregroundStyle(DS.ink3)
                    .padding(.vertical, 12)
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Text("MAILBOX").frame(width: 260, alignment: .leading)
                        Text("TRANSPORT").frame(width: 150, alignment: .leading)
                        Text("STATUS").frame(width: 120, alignment: .leading)
                        Text("LAST PASS").frame(width: 110, alignment: .leading)
                        Text("TELEMETRY").frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(DS.mono(9.5, weight: .semibold))
                    .tracking(0.7)
                    .foregroundStyle(DS.ink3)
                    .padding(.vertical, 6)

                    Rectangle().fill(DS.border).frame(height: 1)

                    ForEach(s.mailboxes) { m in
                        MailboxRow(item: m)
                        Rectangle().fill(DS.borderSubtle).frame(height: 1)
                    }
                }
            }
        }
    }

    // MARK: Recent Ingested Invoice Feed

    private func recentEventsPanel(_ s: SyncSnapshot) -> some View {
        let visible = Array(s.recentEvents.prefix(14))
        let grossCharges = s.recentEvents.filter { $0.amount > 0 }.map(\.amount).reduce(0, +)
        let refundCredits = abs(s.recentEvents.filter { $0.amount < 0 }.map(\.amount).reduce(0, +))

        return DSPanel(
            eyebrow: "INGESTION LOG",
            title: "Recent auto-recorded charges",
            subtitle: "Deduplicated across merchant receipts, Apple billing, PayPal & bank alerts",
            fillHeight: true
        ) {
            DSStatusPill(text: "\(s.recentEvents.count) recorded", tint: DS.mint)
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                if visible.isEmpty {
                    Text("No new charges ingested in the recent window.")
                        .font(DS.display(12))
                        .foregroundStyle(DS.ink3)
                        .padding(.vertical, 16)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(visible.enumerated()), id: \.element.id) { idx, ev in
                            if idx > 0 {
                                Rectangle().fill(DS.borderSubtle).frame(height: 1)
                            }
                            Button {
                                if let svc = store.derived?.servicesByID[ev.serviceID] {
                                    store.explorer.focusService(svc, scroll: true)
                                    store.selectedTab = .ledger
                                }
                            } label: {
                                HStack(spacing: 10) {
                                    Text(Schedule.parseDay(ev.date).map(DayText.short) ?? ev.date)
                                        .font(DS.mono(10.5, weight: .semibold))
                                        .foregroundStyle(DS.ink2)
                                        .frame(width: 56, alignment: .leading)

                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(ev.serviceName)
                                            .font(DS.display(12, weight: .medium))
                                            .foregroundStyle(DS.ink)
                                            .lineLimit(1)
                                        Text("\(ev.source) · \(ev.mailbox)")
                                            .font(DS.mono(9.5))
                                            .foregroundStyle(DS.ink3)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 8)
                                    Text(Money.exact(ev.amount))
                                        .font(DS.mono(11.5, weight: .semibold))
                                        .foregroundStyle(ev.amount < 0 ? DS.mint : DS.amber)
                                }
                                .padding(.vertical, 5.5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .focusEffectDisabled()
                            .help(ev.subject)
                        }
                    }
                }

                Spacer(minLength: 6)

                HStack(spacing: 14) {
                    Stat(label: "settled", value: Money.exact(grossCharges))
                    if refundCredits > 0 {
                        Stat(label: "credits", value: "−\(Money.exact(refundCredits))")
                    }
                    Stat(label: "net", value: Money.exact(grossCharges - refundCredits))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: DS.radiusWell).fill(DS.well.opacity(0.45)))
                .overlay(RoundedRectangle(cornerRadius: DS.radiusWell).strokeBorder(DS.borderSubtle, lineWidth: 1))
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
    }

    // MARK: Unassigned Subscription Candidates

    private func unassignedPanel(_ s: SyncSnapshot) -> some View {
        DSPanel(
            eyebrow: "DISCOVERY QUEUE",
            title: "Unassigned subscription-like receipts",
            subtitle: "Recurring-wording charges not yet mapped to an entry in subscriptions.json"
        ) {
            DSStatusPill(text: "\(s.unassignedCandidates.count) QUEUED", tint: s.unassignedCandidates.isEmpty ? DS.ink3 : DS.amber)
        } content: {
            if s.unassignedCandidates.isEmpty {
                Text("All detected recurring charges matched existing ledger entries.")
                    .font(DS.display(12))
                    .foregroundStyle(DS.ink3)
                    .padding(.vertical, 10)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(s.unassignedCandidates.prefix(8).enumerated()), id: \.element.id) { idx, u in
                        if idx > 0 {
                            Rectangle().fill(DS.borderSubtle).frame(height: 1)
                        }
                        HStack(spacing: 10) {
                            Text(Schedule.parseDay(u.date).map(DayText.short) ?? u.date)
                                .font(DS.mono(10.5))
                                .foregroundStyle(DS.ink3)
                                .frame(width: 56, alignment: .leading)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(u.merchant)
                                    .font(DS.display(12, weight: .medium))
                                    .foregroundStyle(DS.ink)
                                    .lineLimit(1)
                                Text(u.subject)
                                    .font(DS.display(10))
                                    .foregroundStyle(DS.ink3)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Text(Money.exact(u.amount))
                                .font(DS.mono(11.5, weight: .semibold))
                                .foregroundStyle(DS.ink2)
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
        }
    }

    // MARK: Channel & Source Rail Breakdown (Balances Right Column Flush to Ingestion Log)

    private func channelBreakdownPanel(_ s: SyncSnapshot) -> some View {
        var bySource: [String: (count: Int, amount: Double)] = [:]
        var byMailbox: [String: (count: Int, amount: Double)] = [:]
        for ev in s.recentEvents {
            let src = ev.source.isEmpty ? "receipt" : ev.source
            var sc = bySource[src] ?? (0, 0)
            sc.count += 1
            sc.amount += abs(ev.amount)
            bySource[src] = sc

            let mb = ev.mailbox.isEmpty ? "unknown" : ev.mailbox
            var mc = byMailbox[mb] ?? (0, 0)
            mc.count += 1
            mc.amount += max(0, ev.amount)
            byMailbox[mb] = mc
        }

        let sourceRows = bySource.map { (key: $0.key, count: $0.value.count, amount: $0.value.amount) }
            .sorted { $0.amount > $1.amount }
        let mailboxRows = byMailbox.map { (key: $0.key, count: $0.value.count, amount: $0.value.amount) }
            .sorted { $0.amount > $1.amount }
        let maxSrcAmt = max(sourceRows.map(\.amount).max() ?? 1, 0.01)
        let maxMboxAmt = max(mailboxRows.map(\.amount).max() ?? 1, 0.01)

        return DSPanel(
            eyebrow: "SOURCE & INBOX TELEMETRY",
            title: "Ingestion rail attribution",
            subtitle: "Classification across merchant receipts, invoices, card alerts, refunds & mailboxes",
            fillHeight: true
        ) {
            DSStatusPill(text: "SHA-256 DEDUPED", tint: DS.cyan)
        } content: {
            VStack(alignment: .leading, spacing: 9) {
                DSEyebrow(text: "By document class", color: DS.ink3)
                ForEach(sourceRows, id: \.key) { row in
                    let tint: Color = row.key == "refund" ? DS.mint : (row.key == "card_alert" ? DS.coral : (row.key == "invoice" ? DS.cyan : DS.amber))
                    HStack(spacing: 10) {
                        Text(row.key.replacingOccurrences(of: "_", with: " "))
                            .font(DS.mono(10.5, weight: .medium))
                            .foregroundStyle(DS.ink2)
                            .frame(width: 96, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3).fill(DS.well).frame(height: 8)
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(tint.opacity(0.9))
                                    .frame(width: max(3, geo.size.width * row.amount / maxSrcAmt), height: 8)
                            }
                            .frame(maxHeight: .infinity, alignment: .center)
                        }
                        .frame(height: 14)
                        Text("\(row.count)")
                            .font(DS.mono(10))
                            .foregroundStyle(DS.ink3)
                            .frame(width: 24, alignment: .trailing)
                        Text(Money.exact(row.amount))
                            .font(DS.mono(11, weight: .semibold))
                            .foregroundStyle(row.key == "refund" ? DS.mint : DS.ink)
                            .frame(width: 78, alignment: .trailing)
                    }
                }

                Rectangle().fill(DS.borderSubtle).frame(height: 1).padding(.vertical, 2)

                DSEyebrow(text: "By destination inbox", color: DS.ink3)
                ForEach(mailboxRows.prefix(4), id: \.key) { row in
                    HStack(spacing: 10) {
                        Text(row.key)
                            .font(DS.mono(10.5))
                            .foregroundStyle(DS.ink2)
                            .lineLimit(1)
                            .frame(width: 168, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3).fill(DS.well).frame(height: 8)
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(DS.mint.opacity(0.85))
                                    .frame(width: max(3, geo.size.width * row.amount / maxMboxAmt), height: 8)
                            }
                            .frame(maxHeight: .infinity, alignment: .center)
                        }
                        .frame(height: 14)
                        Text("\(row.count)")
                            .font(DS.mono(10))
                            .foregroundStyle(DS.ink3)
                            .frame(width: 20, alignment: .trailing)
                        Text(Money.exact(row.amount))
                            .font(DS.mono(11, weight: .semibold))
                            .foregroundStyle(DS.ink)
                            .frame(width: 78, alignment: .trailing)
                    }
                }

                Spacer(minLength: 6)

                HStack(spacing: 14) {
                    Stat(label: "push", value: "IMAP IDLE + 20s Δ")
                    Stat(label: "sweep", value: "hourly reconciliation")
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: DS.radiusWell).fill(DS.well.opacity(0.45)))
                .overlay(RoundedRectangle(cornerRadius: DS.radiusWell).strokeBorder(DS.borderSubtle, lineWidth: 1))
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

private struct SyncMetricCard: View {
    let eyebrow: String
    let value: String
    let caption: String
    let accent: Color
    let showPulse: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if showPulse { DSLiveDot(color: accent, size: 6.5) }
                DSEyebrow(text: eyebrow, color: accent)
            }
            Text(value)
                .font(DS.display(24, weight: .bold))
                .foregroundStyle(DS.ink)
            Spacer(minLength: 2)
            Text(caption)
                .font(DS.display(10.5))
                .foregroundStyle(DS.ink3)
                .lineLimit(1)
        }
        .padding(13)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: DS.radiusCard).fill(DS.surface))
        .overlay(alignment: .top) {
            UnevenRoundedRectangle(
                topLeadingRadius: DS.radiusCard,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: DS.radiusCard
            )
            .fill(accent.opacity(0.85))
            .frame(height: 2)
        }
        .overlay(RoundedRectangle(cornerRadius: DS.radiusCard).strokeBorder(DS.border, lineWidth: 1))
    }
}

private struct MailboxRow: View {
    let item: SyncMailboxStatus

    private var transportLabel: String {
        switch item.provider {
        case "gmail": return "Gmail API + 20s Δ"
        case "icloud": return "TLS IMAP IDLE :993"
        case "owa": return "Headless OWA"
        default: return item.provider.uppercased()
        }
    }

    private var badgeSpec: (text: String, tint: Color) {
        switch item.status {
        case "idle_live": return ("LIVE PUSH", DS.mint)
        case "ok": return ("SYNCED", DS.mint)
        case "reauth_needed": return ("REAUTH NEEDED", DS.amber)
        case "error": return ("ERROR", DS.coral)
        default: return (item.status.uppercased(), DS.ink3)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                DSLiveDot(color: badgeSpec.tint, size: 6)
                Text(item.email)
                    .font(DS.mono(11.5, weight: .medium))
                    .foregroundStyle(DS.ink)
                    .lineLimit(1)
            }
            .frame(width: 260, alignment: .leading)

            Text(transportLabel)
                .font(DS.mono(10.5))
                .foregroundStyle(DS.ink2)
                .frame(width: 150, alignment: .leading)

            DSStatusPill(text: badgeSpec.text, tint: badgeSpec.tint)
                .frame(width: 120, alignment: .leading)

            Text(DayText.relativeISO(item.lastCheckedAt))
                .font(DS.mono(10.5))
                .foregroundStyle(DS.ink3)
                .frame(width: 110, alignment: .leading)

            Text(item.detail)
                .font(DS.display(11))
                .foregroundStyle(DS.ink2)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8.5)
    }
}
