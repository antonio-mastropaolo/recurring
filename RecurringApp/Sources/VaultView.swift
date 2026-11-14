import SwiftUI

/// Native Sentinel-grade encrypted API key Vault surface inside Recurring v3.
/// Enforces canonical Helix ecosystem key vocabulary: `Admin key` and `Org key`.
struct VaultView: View {
    @EnvironmentObject var store: Store
    @Environment(\.isSnapshotRender) private var isSnapshotRender
    var scrollable: Bool = true

    // Inline unlock / init gate
    @State private var passphrase: String = ""
    @State private var unlockError: String?
    @State private var isUnlocking: Bool = false

    // Inline Add Key drawer
    @State private var showAddDrawer: Bool = false
    @State private var newLabel: String = ""
    @State private var newSecret: String = ""
    @State private var newTier: String = "org"
    @State private var newProvider: String = "auto"
    @State private var newAccount: String = ""
    @State private var addError: String?

    // Inline Rotate Key drawer
    @State private var rotatingKey: VaultKeyItem?
    @State private var replacementSecret: String = ""
    @State private var rotateError: String?

    // Ephemeral secret reveal (auto-hides on lock)
    @State private var revealedSecrets: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.gridGap) {
            healthStrip
            if !store.vault.unlocked {
                lockedGateCard
            }
            if showAddDrawer {
                addKeyCard
            }
            if let rk = rotatingKey {
                rotateKeyCard(rk)
            }
            VaultKeysPanel(
                scrollable: scrollable,
                explorer: store.explorer,
                showAddDrawer: $showAddDrawer,
                rotatingKey: $rotatingKey,
                revealedSecrets: $revealedSecrets
            )
            if !store.vault.strayFindings.isEmpty {
                strayFindingsPanel
            }
        }
    }

    // MARK: 5-Cell Observatory Health Strip

    private var healthStrip: some View {
        let v = store.vault
        return HStack(spacing: DS.gridGap) {
            VaultMetricCard(
                eyebrow: "ACTIVE INVENTORY",
                value: "\(v.activeKeys.count)",
                caption: "\(v.adminCount) Admin key · \(v.orgCount) Org key",
                accent: DS.amber
            )
            VaultMetricCard(
                eyebrow: "VERIFIED HEALTHY",
                value: "\(v.healthyCount)",
                caption: v.lastSweepAt.map { "swept \(DayText.relativeISO($0))" } ?? "unlock & run live sweep",
                accent: DS.mint
            )
            VaultMetricCard(
                eyebrow: "STALE (≥90D)",
                value: "\(v.staleCount)",
                caption: "rotation recommended",
                accent: v.staleCount > 0 ? DS.amber : DS.ink3
            )
            VaultMetricCard(
                eyebrow: "GIT LEAKS",
                value: "\(v.leakedCount)",
                caption: v.leakedCount == 0 ? "0 tracked in git" : "immediate rotation required",
                accent: v.leakedCount > 0 ? DS.coral : DS.mint
            )
            VaultMetricCard(
                eyebrow: "UNVAULTED .ENV",
                value: "\(v.strayFindings.count)",
                caption: v.lastScanAt.map { "scanned \(DayText.relativeISO($0))" } ?? "across ~/Projects",
                accent: v.strayFindings.isEmpty ? DS.ink3 : DS.cyan
            )
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Inline Compact Sentinel Lock / Init Bar

    private var lockedGateCard: some View {
        let isInit = store.vault.initialized
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(DS.amber.opacity(0.14))
                        .frame(width: 32, height: 32)
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(DS.amber.opacity(0.42), lineWidth: 1))
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DS.amber)
                }

                VStack(alignment: .leading, spacing: 2) {
                    DSEyebrow(
                        text: isInit ? "VAULT LOCKED · AES-256-GCM + ARGON2ID" : "INITIALIZE VAULT · AES-256-GCM + ARGON2ID",
                        color: DS.amber
                    )
                    Text(isInit
                         ? "Unlock 12h session to copy, reveal, add, rotate, or sweep live keys"
                         : "Create a master passphrase to arm encrypted API key storage")
                        .font(DS.display(12.5, weight: .semibold))
                        .foregroundStyle(DS.ink)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                HStack(spacing: 8) {
                    Image(systemName: "key.horizontal.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DS.amber)
                    Group {
                        if isSnapshotRender {
                            Text(isInit ? "Enter master passphrase…" : "Choose master passphrase (≥ 6 chars)…")
                                .font(DS.mono(11.5))
                                .foregroundStyle(DS.ink3)
                                .frame(width: 225, alignment: .leading)
                        } else {
                            SecureField(isInit ? "Enter master passphrase…" : "Choose master passphrase (≥ 6 chars)…", text: $passphrase)
                                .textFieldStyle(.plain)
                                .focusEffectDisabled()
                                .font(DS.mono(11.5))
                                .foregroundStyle(DS.ink)
                                .frame(width: 225)
                                .onSubmit { submitUnlock() }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: DS.radiusWell).fill(DS.well))
                .overlay(RoundedRectangle(cornerRadius: DS.radiusWell).strokeBorder(DS.border, lineWidth: 1))

                DSChipButton(
                    title: isUnlocking ? "Verifying…" : (isInit ? "Unlock 12h Session" : "Initialize Vault"),
                    icon: "lock.open.fill",
                    prominent: true,
                    disabled: passphrase.isEmpty || isUnlocking
                ) {
                    submitUnlock()
                }

                DSChipButton(title: "Import Sentinel DB", icon: "square.and.arrow.down") {
                    Task { await store.importSentinelVault() }
                }
            }
            if let unlockError {
                Text(unlockError)
                    .font(DS.display(11.5, weight: .medium))
                    .foregroundStyle(DS.coral)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: DS.radiusCard).fill(DS.surface))
        .overlay(alignment: .top) {
            UnevenRoundedRectangle(
                topLeadingRadius: DS.radiusCard,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: DS.radiusCard
            )
            .fill(DS.amber.opacity(0.88))
            .frame(height: 2)
        }
        .overlay(RoundedRectangle(cornerRadius: DS.radiusCard).strokeBorder(DS.border, lineWidth: 1))
    }

    private func submitUnlock() {
        guard !passphrase.isEmpty, !isUnlocking else { return }
        isUnlocking = true
        unlockError = nil
        let pw = passphrase
        Task {
            let res = store.vault.initialized
                ? await store.unlockVault(passphrase: pw)
                : await store.initVault(passphrase: pw)
            isUnlocking = false
            switch res {
            case .success:
                passphrase = ""
                unlockError = nil
            case .failure(let err):
                unlockError = err.localizedDescription
            }
        }
    }

    // MARK: Inline Add Key Card

    private var addKeyCard: some View {
        DSPanel(
            eyebrow: "ENCRYPT NEW CREDENTIAL",
            title: "Add API key to Vault",
            subtitle: "Provider & Admin key / Org key tier auto-detect from prefix, or select explicitly",
            accentBar: DS.mint
        ) {
            DSChipButton(title: "Cancel", icon: "xmark") {
                showAddDrawer = false
                newSecret = ""
                addError = nil
            }
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    TextField("Label (e.g. Anthropic · Prod)", text: $newLabel)
                        .textFieldStyle(.plain)
                        .font(DS.display(12))
                        .foregroundStyle(DS.ink)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: DS.radiusWell).fill(DS.well))
                        .overlay(RoundedRectangle(cornerRadius: DS.radiusWell).strokeBorder(DS.border, lineWidth: 1))

                    TextField("Account email (links to subscription)", text: $newAccount)
                        .textFieldStyle(.plain)
                        .font(DS.mono(11.5))
                        .foregroundStyle(DS.ink)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: DS.radiusWell).fill(DS.well))
                        .overlay(RoundedRectangle(cornerRadius: DS.radiusWell).strokeBorder(DS.border, lineWidth: 1))

                    HStack(spacing: 6) {
                        DSFilterChip(title: "Org key", selected: newTier == "org") { newTier = "org" }
                        DSFilterChip(title: "Admin key", selected: newTier == "admin") { newTier = "admin" }
                    }
                }

                HStack(spacing: 10) {
                    SecureField("Paste raw API secret (encrypted via stdin pipe, never argv)…", text: $newSecret)
                        .textFieldStyle(.plain)
                        .font(DS.mono(12))
                        .foregroundStyle(DS.ink)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: DS.radiusWell).fill(DS.well))
                        .overlay(RoundedRectangle(cornerRadius: DS.radiusWell).strokeBorder(DS.border, lineWidth: 1))

                    DSChipButton(
                        title: "Encrypt & Store",
                        icon: "checkmark.shield.fill",
                        prominent: true,
                        disabled: newLabel.trimmingCharacters(in: .whitespaces).isEmpty || newSecret.count < 8
                    ) {
                        Task {
                            let res = await store.addVaultKey(
                                label: newLabel.trimmingCharacters(in: .whitespaces),
                                secret: newSecret,
                                tier: newTier,
                                provider: newProvider,
                                account: newAccount
                            )
                            switch res {
                            case .success:
                                newLabel = ""
                                newSecret = ""
                                newAccount = ""
                                addError = nil
                                showAddDrawer = false
                            case .failure(let err):
                                addError = err.localizedDescription
                            }
                        }
                    }
                }
                if let addError {
                    Text(addError).font(DS.display(11.5)).foregroundStyle(DS.coral)
                }
            }
        }
    }

    // MARK: Inline Rotate Key Card

    private func rotateKeyCard(_ key: VaultKeyItem) -> some View {
        DSPanel(
            eyebrow: "ATOMIC KEY ROTATION",
            title: "Rotate '\(key.label)' (\(key.tierLabel))",
            subtitle: "Wipes previous ciphertext immediately and links the new \(key.tierLabel) to \(key.account ?? key.providerLabel)",
            accentBar: DS.amber
        ) {
            DSChipButton(title: "Cancel", icon: "xmark") {
                rotatingKey = nil
                replacementSecret = ""
                rotateError = nil
            }
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    SecureField("Paste replacement secret for \(key.label)…", text: $replacementSecret)
                        .textFieldStyle(.plain)
                        .font(DS.mono(12))
                        .foregroundStyle(DS.ink)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: DS.radiusWell).fill(DS.well))
                        .overlay(RoundedRectangle(cornerRadius: DS.radiusWell).strokeBorder(DS.border, lineWidth: 1))

                    DSChipButton(
                        title: "Commit Rotation",
                        icon: "arrow.triangle.2.circlepath",
                        prominent: true,
                        disabled: replacementSecret.count < 8
                    ) {
                        Task {
                            let res = await store.rotateVaultKey(id: key.id, replacementSecret: replacementSecret)
                            switch res {
                            case .success:
                                replacementSecret = ""
                                rotateError = nil
                                rotatingKey = nil
                            case .failure(let err):
                                rotateError = err.localizedDescription
                            }
                        }
                    }
                }
                if let rotateError {
                    Text(rotateError).font(DS.display(11.5)).foregroundStyle(DS.coral)
                }
            }
        }
    }

    // MARK: Stray `.env` Findings Panel

    private var strayFindingsPanel: some View {
        DSPanel(
            eyebrow: "FILESYSTEM PROVENANCE · ~/PROJECTS",
            title: "Unvaulted keys discovered in .env & shell configs",
            subtitle: "Masked prefixes & file paths only — zero plaintext secrets are persisted on disk",
            accentBar: store.vault.strayFindings.contains(where: \.gitTracked) ? DS.coral : DS.cyan
        ) {
            DSStatusPill(text: "\(store.vault.strayFindings.count) unvaulted", tint: DS.cyan)
        } content: {
            VStack(spacing: 0) {
                ForEach(store.vault.strayFindings.prefix(18)) { sf in
                    HStack(spacing: 12) {
                        DSProviderBadge(provider: sf.provider, tileSize: 24, glyphSize: 13)
                        Text(sf.providerLabel)
                            .font(DS.display(12, weight: .semibold))
                            .foregroundStyle(DS.ink)
                            .frame(width: 120, alignment: .leading)
                        DSKeyTierBadge(tier: sf.tier)
                        Text(sf.prefixMasked)
                            .font(DS.mono(11.5))
                            .foregroundStyle(DS.ink2)
                            .frame(width: 185, alignment: .leading)
                        if sf.gitTracked {
                            DSStatusPill(text: "GIT TRACKED LEAK", tint: DS.coral, filled: true)
                        }
                        Text(sf.locations.map { "\($0.varName) in \($0.path)" }.joined(separator: " · "))
                            .font(DS.mono(10.5))
                            .foregroundStyle(DS.ink3)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                    }
                    .padding(.vertical, 7)
                    Rectangle().fill(DS.borderSubtle).frame(height: 1)
                }
            }
        }
    }
}

