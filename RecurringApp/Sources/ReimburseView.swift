import AppKit
import SwiftUI

/// Observatory `04 · Reimburse` surface — native UI for `recurring wm-cloud` / `recurring reimburse`.
/// Compiles deterministic per-provider paid-receipt PDFs across `[since..until]`, pairs 1:1 IT approvals,
/// runs the 5-point anti-hallucination gate (`claimed == embedded PDF pages`), packages `<slug>.zip`,
/// and previews `approval-notice.txt` (never auto-sends).
struct ReimburseView: View {
    @EnvironmentObject var store: Store
    @Environment(\.isSnapshotRender) private var isSnapshotRender

    private enum AuditTab: String, CaseIterable, Identifiable {
        case included = "Included"
        case blocked = "Blocked"
        case excluded = "Excluded / Deduped"
        case approvals = "IT Approvals"
        var id: String { rawValue }
    }

    @State private var sinceInput: String = ""
    @State private var untilInput: String = ""
    @State private var withCover: Bool = false
    @State private var selectedAuditTab: AuditTab = .included
    @State private var didSeedDates: Bool = false

    private var rState: ReimburseSnapshot { store.reimburse }
    private var pkt: ReimbursePacketData? { rState.latestPacket }

    private var effectiveSince: String {
        if !sinceInput.isEmpty { return sinceInput }
        if let p = pkt, !p.periodStart.isEmpty { return p.periodStart }
        if !rState.defaultSinceDate.isEmpty { return rState.defaultSinceDate }
        return Schedule.isoDay(store.today.addingTimeInterval(-30 * 86400))
    }

