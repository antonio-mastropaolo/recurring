import AppKit
import Combine
import Foundation
import UserNotifications
import os

let log = Logger(subsystem: "com.amastro.Recurring.v3", category: "app")

// MARK: - Vault & Sync Models (Non-secret projections read from ~/.recurring/*.json)

enum DashboardTab: String, CaseIterable, Identifiable {
    case ledger = "ledger"
    case vault = "vault"
    case sync = "sync"
    case reimburse = "reimburse"

    var id: String { rawValue }

    var indexLabel: String {
        switch self {
        case .ledger: return "01"
        case .vault: return "02"
        case .sync: return "03"
        case .reimburse: return "04"
        }
    }

    var title: String {
        switch self {
        case .ledger: return "Ledger"
        case .vault: return "API Vault"
        case .sync: return "Invoice Sync"
        case .reimburse: return "Reimburse"
        }
    }

    var icon: String {
        switch self {
        case .ledger: return "chart.bar.xaxis"
        case .vault: return "lock.shield.fill"
        case .sync: return "bolt.horizontal.circle.fill"
        case .reimburse: return "doc.zipper"
        }
    }
}

struct VaultLocationItem: Codable, Hashable {
    let path: String
    let varName: String
    let gitTracked: Bool

    enum CodingKeys: String, CodingKey {
        case path
        case varName = "var_name"
        case gitTracked = "git_tracked"
    }
}

struct VaultKeyItem: Identifiable, Hashable {
    let id: String
    let label: String
    let provider: String
    let tier: String        // "admin" | "org"
    let account: String?
    let serviceID: String?
    let prefixMasked: String
    let last4: String?
    let trackedOnly: Bool
    let status: String      // "active" | "revoked"
    let health: String      // "ok" | "stale" | "revoked" | "leaked" | "rate_limited" | "unverified"
    let healthDetail: String?
    let lastCheckedAt: String?
    let createdAt: String?
    let rotatedFromID: String?
    let locations: [VaultLocationItem]
    let searchHaystack: String

    var tierLabel: String { tier == "admin" ? "Admin key" : "Org key" }
    var isRevoked: Bool { status == "revoked" }

    init(
        id: String,
        label: String,
        provider: String,
        tier: String,
        account: String?,
        serviceID: String?,
        prefixMasked: String,
        last4: String?,
        trackedOnly: Bool,
        status: String,
        health: String,
        healthDetail: String?,
        lastCheckedAt: String?,
        createdAt: String?,
        rotatedFromID: String?,
        locations: [VaultLocationItem]
    ) {
        self.id = id
        self.label = label
        self.provider = provider
        self.tier = tier
        self.account = account
        self.serviceID = serviceID
        self.prefixMasked = prefixMasked
        self.last4 = last4
        self.trackedOnly = trackedOnly
        self.status = status
        self.health = health
        self.healthDetail = healthDetail
        self.lastCheckedAt = lastCheckedAt
        self.createdAt = createdAt
        self.rotatedFromID = rotatedFromID
        self.locations = locations
        let provLabel = Self.providerDisplayName(provider)
        let tLabel = tier == "admin" ? "Admin key" : "Org key"
        self.searchHaystack = "\(label) \(provLabel) \(provider) \(tLabel) \(account ?? "") \(prefixMasked) \(serviceID ?? "")"
            .lowercased()
    }

    var providerLabel: String { Self.providerDisplayName(provider) }

    static func providerDisplayName(_ provider: String) -> String {
        switch provider.lowercased() {
        case "anthropic": return "Anthropic"
        case "openai": return "OpenAI"
        case "google": return "Google / Gemini"
        case "openrouter": return "OpenRouter"
        case "xai": return "xAI / Grok"
        case "groq": return "Groq"
        case "github": return "GitHub"
        case "stripe": return "Stripe"
        case "resend": return "Resend"
        case "supabase": return "Supabase"
        case "vercel": return "Vercel"
        case "cloudflare": return "Cloudflare"
        case "flyio": return "Fly.io"
        case "huggingface": return "Hugging Face"
        case "perplexity": return "Perplexity"
        default: return provider.capitalized
        }
    }
}

struct StrayKeyFinding: Identifiable, Hashable {
    var id: String { fingerprint }
    let fingerprint: String
    let provider: String
    let providerLabel: String
    let tier: String
    let prefixMasked: String
    let gitTracked: Bool
    let locations: [VaultLocationItem]
}

struct VaultSnapshot: Equatable {
    let initialized: Bool
    let unlocked: Bool
    let sessionExpiresAt: String?
    let lastSweepAt: String?
    let lastScanAt: String?
    let keys: [VaultKeyItem]
    let strayFindings: [StrayKeyFinding]

    // Precomputed O(1) aggregates (eliminates repeated filter passes per render)
    let activeKeys: [VaultKeyItem]
    let revokedKeys: [VaultKeyItem]
    let adminCount: Int
    let orgCount: Int
    let healthyCount: Int
    let staleCount: Int
    let leakedCount: Int
    let unverifiedCount: Int
    let attentionCount: Int
    let keysByServiceID: [String: [VaultKeyItem]]

    init(
        initialized: Bool,
        unlocked: Bool,
        sessionExpiresAt: String?,
        lastSweepAt: String?,
        lastScanAt: String?,
        keys: [VaultKeyItem],
        strayFindings: [StrayKeyFinding]
    ) {
        self.initialized = initialized
        self.unlocked = unlocked
        self.sessionExpiresAt = sessionExpiresAt
        self.lastSweepAt = lastSweepAt
        self.lastScanAt = lastScanAt
        self.keys = keys
        self.strayFindings = strayFindings

        let active = keys.filter { !$0.isRevoked }
        self.activeKeys = active
        self.revokedKeys = keys.filter(\.isRevoked)
        self.adminCount = active.filter { $0.tier == "admin" }.count
        self.orgCount = active.filter { $0.tier != "admin" }.count
        self.healthyCount = active.filter { $0.health == "ok" }.count
        self.staleCount = active.filter { $0.health == "stale" }.count
        self.leakedCount = active.filter { $0.health == "leaked" }.count + strayFindings.filter(\.gitTracked).count
        self.unverifiedCount = active.filter { $0.health == "unverified" }.count
        self.attentionCount = active.filter { ["leaked", "stale", "revoked", "rate_limited"].contains($0.health) }.count

        var bySvc: [String: [VaultKeyItem]] = [:]
        for k in active {
            if let sid = k.serviceID, !sid.isEmpty {
                bySvc[sid, default: []].append(k)
            }
        }
        self.keysByServiceID = bySvc
    }

    static let empty = VaultSnapshot(
        initialized: false,
        unlocked: false,
        sessionExpiresAt: nil,
        lastSweepAt: nil,
        lastScanAt: nil,
        keys: [],
        strayFindings: []
    )
}

struct SyncMailboxStatus: Identifiable, Hashable {
    var id: String { email }
    let email: String
    let provider: String
    let status: String      // "idle_live" | "ok" | "reauth_needed" | "error"
    let detail: String
    let lastCheckedAt: String?
    let scannedCount: Int
    let matchedCount: Int
}

struct SyncIngestEvent: Identifiable, Hashable {
    var id: String { "\(serviceID)|\(date)|\(amount)|\(subject)" }
    let serviceID: String
    let serviceName: String
    let date: String
    let amount: Double
    let source: String
    let mailbox: String
    let subject: String
    let ingestedAt: String?
}

struct UnassignedCandidate: Identifiable, Hashable {
    var id: String { "\(date)|\(merchant)|\(amount)|\(mailbox)" }
    let date: String
    let merchant: String
    let amount: Double
    let mailbox: String
    let source: String
    let subject: String
}

struct SyncSnapshot: Equatable {
    let daemonPID: Int?
    let daemonAlive: Bool
    let mode: String
    let lastSyncAt: String?
    let nextHourlyAt: String?
    let asOf: String?
    let reachableMailboxes: Int
    let totalMailboxes: Int
    let mailboxes: [SyncMailboxStatus]
    let recentEvents: [SyncIngestEvent]
    let unassignedCandidates: [UnassignedCandidate]

    static let empty = SyncSnapshot(
        daemonPID: nil,
        daemonAlive: false,
        mode: "idle",
        lastSyncAt: nil,
        nextHourlyAt: nil,
        asOf: nil,
        reachableMailboxes: 0,
        totalMailboxes: 0,
        mailboxes: [],
        recentEvents: [],
        unassignedCandidates: []
    )
}

// MARK: - Reimbursement Packet Models (`~/.recurring/reimburse_state.json`)

struct ReimburseReceiptItem: Identifiable, Hashable {
    var id: String { "\(provider)|\(date)|\(receiptRef)|\(file)" }
    let provider: String
    let date: String
    let amount: Double
    let subject: String
    let receiptRef: String
    let mailbox: String
    let pdfSource: String
    let file: String
    let pages: Int
    let preApprovalDate: Bool
}

struct ReimburseGroupItem: Identifiable, Hashable {
    var id: String { provider }
    let provider: String
    let label: String
    let subtotalUSD: Double
    let receiptCount: Int
    let sourcePages: Int
    let compiledPages: Int
    let pdfPath: String
    let pdfFilename: String
    let approvalStatus: String
    let approvalTicket: String
    let approvalApprovedOn: String
    let approvalFilename: String?
    let approvalBundlePath: String?
    let preApprovalCount: Int
    let receipts: [ReimburseReceiptItem]

    var pagesReconciled: Bool { compiledPages >= sourcePages && sourcePages > 0 }
    var hasApprovalArtifact: Bool { approvalBundlePath != nil && approvalFilename != nil }
}

struct ReimburseExcludedItem: Identifiable, Hashable {
    var id: String { "\(provider)|\(date)|\(amount)|\(receiptRef)|\(reason)" }
    let provider: String
    let label: String
    let date: String
    let amount: Double
    let receiptRef: String
    let subject: String
    let reason: String
    let ticket: String
}

struct ReimburseApprovalItem: Identifiable, Hashable {
    var id: String { provider }
    let provider: String
    let label: String
    let status: String
    let ticket: String
    let approvedOn: String
    let note: String
    let file: String?
    let filename: String?

    var isVerified: Bool { file != nil && status == "approved" }
}

struct ReimburseDraftNotice: Equatable {
    let to: String
    let subject: String
    let attachment: String
    let body: String
}