// MARK: - Isolated Key Inventory Panel (Search/Filter State Scoped Out of Health Strip)

private struct VaultKeysPanel: View {
    @EnvironmentObject var store: Store
    @Environment(\.isSnapshotRender) private var isSnapshotRender

    let scrollable: Bool
    @ObservedObject var explorer: ExplorerState
    @Binding var showAddDrawer: Bool
    @Binding var rotatingKey: VaultKeyItem?
    @Binding var revealedSecrets: [String: String]

    @State private var tierFilter: TierFilter = .all
    @State private var showRevoked: Bool = false

    enum TierFilter: String, CaseIterable {
        case all = "All"
        case admin = "Admin key"
        case org = "Org key"
        case attention = "Needs attention"
    }

    private func countForFilter(_ f: TierFilter) -> Int {
        let v = store.vault
        switch f {
        case .all: return v.activeKeys.count
        case .admin: return v.adminCount
        case .org: return v.orgCount
        case .attention: return v.attentionCount
        }
    }

    private var filteredKeys: [VaultKeyItem] {
        let base = showRevoked ? store.vault.keys : store.vault.activeKeys
        let q = explorer.vaultSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return base.filter { k in
            switch tierFilter {
            case .all: break
            case .admin: if k.tier != "admin" { return false }
            case .org: if k.tier != "org" { return false }
            case .attention:
                if !["leaked", "stale", "revoked", "rate_limited"].contains(k.health) { return false }
            }
            if !q.isEmpty && !k.searchHaystack.contains(q) {
                return false
            }
            return true
        }
    }

