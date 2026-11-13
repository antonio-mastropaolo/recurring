import SwiftUI

/// Observatory surface for real-time + hourly multi-mailbox invoice ingestion.
struct SyncCenterView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let s = store.syncState
        VStack(alignment: .leading, spacing: 20) {
            daemonStrip(s)
            mailboxesPanel(s)
            HStack(alignment: .top, spacing: 18) {
                recentEventsPanel(s)
                unassignedPanel(s)
            }
        }
    }

    // MARK: Daemon Telemetry Strip

    private func daemonStrip(_ s: SyncSnapshot) -> some View {
        let liveColor = s.daemonAlive ? DS.mint : DS.amber
        return HStack(spacing: 12) {
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
        DSPanel(
            eyebrow: "INGESTION LOG",
            title: "Recent auto-recorded charges",
            subtitle: "Deduplicated across merchant receipts, Apple billing, PayPal & bank alerts"
        ) {
            DSStatusPill(text: "\(s.recentEvents.count) recorded", tint: DS.mint)
        } content: {
            if s.recentEvents.isEmpty {
                Text("No new charges ingested in the recent window.")
                    .font(DS.display(12))
                    .foregroundStyle(DS.ink3)
                    .padding(.vertical, 16)
            } else {
                VStack(spacing: 0) {
                    ForEach(s.recentEvents.prefix(20)) { ev in
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
                                    .frame(width: 58, alignment: .leading)

                                VStack(alignment: .leading, spacing: 1.5) {
                                    Text(ev.serviceName)
                                        .font(DS.display(12.5, weight: .medium))
                                        .foregroundStyle(DS.ink)
                                        .lineLimit(1)
                                    Text("\(ev.source) · \(ev.mailbox)")
                                        .font(DS.mono(10))
                                        .foregroundStyle(DS.ink3)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                Text(Money.exact(ev.amount))
                                    .font(DS.mono(12, weight: .semibold))
                                    .foregroundStyle(ev.amount < 0 ? DS.mint : DS.amber)
                            }
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .help(ev.subject)
                        Rectangle().fill(DS.borderSubtle).frame(height: 1)
                    }
                }
            }
        }
    }

    // MARK: Unassigned Subscription Candidates

    private func unassignedPanel(_ s: SyncSnapshot) -> some View {
        DSPanel(
            eyebrow: "DISCOVERY QUEUE",
            title: "Unassigned subscription-like receipts",
            subtitle: "Recurring-wording charges not yet mapped to an entry in subscriptions.json"
        ) {
            DSStatusPill(text: "\(s.unassignedCandidates.count)", tint: s.unassignedCandidates.isEmpty ? DS.ink3 : DS.amber)
        } content: {
            if s.unassignedCandidates.isEmpty {
                Text("All detected recurring charges matched existing ledger entries.")
                    .font(DS.display(12))
                    .foregroundStyle(DS.ink3)
                    .padding(.vertical, 16)
            } else {
                VStack(spacing: 0) {
                    ForEach(s.unassignedCandidates.prefix(15)) { u in
                        HStack(spacing: 10) {
                            Text(Schedule.parseDay(u.date).map(DayText.short) ?? u.date)
                                .font(DS.mono(10.5))
                                .foregroundStyle(DS.ink3)
                                .frame(width: 58, alignment: .leading)
                            VStack(alignment: .leading, spacing: 1.5) {
                                Text(u.merchant)
                                    .font(DS.display(12, weight: .medium))
                                    .foregroundStyle(DS.ink)
                                    .lineLimit(1)
                                Text(u.subject)
                                    .font(DS.display(10.5))
                                    .foregroundStyle(DS.ink3)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Text(Money.exact(u.amount))
                                .font(DS.mono(12, weight: .semibold))
                                .foregroundStyle(DS.ink2)
                        }
                        .padding(.vertical, 7)
                        Rectangle().fill(DS.borderSubtle).frame(height: 1)
                    }
                }
            }
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
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                if showPulse { DSLiveDot(color: accent, size: 6.5) }
                DSEyebrow(text: eyebrow, color: accent)
            }
            Text(value)
                .font(DS.display(24, weight: .bold))
                .foregroundStyle(DS.ink)
            Text(caption)
                .font(DS.display(11))
                .foregroundStyle(DS.ink3)
                .lineLimit(1)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.radiusCard).fill(DS.surface))
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