struct ReimbursePacketData: Equatable {
    let batchID: String
    let batchDir: String
    let bundleSlug: String
    let zipPath: String?
    let zipFilename: String
    let periodStart: String
    let periodEnd: String
    let coverPages: Int
    let totalUSD: Double
    let receiptCount: Int
    let providerCount: Int
    let gatePassed: Bool
    let totalSourcePages: Int
    let totalCompiledPages: Int
    let violations: [String]
    let warnings: [String]
    let groups: [ReimburseGroupItem]
    let blockedUnapproved: [ReimburseExcludedItem]
    let excluded: [ReimburseExcludedItem]
    let preApprovalWarningCount: Int
    let draftNotice: ReimburseDraftNotice?
    let generatedAt: String
}

struct ReimburseBatchSummary: Identifiable, Hashable {
    var id: String { batchID }
    let batchID: String
    let batchDir: String
    let zipPath: String?
    let start: String
    let end: String
    let totalUSD: Double
    let receiptCount: Int
    let providerCount: Int
    let passed: Bool
    let generatedAt: String
}

struct ReimburseSnapshot: Equatable {
    let updatedAt: String?
    let organization: String
    let bundleSlug: String
    let approverName: String
    let approverEmail: String
    let fundingWorktag: String
    let fundNumber: String
    let lastSentDate: String?
    let defaultSinceDate: String
    let approvals: [ReimburseApprovalItem]
    let verifiedApprovalCount: Int
    let pendingApprovalCount: Int
    let latestPacket: ReimbursePacketData?
    let recentBatches: [ReimburseBatchSummary]

    static let empty = ReimburseSnapshot(
        updatedAt: nil,
        organization: "Institution",
        bundleSlug: "cloud-reimbursements",
        approverName: "",
        approverEmail: "",
        fundingWorktag: "",
        fundNumber: "",
        lastSentDate: nil,
        defaultSinceDate: "",
        approvals: [],
        verifiedApprovalCount: 0,
        pendingApprovalCount: 0,
        latestPacket: nil,
        recentBatches: []
    )
}

// MARK: - Explorer Interactive Filter / Sort / Focus State
// Decoupled from Store so typing in search, sorting columns, or expanding a row
// only re-evaluates the Explorer/linked filter chips — NEVER Swift Charts panels!

enum LedgerTypeFilter: String, CaseIterable, Hashable {
    case all = "All active+"
    case dueSoon = "Due ≤7d"
    case needsCheck = "Needs check"
    case closing = "Closing"
    case monthly = "Monthly"
    case yearly = "Yearly+"
    case prepaid = "Prepaid"
    case usage = "Usage"
    case unverified = "Unverified"
    case ended = "Ended"
}

enum LedgerSortColumn: String, CaseIterable, Hashable {
    case service = "SERVICE"
    case type = "TYPE"
    case account = "ACCOUNT · CARD"
    case cycle = "PER CYCLE"
    case monthly = "PER MONTH"
    case next = "NEXT"
    case lastCharged = "LAST CHARGED"

    var defaultAscending: Bool {
        switch self {
        case .service, .type, .account, .next: return true
        case .cycle, .monthly, .lastCharged: return false
        }
    }
}

enum AttributionFilter: Equatable {
    case account(String)
    case card(key: String, label: String)

    var pillLabel: String {
        switch self {
        case .account(let a): return "Account: \(a)"
        case .card(_, let label): return "Payment: \(label)"
        }
    }

    func matches(_ s: Service) -> Bool {
        switch self {
        case .account(let a):
            return (s.account ?? "unknown") == a
        case .card(let key, _):
            return (s.card ?? "unknown") == key
        }
    }
}

struct OverlapFilter: Equatable {
    let name: String
    let memberIDs: Set<String>
}

@MainActor
final class ExplorerState: ObservableObject {
    @Published var searchQuery: String = ""
    @Published var typeFilter: LedgerTypeFilter = .all
    @Published var categoryFilter: String? = nil
    @Published var attributionFilter: AttributionFilter? = nil
    @Published var overlapFilter: OverlapFilter? = nil
    @Published var hideDomains: Bool = false
    @Published var sortColumn: LedgerSortColumn = .monthly
    @Published var sortAscending: Bool = false
    @Published var expandedServiceID: String? = nil
    @Published var scrollRequestID: Int = 0

    @Published var vaultSearchQuery: String = ""

    var hasActiveLedgerFilters: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || typeFilter != .all
            || categoryFilter != nil
            || attributionFilter != nil
            || overlapFilter != nil
            || hideDomains
    }

    func resetLedgerFilters() {
        searchQuery = ""
        typeFilter = .all
        categoryFilter = nil
        attributionFilter = nil
        overlapFilter = nil
        hideDomains = false
    }

    func toggleSort(_ col: LedgerSortColumn) {
        if sortColumn == col {
            sortAscending.toggle()
        } else {
            sortColumn = col
            sortAscending = col.defaultAscending
        }
    }

    func toggleCategory(_ category: String, scroll: Bool = false) {
        if categoryFilter == category {
            categoryFilter = nil
        } else {
            categoryFilter = category
            if typeFilter == .ended { typeFilter = .all }
        }
        if scroll { scrollRequestID &+= 1 }
    }

    func toggleAttribution(_ filter: AttributionFilter, scroll: Bool = true) {
        if attributionFilter == filter {
            attributionFilter = nil
        } else {
            attributionFilter = filter
            overlapFilter = nil
            if typeFilter == .ended || typeFilter == .unverified { typeFilter = .all }
            if scroll { scrollRequestID &+= 1 }
        }
    }

    func toggleOverlap(_ group: CutGroup, scroll: Bool = true) {
        let ids = Set(group.members.map(\.id))
        let next = OverlapFilter(name: group.name, memberIDs: ids)
        if overlapFilter == next {
            overlapFilter = nil
        } else {
            overlapFilter = next
            categoryFilter = nil
            attributionFilter = nil
            typeFilter = .all
            if scroll { scrollRequestID &+= 1 }
        }
    }

    func focusService(_ s: Service, scroll: Bool = true) {
        if s.status == .cancelled && typeFilter != .ended {
            typeFilter = .ended
        } else if s.status == .unverified && typeFilter != .all && typeFilter != .unverified && typeFilter != .needsCheck {
            typeFilter = .all
        }
        categoryFilter = nil
        attributionFilter = nil
        overlapFilter = nil
        if s.isDomain { hideDomains = false }
        searchQuery = ""
        expandedServiceID = s.id
        if scroll { scrollRequestID &+= 1 }
    }
}

// MARK: - Precomputed Ledger & Insight Projections (O(1) View Rendering)

struct ServiceRowMeta: Equatable {
    let id: String
    let displayName: String
    let subtitle: String?
    let typeLabel: String
    let scheduleLabel: String
    let accountCardText: String
    let cycleText: String
    let monthlyEquiv: Double?
    let monthlyText: String
    let monthlySortKey: Double
    let cycleSortKey: Double
    let nextDate: Date?
    let nextSortTimestamp: TimeInterval
    let daysUntilNext: Int?
    let nextText: String
    let nextUrgent: Bool
    let lastChargedText: String
    let lastChargedSortKey: String
    let popoverSubtitle: String?
    let hasWarning: Bool
    let isDueWithin7d: Bool
    let searchHaystack: String
}

struct RenewalDayBucket: Identifiable, Equatable {
    let id: String
    let dayISO: String
    let day: Date
    let category: String
    let amount: Double
}

struct RenewalRadarData: Equatable {
    let buckets: [RenewalDayBucket]
    let categories: [String]
    let total30d: Double
    let total7d: Double
    let count30d: Int
    let count7d: Int
    let bigRenewals: [Renewal]
    let bigTotal: Double
    let peakDayLabel: String?
    let byDayISO: [String: [Renewal]]
    let endDay: Date
}

struct CashFlowData: Equatable {
    let buckets: [MonthBucket]
    let categories: [String]
    let monthTotals: [String: Double]
    let settledByMonth: [String: Double]
    let scheduledByMonth: [String: Double]
    let monthDates: [String: Date]
    let thisMonth: Date
    let thisMonthKey: String
    let horizonEnd: Date
}

struct CalendarCellData: Identifiable, Equatable {
    let id: String
    let week: String
    let weekday: String
    let date: Date
    let dayISO: String
    let amount: Double
    let chargeCount: Int
}

struct CalendarDayCharge: Identifiable, Equatable {
    var id: String { "\(serviceID)|\(amount)|\(note ?? "")" }
    let serviceID: String
    let serviceName: String
    let category: String
    let amount: Double
    let note: String?
}

struct CalendarHeatmapData: Equatable {
    let cells: [CalendarCellData]
    let byID: [String: CalendarCellData]
    let weekLabels: [String]
    let settledDays: Int
    let totalAmount: Double
    let maxAmount: Double
    let peakLabel: String?
    let busiestWeekday: String?
    let firstHalfPercent: Int?
    let totalChargeCount: Int
    let byDayISO: [String: [CalendarDayCharge]]
}

struct TermWindowItem: Identifiable, Equatable {
    var id: String { service.id }
    let service: Service
    let displayName: String
    let start: Date
    let end: Date
    let renews: Bool
    let fractionUsed: Double
    let daysLeft: Int
}

struct DomainRollupData: Equatable {
    let domains: [Service]
    let yearlyTotal: Double
    let missingPriceCount: Int
    let nextRenewalDays: Int?
    let nextRenewalRelative: String?
    let sortedNames: String
}

struct PopoverCategoryGroup: Identifiable, Equatable {
    var id: String { category }
    let category: String
    let others: [Service]
    let domains: [Service]
    let totalCount: Int
    let monthlyTotal: Double
}

// MARK: - Store

@MainActor
final class Store: ObservableObject {
    @Published private(set) var ledger: Ledger?
    @Published private(set) var derived: Derived?
    @Published private(set) var loadError: String?
    var issues: [String] { ledger?.issues ?? [] }
    @Published private(set) var today = Date()

    @Published var selectedTab: DashboardTab = .ledger
    @Published private(set) var vault: VaultSnapshot = .empty
    @Published private(set) var syncState: SyncSnapshot = .empty
    @Published private(set) var reimburse: ReimburseSnapshot = .empty

    @Published private(set) var isSyncingNow: Bool = false
    @Published private(set) var isSweepingVault: Bool = false
    @Published private(set) var isScanningEnv: Bool = false
    @Published private(set) var isBuildingPacket: Bool = false
    @Published private(set) var isVerifyingPacket: Bool = false
    @Published var statusBanner: (message: String, isError: Bool)?

    let explorer = ExplorerState()

    let fileURL = LedgerFile.url
    var dataDirURL: URL { LedgerFile.canonical(fileURL).deletingLastPathComponent() }
    var vaultFileURL: URL { dataDirURL.appendingPathComponent("vault.json") }
    var masterKeyURL: URL { dataDirURL.appendingPathComponent("master.key") }
    var syncStateURL: URL { dataDirURL.appendingPathComponent("sync_state.json") }
    var reimburseStateURL: URL { dataDirURL.appendingPathComponent("reimburse_state.json") }