    var body: some View {
        let rows = filteredKeys
        let servicesByID = store.derived?.servicesByID ?? [:]
        return DSPanel(
            eyebrow: "KEYRING INVENTORY",
            title: "API keys & linked billing accounts",
            subtitle: "\(rows.count) shown · canonical Helix tiers (`Admin key` / `Org key`) linked to recurring subscriptions"
        ) {
            HStack(spacing: 8) {
                if store.vault.unlocked {
                    DSChipButton(title: "Add Key", icon: "plus", prominent: true) {
                        showAddDrawer.toggle()
                    }
                    DSChipButton(
                        title: store.isSweepingVault ? "Sweeping…" : "Sweep Health",
                        icon: "waveform.path.ecg",
                        disabled: store.isSweepingVault
                    ) {
                        Task { await store.sweepVaultHealth() }
                    }
                }
                DSChipButton(
                    title: store.isScanningEnv ? "Scanning…" : "Scan ~/Projects",
                    icon: "doc.text.magnifyingglass",
                    disabled: store.isScanningEnv
                ) {
                    Task { await store.scanProjectsEnv() }
                }
                if store.vault.unlocked {
                    DSChipButton(title: "Lock", icon: "lock.fill") {
                        revealedSecrets.removeAll()
                        Task { await store.lockVault() }
                    }
                }
            }
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    ForEach(TierFilter.allCases, id: \.self) { f in
                        DSFilterChip(
                            title: f.rawValue,
                            selected: tierFilter == f,
                            count: countForFilter(f)
                        ) {
                            tierFilter = f
                        }
                    }
                    DSFilterChip(
                        title: "Include revoked",
                        selected: showRevoked,
                        count: store.vault.revokedKeys.count
                    ) {
                        showRevoked.toggle()
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11))
                            .foregroundStyle(DS.ink3)
                        if isSnapshotRender {
                            Text("Filter provider, label, account…")
                                .font(DS.display(11.5))
                                .foregroundStyle(DS.ink3)
                                .frame(width: 210, alignment: .leading)
                        } else {
                            TextField("Filter provider, label, account…", text: $explorer.vaultSearchQuery)
                                .textFieldStyle(.plain)
                                .focusEffectDisabled()
                                .font(DS.display(11.5))
                                .foregroundStyle(DS.ink)
                                .frame(width: 192)
                            if !explorer.vaultSearchQuery.isEmpty {
                                Button {
                                    explorer.vaultSearchQuery = ""
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
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: DS.radiusWell).fill(DS.well))
                    .overlay(RoundedRectangle(cornerRadius: DS.radiusWell).strokeBorder(DS.border, lineWidth: 1))
                }

                VStack(spacing: 0) {
                    VaultTableHeader()
                    Rectangle().fill(DS.border).frame(height: 1)
                    if rows.isEmpty {
                        Text("No keys match the active filter.")
                            .font(DS.display(12))
                            .foregroundStyle(DS.ink3)
                            .padding(.vertical, 24)
                            .frame(maxWidth: .infinity)
                    } else if scrollable {
                        LazyVStack(spacing: 0) {
                            rowsList(rows, servicesByID: servicesByID)
                        }
                    } else {
                        VStack(spacing: 0) {
                            rowsList(rows, servicesByID: servicesByID)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func rowsList(_ rows: [VaultKeyItem], servicesByID: [String: Service]) -> some View {
        ForEach(rows) { item in
            let linked = item.serviceID.flatMap { servicesByID[$0] }
            VaultKeyRow(
                item: item,
                linkedService: linked,
                linkedDisplayName: linked.map { store.displayName(for: $0) },
                unlocked: store.vault.unlocked,
                revealed: revealedSecrets[item.id],
                onInspectService: { svc in
                    store.explorer.focusService(svc, scroll: true)
                    store.selectedTab = .ledger
                },
                onCopy: {
                    Task { await store.copyVaultSecret(id: item.id, label: item.label) }
                },
                onToggleReveal: {
                    if revealedSecrets[item.id] != nil {
                        revealedSecrets.removeValue(forKey: item.id)
                    } else {
                        Task {
                            if let sec = await store.revealVaultSecret(id: item.id) {
                                revealedSecrets[item.id] = sec
                            }
                        }
                    }
                },
                onRotate: {
                    rotatingKey = item
                },
                onRevoke: {
                    Task { await store.revokeVaultKey(id: item.id) }
                }
            )
            Rectangle().fill(DS.borderSubtle).frame(height: 1)
        }
    }
}

// MARK: - Vault Subcomponents

private struct VaultMetricCard: View {
    let eyebrow: String
    let value: String
    let caption: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            DSEyebrow(text: eyebrow, color: accent)
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

private struct VaultTableHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            Text("PROVIDER · LABEL").frame(maxWidth: .infinity, alignment: .leading)
            Text("TIER").frame(width: 102, alignment: .leading)
            Text("MASKED SECRET").frame(width: 186, alignment: .leading)
            Text("LINKED PLAN").frame(width: 170, alignment: .leading)
            Text(".ENV").frame(width: 68, alignment: .leading)
            Text("HEALTH").frame(width: 104, alignment: .leading)
            Text("ACTIONS").frame(width: 112, alignment: .trailing)
        }
        .font(DS.mono(9.5, weight: .semibold))
        .tracking(0.7)
        .foregroundStyle(DS.ink3)
        .padding(.vertical, 7)
    }
}

private struct VaultKeyRow: View {
    let item: VaultKeyItem
    let linkedService: Service?
    let linkedDisplayName: String?
    let unlocked: Bool
    let revealed: String?
    let onInspectService: (Service) -> Void
    let onCopy: () -> Void
    let onToggleReveal: () -> Void
    let onRotate: () -> Void
    let onRevoke: () -> Void
    @State private var hovering = false

    private var healthSpec: (label: String, tint: Color) {
        if item.isRevoked { return ("revoked", DS.ink3) }
        switch item.health {
        case "ok": return ("healthy", DS.mint)
        case "stale": return ("stale", DS.amber)
        case "leaked": return ("leaked", DS.coral)
        case "revoked": return ("revoked", DS.coral)
        case "rate_limited": return ("429 quota", DS.amber)
        default: return (item.trackedOnly ? "tracked" : "unverified", DS.ink3)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 9) {
                DSProviderBadge(provider: item.provider, tileSize: 26, glyphSize: 14)
                VStack(alignment: .leading, spacing: 1.5) {
                    Text(item.label)
                        .font(DS.display(12.5, weight: .medium))
                        .foregroundStyle(DS.ink)
                        .lineLimit(1)
                    Text([item.providerLabel, item.account].compactMap { $0 }.joined(separator: " · "))
                        .font(DS.display(10.5))
                        .foregroundStyle(DS.ink3)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            DSKeyTierBadge(tier: item.tier)
                .frame(width: 102, alignment: .leading)

            Text(revealed ?? item.prefixMasked)
                .font(DS.mono(11))
                .foregroundStyle(revealed != nil ? DS.amber : DS.ink2)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 186, alignment: .leading)

            Group {
                if let svc = linkedService {
                    Button {
                        onInspectService(svc)
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                Text(linkedDisplayName ?? svc.name)
                                    .font(DS.display(11.5, weight: .medium))
                                    .foregroundStyle(DS.ink2)
                                    .lineLimit(1)
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 8.5, weight: .bold))
                                    .foregroundStyle(DS.ink3)
                            }
                            Text("\(Money.row(svc)) · \(svc.typeLabel)")
                                .font(DS.mono(10))
                                .foregroundStyle(DS.ink3)
                                .lineLimit(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .help("Inspect '\(linkedDisplayName ?? svc.name)' in Ledger Explorer")
                } else {
                    Text("—")
                        .font(DS.mono(11))
                        .foregroundStyle(DS.ink3)
                }
            }
            .frame(width: 170, alignment: .leading)

            Group {
                if item.locations.isEmpty {
                    Text("—")
                        .font(DS.mono(10.5))
                        .foregroundStyle(DS.ink3)
                } else {
                    let leaked = item.locations.contains(where: \.gitTracked)
                    DSStatusPill(
                        text: "\(item.locations.count) file\(item.locations.count == 1 ? "" : "s")",
                        tint: leaked ? DS.coral : DS.cyan
                    )
                    .help(item.locations.map { "\($0.varName) in \($0.path)\($0.gitTracked ? " [GIT TRACKED]" : "")" }.joined(separator: "\n"))
                }
            }
            .frame(width: 68, alignment: .leading)

            DSStatusPill(text: healthSpec.label, tint: healthSpec.tint)
                .frame(width: 104, alignment: .leading)
                .help(item.healthDetail ?? "")

            HStack(spacing: 6) {
                RowIconButton(
                    icon: "doc.on.doc",
                    help: item.trackedOnly ? "Tracked hint only (no secret stored)" : "Copy secret (30s auto-clear)",
                    disabled: !unlocked || item.trackedOnly || item.isRevoked,
                    action: onCopy
                )
                RowIconButton(
                    icon: revealed != nil ? "eye.slash" : "eye",
                    help: revealed != nil ? "Hide secret" : "Reveal secret",
                    disabled: !unlocked || item.trackedOnly || item.isRevoked,
                    action: onToggleReveal
                )
                RowIconButton(
                    icon: "arrow.triangle.2.circlepath",
                    help: "Rotate key",
                    disabled: !unlocked || item.isRevoked,
                    action: onRotate
                )
                RowIconButton(
                    icon: "trash",
                    help: "Revoke & wipe ciphertext",
                    tint: DS.coral,
                    disabled: item.isRevoked,
                    action: onRevoke
                )
            }
            .frame(width: 112, alignment: .trailing)
        }
        .opacity(item.isRevoked ? 0.52 : 1)
        .padding(.vertical, 6.5)
        .padding(.horizontal, 4)
        .background(hovering ? DS.rowHover : Color.clear)
        .onHover { hovering = $0 }
    }
}

private struct RowIconButton: View {
    let icon: String
    let help: String
    var tint: Color = DS.ink2
    var disabled: Bool = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovering ? DS.ink : tint)
                .frame(width: 23, height: 23)
                .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? DS.elevated : DS.well))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(DS.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(disabled)
        .opacity(disabled ? 0.32 : 1)
        .onHover { hovering = $0 }
        .help(help)
    }
}