    private var effectiveUntil: String {
        if !untilInput.isEmpty { return untilInput }
        if let p = pkt, !p.periodEnd.isEmpty { return p.periodEnd }
        return Schedule.isoDay(store.today)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            kpiRow
            packetBuilderPanel
            if let pkt {
                if !pkt.violations.isEmpty {
                    gateViolationsBanner(pkt.violations)
                }
                providerPairingPanel(pkt)
                HStack(alignment: .top, spacing: 18) {
                    auditLedgerPanel(pkt)
                    draftNoticePanel(pkt)
                }
            } else {
                emptyPacketPanel
            }
        }
        .onAppear {
            seedDefaultDatesIfNeeded()
        }
        .onChange(of: rState.defaultSinceDate) { _, _ in
            seedDefaultDatesIfNeeded()
        }
    }

    private func seedDefaultDatesIfNeeded() {
        guard !didSeedDates else { return }
        didSeedDates = true
        if let p = pkt {
            sinceInput = p.periodStart
            untilInput = p.periodEnd
            withCover = p.coverPages > 0
        } else {
            sinceInput = rState.defaultSinceDate.isEmpty
                ? Schedule.isoDay(store.today.addingTimeInterval(-30 * 86400))
                : rState.defaultSinceDate
            untilInput = Schedule.isoDay(store.today)
        }
    }

    // MARK: - 1. 5-Cell Telemetry Row

    private var kpiRow: some View {
        let total = pkt?.totalUSD ?? 0
        let rcptCount = pkt?.receiptCount ?? 0
        let provCount = pkt?.providerCount ?? 0
        let pairedCount = pkt?.groups.filter(\.hasApprovalArtifact).count ?? 0
        let blockedCount = pkt?.blockedUnapproved.count ?? 0
        let excludedCount = pkt?.excluded.count ?? 0
        let preWarn = pkt?.preApprovalWarningCount ?? 0

        let gateLabel: String = {
            guard let pkt else { return "READY" }
            return pkt.gatePassed ? "PASS" : "FAIL"
        }()
        let gateColor: Color = {
            guard let pkt else { return DS.ink2 }
            return pkt.gatePassed ? DS.mint : DS.coral
        }()

        let windowValue: String = {
            let s = effectiveSince
            let u = effectiveUntil
            let sShort = Schedule.parseDay(s).map(DayText.short) ?? s
            let uShort = Schedule.parseDay(u).map(DayText.short) ?? u
            return "\(sShort) → \(uShort)"
        }()

        return HStack(spacing: 12) {
            KPI(
                label: "Reimbursable packet",
                value: Money.exact(total),
                caption: pkt != nil
                    ? "\(rcptCount) paid receipt\(rcptCount == 1 ? "" : "s") across \(provCount) provider\(provCount == 1 ? "" : "s")"
                    : "Select date range to compile .zip",
                delta: pkt?.zipPath != nil ? "✓ \(rState.bundleSlug).zip ready" : nil,
                deltaColor: DS.mint,
                accent: DS.amber
            )
            KPI(
                label: "Date window",
                value: windowValue,
                caption: rState.lastSentDate.map { "Last sent cutoff: \($0)" } ?? "No prior sent batch recorded",
                delta: "\(effectiveSince) .. \(effectiveUntil)",
                deltaColor: DS.cyan
            )
            KPI(
                label: "1:1 IT approvals",
                value: pkt != nil ? "\(pairedCount)/\(provCount)" : "\(rState.verifiedApprovalCount)",
                caption: "\(rState.verifiedApprovalCount) verified on disk · \(rState.pendingApprovalCount) pending",
                delta: pairedCount == provCount && provCount > 0 ? "✓ Every bundle paired" : nil,
                deltaColor: DS.mint,
                valueColor: (pkt != nil && pairedCount == provCount) ? DS.mint : DS.ink
            )
            KPI(
                label: "5-point verify gate",
                value: gateLabel,
                caption: "Byte-level %PDF + page reconciliation",
                delta: pkt.map { "✓ \($0.totalCompiledPages) out == \($0.totalSourcePages) src\(pkt?.coverPages ?? 0 > 0 ? " + cover" : "")" },
                deltaColor: gateColor,
                valueColor: gateColor,
                accent: pkt?.gatePassed == false ? DS.coral : DS.mint
            )
            KPI(
                label: "Guardrails & dedup",
                value: "\(blockedCount + excludedCount)",
                caption: "\(blockedCount) unapproved · \(excludedCount) deduped/unpaid",
                delta: preWarn > 0 ? "⚠ \(preWarn) pre-approval date\(preWarn == 1 ? "" : "s")" : "✓ Double-submit lock active",
                deltaColor: preWarn > 0 ? DS.amber : DS.mint,
                valueColor: blockedCount > 0 ? DS.amber : DS.ink
            )
        }
    }

    // MARK: - 2. Interactive Deterministic Packet Builder Panel

    private var packetBuilderPanel: some View {
        let cliPreview = "recurring wm-cloud --since \(effectiveSince) --until \(effectiveUntil)" + (withCover ? " --cover" : "")

        return DSPanel(
            eyebrow: "WM-CLOUD DETERMINISTIC ENGINE",
            title: "Cloud & API Receipt Packet Compiler",
            subtitle: "Harvests paid PDFs across mailboxes + portal cache, enforces 1:1 IT approval pairing & double-submit deduplication, and packages \(rState.bundleSlug).zip.",
            accentBar: DS.amber
        ) {
            HStack(spacing: 8) {
                DSStatusPill(text: "NEVER AUTO-SENDS", tint: DS.mint)
                if !rState.fundNumber.isEmpty {
                    DSStatusPill(text: "FUND #\(rState.fundNumber)", tint: DS.cyan)
                }
            }
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    dateInputBox(label: "SINCE", text: $sinceInput, fallback: effectiveSince)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(DS.ink3)
                    dateInputBox(label: "UNTIL", text: $untilInput, fallback: effectiveUntil)

                    // Quick window presets
                    HStack(spacing: 6) {
                        presetChip("Since Last Sent") {
                            if !rState.defaultSinceDate.isEmpty {
                                sinceInput = rState.defaultSinceDate
                            }
                            untilInput = Schedule.isoDay(store.today)
                        }
                        presetChip("Month to Date") {
                            let ms = DashboardView.monthStart(store.today)
                            sinceInput = Schedule.isoDay(ms)
                            untilInput = Schedule.isoDay(store.today)
                        }
                        presetChip("Last 30d") {
                            sinceInput = Schedule.isoDay(store.today.addingTimeInterval(-30 * 86400))
                            untilInput = Schedule.isoDay(store.today)
                        }
                    }

                    DSFilterChip(
                        title: "Cover Sheet",
                        selected: withCover
                    ) {
                        withCover.toggle()
                    }

                    Spacer(minLength: 8)

                    DSChipButton(
                        title: store.isVerifyingPacket ? "Verifying…" : "Re-Verify Gate",
                        icon: "checkmark.shield",
                        disabled: store.isVerifyingPacket || pkt == nil
                    ) {
                        Task { await store.verifyLatestPacket() }
                    }

                    if let zip = pkt?.zipPath, !zip.isEmpty {
                        DSChipButton(title: "Reveal .zip", icon: "folder") {
                            store.revealInFinder(path: zip)
                        }
                    }

                    DSChipButton(
                        title: store.isBuildingPacket ? "Compiling…" : "Build Packet (.zip)",
                        icon: "doc.zipper",
                        prominent: true,
                        disabled: store.isBuildingPacket
                    ) {
                        let s = effectiveSince
                        let u = effectiveUntil
                        Task {
                            await store.buildReimbursementPacket(since: s, until: u, withCover: withCover)
                        }
                    }
                }

                HStack(spacing: 12) {
                    HStack(spacing: 7) {
                        Text("$")
                            .font(DS.mono(10.5, weight: .bold))
                            .foregroundStyle(DS.amber)
                        Text(cliPreview)
                            .font(DS.mono(10.5))
                            .foregroundStyle(DS.ink2)
                            .lineLimit(1)
                        Button {
                            store.copyText(cliPreview, banner: "Copied CLI command")
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(DS.ink3)
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5.5)
                    .background(RoundedRectangle(cornerRadius: DS.radiusWell).fill(DS.well))
                    .overlay(RoundedRectangle(cornerRadius: DS.radiusWell).strokeBorder(DS.border, lineWidth: 1))

                    if !rState.fundingWorktag.isEmpty || !rState.approverEmail.isEmpty {
                        Text(
                            [
                                rState.organization,
                                rState.fundingWorktag.isEmpty ? nil : rState.fundingWorktag,
                                rState.approverEmail.isEmpty ? nil : "Approver: \(rState.approverEmail)",
                            ]
                            .compactMap { $0 }
                            .joined(separator: " · ")
                        )
                        .font(DS.mono(10))
                        .foregroundStyle(DS.ink3)
                        .lineLimit(1)
                    }
                    Spacer()
                }
            }
        }
    }

    private func dateInputBox(label: String, text: Binding<String>, fallback: String) -> some View {
        HStack(spacing: 7) {
            Text(label)
                .font(DS.mono(9, weight: .bold))
                .foregroundStyle(DS.ink3)
            if isSnapshotRender {
                Text(fallback)
                    .font(DS.mono(11.5, weight: .semibold))
                    .foregroundStyle(DS.ink)
                    .frame(width: 90, alignment: .leading)
            } else {
                TextField("YYYY-MM-DD", text: text)
                    .textFieldStyle(.plain)
                    .focusEffectDisabled()
                    .font(DS.mono(11.5, weight: .semibold))
                    .foregroundStyle(DS.ink)
                    .frame(width: 90)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: DS.radiusWell).fill(DS.well))
        .overlay(RoundedRectangle(cornerRadius: DS.radiusWell).strokeBorder(DS.border, lineWidth: 1))
    }

    private func presetChip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(DS.display(11, weight: .medium))
                .foregroundStyle(DS.ink2)
                .padding(.horizontal, 9)
                .padding(.vertical, 5.5)
                .background(RoundedRectangle(cornerRadius: DS.radiusPill).fill(DS.well))
                .overlay(RoundedRectangle(cornerRadius: DS.radiusPill).strokeBorder(DS.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    // MARK: - 3. Gate Violations Banner (When Any Violation Exists)

    private func gateViolationsBanner(_ violations: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: "xmark.octagon.fill")
                    .font(.system(size: 12, weight: .bold))
                Text("5-POINT ANTI-HALLUCINATION GATE BLOCKED ARCHIVE (\(violations.count) VIOLATION\(violations.count == 1 ? "" : "S"))")
                    .font(DS.mono(10.5, weight: .bold))
            }
            .foregroundStyle(DS.coral)

            ForEach(violations, id: \.self) { v in
                Text("• \(v)")
                    .font(DS.mono(10.5))
                    .foregroundStyle(DS.ink)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.radiusCard).fill(DS.coral.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: DS.radiusCard).strokeBorder(DS.coral.opacity(0.45), lineWidth: 1))
    }

    // MARK: - 4. Provider 1:1 Pairing & Compiled PDFs Table

    private func providerPairingPanel(_ pkt: ReimbursePacketData) -> some View {
        DSPanel(
            eyebrow: "1:1 PROVIDER BUNDLES",
            title: "Compiled Receipt PDFs & Paired IT Approvals",
            subtitle: "Archive structure inside \(pkt.zipFilename): \(pkt.bundleSlug)/<provider>/{receipts-<provider>-<window>.pdf, approval-<provider>.*}",
            accentBar: pkt.gatePassed ? DS.mint : DS.coral
        ) {
            DSStatusPill(
                text: "\(pkt.providerCount) PROVIDERS · \(pkt.totalCompiledPages) PAGES · \(Money.exact(pkt.totalUSD))",
                tint: pkt.gatePassed ? DS.mint : DS.amber
            )
        } content: {
            VStack(spacing: 0) {
                // Header
                HStack(spacing: 12) {
                    Text("PROVIDER")
                        .frame(width: 210, alignment: .leading)
                    Text("COMPILED PDF")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("RCPTS")
                        .frame(width: 54, alignment: .trailing)
                    Text("PAGES")
                        .frame(width: 96, alignment: .trailing)
                    Text("PAIRED IT APPROVAL")
                        .frame(width: 265, alignment: .leading)
                    Text("SUBTOTAL")
                        .frame(width: 100, alignment: .trailing)
                    Text("")
                        .frame(width: 64, alignment: .trailing)
                }
                .font(DS.mono(9.5, weight: .semibold))
                .foregroundStyle(DS.ink3)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(DS.well.opacity(0.75))

                ForEach(pkt.groups) { g in
                    Rectangle().fill(DS.borderSubtle).frame(height: 1)
                    HStack(spacing: 12) {
                        HStack(spacing: 9) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(DS.well)
                                    .frame(width: 26, height: 26)
                                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DS.border, lineWidth: 1))
                                DSProviderGlyph(provider: g.provider, size: 14)
                            }
                            VStack(alignment: .leading, spacing: 1.5) {
                                Text(g.label)
                                    .font(DS.display(12.5, weight: .semibold))
                                    .foregroundStyle(DS.ink)
                                    .lineLimit(1)
                                if g.preApprovalCount > 0 {
                                    Text("⚠ \(g.preApprovalCount) pre-approval date")
                                        .font(DS.mono(9, weight: .semibold))
                                        .foregroundStyle(DS.amber)
                                }
                            }
                        }
                        .frame(width: 210, alignment: .leading)

                        Text(g.pdfFilename)
                            .font(DS.mono(10.5))
                            .foregroundStyle(DS.ink2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text("\(g.receiptCount)")
                            .font(DS.mono(11.5, weight: .semibold))
                            .foregroundStyle(DS.ink)
                            .frame(width: 54, alignment: .trailing)

                        HStack(spacing: 4) {
                            Spacer(minLength: 0)
                            Text("\(g.sourcePages)→\(g.compiledPages)p")
                                .font(DS.mono(10.5, weight: .semibold))
                                .foregroundStyle(g.pagesReconciled ? DS.mint : DS.coral)
                            Image(systemName: g.pagesReconciled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(g.pagesReconciled ? DS.mint : DS.coral)
                        }
                        .frame(width: 96, alignment: .trailing)

                        HStack(spacing: 6) {
                            if let appFile = g.approvalFilename {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(DS.mint)
                                Text(appFile)
                                    .font(DS.mono(10.5))
                                    .foregroundStyle(DS.ink2)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if !g.approvalTicket.isEmpty {
                                    DSStatusPill(text: "#\(g.approvalTicket)", tint: DS.cyan)
                                }
                            } else {
                                DSStatusPill(text: "MISSING APPROVAL", tint: DS.coral)
                            }
                        }
                        .frame(width: 265, alignment: .leading)

                        Text(Money.exact(g.subtotalUSD))
                            .font(DS.mono(12.5, weight: .bold))
                            .foregroundStyle(DS.ink)
                            .frame(width: 100, alignment: .trailing)

                        HStack(spacing: 4) {
                            Spacer(minLength: 0)
                            if !isSnapshotRender {
                                Button {
                                    store.revealInFinder(path: g.pdfPath)
                                } label: {
                                    Text("PDF")
                                        .font(DS.mono(9.5, weight: .semibold))
                                        .foregroundStyle(DS.ink2)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3.5)
                                        .background(RoundedRectangle(cornerRadius: DS.radiusPill).fill(DS.well))
                                        .overlay(RoundedRectangle(cornerRadius: DS.radiusPill).strokeBorder(DS.border, lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                                .focusEffectDisabled()
                            } else {
                                DSStatusPill(text: "OK", tint: DS.mint)
                            }
                        }
                        .frame(width: 64, alignment: .trailing)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9.5)
                }

                // Total Footer Row
                Rectangle().fill(DS.border).frame(height: 1)
                HStack(spacing: 12) {
                    Text("PACKET TOTAL (\(pkt.providerCount) APPROVED PROVIDERS)")
                        .font(DS.mono(10, weight: .bold))
                        .foregroundStyle(DS.amber)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(pkt.receiptCount) rcpts")
                        .font(DS.mono(10.5, weight: .semibold))
                        .foregroundStyle(DS.ink2)
                    Text("\(pkt.totalCompiledPages) pages")
                        .font(DS.mono(10.5, weight: .semibold))
                        .foregroundStyle(DS.mint)
                        .frame(width: 96, alignment: .trailing)
                    Spacer().frame(width: 265)
                    Text(Money.exact(pkt.totalUSD))
                        .font(DS.mono(13.5, weight: .bold))
                        .foregroundStyle(DS.amber)
                        .frame(width: 100, alignment: .trailing)
                    Spacer().frame(width: 64)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(DS.well.opacity(0.45))
            }
            .clipShape(RoundedRectangle(cornerRadius: DS.radiusWell))
            .overlay(RoundedRectangle(cornerRadius: DS.radiusWell).strokeBorder(DS.border, lineWidth: 1))
        }
    }

    // MARK: - 5. Left Column: Itemized Receipts, Blocked Unapproved, Deduped & IT Approvals

    private func auditLedgerPanel(_ pkt: ReimbursePacketData) -> some View {
        let allIncluded = pkt.groups.flatMap(\.receipts)

        return DSPanel(
            eyebrow: "SOURCE-LEVEL AUDIT",
            title: "Receipts, Exclusions & IT Approval Registry",
            subtitle: "Unpaid 'Amount due' invoices, prior sent batches, and unapproved vendors are isolated automatically."
        ) {
            EmptyView()
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    DSFilterChip(
                        title: "Included",
                        selected: selectedAuditTab == .included,
                        count: allIncluded.count,
                        dot: DS.mint
                    ) { selectedAuditTab = .included }

                    DSFilterChip(
                        title: "Blocked",
                        selected: selectedAuditTab == .blocked,
                        count: pkt.blockedUnapproved.count,
                        dot: pkt.blockedUnapproved.isEmpty ? nil : DS.amber
                    ) { selectedAuditTab = .blocked }

                    DSFilterChip(
                        title: "Deduped / Excluded",
                        selected: selectedAuditTab == .excluded,
                        count: pkt.excluded.count
                    ) { selectedAuditTab = .excluded }

                    DSFilterChip(
                        title: "IT Approvals",
                        selected: selectedAuditTab == .approvals,
                        count: rState.approvals.count,
                        dot: DS.cyan
                    ) { selectedAuditTab = .approvals }
                }

                VStack(spacing: 0) {
                    switch selectedAuditTab {
                    case .included:
                        ForEach(Array(allIncluded.prefix(12).enumerated()), id: \.element.id) { idx, r in
                            if idx > 0 { Rectangle().fill(DS.borderSubtle).frame(height: 1) }
                            HStack(spacing: 10) {
                                Text(r.date)
                                    .font(DS.mono(10.5))
                                    .foregroundStyle(DS.ink3)
                                    .frame(width: 82, alignment: .leading)
                                VStack(alignment: .leading, spacing: 1.5) {
                                    HStack(spacing: 6) {
                                        Text(VaultKeyItem.providerDisplayName(r.provider))
                                            .font(DS.display(12, weight: .semibold))
                                            .foregroundStyle(DS.ink)
                                        if !r.receiptRef.isEmpty {
                                            Text("#\(r.receiptRef)")
                                                .font(DS.mono(9.5))
                                                .foregroundStyle(DS.ink3)
                                                .lineLimit(1)
                                        }
                                        if r.preApprovalDate {
                                            DSStatusPill(text: "PRE-APPROVAL", tint: DS.amber)
                                        }
                                    }
                                    Text("\(r.pdfSource) · \(r.pages)p\(r.mailbox.isEmpty ? "" : " · \(r.mailbox)")")
                                        .font(DS.mono(9.5))
                                        .foregroundStyle(DS.ink3)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 6)
                                Text(Money.exact(r.amount))
                                    .font(DS.mono(11.5, weight: .semibold))
                                    .foregroundStyle(DS.ink)
                            }
                            .padding(.horizontal, 11)
                            .padding(.vertical, 7.5)
                        }
                        if allIncluded.count > 12 {
                            Text("+ \(allIncluded.count - 12) more verified receipt PDFs in manifest.json")
                                .font(DS.mono(10))
                                .foregroundStyle(DS.ink3)
                                .padding(10)
                        }

                    case .blocked:
                        if pkt.blockedUnapproved.isEmpty {
                            emptyAuditRow("Zero blocked receipts — every harvested vendor has a verified IT approval.")
                        } else {
                            ForEach(Array(pkt.blockedUnapproved.enumerated()), id: \.element.id) { idx, b in
                                if idx > 0 { Rectangle().fill(DS.borderSubtle).frame(height: 1) }
                                excludedRow(b, tint: DS.amber)
                            }
                        }

                    case .excluded:
                        if pkt.excluded.isEmpty {
                            emptyAuditRow("No duplicate or unpaid-invoice exclusions in this window.")
                        } else {
                            ForEach(Array(pkt.excluded.prefix(12).enumerated()), id: \.element.id) { idx, ex in
                                if idx > 0 { Rectangle().fill(DS.borderSubtle).frame(height: 1) }
                                excludedRow(ex, tint: DS.ink3)
                            }
                        }

                    case .approvals:
                        ForEach(Array(rState.approvals.enumerated()), id: \.element.id) { idx, a in
                            if idx > 0 { Rectangle().fill(DS.borderSubtle).frame(height: 1) }
                            HStack(spacing: 10) {
                                DSStatusPill(
                                    text: a.isVerified ? "VERIFIED" : a.status.uppercased(),
                                    tint: a.isVerified ? DS.mint : DS.amber
                                )
                                Text(a.label)
                                    .font(DS.display(12, weight: .semibold))
                                    .foregroundStyle(DS.ink)
                                if !a.ticket.isEmpty {
                                    Text("#\(a.ticket)")
                                        .font(DS.mono(10, weight: .semibold))
                                        .foregroundStyle(DS.cyan)
                                }
                                Spacer()
                                Text(a.filename ?? (a.note.isEmpty ? "no artifact" : a.note))
                                    .font(DS.mono(10))
                                    .foregroundStyle(DS.ink3)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 11)
                            .padding(.vertical, 7.5)
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: DS.radiusWell).fill(DS.well.opacity(0.45)))
                .overlay(RoundedRectangle(cornerRadius: DS.radiusWell).strokeBorder(DS.border, lineWidth: 1))
            }
        }
    }

    private func excludedRow(_ item: ReimburseExcludedItem, tint: Color) -> some View {
        HStack(spacing: 10) {
            Text(item.date)
                .font(DS.mono(10.5))
                .foregroundStyle(DS.ink3)
                .frame(width: 82, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.label)
                        .font(DS.display(12, weight: .semibold))
                        .foregroundStyle(DS.ink)
                    DSStatusPill(text: item.reason, tint: tint)
                }
                if !item.receiptRef.isEmpty {
                    Text("#\(item.receiptRef)")
                        .font(DS.mono(9.5))
                        .foregroundStyle(DS.ink3)
                }
            }
            Spacer()
            Text(Money.exact(item.amount))
                .font(DS.mono(11.5, weight: .semibold))
                .foregroundStyle(DS.ink2)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7.5)
    }

    private func emptyAuditRow(_ text: String) -> some View {
        Text(text)
            .font(DS.display(11.5))
            .foregroundStyle(DS.ink3)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 6. Right Column: Approver Draft Notice (`approval-notice.txt`)

    private func draftNoticePanel(_ pkt: ReimbursePacketData) -> some View {
        let notice = pkt.draftNotice

        return DSPanel(
            eyebrow: "APPROVER NOTICE DRAFT",
            title: "approval-notice.txt",
            subtitle: "Saved locally inside the batch directory — copy into your mail client alongside \(pkt.zipFilename)."
        ) {
            HStack(spacing: 6) {
                if let notice {
                    DSChipButton(title: "Copy Subject", icon: "text.quote") {
                        store.copyText(notice.subject, banner: "Copied email subject")
                    }
                    DSChipButton(title: "Copy Body", icon: "doc.on.doc") {
                        store.copyText(notice.body, banner: "Copied draft email body")
                    }
                }
            }
        } content: {
            if let notice {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 5) {
                        draftMetaLine("TO", notice.to.isEmpty ? "(configure approver.email in reimburse_config.json)" : notice.to)
                        draftMetaLine("SUBJECT", notice.subject)
                        draftMetaLine("ATTACH", notice.attachment)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: DS.radiusWell).fill(DS.well))
                    .overlay(RoundedRectangle(cornerRadius: DS.radiusWell).strokeBorder(DS.border, lineWidth: 1))

                    Text(notice.body)
                        .font(DS.mono(10.5))
                        .foregroundStyle(DS.ink2)
                        .lineSpacing(2.5)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: DS.radiusWell).fill(DS.canvas))
                        .overlay(RoundedRectangle(cornerRadius: DS.radiusWell).strokeBorder(DS.border, lineWidth: 1))
                }
            } else {
                emptyAuditRow("Build a packet to generate approval-notice.txt.")
            }
        }
    }

    private func draftMetaLine(_ key: String, _ val: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(key)
                .font(DS.mono(9.5, weight: .bold))
                .foregroundStyle(DS.amber)
                .frame(width: 58, alignment: .leading)
            Text(val)
                .font(DS.mono(10.5, weight: .medium))
                .foregroundStyle(DS.ink)
                .lineLimit(2)
        }
    }

    // MARK: - Empty Initial State

    private var emptyPacketPanel: some View {
        DSPanel(
            eyebrow: "NO PACKET BUILT YET",
            title: "Ready to Compile Receipt Packet",
            subtitle: "Choose a [SINCE .. UNTIL] window above and click 'Build Packet (.zip)' or run `recurring wm-cloud` from your terminal."
        ) {
            DSStatusPill(text: "\(rState.verifiedApprovalCount) APPROVALS READY", tint: DS.mint)
        } content: {
            Text("Configure ~/.recurring/reimburse_config.json (see examples/reimburse_config.example.json) and drop provider IT approval PDFs/PNGs into ~/.recurring/reimbursements/approvals/.")
                .font(DS.display(12))
                .foregroundStyle(DS.ink2)
        }
    }
}