    private struct FileStamp: Equatable {
        let mtime: Date?
        let inode: UInt64?
        let size: UInt64?

        static func of(_ path: String) -> FileStamp {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
                return FileStamp(mtime: nil, inode: nil, size: nil)
            }
            return FileStamp(
                mtime: attrs[.modificationDate] as? Date,
                inode: (attrs[.systemFileNumber] as? NSNumber)?.uint64Value,
                size: (attrs[.size] as? NSNumber)?.uint64Value
            )
        }
    }

    private let ioQueue = DispatchQueue(label: "com.amastro.Recurring.v3.io", qos: .userInitiated)
    private var dirFD: Int32 = -1
    private var dirSource: DispatchSourceFileSystemObject?
    nonisolated(unsafe) private var debounceWork: DispatchWorkItem?
    private var housekeepingTimer: Timer?
    private var generation = 0
    private var clipboardClearTask: Task<Void, Never>?

    // Accessed only on ioQueue (or synchronously during init)
    nonisolated(unsafe) private var lastLedgerStamp: FileStamp?
    nonisolated(unsafe) private var lastVaultStamp: FileStamp?
    nonisolated(unsafe) private var lastMasterKeyExists: Bool?
    nonisolated(unsafe) private var lastSyncStamp: FileStamp?
    nonisolated(unsafe) private var lastReimburseStamp: FileStamp?

    nonisolated static let dueSoonDays = 2
    nonisolated static let upcomingDays = 7
    nonisolated static let housekeepingSeconds: TimeInterval = 30
    nonisolated static let cashMonthsBack = 4
    nonisolated static let cashMonthsAhead = 11
    nonisolated static let renewalDays = 30
    nonisolated static let savingsDays = 30

    struct Derived: Equatable {
        let generation: Int
        let dayKey: String
        let activeCount: Int
        let monthlyTotal: Double
        let burn: Insights.BurnBreakdown
        let displayNames: [String: String]
        let servicesByID: [String: Service]
        let rowMeta: [String: ServiceRowMeta]
        let upcoming: [ScheduledEvent]
        let upcoming7dTotal: Double
        let hasDueSoon: Bool
        let renewals: [Renewal]
        let renewalRadar: RenewalRadarData
        let watch: [WatchItem]
        let lateWatch: [WatchItem]
        let watchingItems: [WatchItem]
        let clearedWatchCount: Int
        let clearedWatchNames: String
        let savings: Savings
        let cutGroups: [CutGroup]
        let cutsByMonth: [(month: String, monthly: Double)]
        let refundClaims: [(service: Service, claim: RefundClaim)]
        let pendingRefunds: Double
        let wonRefunds: Double
        let totalMoneyBack: Double
        let cashFlow: CashFlowData
        let calendarHeatmap: CalendarHeatmapData
        let termWindows: [TermWindowItem]
        let domainRollup: DomainRollupData?
        let orderedCategories: [String]
        let popoverCategories: [PopoverCategoryGroup]
        let typeFilterCounts: [LedgerTypeFilter: Int]
        let categoryCounts: [String: Int]

        static func == (lhs: Derived, rhs: Derived) -> Bool {
            lhs.generation == rhs.generation && lhs.dayKey == rhs.dayKey
        }

        nonisolated static func build(ledger: Ledger, today: Date, generation: Int) -> Derived {
            let cal = Schedule.calendar
            let startToday = cal.startOfDay(for: today)
            let dayKey = Schedule.isoDay(startToday)

            let names = ledger.disambiguatedNames()
            let svcsByID = Dictionary(ledger.services.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let burn = Insights.burnBreakdown(ledger, today: startToday)
            let upcoming = Schedule.events(ledger, from: startToday, within: Store.upcomingDays)
            let upcoming7dTotal = upcoming.filter { $0.kind == .charge }.compactMap(\.amount).reduce(0, +)
            let hasDueSoon = upcoming.contains {
                $0.kind == .charge && Schedule.daysUntil($0.date, from: startToday) <= Store.dueSoonDays
            }

            let renewals = Insights.renewals(ledger, from: startToday, within: Store.renewalDays)
            let watch = Insights.watch(ledger, today: startToday)
            let lateWatch = watch.filter { $0.status == .chargedAfterCancel }
            let watchingItems = watch.filter { $0.status == .watching }
            let clearedWatch = watch.filter { $0.status == .clear }

            let savings = Insights.savings(ledger, today: startToday, sinceDays: Store.savingsDays)
            let cutGroups = Insights.cutGroups(ledger, today: startToday)
            let cutsByMonth = Insights.cutsByMonth(ledger, today: startToday)
            let refundClaims = Insights.refunds(ledger)
            let pendingRefunds = Insights.pendingRefundTotal(ledger)
            let wonRefunds = refundClaims.filter { $0.claim.status == .won }.map(\.claim.amount).reduce(0, +)
            let totalMoneyBack = pendingRefunds + lateWatch.map(\.lateTotal).reduce(0, +)

            // 1. Precompute per-service RowMeta & filter counts in a single pass
            var metaMap: [String: ServiceRowMeta] = [:]
            metaMap.reserveCapacity(ledger.services.count)

            var typeCounts: [LedgerTypeFilter: Int] = [:]
            var catCounts: [String: Int] = [:]

            for s in ledger.services {
                let disp = names[s.id] ?? s.name
                let mo = s.monthlyEquivalent(on: startToday)
                let moText = mo.map(Money.exact) ?? "—"
                let cycText = Money.row(s)
                let acctCard = [s.accountShort, s.card].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")

                let nextDate = Schedule.nextCharge(for: s, from: startToday)
                let daysNext = nextDate.map { Schedule.daysUntil($0, from: startToday) }

                let nextTuple: (String, Bool, TimeInterval)
                if s.status == .cancelled {
                    if s.isEnding(on: startToday), let e = Schedule.parseDay(s.endsOn) {
                        nextTuple = ("ends \(DayText.short(e))", false, e.timeIntervalSince1970 + 1e9)
                    } else {
                        let txt = s.cancelledOn.flatMap(Schedule.parseDay).map { "ended \(DayText.short($0))" } ?? "ended"
                        nextTuple = (txt, false, 9e12)
                    }
                } else if s.status == .unverified {
                    nextTuple = ("unverified", false, 8e12)
                } else if s.isClosing {
                    let txt = nextDate.map { "closing · \(DayText.relative($0, from: startToday))" } ?? "closing"
                    nextTuple = (txt, true, nextDate?.timeIntervalSince1970 ?? 7e12)
                } else if s.termIsRunning(on: startToday), let e = Schedule.parseDay(s.termEnd) {
                    nextTuple = ("expires \(DayText.relative(e, from: startToday))", false, e.timeIntervalSince1970)
                } else if let d = nextDate, let dn = daysNext {
                    nextTuple = (DayText.relative(d, from: startToday), dn <= Store.dueSoonDays, d.timeIntervalSince1970)
                } else {
                    nextTuple = ("—", false, 6e12)
                }

                let lastDate = Schedule.parseDay(s.lastCharged)
                let lastText = lastDate.map(DayText.short) ?? "—"
                let lastSort = s.lastCharged ?? ""

                let popSub: String? = {
                    if s.isClosing, let nd = nextDate {
                        return "closing · next charge \(DayText.relative(nd, from: startToday))"
                    }
                    if s.status == .cancelled {
                        return s.cancelledOn.map { "ended \(Schedule.parseDay($0).map(DayText.short) ?? $0)" } ?? "ended"
                    }
                    if s.status == .unverified {
                        return s.lastCharged.map { "last seen \(Schedule.parseDay($0).map(DayText.short) ?? $0)" } ?? "no charge seen"
                    }
                    let parts = [
                        lastDate.map { "charged \(DayText.short($0))" },
                        s.accountShort.isEmpty ? nil : s.accountShort,
                    ]
                    let joined = parts.compactMap { $0 }.joined(separator: " · ")
                    return joined.isEmpty ? nil : joined
                }()

                let sub = [s.plan, s.note].compactMap { $0 }.first
                let due7 = s.status == .active && (daysNext.map { $0 >= 0 && $0 <= 7 } ?? false)
                let hay = [
                    disp, s.id, s.category, s.plan ?? "", s.account ?? "",
                    s.card ?? "", s.note ?? "", s.check ?? "", s.cadence.label, s.status.rawValue,
                ].joined(separator: " ").lowercased()

                metaMap[s.id] = ServiceRowMeta(
                    id: s.id,
                    displayName: disp,
                    subtitle: sub,
                    typeLabel: s.typeLabel,
                    scheduleLabel: s.scheduleLabel,
                    accountCardText: acctCard,
                    cycleText: cycText,
                    monthlyEquiv: mo,
                    monthlyText: moText,
                    monthlySortKey: mo ?? -1,
                    cycleSortKey: s.amount ?? -1,
                    nextDate: nextDate,
                    nextSortTimestamp: nextTuple.2,
                    daysUntilNext: daysNext,
                    nextText: nextTuple.0,
                    nextUrgent: nextTuple.1,
                    lastChargedText: lastText,
                    lastChargedSortKey: lastSort,
                    popoverSubtitle: popSub,
                    hasWarning: s.check != nil || s.status == .unverified,
                    isDueWithin7d: due7,
                    searchHaystack: hay
                )

                // Tally filter counts
                if s.status != .cancelled {
                    typeCounts[.all, default: 0] += 1
                    catCounts[s.category, default: 0] += 1
                }
                if due7 { typeCounts[.dueSoon, default: 0] += 1 }
                if s.status == .unverified || (s.status == .active && s.check != nil && !s.isClosing) {
                    typeCounts[.needsCheck, default: 0] += 1
                }
                if s.isClosing { typeCounts[.closing, default: 0] += 1 }
                if s.status == .active && [.monthly, .biweekly].contains(s.cadence) {
                    typeCounts[.monthly, default: 0] += 1
                }
                if s.status == .active && (s.cadence.months ?? 0) >= 3 {
                    typeCounts[.yearly, default: 0] += 1
                }
                if s.status == .active && s.cadence == .term {
                    typeCounts[.prepaid, default: 0] += 1
                }
                if s.status == .active && s.cadence == .usage {
                    typeCounts[.usage, default: 0] += 1
                }
                if s.status == .unverified { typeCounts[.unverified, default: 0] += 1 }
                if s.status == .cancelled { typeCounts[.ended, default: 0] += 1 }
            }

            // 2. Precompute Renewal Radar 30d model
            var rSums: [String: (String, Date, String, Double)] = [:]
            var rPerDay: [String: Double] = [:]
            var rByDayISO: [String: [Renewal]] = [:]
            var total7d = 0.0
            var count7d = 0
            for r in renewals {
                let iso = Schedule.isoDay(r.date)
                rByDayISO[iso, default: []].append(r)
                if r.daysLeft <= 7 {
                    count7d += 1
                    total7d += r.amount ?? 0
                }
                guard let a = r.amount else { continue }
                rPerDay[iso, default: 0] += a
                let k = "\(iso)|\(r.service.category)"
                let cur = rSums[k] ?? (iso, r.date, r.service.category, 0)
                rSums[k] = (cur.0, cur.1, cur.2, cur.3 + a)
            }
            var rBuckets: [RenewalDayBucket] = []
            rBuckets.reserveCapacity(rSums.count)
            for (key, v) in rSums {
                rBuckets.append(RenewalDayBucket(id: key, dayISO: v.0, day: v.1, category: v.2, amount: v.3))
            }
            rBuckets.sort { a, b in
                a.day == b.day ? a.category < b.category : a.day < b.day
            }
            let rCats = DS.orderedCategories(Array(Set(rBuckets.map { $0.category })))
            let total30d = renewals.compactMap(\.amount).reduce(0, +)
            let bigRenewals = renewals.filter { ($0.amount ?? 0) >= Insights.bigRenewal }
            let bigTotal = bigRenewals.compactMap(\.amount).reduce(0, +)
            let peakEntry = rPerDay.max { $0.value < $1.value }
            let peakLabel: String? = peakEntry.flatMap { pe in
                Schedule.parseDay(pe.key).map { "\(DayText.short($0)) · \(Money.whole(pe.value))" }
            }
            let end30d = cal.date(byAdding: .day, value: 31, to: startToday) ?? startToday
            let radar = RenewalRadarData(
                buckets: rBuckets,
                categories: rCats,
                total30d: total30d,
                total7d: total7d,
                count30d: renewals.count,
                count7d: count7d,
                bigRenewals: bigRenewals,
                bigTotal: bigTotal,
                peakDayLabel: peakLabel,
                byDayISO: rByDayISO,
                endDay: end30d
            )

            // 3. Precompute CashFlow summary
            let cfBuckets = CashFlow.buckets(ledger, today: startToday, monthsBack: Store.cashMonthsBack, monthsAhead: Store.cashMonthsAhead)
            let cfCats = DS.orderedCategories(Array(Set(cfBuckets.map(\.category))))
            var mTotals: [String: Double] = [:]
            var mSettled: [String: Double] = [:]
            var mScheduled: [String: Double] = [:]
            var mDates: [String: Date] = [:]
            for b in cfBuckets {
                mTotals[b.month, default: 0] += b.amount
                if b.projected {
                    mScheduled[b.month, default: 0] += b.amount
                } else {
                    mSettled[b.month, default: 0] += b.amount
                }
                if mDates[b.month] == nil {
                    let parts = b.month.split(separator: "-").compactMap { Int($0) }
                    if parts.count == 2, let md = Schedule.clampedDate(year: parts[0], month: parts[1], day: 1) {
                        mDates[b.month] = md
                    }
                }
            }
            let thisMonthComps = cal.dateComponents([.year, .month], from: startToday)
            let thisMonth = Schedule.clampedDate(year: thisMonthComps.year ?? 2026, month: thisMonthComps.month ?? 1, day: 1) ?? startToday
            let thisMonthKey = Schedule.monthKey(thisMonth)
            if mDates[thisMonthKey] == nil { mDates[thisMonthKey] = thisMonth }
            let horizonEnd = cal.date(byAdding: .month, value: 12, to: thisMonth) ?? startToday
            let cfData = CashFlowData(
                buckets: cfBuckets,
                categories: cfCats,
                monthTotals: mTotals,
                settledByMonth: mSettled,
                scheduledByMonth: mScheduled,
                monthDates: mDates,
                thisMonth: thisMonth,
                thisMonthKey: thisMonthKey,
                horizonEnd: horizonEnd
            )

            // 4. Precompute 20-week Charge Calendar Heatmap
            let weeks = 20
            let weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
            var perDayAmt: [String: Double] = [:]
            var perDayEntries: [String: [CalendarDayCharge]] = [:]
            var allChargeCount = 0
            for s in ledger.services {
                let sName = names[s.id] ?? s.name
                for c in s.charges where c.amount > 0 {
                    perDayAmt[c.date, default: 0] += c.amount
                    perDayEntries[c.date, default: []].append(
                        CalendarDayCharge(serviceID: s.id, serviceName: sName, category: s.category, amount: c.amount, note: c.note)
                    )
                    allChargeCount += 1
                }
            }
            for k in perDayEntries.keys {
                perDayEntries[k]?.sort { $0.amount > $1.amount }
            }
            let weekdayIdx = (cal.component(.weekday, from: startToday) + 5) % 7
            let thisMonday = cal.date(byAdding: .day, value: -weekdayIdx, to: startToday) ?? startToday
            let gridStart = cal.date(byAdding: .day, value: -7 * (weeks - 1), to: thisMonday) ?? startToday
            var cells: [CalendarCellData] = []
            cells.reserveCapacity(weeks * 7)
            var weekLabels: [String] = []
            for w in 0..<weeks {
                guard let monday = cal.date(byAdding: .day, value: 7 * w, to: gridStart) else { continue }
                let label = "\(DayText.short(monday))#\(w)"
                weekLabels.append(label)
                for d in 0..<7 {
                    guard let day = cal.date(byAdding: .day, value: d, to: monday), day <= startToday else { continue }
                    let iso = Schedule.isoDay(day)
                    let cellID = "\(label)|\(weekdays[d])"
                    cells.append(CalendarCellData(
                        id: cellID,
                        week: label,
                        weekday: weekdays[d],
                        date: day,
                        dayISO: iso,
                        amount: perDayAmt[iso] ?? 0,
                        chargeCount: perDayEntries[iso]?.count ?? 0
                    ))
                }
            }
            let cellsByID = Dictionary(cells.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let activeCells = cells.filter { $0.amount > 0 }
            let calMax = activeCells.map(\.amount).max() ?? 1
            let calTotal = activeCells.map(\.amount).reduce(0, +)
            let calBiggest = activeCells.max { $0.amount < $1.amount }
            let byWd = Dictionary(grouping: activeCells, by: \.weekday).mapValues { $0.map(\.amount).reduce(0, +) }
            let busiestWd = byWd.max { $0.value < $1.value }?.key
            let firstHalfAmt = activeCells.filter { cal.component(.day, from: $0.date) <= 15 }.map(\.amount).reduce(0, +)
            let heatmap = CalendarHeatmapData(
                cells: cells,
                byID: cellsByID,
                weekLabels: weekLabels,
                settledDays: activeCells.count,
                totalAmount: calTotal,
                maxAmount: calMax,
                peakLabel: calBiggest.map { "\(DayText.short($0.date)) \(Money.whole($0.amount))" },
                busiestWeekday: busiestWd,
                firstHalfPercent: calTotal > 0 ? Int((firstHalfAmt / calTotal * 100).rounded()) : nil,
                totalChargeCount: allChargeCount,
                byDayISO: perDayEntries
            )

            // 5. Precompute Multi-month & Prepaid Term Windows + Domain Rollup
            let activeSvcs = ledger.active
            let domains = activeSvcs.filter(\.isDomain)
            let termItems: [TermWindowItem] = activeSvcs
                .filter { !$0.isDomain && ($0.cadence == .term || ($0.cadence.months ?? 0) >= 6) && $0.amount != nil }
                .compactMap { s -> TermWindowItem? in
                    let start: Date
                    let end: Date
                    let renews: Bool
                    if s.cadence == .term, let a = Schedule.parseDay(s.termStart), let b = Schedule.parseDay(s.termEnd) {
                        start = a; end = b; renews = false
                    } else if let next = metaMap[s.id]?.nextDate, let m = s.cadence.months,
                              let st = cal.date(byAdding: .month, value: -m, to: next) {
                        start = st; end = next; renews = true
                    } else {
                        return nil
                    }
                    let span = max(1, Double(Schedule.daysUntil(end, from: start)))
                    let used = min(1, max(0, Double(Schedule.daysUntil(startToday, from: start)) / span))
                    let left = Schedule.daysUntil(end, from: startToday)
                    return TermWindowItem(
                        service: s,
                        displayName: names[s.id] ?? s.name,
                        start: start,
                        end: end,
                        renews: renews,
                        fractionUsed: used,
                        daysLeft: left
                    )
                }
                .sorted { $0.end < $1.end }

            let domainRollup: DomainRollupData? = {
                guard !domains.isEmpty else { return nil }
                let yr = domains.compactMap { $0.yearlyEquivalent(on: startToday) }.reduce(0, +)
                let missing = domains.filter { $0.amount == nil }.count
                let nextD = domains.compactMap { metaMap[$0.id]?.nextDate ?? Schedule.parseDay($0.termEnd) }.min()
                return DomainRollupData(
                    domains: domains,
                    yearlyTotal: yr,
                    missingPriceCount: missing,
                    nextRenewalDays: nextD.map { Schedule.daysUntil($0, from: startToday) },
                    nextRenewalRelative: nextD.map { DayText.relative($0, from: startToday) },
                    sortedNames: domains.map(\.name).sorted().joined(separator: ", ")
                )
            }()

            // 6. Precompute Ordered Categories & Popover Sections
            let orderedCats = DS.orderedCategories(ledger.categories)
            let popGroups: [PopoverCategoryGroup] = orderedCats.compactMap { cat in
                let items = activeSvcs
                    .filter { $0.category == cat && !$0.isClosing }
                    .sorted { (metaMap[$0.id]?.monthlySortKey ?? 0) > (metaMap[$1.id]?.monthlySortKey ?? 0) }
                guard !items.isEmpty else { return nil }
                let doms = items.filter(\.isDomain)
                let others = items.filter { !$0.isDomain }
                let moSum = items.compactMap { metaMap[$0.id]?.monthlyEquiv }.reduce(0, +)
                return PopoverCategoryGroup(
                    category: cat,
                    others: others,
                    domains: doms,
                    totalCount: items.count,
                    monthlyTotal: moSum
                )
            }

            return Derived(
                generation: generation,
                dayKey: dayKey,
                activeCount: activeSvcs.count,
                monthlyTotal: burn.totalMonthly,
                burn: burn,
                displayNames: names,
                servicesByID: svcsByID,
                rowMeta: metaMap,
                upcoming: upcoming,
                upcoming7dTotal: upcoming7dTotal,
                hasDueSoon: hasDueSoon,
                renewals: renewals,
                renewalRadar: radar,
                watch: watch,
                lateWatch: lateWatch,
                watchingItems: watchingItems,
                clearedWatchCount: clearedWatch.count,
                clearedWatchNames: clearedWatch.map(\.service.name).joined(separator: ", "),
                savings: savings,
                cutGroups: cutGroups,
                cutsByMonth: cutsByMonth,
                refundClaims: refundClaims,
                pendingRefunds: pendingRefunds,
                wonRefunds: wonRefunds,
                totalMoneyBack: totalMoneyBack,
                cashFlow: cfData,
                calendarHeatmap: heatmap,
                termWindows: termItems,
                domainRollup: domainRollup,
                orderedCategories: orderedCats,
                popoverCategories: popGroups,
                typeFilterCounts: typeCounts,
                categoryCounts: catCounts
            )
        }
    }

    init(poll: Bool = true, initialTab: DashboardTab = .ledger) {
        self.selectedTab = initialTab
        reloadSynchronously(force: true)
        guard poll else { return }
        startDirectoryWatcher()
        housekeepingTimer = Timer.scheduledTimer(withTimeInterval: Self.housekeepingSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.runHousekeepingTick()
            }
        }
        housekeepingTimer?.tolerance = 10
    }

    deinit {
        debounceWork?.cancel()
        dirSource?.cancel()
        housekeepingTimer?.invalidate()
    }

    // MARK: Convenience Accessors (O(1) reads from `derived`)

    var monthlyTotal: Double { derived?.monthlyTotal ?? 0 }
    var upcoming: [ScheduledEvent] { derived?.upcoming ?? [] }
    var hasDueSoon: Bool { derived?.hasDueSoon ?? false }
    var dataAgeDays: Int? {
        guard let d = Schedule.parseDay(ledger?.asOf) else { return nil }
        return Schedule.daysUntil(today, from: d)
    }
    var renewals: [Renewal] { derived?.renewals ?? [] }
    var watchItems: [WatchItem] { derived?.watch ?? [] }
    var savings: Savings? { derived?.savings }
    var cutGroups: [CutGroup] { derived?.cutGroups ?? [] }
    var cutsByMonth: [(month: String, monthly: Double)] { derived?.cutsByMonth ?? [] }
    var refundClaims: [(service: Service, claim: RefundClaim)] { derived?.refundClaims ?? [] }
    var pendingRefunds: Double { derived?.pendingRefunds ?? 0 }
    var cashFlow: [MonthBucket] { derived?.cashFlow.buckets ?? [] }

    func displayName(for service: Service) -> String {
        derived?.displayNames[service.id] ?? service.name
    }

    func meta(for service: Service) -> ServiceRowMeta? {
        derived?.rowMeta[service.id]
    }

    // MARK: Kernel File-System Watcher + Background I/O Reload

    private func startDirectoryWatcher() {
        let dir = dataDirURL
        try? LedgerFile.ensurePrivateDirectory(dir)
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        self.dirFD = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .attrib],
            queue: ioQueue
        )
        source.setEventHandler { [weak self] in
            self?.scheduleBackgroundReload(force: false)
        }
        source.setCancelHandler {
            close(fd)
        }
        self.dirSource = source
        source.resume()
    }

    nonisolated private func scheduleBackgroundReload(force: Bool) {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.performBackgroundReload(force: force)
        }
        debounceWork = work
        ioQueue.asyncAfter(deadline: .now() + .milliseconds(55), execute: work)
    }

    private func runHousekeepingTick() {
        let now = Date()
        if !Schedule.calendar.isDate(now, inSameDayAs: today) {
            today = now
            if let ledger {
                generation &+= 1
                let gen = generation
                ioQueue.async { [weak self] in
                    let d = Derived.build(ledger: ledger, today: now, generation: gen)
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == gen else { return }
                        self.derived = d
                    }
                }
            }
        }
        // Check file changes & daemon PID liveness off main actor
        ioQueue.async { [weak self] in
            self?.performBackgroundReload(force: false, refreshDaemonLiveness: true)
        }
    }

    func reload(force: Bool) {
        ioQueue.async { [weak self] in
            self?.performBackgroundReload(force: force)
        }
    }

    /// Synchronous load path used ONCE at process startup and by `--snapshot` headless rendering.
    func reloadSynchronously(force: Bool) {
        let lURL = fileURL
        let vURL = vaultFileURL
        let mkURL = masterKeyURL
        let sURL = syncStateURL
        let now = today

        let lStamp = FileStamp.of(lURL.path)
        if force || lStamp != lastLedgerStamp {
            lastLedgerStamp = lStamp
            switch Self.decodeLedger(from: lURL) {
            case .loaded(let l):
                generation &+= 1
                ledger = l
                derived = Derived.build(ledger: l, today: now, generation: generation)
                loadError = nil
                log.notice("Recurring: loaded \(l.services.count, privacy: .public) services, \(l.issues.count, privacy: .public) file problems")
            case .missing(let msg):
                ledger = nil
                derived = nil
                loadError = msg
            case .failed(let msg):
                loadError = msg
            }
        }

        let vStamp = FileStamp.of(vURL.path)
        let mkExists = FileManager.default.fileExists(atPath: mkURL.path)
        if force || vStamp != lastVaultStamp || mkExists != lastMasterKeyExists {
            lastVaultStamp = vStamp
            lastMasterKeyExists = mkExists
            vault = Self.decodeVault(from: vURL, mkExists: mkExists)
        }

        let sStamp = FileStamp.of(sURL.path)
        if force || sStamp != lastSyncStamp {
            lastSyncStamp = sStamp
            syncState = Self.decodeSyncState(from: sURL)
        }

        let rURL = reimburseStateURL
        let rStamp = FileStamp.of(rURL.path)
        if force || rStamp != lastReimburseStamp {
            lastReimburseStamp = rStamp
            reimburse = Self.decodeReimburseState(from: rURL)
        }
    }

    nonisolated private func performBackgroundReload(force: Bool, refreshDaemonLiveness: Bool = false) {
        let lURL = LedgerFile.url
        let canonicalDir = LedgerFile.canonical(lURL).deletingLastPathComponent()
        let vURL = canonicalDir.appendingPathComponent("vault.json")
        let mkURL = canonicalDir.appendingPathComponent("master.key")
        let sURL = canonicalDir.appendingPathComponent("sync_state.json")
        let rURL = canonicalDir.appendingPathComponent("reimburse_state.json")

        let lStamp = FileStamp.of(lURL.path)
        var ledgerUpdate: LedgerDecodeResult?
        if force || lStamp != lastLedgerStamp {
            lastLedgerStamp = lStamp
            ledgerUpdate = Self.decodeLedger(from: lURL)
        }

        let vStamp = FileStamp.of(vURL.path)
        let mkExists = FileManager.default.fileExists(atPath: mkURL.path)
        var vaultUpdate: VaultSnapshot?
        if force || vStamp != lastVaultStamp || mkExists != lastMasterKeyExists {
            lastVaultStamp = vStamp
            lastMasterKeyExists = mkExists
            vaultUpdate = Self.decodeVault(from: vURL, mkExists: mkExists)
        }

        let sStamp = FileStamp.of(sURL.path)
        var syncUpdate: SyncSnapshot?
        if force || sStamp != lastSyncStamp || refreshDaemonLiveness {
            lastSyncStamp = sStamp
            syncUpdate = Self.decodeSyncState(from: sURL)
        }

        let rStamp = FileStamp.of(rURL.path)
        var reimburseUpdate: ReimburseSnapshot?
        if force || rStamp != lastReimburseStamp {
            lastReimburseStamp = rStamp
            reimburseUpdate = Self.decodeReimburseState(from: rURL)
        }

        guard ledgerUpdate != nil || vaultUpdate != nil || syncUpdate != nil || reimburseUpdate != nil else { return }

        let now = Date()
        let prebuiltDerived: Derived? = {
            if case .loaded(let l) = ledgerUpdate {
                return Derived.build(ledger: l, today: now, generation: 0)
            }
            return nil
        }()

        Task { @MainActor [weak self] in
            guard let self else { return }
            if !Schedule.calendar.isDate(now, inSameDayAs: self.today) {
                self.today = now
            }
            if let ledgerUpdate {
                switch ledgerUpdate {
                case .loaded(let l):
                    self.generation &+= 1
                    self.ledger = l
                    if let d = prebuiltDerived {
                        self.derived = Derived.withGeneration(d, generation: self.generation)
                    } else {
                        self.derived = Derived.build(ledger: l, today: self.today, generation: self.generation)
                    }
                    self.loadError = nil
                case .missing(let msg):
                    self.ledger = nil
                    self.derived = nil
                    self.loadError = msg
                case .failed(let msg):
                    self.loadError = msg
                }
            }
            if let vaultUpdate, vaultUpdate != self.vault {
                self.vault = vaultUpdate
            }
            if let syncUpdate, syncUpdate != self.syncState {
                self.syncState = syncUpdate
            }
            if let reimburseUpdate, reimburseUpdate != self.reimburse {
                self.reimburse = reimburseUpdate
            }
        }
    }

    private enum LedgerDecodeResult {
        case loaded(Ledger)
        case missing(String)
        case failed(String)
    }

    nonisolated private static func decodeLedger(from url: URL) -> LedgerDecodeResult {
        do {
            let l = try LedgerFile.load(from: url)
            return .loaded(l)
        } catch CocoaError.fileReadNoSuchFile {
            return .missing("No list yet at \(url.path)")
        } catch {
            return .failed("Couldn't read \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    nonisolated private static func decodeVault(from url: URL, mkExists: Bool) -> VaultSnapshot {
        guard let data = try? Data(contentsOf: url),
              let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return VaultSnapshot(
                initialized: mkExists,
                unlocked: false,
                sessionExpiresAt: nil,
                lastSweepAt: nil,
                lastScanAt: nil,
                keys: [],
                strayFindings: []
            )
        }

        let expiresISO = raw["session_expires_at"] as? String
        let isUnlocked: Bool = {
            guard let expDate = DayText.parseISO(expiresISO) else { return false }
            return expDate > Date()
        }()

        let rawKeys = (raw["keys"] as? [[String: Any]]) ?? []
        let parsedKeys: [VaultKeyItem] = rawKeys.compactMap { o in
            guard let id = o["id"] as? String else { return nil }
            let rawLocs = (o["locations"] as? [[String: Any]]) ?? []
            let locs = rawLocs.compactMap { l -> VaultLocationItem? in
                guard let p = l["path"] as? String else { return nil }
                return VaultLocationItem(
                    path: p,
                    varName: (l["var_name"] as? String) ?? "API_KEY",
                    gitTracked: (l["git_tracked"] as? Bool) ?? false
                )
            }
            return VaultKeyItem(
                id: id,
                label: (o["label"] as? String) ?? id,
                provider: (o["provider"] as? String) ?? "other",
                tier: ((o["tier"] as? String) == "admin") ? "admin" : "org",
                account: o["account"] as? String,
                serviceID: o["service_id"] as? String,
                prefixMasked: (o["prefix_masked"] as? String) ?? "••••••••",
                last4: o["last4"] as? String,
                trackedOnly: (o["tracked_only"] as? Bool) ?? false,
                status: (o["status"] as? String) ?? "active",
                health: (o["health"] as? String) ?? "unverified",
                healthDetail: o["health_detail"] as? String,
                lastCheckedAt: o["last_checked_at"] as? String,
                createdAt: o["created_at"] as? String,
                rotatedFromID: o["rotated_from_id"] as? String,
                locations: locs
            )
        }

        let rawStrays = (raw["stray_findings"] as? [[String: Any]]) ?? []
        let parsedStrays: [StrayKeyFinding] = rawStrays.compactMap { s in
            guard let fp = s["fingerprint"] as? String else { return nil }
            let rawLocs = (s["locations"] as? [[String: Any]]) ?? []
            let locs = rawLocs.compactMap { l -> VaultLocationItem? in
                guard let p = l["path"] as? String else { return nil }
                return VaultLocationItem(
                    path: p,
                    varName: (l["var_name"] as? String) ?? "API_KEY",
                    gitTracked: (l["git_tracked"] as? Bool) ?? false
                )
            }
            return StrayKeyFinding(
                fingerprint: fp,
                provider: (s["provider"] as? String) ?? "other",
                providerLabel: (s["provider_label"] as? String) ?? "Other",
                tier: ((s["tier"] as? String) == "admin") ? "admin" : "org",
                prefixMasked: (s["prefix_masked"] as? String) ?? "••••••••",
                gitTracked: (s["git_tracked"] as? Bool) ?? false,
                locations: locs
            )
        }

        return VaultSnapshot(
            initialized: mkExists,
            unlocked: isUnlocked,
            sessionExpiresAt: expiresISO,
            lastSweepAt: raw["last_sweep_at"] as? String,
            lastScanAt: raw["last_scan_at"] as? String,
            keys: parsedKeys,
            strayFindings: parsedStrays
        )
    }

    nonisolated private static func decodeSyncState(from url: URL) -> SyncSnapshot {
        guard let data = try? Data(contentsOf: url),
              let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .empty
        }

        let pid = raw["daemon_pid"] as? Int
        let alive: Bool = {
            guard let pid, pid > 1 else { return false }
            errno = 0
            let rc = kill(pid_t(pid), 0)
            return rc == 0 || errno == EPERM
        }()

        let mboxDict = (raw["mailboxes"] as? [String: [String: Any]]) ?? [:]
        let orderedEmails = (raw["mailbox_order"] as? [String]) ?? []
        let allEmails = orderedEmails + mboxDict.keys.filter { !orderedEmails.contains($0) }.sorted()
        let mailboxes: [SyncMailboxStatus] = allEmails.compactMap { em in
            guard let m = mboxDict[em] else { return nil }
            return SyncMailboxStatus(
                email: em,
                provider: (m["provider"] as? String) ?? "mail",
                status: (m["status"] as? String) ?? "unknown",
                detail: (m["detail"] as? String) ?? "",
                lastCheckedAt: m["last_checked_at"] as? String,
                scannedCount: (m["scanned_count"] as? Int) ?? 0,
                matchedCount: (m["matched_count"] as? Int) ?? 0
            )
        }

        let rawEvents = (raw["recent_events"] as? [[String: Any]]) ?? []
        let events: [SyncIngestEvent] = rawEvents.compactMap { e in
            guard let sid = e["service_id"] as? String,
                  let date = e["date"] as? String,
                  let amt = (e["amount"] as? NSNumber)?.doubleValue else { return nil }
            return SyncIngestEvent(
                serviceID: sid,
                serviceName: (e["service_name"] as? String) ?? sid,
                date: date,
                amount: amt,
                source: (e["source"] as? String) ?? "receipt",
                mailbox: (e["mailbox"] as? String) ?? "",
                subject: (e["subject"] as? String) ?? "",
                ingestedAt: e["ingested_at"] as? String
            )
        }

        let rawUnassigned = (raw["unassigned_candidates"] as? [[String: Any]]) ?? []
        let unassigned: [UnassignedCandidate] = rawUnassigned.compactMap { u in
            guard let date = u["date"] as? String,
                  let merch = u["merchant"] as? String,
                  let amt = (u["amount"] as? NSNumber)?.doubleValue else { return nil }
            return UnassignedCandidate(
                date: date,
                merchant: merch,
                amount: amt,
                mailbox: (u["mailbox"] as? String) ?? "",
                source: (u["source"] as? String) ?? "receipt",
                subject: (u["subject"] as? String) ?? ""
            )
        }

        return SyncSnapshot(
            daemonPID: pid,
            daemonAlive: alive,
            mode: (raw["mode"] as? String) ?? "hourly",
            lastSyncAt: raw["last_sync_at"] as? String,
            nextHourlyAt: raw["next_hourly_at"] as? String,
            asOf: raw["as_of"] as? String,
            reachableMailboxes: (raw["reachable_mailboxes"] as? Int) ?? mailboxes.filter { ["ok", "idle_live"].contains($0.status) }.count,
            totalMailboxes: (raw["total_mailboxes"] as? Int) ?? mailboxes.count,
            mailboxes: mailboxes,
            recentEvents: events,
            unassignedCandidates: unassigned
        )
    }

    nonisolated private static func decodeReimburseState(from url: URL) -> ReimburseSnapshot {
        guard let data = try? Data(contentsOf: url),
              let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .empty
        }

        let rawApprovals = (raw["approvals"] as? [[String: Any]]) ?? []
        let approvals: [ReimburseApprovalItem] = rawApprovals.compactMap { a in
            guard let prov = a["provider"] as? String else { return nil }
            return ReimburseApprovalItem(
                provider: prov,
                label: (a["label"] as? String) ?? prov,
                status: (a["status"] as? String) ?? "missing",
                ticket: (a["ticket"] as? String) ?? "",
                approvedOn: (a["approved_on"] as? String) ?? "",
                note: (a["note"] as? String) ?? "",
                file: a["file"] as? String,
                filename: a["filename"] as? String
            )
        }

        func parseExcluded(_ arr: [[String: Any]]) -> [ReimburseExcludedItem] {
            arr.compactMap { e in
                guard let prov = e["provider"] as? String else { return nil }
                return ReimburseExcludedItem(
                    provider: prov,
                    label: (e["label"] as? String) ?? VaultKeyItem.providerDisplayName(prov),
                    date: (e["date"] as? String) ?? "",
                    amount: (e["amount"] as? NSNumber)?.doubleValue ?? 0,
                    receiptRef: (e["receipt_ref"] as? String) ?? "",
                    subject: (e["subject"] as? String) ?? "",
                    reason: (e["reason"] as? String) ?? "excluded",
                    ticket: (e["ticket"] as? String) ?? ""
                )
            }
        }

        let latestPacket: ReimbursePacketData? = {
            guard let p = raw["latest_packet"] as? [String: Any] else { return nil }
            let period = (p["period"] as? [String: Any]) ?? [:]
            let ver = (p["verification"] as? [String: Any]) ?? [:]
            let rawGroups = (p["groups"] as? [[String: Any]]) ?? []
            let groups: [ReimburseGroupItem] = rawGroups.compactMap { g in
                guard let prov = g["provider"] as? String else { return nil }
                let rawRcpts = (g["receipts"] as? [[String: Any]]) ?? []
                let rcpts: [ReimburseReceiptItem] = rawRcpts.map { r in
                    ReimburseReceiptItem(
                        provider: (r["provider"] as? String) ?? prov,
                        date: (r["date"] as? String) ?? "",
                        amount: (r["amount"] as? NSNumber)?.doubleValue ?? 0,
                        subject: (r["subject"] as? String) ?? "",
                        receiptRef: (r["receipt_ref"] as? String) ?? "",
                        mailbox: (r["mailbox"] as? String) ?? "",
                        pdfSource: (r["pdf_source"] as? String) ?? "attachment",
                        file: (r["file"] as? String) ?? "",
                        pages: (r["pages"] as? Int) ?? 1,
                        preApprovalDate: (r["pre_approval_date"] as? Bool) ?? false
                    )
                }
                return ReimburseGroupItem(
                    provider: prov,
                    label: (g["label"] as? String) ?? prov,
                    subtotalUSD: (g["subtotal_usd"] as? NSNumber)?.doubleValue ?? 0,
                    receiptCount: (g["receipt_count"] as? Int) ?? rcpts.count,
                    sourcePages: (g["source_pages"] as? Int) ?? 0,
                    compiledPages: (g["compiled_pages"] as? Int) ?? 0,
                    pdfPath: (g["pdf_path"] as? String) ?? "",
                    pdfFilename: (g["pdf_filename"] as? String) ?? "",
                    approvalStatus: (g["approval_status"] as? String) ?? "missing",
                    approvalTicket: (g["approval_ticket"] as? String) ?? "",
                    approvalApprovedOn: (g["approval_approved_on"] as? String) ?? "",
                    approvalFilename: g["approval_filename"] as? String,
                    approvalBundlePath: g["approval_bundle_path"] as? String,
                    preApprovalCount: (g["pre_approval_count"] as? Int) ?? 0,
                    receipts: rcpts
                )
            }
            let draft: ReimburseDraftNotice? = {
                guard let d = p["draft_notice"] as? [String: Any] else { return nil }
                return ReimburseDraftNotice(
                    to: (d["to"] as? String) ?? "",
                    subject: (d["subject"] as? String) ?? "",
                    attachment: (d["attachment"] as? String) ?? "",
                    body: (d["body"] as? String) ?? ""
                )
            }()
            return ReimbursePacketData(
                batchID: (p["batch_id"] as? String) ?? "",
                batchDir: (p["batch_dir"] as? String) ?? "",
                bundleSlug: (p["bundle_slug"] as? String) ?? "cloud-reimbursements",
                zipPath: p["zip_path"] as? String,
                zipFilename: (p["zip_filename"] as? String) ?? "cloud-reimbursements.zip",
                periodStart: (period["start"] as? String) ?? "",
                periodEnd: (period["end"] as? String) ?? "",
                coverPages: (p["cover_pages"] as? Int) ?? 0,
                totalUSD: (p["total_usd"] as? NSNumber)?.doubleValue ?? 0,
                receiptCount: (p["receipt_count"] as? Int) ?? 0,
                providerCount: (p["provider_count"] as? Int) ?? groups.count,
                gatePassed: (ver["passed"] as? Bool) ?? false,
                totalSourcePages: (ver["total_source_pages"] as? Int) ?? 0,
                totalCompiledPages: (ver["total_compiled_pages"] as? Int) ?? 0,
                violations: (ver["violations"] as? [String]) ?? [],
                warnings: (ver["warnings"] as? [String]) ?? [],
                groups: groups,
                blockedUnapproved: parseExcluded((p["blocked_unapproved"] as? [[String: Any]]) ?? []),
                excluded: parseExcluded((p["excluded"] as? [[String: Any]]) ?? []),
                preApprovalWarningCount: ((p["pre_approval_warnings"] as? [[String: Any]]) ?? []).count,
                draftNotice: draft,
                generatedAt: (p["generated_at"] as? String) ?? ""
            )
        }()

        let rawBatches = (raw["recent_batches"] as? [[String: Any]]) ?? []
        let batches: [ReimburseBatchSummary] = rawBatches.compactMap { b in
            guard let bid = b["batch_id"] as? String else { return nil }
            return ReimburseBatchSummary(
                batchID: bid,
                batchDir: (b["batch_dir"] as? String) ?? "",
                zipPath: b["zip_path"] as? String,
                start: (b["start"] as? String) ?? "",
                end: (b["end"] as? String) ?? "",
                totalUSD: (b["total_usd"] as? NSNumber)?.doubleValue ?? 0,
                receiptCount: (b["receipt_count"] as? Int) ?? 0,
                providerCount: (b["provider_count"] as? Int) ?? 0,
                passed: (b["passed"] as? Bool) ?? false,
                generatedAt: (b["generated_at"] as? String) ?? ""
            )
        }

        return ReimburseSnapshot(
            updatedAt: raw["updated_at"] as? String,
            organization: (raw["organization"] as? String) ?? "Institution",
            bundleSlug: (raw["bundle_slug"] as? String) ?? "cloud-reimbursements",
            approverName: (raw["approver_name"] as? String) ?? "",
            approverEmail: (raw["approver_email"] as? String) ?? "",
            fundingWorktag: (raw["funding_worktag"] as? String) ?? "",
            fundNumber: (raw["fund_number"] as? String) ?? "",
            lastSentDate: raw["last_sent_date"] as? String,
            defaultSinceDate: (raw["default_since_date"] as? String) ?? "",
            approvals: approvals,
            verifiedApprovalCount: approvals.filter(\.isVerified).count,
            pendingApprovalCount: approvals.filter { $0.status == "pending" }.count,
            latestPacket: latestPacket,
            recentBatches: batches
        )
    }

    // MARK: Optimistic Zero-Latency Mutations + Background F_FULLFSYNC Persistence

    func setStatus(_ id: String, cancelled: Bool) {
        let targetURL = fileURL
        let now = today
        if var optimistic = ledger, optimistic.applyStatus(id: id, cancelled: cancelled, today: now) {
            let previous = ledger
            generation &+= 1
            ledger = optimistic
            derived = Derived.build(ledger: optimistic, today: now, generation: generation)
            let label = derived?.displayNames[id] ?? id
            flash(cancelled ? "Marked '\(label)' ended" : "Reactivated '\(label)'")

            ioQueue.async { [weak self] in
                do {
                    try LedgerFile.setStatus(targetURL, id: id, cancelled: cancelled, today: now)
                    self?.performBackgroundReload(force: true)
                } catch {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if let previous {
                            self.generation &+= 1
                            self.ledger = previous
                            self.derived = Derived.build(ledger: previous, today: self.today, generation: self.generation)
                        }
                        self.flash("Couldn't save: \(error.localizedDescription)", isError: true)
                    }
                }
            }
        } else {
            ioQueue.async { [weak self] in
                do {
                    try LedgerFile.setStatus(targetURL, id: id, cancelled: cancelled, today: now)
                    self?.performBackgroundReload(force: true)
                } catch {
                    Task { @MainActor [weak self] in
                        self?.flash("Couldn't save: \(error.localizedDescription)", isError: true)
                    }
                }
            }
        }
    }

    func setClosing(_ id: String, closing: Bool) {
        let targetURL = fileURL
        let now = today
        if var optimistic = ledger, optimistic.applyClosing(id: id, closing: closing, today: now) {
            let previous = ledger
            generation &+= 1
            ledger = optimistic
            derived = Derived.build(ledger: optimistic, today: now, generation: generation)
            let label = derived?.displayNames[id] ?? id
            flash(closing ? "Marked '\(label)' closing" : "Cleared closing flag on '\(label)'")

            ioQueue.async { [weak self] in
                do {
                    try LedgerFile.setClosing(targetURL, id: id, closing: closing, today: now)
                    self?.performBackgroundReload(force: true)
                } catch {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if let previous {
                            self.generation &+= 1
                            self.ledger = previous
                            self.derived = Derived.build(ledger: previous, today: self.today, generation: self.generation)
                        }
                        self.flash("Couldn't save: \(error.localizedDescription)", isError: true)
                    }
                }
            }
        }
    }

    func clearCheck(_ id: String) {
        let targetURL = fileURL
        if var optimistic = ledger, optimistic.applyClearCheck(id: id) {
            let previous = ledger
            generation &+= 1
            ledger = optimistic
            derived = Derived.build(ledger: optimistic, today: today, generation: generation)
            let label = derived?.displayNames[id] ?? id
            flash("Cleared triage flag on '\(label)'")

            ioQueue.async { [weak self] in
                do {
                    try LedgerFile.clearCheck(targetURL, id: id)
                    self?.performBackgroundReload(force: true)
                } catch {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if let previous {
                            self.generation &+= 1
                            self.ledger = previous
                            self.derived = Derived.build(ledger: previous, today: self.today, generation: self.generation)
                        }
                        self.flash("Couldn't save: \(error.localizedDescription)", isError: true)
                    }
                }
            }
        }
    }

    func openVaultForService(_ s: Service) {
        explorer.vaultSearchQuery = s.id
        selectedTab = .vault
    }

    func copyText(_ text: String, banner: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        flash(banner)
    }

    func openFileInEditor() {
        let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        NSWorkspace.shared.open([fileURL], withApplicationAt: textEdit,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - Headless CLI Bridge (`recurring sync` & `recurring vault`)

    private nonisolated static func resolveCLIExecutable() -> (python: String, script: String) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/recurring",
            "\(home)/Projects/Recurring/cli/recurring",
        ]
        let script = candidates.first { FileManager.default.fileExists(atPath: $0) } ?? candidates[1]
        let brewPy = "/opt/homebrew/bin/python3"
        let py = FileManager.default.fileExists(atPath: brewPy) ? brewPy : "/usr/bin/python3"
        return (py, script)
    }

    private nonisolated static func runCLI(args: [String], stdinString: String? = nil) async -> (code: Int32, stdout: String, stderr: String) {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let (py, script) = resolveCLIExecutable()
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: py)
                proc.arguments = [script] + args

                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
                proc.environment = env

                let outPipe = Pipe()
                let errPipe = Pipe()
                proc.standardOutput = outPipe
                proc.standardError = errPipe

                var inPipe: Pipe?
                if stdinString != nil {
                    let p = Pipe()
                    proc.standardInput = p
                    inPipe = p
                }

                do {
                    try proc.run()
                    if let s = stdinString, let fh = inPipe?.fileHandleForWriting {
                        if let data = (s + "\n").data(using: .utf8) {
                            try? fh.write(contentsOf: data)
                        }
                        try? fh.close()
                    }
                    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    proc.waitUntilExit()
                    cont.resume(returning: (
                        proc.terminationStatus,
                        String(data: outData, encoding: .utf8) ?? "",
                        String(data: errData, encoding: .utf8) ?? ""
                    ))
                } catch {
                    cont.resume(returning: (1, "", error.localizedDescription))
                }
            }
        }
    }

    func flash(_ message: String, isError: Bool = false) {
        statusBanner = (message, isError)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if self?.statusBanner?.message == message {
                self?.statusBanner = nil
            }
        }
    }

    func syncInvoicesNow() async {
        guard !isSyncingNow else { return }
        isSyncingNow = true
        defer { isSyncingNow = false }
        let res = await Self.runCLI(args: ["sync", "--json"])
        reload(force: true)
        if res.code == 0 {
            if let data = res.stdout.data(using: .utf8),
               let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let count = obj["added_count"] as? Int {
                flash(count > 0 ? "Synced \(count) new invoice\(count == 1 ? "" : "s")" : "All mailboxes up to date")
            } else {
                flash("Invoice sync complete")
            }
        } else {
            let err = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            flash(err.isEmpty ? "Sync failed" : err, isError: true)
        }
    }

    func initVault(passphrase: String) async -> Result<Void, Error> {
        let res = await Self.runCLI(args: ["vault", "init", "--passphrase-stdin", "--json"], stdinString: passphrase)
        reload(force: true)
        if res.code == 0 {
            flash("Vault initialized & unlocked")
            return .success(())
        }
        let msg = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failure(NSError(domain: "Vault", code: Int(res.code), userInfo: [NSLocalizedDescriptionKey: msg.isEmpty ? "Failed to initialize vault" : msg]))
    }

    func unlockVault(passphrase: String) async -> Result<Void, Error> {
        let res = await Self.runCLI(args: ["vault", "unlock", "--passphrase-stdin", "--json"], stdinString: passphrase)
        reload(force: true)
        if res.code == 0 {
            flash("Vault unlocked (12h session)")
            return .success(())
        }
        let msg = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failure(NSError(domain: "Vault", code: Int(res.code), userInfo: [NSLocalizedDescriptionKey: msg.isEmpty ? "Invalid passphrase" : msg]))
    }

    func lockVault() async {
        _ = await Self.runCLI(args: ["vault", "lock", "--json"])
        reload(force: true)
        flash("Vault locked")
    }

    func copyVaultSecret(id: String, label: String) async {
        let res = await Self.runCLI(args: ["vault", "secret", id])
        guard res.code == 0, !res.stdout.isEmpty else {
            let msg = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            flash(msg.isEmpty ? "Unlock vault to copy secrets" : msg, isError: true)
            return
        }
        let secret = res.stdout.trimmingCharacters(in: .newlines)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(secret, forType: .string)
        let savedChangeCount = pb.changeCount
        flash("Copied '\(label)' — clipboard auto-clears in 30s")

        clipboardClearTask?.cancel()
        clipboardClearTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled else { return }
            if NSPasteboard.general.changeCount == savedChangeCount {
                NSPasteboard.general.clearContents()
            }
        }
    }

    func revealVaultSecret(id: String) async -> String? {
        let res = await Self.runCLI(args: ["vault", "secret", id])
        guard res.code == 0 else {
            let msg = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            flash(msg.isEmpty ? "Could not decrypt key" : msg, isError: true)
            return nil
        }
        return res.stdout.trimmingCharacters(in: .newlines)
    }

    func addVaultKey(label: String, secret: String, tier: String?, provider: String?, account: String?) async -> Result<Void, Error> {
        var args = ["vault", "add", "--label", label, "--secret-stdin", "--json"]
        if let tier, !tier.isEmpty, tier != "auto" { args += ["--tier", tier] }
        if let provider, !provider.isEmpty, provider != "auto" { args += ["--provider", provider] }
        if let account, !account.trimmingCharacters(in: .whitespaces).isEmpty {
            args += ["--account", account.trimmingCharacters(in: .whitespaces)]
        }
        let res = await Self.runCLI(args: args, stdinString: secret)
        reload(force: true)
        if res.code == 0 {
            flash("Added key '\(label)' to Vault")
            return .success(())
        }
        let msg = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failure(NSError(domain: "Vault", code: Int(res.code), userInfo: [NSLocalizedDescriptionKey: msg.isEmpty ? "Could not add key" : msg]))
    }

    func rotateVaultKey(id: String, replacementSecret: String) async -> Result<Void, Error> {
        let res = await Self.runCLI(args: ["vault", "rotate", id, "--secret-stdin", "--json"], stdinString: replacementSecret)
        reload(force: true)
        if res.code == 0 {
            flash("Key rotated & previous ciphertext wiped")
            return .success(())
        }
        let msg = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failure(NSError(domain: "Vault", code: Int(res.code), userInfo: [NSLocalizedDescriptionKey: msg.isEmpty ? "Rotation failed" : msg]))
    }

    func revokeVaultKey(id: String, purge: Bool = false) async {
        var args = ["vault", "delete", id, "--json"]
        if purge { args.append("--purge") }
        let res = await Self.runCLI(args: args)
        reload(force: true)
        if res.code == 0 {
            flash(purge ? "Key purged from vault" : "Key revoked & ciphertext wiped")
        } else {
            flash(res.stderr.trimmingCharacters(in: .whitespacesAndNewlines), isError: true)
        }
    }

    func sweepVaultHealth() async {
        guard !isSweepingVault else { return }
        isSweepingVault = true
        defer { isSweepingVault = false }
        let res = await Self.runCLI(args: ["vault", "sweep", "--json"])
        reload(force: true)
        if res.code == 0 {
            flash("Live health sweep complete")
        } else {
            flash(res.stderr.trimmingCharacters(in: .whitespacesAndNewlines), isError: true)
        }
    }

    func scanProjectsEnv() async {
        guard !isScanningEnv else { return }
        isScanningEnv = true
        defer { isScanningEnv = false }
        let res = await Self.runCLI(args: ["vault", "scan", "--json"])
        reload(force: true)
        if res.code == 0 {
            flash("Scanned ~/Projects (.env provenance updated)")
        } else {
            flash(res.stderr.trimmingCharacters(in: .whitespacesAndNewlines), isError: true)
        }
    }

    func importSentinelVault() async {
        let res = await Self.runCLI(args: ["vault", "import-sentinel", "--json"])
        reload(force: true)
        if res.code == 0 {
            flash("Imported Sentinel vault")
        } else {
            flash(res.stderr.trimmingCharacters(in: .whitespacesAndNewlines), isError: true)
        }
    }

    // MARK: - Deterministic Cloud Receipt Packet Bridge (`recurring wm-cloud`)

    func buildReimbursementPacket(since: String, until: String, withCover: Bool) async {
        guard !isBuildingPacket else { return }
        isBuildingPacket = true
        defer { isBuildingPacket = false }

        var args = ["wm-cloud", "build", "--json"]
        let sTrim = since.trimmingCharacters(in: .whitespacesAndNewlines)
        let uTrim = until.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sTrim.isEmpty { args += ["--since", sTrim] }
        if !uTrim.isEmpty { args += ["--until", uTrim] }
        if withCover { args.append("--cover") }

        let res = await Self.runCLI(args: args)
        reload(force: true)
        if res.code == 0 {
            if let data = res.stdout.data(using: .utf8),
               let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let total = (obj["total_usd"] as? NSNumber)?.doubleValue,
               let count = obj["receipt_count"] as? Int {
                flash("Built verified packet · \(Money.exact(total)) (\(count) receipt\(count == 1 ? "" : "s"))")
            } else {
                flash("Reimbursement packet compiled & verified")
            }
        } else {
            let err = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            flash(err.isEmpty ? "Packet verify gate failed" : err, isError: true)
        }
    }

    func verifyLatestPacket() async {
        guard !isVerifyingPacket else { return }
        isVerifyingPacket = true
        defer { isVerifyingPacket = false }
        let res = await Self.runCLI(args: ["reimburse", "verify", "--json"])
        reload(force: true)
        if res.code == 0 {
            flash("5-point anti-hallucination gate PASSED")
        } else {
            let err = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            flash(err.isEmpty ? "Verify gate reported violations" : err, isError: true)
        }
    }

    func refreshReimburseStatus() async {
        _ = await Self.runCLI(args: ["reimburse", "status", "--json"])
        reload(force: true)
    }

    func revealInFinder(path: String) {
        guard !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            flash("File not found on disk", isError: true)
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

extension Store.Derived {
    nonisolated static func withGeneration(_ d: Store.Derived, generation: Int) -> Store.Derived {
        Store.Derived(
            generation: generation,
            dayKey: d.dayKey,
            activeCount: d.activeCount,
            monthlyTotal: d.monthlyTotal,
            burn: d.burn,
            displayNames: d.displayNames,
            servicesByID: d.servicesByID,
            rowMeta: d.rowMeta,
            upcoming: d.upcoming,
            upcoming7dTotal: d.upcoming7dTotal,
            hasDueSoon: d.hasDueSoon,
            renewals: d.renewals,
            renewalRadar: d.renewalRadar,
            watch: d.watch,
            lateWatch: d.lateWatch,
            watchingItems: d.watchingItems,
            clearedWatchCount: d.clearedWatchCount,
            clearedWatchNames: d.clearedWatchNames,
            savings: d.savings,
            cutGroups: d.cutGroups,
            cutsByMonth: d.cutsByMonth,
            refundClaims: d.refundClaims,
            pendingRefunds: d.pendingRefunds,
            wonRefunds: d.wonRefunds,
            totalMoneyBack: d.totalMoneyBack,
            cashFlow: d.cashFlow,
            calendarHeatmap: d.calendarHeatmap,
            termWindows: d.termWindows,
            domainRollup: d.domainRollup,
            orderedCategories: d.orderedCategories,
            popoverCategories: d.popoverCategories,
            typeFilterCounts: d.typeFilterCounts,
            categoryCounts: d.categoryCounts
        )
    }
}

// MARK: - Reminders & Cached Thread-Safe Money Formatting

@MainActor
final class Reminders: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private let sentKey = "notifiedCharges"
    static let chargeLeadDays = 1
    static let expiryLeadDays = 7
    @Published private(set) var authorized: Bool?

    func start(onReady: @escaping @MainActor () -> Void) {
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error { log.error("Recurring: notification auth error: \(error.localizedDescription, privacy: .public)") }
            log.notice("Recurring: notifications \(granted ? "authorized" : "not authorized", privacy: .public)")
            Task { @MainActor in
                self.authorized = granted
                if granted { onReady() }
            }
        }
    }

    func check(_ store: Store) {
        guard authorized == true, let ledger = store.ledger else { return }
        var sent = Set(UserDefaults.standard.stringArray(forKey: sentKey) ?? [])
        let today = store.today
        let due = Schedule.events(ledger, from: today, within: Self.expiryLeadDays).filter {
            $0.kind == .expiry || Schedule.daysUntil($0.date, from: today) <= Self.chargeLeadDays
        }
        for item in due {
            let key = "\(item.service.id)|\(item.kind.rawValue)|\(Schedule.isoDay(item.date))"
            guard !sent.contains(key) else { continue }
            let days = Schedule.daysUntil(item.date, from: today)
            let when = days == 0 ? "today" : days == 1 ? "tomorrow" : "in \(days) days"
            let content = UNMutableNotificationContent()
            content.title = item.service.name
            switch item.kind {
            case .charge:
                content.body = item.service.amount == nil
                    ? "Charges \(when) (amount unknown)"
                    : "\(Money.row(item.service)) charges \(when)"
            case .expiry: content.body = "Prepaid plan expires \(when)"
            case .ending: content.body = "Service ends \(when)"
            }
            if let plan = item.service.plan { content.subtitle = plan }
            let req = UNNotificationRequest(identifier: key, content: content, trigger: nil)
            center.add(req) { error in
                if let error {
                    log.error("Recurring: notify failed: \(error.localizedDescription, privacy: .public)")
                    return
                }
                Task { @MainActor [weak self] in self?.markSent(key) }
            }
        }
        let cutoff = Schedule.isoDay(today.addingTimeInterval(-60 * 86400))
        sent = sent.filter { ($0.split(separator: "|").last.map(String.init) ?? "") >= cutoff }
        UserDefaults.standard.set(Array(sent), forKey: sentKey)
    }

    private func markSent(_ key: String) {
        var sent = Set(UserDefaults.standard.stringArray(forKey: sentKey) ?? [])
        sent.insert(key)
        UserDefaults.standard.set(Array(sent), forKey: sentKey)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

enum Money {
    private static let lock = NSLock()
    private static let wholeFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.locale = Locale(identifier: "en_US")
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 0
        return f
    }()
    private static let exactFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.locale = Locale(identifier: "en_US")
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f
    }()

    static func whole(_ v: Double) -> String {
        lock.lock()
        defer { lock.unlock() }
        return wholeFormatter.string(from: NSNumber(value: v.rounded())) ?? "$\(Int(v))"
    }

    static func exact(_ v: Double) -> String {
        lock.lock()
        defer { lock.unlock() }
        return exactFormatter.string(from: NSNumber(value: v)) ?? String(format: "$%.2f", v)
    }

    static func bareExact(_ v: Double) -> String {
        let s = exact(v)
        return s.hasPrefix("$") ? String(s.dropFirst()) : s
    }

    static func row(_ s: Service) -> String {
        guard let a = s.amount else { return "—" }
        return s.amountKind == .approx ? "~" + exact(a) : exact(a)
    }
}
