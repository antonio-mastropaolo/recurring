import Foundation

// Pure data + scheduling logic. No AppKit/SwiftUI here so tests/ModelTests.swift
// can compile this file standalone with `swiftc`.

enum AmountKind: String {
    case fixed, approx, usage, unknown
}

/// How a service bills. `term` is a one-shot prepaid purchase that buys access
/// for a fixed window (term_start → term_end) and does not renew by itself.
enum Cadence: String, CaseIterable {
    case biweekly, monthly, quarterly, semiannual, annual, term, usage, topup, other

    /// Billing interval in months for things that recur; nil otherwise.
    /// `usage` is a monthly invoice whose amount varies.
    var months: Int? {
        switch self {
        case .monthly, .usage: return 1
        case .quarterly: return 3
        case .semiannual: return 6
        case .annual: return 12
        case .biweekly, .term, .topup, .other: return nil
        }
    }

    /// Billing interval in days for cycles that aren't month-based.
    var days: Int? { self == .biweekly ? 14 : nil }

    var label: String {
        switch self {
        case .biweekly: return "Every 2 weeks"
        case .monthly: return "Monthly"
        case .quarterly: return "Quarterly"
        case .semiannual: return "Every 6 mo"
        case .annual: return "Yearly"
        case .term: return "Prepaid term"
        case .usage: return "Usage, monthly"
        case .topup: return "Top-up"
        case .other: return "Other"
        }
    }
}

/// `unverified`: the evidence couldn't confirm it's still billing (no charge in
/// the last expected cycle, billed to a card we can't see, failed payment).
/// Listed, never counted in totals.
enum ServiceStatus: String {
    case active, cancelled, unverified
}

struct Charge: Hashable {
    var date: String      // yyyy-MM-dd
    var amount: Double    // USD actually charged
    var note: String?
}

/// Money the user is asking a merchant (or the card issuer) to give back.
enum RefundStatus: String, CaseIterable {
    case open        // found, not asked for yet
    case requested   // asked, waiting
    case won         // refunded
    case lost        // denied
}

struct RefundClaim: Hashable {
    var amount: Double
    var status: RefundStatus
    var opened: String?
    var resolved: String?
    var note: String?
    var isPending: Bool { status == .open || status == .requested }
}

struct Service: Identifiable, Hashable {
    var id: String
    var name: String
    var category: String
    var plan: String?
    /// Charge per billing cycle in USD (for `term`: the one-shot price). nil = not known.
    var amount: Double?
    var amountKind: AmountKind
    var cadence: Cadence
    /// Day of month the charge lands (monthly), or day within `billingMonth` (annual).
    var billingDay: Int?
    var billingMonth: Int?
    /// Which login/mailbox the bill goes to.
    var account: String?
    /// Last four digits of the card, or "PayPal"/"Apple" when paid through them.
    var card: String?
    var note: String?
    var manageURL: String?
    var status: ServiceStatus
    var cancelledOn: String?
    /// Service keeps running until this date even though it's cancelled.
    var endsOn: String?
    /// Date (yyyy-MM-dd) of the real charge `amount` was taken from.
    var lastCharged: String?
    /// Explicit next renewal date (yyyy-MM-dd) from a receipt/contract (e.g. trial end,
    /// policy schedule shift, or account-credit window). Acts as a floor on scheduled charges.
    var nextRenewal: String?
    /// Prepaid window for `cadence: term` (and the current period of an upfront annual plan).
    var termStart: String?
    var termEnd: String?
    /// Real charges seen in receipts/card alerts, oldest first (refunds negative).
    var charges: [Charge]
    /// Something the evidence couldn't settle; shown as "needs a look".
    var check: String?
    /// Date (yyyy-MM-dd) the user started cancelling; still billing until it lands.
    var cancelRequested: String?
    /// Refunds being chased for this service.
    var refunds: [RefundClaim]
    /// Overlap group ("AI assistants — top tier"): items that do the same job,
    /// shown together under "Where to cut".
    var group: String?

    init(id: String, name: String, category: String, plan: String? = nil,
         amount: Double?, amountKind: AmountKind = .fixed, cadence: Cadence = .monthly,
         billingDay: Int? = nil, billingMonth: Int? = nil, account: String? = nil,
         card: String? = nil, note: String? = nil, manageURL: String? = nil,
         status: ServiceStatus = .active, cancelledOn: String? = nil, endsOn: String? = nil,
         lastCharged: String? = nil, nextRenewal: String? = nil,
         termStart: String? = nil, termEnd: String? = nil,
         charges: [Charge] = [], check: String? = nil, cancelRequested: String? = nil,
         refunds: [RefundClaim] = [], group: String? = nil) {
        self.id = id; self.name = name; self.category = category; self.plan = plan
        self.amount = amount; self.amountKind = amountKind; self.cadence = cadence
        self.billingDay = billingDay; self.billingMonth = billingMonth
        self.account = account; self.card = card; self.note = note; self.manageURL = manageURL
        self.status = status; self.cancelledOn = cancelledOn; self.endsOn = endsOn
        self.lastCharged = lastCharged; self.nextRenewal = nextRenewal
        self.termStart = termStart; self.termEnd = termEnd
        self.charges = charges; self.check = check; self.cancelRequested = cancelRequested
        self.refunds = refunds; self.group = group
    }

    /// The id of a raw service object: its `id`, else its lower-cased name
    /// (`normalize_service` in cli/recurring). The one rule both reading and
    /// `LedgerFile.patch` use to find a service.
    static func id(ofRaw o: [String: Any]) -> String {
        func str(_ k: String) -> String? { (o[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        return str("id") ?? (str("name") ?? "(unnamed)").lowercased()
    }

    /// Builds a service from one raw JSON object, never failing: anything that
    /// doesn't fit the schema is dropped and reported in `issues`. The rules here
    /// are mirrored line for line by `normalize_service` in cli/recurring, and
    /// tests/fixtures/parity*.json pins both to the same results.
    init(raw o: [String: Any], index: Int, issues: inout [String]) {
        func str(_ k: String) -> String? { (o[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let label = str("id") ?? str("name") ?? "service #\(index + 1)"
        func flag(_ k: String, _ why: String) { issues.append("\(label): \(k) \(why)") }

        if let n = str("name") { name = n } else { name = "(unnamed)"; flag("name", "is missing") }
        id = Self.id(ofRaw: o)
        category = str("category") ?? "Other"
        plan = str("plan")

        let rawAmount = Raw.number(o["amount"])
        if let a = rawAmount, a < 0 {
            amount = nil; flag("amount", "is negative — record refunds as negative charges instead")
        } else if let a = rawAmount, a > Raw.maxAmount {
            amount = nil; flag("amount", "is out of range")
        } else {
            amount = rawAmount
            if o["amount"] != nil, !(o["amount"] is NSNull), amount == nil { flag("amount", "is not a finite number") }
        }

        if let raw = o["cadence"] as? String, let c = Cadence(rawValue: raw) { cadence = c }
        else if o["cadence"] == nil { cadence = .monthly }
        else { cadence = .other; flag("cadence", "is not one of \(Cadence.allCases.map(\.rawValue).joined(separator: "/"))") }

        if let raw = o["status"] as? String, let s = ServiceStatus(rawValue: raw) { status = s }
        else if o["status"] == nil { status = .active }
        else { status = .unverified; flag("status", "is not active/cancelled/unverified — treated as unverified") }

        if let raw = o["amount_kind"] as? String, let k = AmountKind(rawValue: raw) { amountKind = k }
        else { amountKind = amount == nil ? .unknown : .fixed }

        billingDay = Raw.int(o["billing_day"]).flatMap { (1...31).contains($0) ? $0 : nil }
        if o["billing_day"] != nil, !(o["billing_day"] is NSNull), billingDay == nil { flag("billing_day", "must be 1–31") }
        billingMonth = Raw.int(o["billing_month"]).flatMap { (1...12).contains($0) ? $0 : nil }
        if o["billing_month"] != nil, !(o["billing_month"] is NSNull), billingMonth == nil { flag("billing_month", "must be 1–12") }

        account = str("account"); card = str("card"); note = str("note"); check = str("check")
        manageURL = str("manage_url")
        for k in ["cancelled_on", "ends_on", "last_charged", "next_renewal", "term_start", "term_end", "cancel_requested"] {
            if let v = o[k], !(v is NSNull), Schedule.parseDay(v as? String) == nil { flag(k, "is not a yyyy-MM-dd date") }
        }
        cancelledOn = str("cancelled_on"); endsOn = str("ends_on"); lastCharged = str("last_charged")
        nextRenewal = str("next_renewal")
        termStart = str("term_start"); termEnd = str("term_end"); cancelRequested = str("cancel_requested")

        var kept: [Charge] = []
        if let list = o["charges"] as? [Any] {
            for (j, item) in list.enumerated() {
                guard let c = item as? [String: Any], let d = c["date"] as? String, Schedule.parseDay(d) != nil,
                      let a = Raw.number(c["amount"]), abs(a) <= Raw.maxAmount else {
                    flag("charges[\(j)]", "needs a yyyy-MM-dd date and a numeric amount — ignored")
                    continue
                }
                kept.append(Charge(date: String(d.prefix(10)), amount: a, note: c["note"] as? String))
            }
        } else if o["charges"] != nil, !(o["charges"] is NSNull) {
            flag("charges", "is not a list — ignored")
        }
        charges = kept

        group = str("group")
        var claims: [RefundClaim] = []
        if let list = o["refunds"] as? [Any] {
            for (j, item) in list.enumerated() {
                let c = item as? [String: Any]
                let status: RefundStatus?
                if let v = c?["status"], !(v is NSNull) { status = (v as? String).flatMap(RefundStatus.init(rawValue:)) } else { status = .open }
                guard let c, let a = Raw.number(c["amount"]), a > 0, a <= Raw.maxAmount, let status else {
                    flag("refunds[\(j)]", "needs a positive amount and status open/requested/won/lost — ignored")
                    continue
                }
                claims.append(RefundClaim(amount: a, status: status, opened: c["opened"] as? String,
                                          resolved: c["resolved"] as? String, note: c["note"] as? String))
            }
        } else if o["refunds"] != nil, !(o["refunds"] is NSNull) {
            flag("refunds", "is not a list — ignored")
        }
        refunds = claims
    }

    /// Active, but the user has started cancelling it.
    var isClosing: Bool { status == .active && cancelRequested != nil }

    /// Domain registrations (plan starts with "domain", billed yearly or as a
    /// prepaid term) are grouped in the UI instead of listed one by one.
    var isDomain: Bool {
        (plan ?? "").lowercased().hasPrefix("domain") && (cadence == .annual || cadence == .term)
    }

    /// Only plain https links to a real host are opened — the file is
    /// user-editable, so never hand the OS a file://, custom-scheme, cleartext
    /// http, or `user@host` (look-alike) URL.
    var safeManageURL: URL? {
        guard let s = manageURL, let comps = URLComponents(string: s),
              comps.scheme?.lowercased() == "https",
              let host = comps.host?.lowercased(), Self.isPublicHostName(host),
              comps.user == nil, comps.password == nil,
              let url = comps.url else { return nil }
        return url
    }

    /// A dotted DNS name that isn't local: no IP literals, no localhost/.local.
    static func isPublicHostName(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }),
              host.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "." }),
              !labels.last!.allSatisfy(\.isNumber) else { return false }   // 127.0.0.1, 10.0.0.8 …
        return !["localhost", "local", "internal", "lan", "home", "arpa"].contains(String(labels.last!))
    }

    /// Host shown next to "Open billing page" so the destination is visible.
    var manageHost: String? { safeManageURL?.host }

    /// Compact handle (prefix before `@`) for the mailbox/login attached to this subscription.
    var accountShort: String {
        guard let a = account else { return "" }
        return a.split(separator: "@").first.map(String.init) ?? a
    }

    /// Disambiguates duplicate plan names (e.g. multiple "Claude Max 20x" accounts)
    /// by appending the account handle or card last4 when siblings share the name.
    func disambiguatedName(among siblings: [Service]) -> String {
        let sameNameCount = siblings.filter { $0.status != .cancelled && $0.name == self.name }.count
        guard sameNameCount > 1 else { return name }
        if !accountShort.isEmpty {
            return "\(name) · \(accountShort)"
        }
        if let c = card, !c.isEmpty {
            return "\(name) · \(c)"
        }
        return name
    }

    /// Average cost per year while active (monthly equivalent × 12).
    func yearlyEquivalent(on today: Date) -> Double? { monthlyEquivalent(on: today).map { $0 * 12 } }

    /// A prepaid term whose window contains `today`.
    func termIsRunning(on today: Date) -> Bool {
        guard cadence == .term, status == .active,
              let start = Schedule.parseDay(termStart), let end = Schedule.parseDay(termEnd)
        else { return false }
        let t = Schedule.calendar.startOfDay(for: today)
        return start <= t && t <= end
    }

    /// Length of the prepaid window in (fractional) months.
    var termMonths: Double? {
        guard let start = Schedule.parseDay(termStart), let end = Schedule.parseDay(termEnd) else { return nil }
        let days = Double(Schedule.daysUntil(end, from: start))
        return days > 0 ? days / 30.436875 : nil
    }

    /// Average cost per month while this is something you're paying for today.
    /// Recurring plans divide by their interval; prepaid terms are spread over
    /// their window; top-ups and ended items count as zero.
    func monthlyEquivalent(on today: Date) -> Double? {
        guard status == .active, let amount else { return nil }
        if cadence == .term {
            guard termIsRunning(on: today), let m = termMonths else { return nil }
            return amount / m
        }
        if let d = cadence.days { return amount * 365.25 / Double(d) / 12 }
        guard let m = cadence.months else { return nil }
        return amount / Double(m)
    }

    /// Cancelled but still usable until `endsOn`.
    func isEnding(on today: Date) -> Bool {
        guard status == .cancelled, let end = Schedule.parseDay(endsOn) else { return false }
        return end >= Schedule.calendar.startOfDay(for: today)
    }
}

struct Ledger {
    var version: Int
    var asOf: String?
    var source: String?
    var currency: String?
    var services: [Service]
    /// Schema problems found while reading (never written back).
    var issues: [String] = []

    init(version: Int, asOf: String? = nil, source: String? = nil, currency: String? = nil,
         services: [Service], issues: [String] = []) {
        self.version = version; self.asOf = asOf; self.source = source; self.currency = currency
        self.services = services; self.issues = issues
    }

    /// Mirrors `normalize` in cli/recurring.
    init(raw: Any) {
        var issues: [String] = []
        let o = raw as? [String: Any] ?? [:]
        if !(raw is [String: Any]) { issues.append("file: top level is not a JSON object") }
        version = Raw.int(o["version"]) ?? 1
        asOf = o["as_of"] as? String
        source = o["source"] as? String
        currency = o["currency"] as? String
        var out: [Service] = []
        if let list = o["services"] as? [Any] {
            for (i, item) in list.enumerated() {
                guard let so = item as? [String: Any] else { issues.append("service #\(i + 1): is not a JSON object — ignored"); continue }
                out.append(Service(raw: so, index: i, issues: &issues))
            }
        } else if o["services"] != nil {
            issues.append("file: services is not a list")
        }
        var seen = Set<String>()
        for s in out where !seen.insert(s.id).inserted { issues.append("\(s.id): id is used more than once") }
        services = out
        self.issues = issues
    }

    var active: [Service] { services.filter { $0.status == .active } }
    var cancelled: [Service] { services.filter { $0.status == .cancelled } }
    var unverified: [Service] { services.filter { $0.status == .unverified } }
    /// Active items the user is cancelling.
    var closing: [Service] { services.filter(\.isClosing) }
    /// Unverified items, plus active (not closing) items carrying a `check` note.
    var needsLook: [Service] { services.filter { $0.status == .unverified || ($0.status == .active && $0.check != nil && !$0.isClosing) } }

    func monthlyTotal(on today: Date) -> Double {
        active.compactMap { $0.monthlyEquivalent(on: today) }.reduce(0, +)
    }

    var unknownAmountCount: Int {
        active.filter { $0.amount == nil }.count
    }

    /// Categories in first-appearance order.
    var categories: [String] {
        var seen = Set<String>(), out: [String] = []
        for s in services where seen.insert(s.category).inserted { out.append(s.category) }
        return out
    }

    /// O(N) single-pass disambiguated display names keyed by Service.id.
    /// Equivalent to calling `s.disambiguatedName(among: services)` for every service
    /// without paying O(N^2) scans inside SwiftUI view bodies.
    func disambiguatedNames() -> [String: String] {
        var counts: [String: Int] = [:]
        counts.reserveCapacity(services.count)
        for s in services where s.status != .cancelled {
            counts[s.name, default: 0] += 1
        }
        var out: [String: String] = [:]
        out.reserveCapacity(services.count)
        for s in services {
            if (counts[s.name] ?? 0) > 1 {
                if !s.accountShort.isEmpty {
                    out[s.id] = "\(s.name) · \(s.accountShort)"
                } else if let c = s.card, !c.isEmpty {
                    out[s.id] = "\(s.name) · \(c)"
                } else {
                    out[s.id] = s.name
                }
            } else {
                out[s.id] = s.name
            }
        }
        return out
    }

    /// Optimistic in-memory transition matching `LedgerFile.setStatus`.
    mutating func applyStatus(id: String, cancelled: Bool, today: Date) -> Bool {
        let matches = services.indices.filter { services[$0].id == id }
        guard matches.count == 1, let idx = matches.first else { return false }
        services[idx].cancelRequested = nil
        if cancelled {
            services[idx].status = .cancelled
            services[idx].cancelledOn = Schedule.isoDay(today)
        } else {
            services[idx].status = .active
            services[idx].cancelledOn = nil
            services[idx].endsOn = nil
        }
        return true
    }

    /// Optimistic in-memory transition matching `LedgerFile.setClosing`.
    mutating func applyClosing(id: String, closing: Bool, today: Date) -> Bool {
        let matches = services.indices.filter { services[$0].id == id }
        guard matches.count == 1, let idx = matches.first, services[idx].status == .active else { return false }
        services[idx].cancelRequested = closing ? Schedule.isoDay(today) : nil
        return true
    }

    /// Optimistic in-memory transition matching `LedgerFile.clearCheck`.
    mutating func applyClearCheck(id: String) -> Bool {
        let matches = services.indices.filter { services[$0].id == id }
        guard matches.count == 1, let idx = matches.first else { return false }
        services[idx].check = nil
        return true
    }
}

enum EventKind: String {
    case charge, expiry, ending
}

struct ScheduledEvent: Hashable {
    let service: Service
    let date: Date
    let kind: EventKind
    /// Amount that will be charged (charges only).
    let amount: Double?
    /// True when the amount is a projection of a variable bill.
    let estimated: Bool
}

enum Schedule {
    /// Gregorian in the *current* time zone. Built once (it's used thousands of
    /// times per redraw); `.autoupdatingCurrent` still follows a time-zone change.
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .autoupdatingCurrent
        return c
    }()

    /// Next date (on or after `today`) this service is charged, or nil when it
    /// doesn't renew on a known schedule (prepaid term, top-up, unknown day).
    static func nextCharge(for s: Service, from today: Date) -> Date? {
        chargeDates(for: s, from: today, through: nil, limit: 1).first
    }

    /// Scheduled charge dates for `s` from `today` up to `through` (inclusive).
    static func chargeDates(for s: Service, from today: Date, through end: Date?, limit: Int = 400) -> [Date] {
        guard s.status == .active else { return [] }
        let cal = calendar
        let rawStart = cal.startOfDay(for: today)
        let start: Date
        if let nr = parseDay(s.nextRenewal), nr > rawStart {
            start = nr
        } else {
            start = rawStart
        }
        if let end, start > end { return [] }
        var out: [Date] = []

        // Fixed-day cycles (every 2 weeks) step from the last charge.
        if let step = s.cadence.days {
            guard let anchor = parseDay(s.termStart) ?? parseDay(s.lastCharged) ?? parseDay(s.nextRenewal) else { return [] }
            for k in 0..<2000 {
                guard let d = cal.date(byAdding: .day, value: k * step, to: anchor) else { break }
                if d < start { continue }
                if let end, d > end { break }
                out.append(d)
                if out.count >= limit { break }
            }
            return out
        }
        guard let m = s.cadence.months else { return [] }

        // Monthly bills on a fixed day: clamp per month so a 31st stays the 31st.
        if m == 1 {
            let day = s.billingDay
                ?? parseDay(s.nextRenewal).map { cal.component(.day, from: $0) }
                ?? parseDay(s.lastCharged).map { cal.component(.day, from: $0) }
            guard let day, day >= 1 else { return [] }
            let ym = cal.dateComponents([.year, .month], from: start)
            guard let y = ym.year, let mo = ym.month else { return [] }
            for k in 0..<(limit + 1) {
                guard let d = clampedDate(year: y, month: mo + k, day: day) else { break }
                if d < start { continue }
                if let end, d > end { break }
                out.append(d)
                if out.count >= limit { break }
            }
            return out
        }

        // Longer cycles step from an anchor date: the current/last period start,
        // else next_renewal, else billing_month/billing_day.
        var anchor = parseDay(s.termStart) ?? parseDay(s.lastCharged) ?? parseDay(s.nextRenewal)
        if anchor == nil, let bm = s.billingMonth, let bd = s.billingDay {
            let y = cal.component(.year, from: start)
            anchor = clampedDate(year: y - 1, month: bm, day: bd)
        }
        guard let anchor else { return [] }
        for k in 0..<2000 {
            guard let d = cal.date(byAdding: .month, value: k * m, to: anchor) else { break }
            if d < start { continue }
            if let end, d > end { break }
            out.append(d)
            if out.count >= limit { break }
        }
        return out
    }

    /// Charges, prepaid-term expiries and wind-downs from today through `days` ahead.
    static func events(_ ledger: Ledger, from today: Date, within days: Int) -> [ScheduledEvent] {
        let cal = calendar
        let start = cal.startOfDay(for: today)
        guard let horizon = cal.date(byAdding: .day, value: days, to: start) else { return [] }
        var out: [ScheduledEvent] = []
        for s in ledger.services {
            for d in chargeDates(for: s, from: start, through: horizon) {
                out.append(ScheduledEvent(service: s, date: d, kind: .charge, amount: s.amount,
                                          estimated: s.amountKind != .fixed))
            }
            if s.termIsRunning(on: start), let end = parseDay(s.termEnd), end <= horizon {
                out.append(ScheduledEvent(service: s, date: end, kind: .expiry, amount: nil, estimated: false))
            }
            if s.isEnding(on: start), let end = parseDay(s.endsOn), end <= horizon {
                out.append(ScheduledEvent(service: s, date: end, kind: .ending, amount: nil, estimated: false))
            }
        }
        return out.sorted { $0.date == $1.date ? $0.service.name < $1.service.name : $0.date < $1.date }
    }

    /// Whole days from start-of-today to `date` (0 = today).
    static func daysUntil(_ date: Date, from today: Date) -> Int {
        let cal = calendar
        return cal.dateComponents([.day], from: cal.startOfDay(for: today),
                                  to: cal.startOfDay(for: date)).day ?? 0
    }

    /// Builds year/month/day, clamping day to the month's length so a "31st"
    /// charge lands on Feb 28/29, Apr 30, etc. Month may overflow (13 → next Jan).
    static func clampedDate(year: Int, month: Int, day: Int) -> Date? {
        let cal = calendar
        guard let first = cal.date(from: DateComponents(year: year, month: month, day: 1)),
              let range = cal.range(of: .day, in: .month, for: first) else { return nil }
        let comps = cal.dateComponents([.year, .month], from: first)
        return cal.date(from: DateComponents(year: comps.year, month: comps.month,
                                             day: min(day, range.count)))
    }

    /// Strict yyyy-MM-dd (extra characters after the 10th are ignored, e.g. a
    /// time). Same rule as `parse_day` in cli/recurring: "20261005", "2026-W41-1"
    /// and impossible dates like 2026-02-30 are rejected.
    static func parseDay(_ iso: String?) -> Date? {
        guard let iso, iso.count >= 10 else { return nil }
        let head = String(iso.prefix(10))
        // Memoized: the same few hundred dates are parsed thousands of times per
        // redraw, and a strict parse (regex + formatter round-trip) costs ~18 µs.
        // Keyed by time zone too, since a day string means local midnight.
        let zone = TimeZone.autoupdatingCurrent.identifier
        parseLock.lock()
        defer { parseLock.unlock() }
        if parseZone != zone { parseCache.removeAll(); parseZone = zone }
        if let hit = parseCache[head] { return hit }
        let d = strictParse(head)
        if parseCache.count >= 8192 { parseCache.removeAll() }
        parseCache[head] = d
        return d
    }

    private static func strictParse(_ head: String) -> Date? {
        guard head.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
              let d = dayFormatter.date(from: head), dayFormatter.string(from: d) == head else { return nil }
        return d
    }

    private static let parseLock = NSLock()
    nonisolated(unsafe) private static var parseCache: [String: Date?] = [:]
    nonisolated(unsafe) private static var parseZone = ""

    static func isoDay(_ date: Date) -> String { dayFormatter.string(from: date) }

    static func monthKey(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .autoupdatingCurrent
        f.isLenient = false
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

/// Cash leaving the account per month and category: real charges for past
/// months, scheduled charges for the rest.
struct MonthBucket: Hashable, Identifiable {
    var id: [String] { [month, category, projected ? "scheduled" : "charged"] }
    let month: String        // yyyy-MM
    let category: String
    let amount: Double
    let projected: Bool
}

enum CashFlow {
    static func buckets(_ ledger: Ledger, today: Date, monthsBack: Int, monthsAhead: Int) -> [MonthBucket] {
        let cal = Schedule.calendar
        let start = cal.startOfDay(for: today)
        guard let firstMonth = cal.date(byAdding: .month, value: -monthsBack,
                                        to: Schedule.clampedDate(year: cal.component(.year, from: start),
                                                                 month: cal.component(.month, from: start), day: 1)!),
              let horizon = cal.date(byAdding: .month, value: monthsAhead + 1,
                                     to: Schedule.clampedDate(year: cal.component(.year, from: start),
                                                              month: cal.component(.month, from: start), day: 1)!)
        else { return [] }
        let lastDay = cal.date(byAdding: .day, value: -1, to: horizon)!

        struct Key: Hashable { let month: String; let category: String; let projected: Bool }
        var sums: [Key: Double] = [:]
        func add(_ month: String, _ cat: String, _ amt: Double, _ projected: Bool) {
            sums[Key(month: month, category: cat, projected: projected), default: 0] += amt
        }
        for s in ledger.services {
            for c in s.charges {
                guard let d = Schedule.parseDay(c.date), d >= firstMonth, d < start else { continue }
                add(Schedule.monthKey(d), s.category, c.amount, false)
            }
            // A charge already recorded for today counts as actual.
            for c in s.charges where c.date == Schedule.isoDay(start) {
                add(Schedule.monthKey(start), s.category, c.amount, false)
            }
            guard let amount = s.amount else { continue }
            for d in Schedule.chargeDates(for: s, from: start, through: lastDay) {
                if d == start, s.charges.contains(where: { $0.date == Schedule.isoDay(start) }) { continue }
                add(Schedule.monthKey(d), s.category, amount, true)
            }
        }
        return sums.map { key, amt in
            MonthBucket(month: key.month, category: key.category, amount: (amt * 100).rounded() / 100, projected: key.projected)
        }
        .sorted { ($0.month, $0.category, $0.projected ? 1 : 0) < ($1.month, $1.category, $1.projected ? 1 : 0) }
    }
}

// MARK: - Insights (renewals, watchlist, savings, where to cut)
// Mirrored by the same-named functions in cli/recurring and pinned by
// tests/fixtures/parity*.json, like the scheduling code above.

struct Renewal: Hashable {
    let service: Service
    let date: Date
    let daysLeft: Int
    /// Last day to cancel without paying: the day before the charge (nil when it's today).
    let cancelBy: Date?
    let amount: Double?
}

enum WatchStatus: String {
    case chargedAfterCancel = "charged_after_cancel"   // a refund case
    case watching = "watch"                            // would-be renewal is close or just passed
    case clear                                          // would-be renewal passed, nothing charged on file
}

struct WatchItem: Hashable {
    let service: Service
    /// When it would have renewed had it not been cancelled.
    let wouldCharge: Date?
    let status: WatchStatus
    /// Charges on file after the cancellation took effect.
    let lateCharges: [Charge]
    var lateTotal: Double { lateCharges.map(\.amount).reduce(0, +) }
}

struct Cancellation: Hashable {
    let service: Service
    let on: Date
    /// What it cost per month while it ran.
    let monthly: Double
    /// Charges it would have made since, minus any that happened anyway.
    let kept: Double
}

struct Savings {
    let since: Date
    let items: [Cancellation]
    let monthly: Double
    let kept: Double
    /// Still billing but being cancelled ("closing").
    let closingMonthly: Double
    var yearly: Double { monthly * 12 }
}

struct CutGroup: Hashable {
    let name: String
    /// true = found by name (same service twice); false = a `group` the user set.
    let auto: Bool
    let members: [Service]
    let monthly: Double
    /// Keeping only the priciest member saves at least `saveMin`; keeping only the cheapest saves `saveMax`.
    let saveMin: Double
    let saveMax: Double
}

enum Insights {
    /// Cancellations this recent stay on the watchlist.
    static let watchDays = 60
    /// A renewal can post a few days late; keep watching that long.
    static let watchGraceDays = 3
    /// Renewals at or above this are "big" (highlighted, listed with cancel-by).
    static let bigRenewal = 50.0

    private static var cal: Calendar { Schedule.calendar }

    static func renewals(_ ledger: Ledger, from today: Date, within days: Int) -> [Renewal] {
        Schedule.events(ledger, from: today, within: days).filter { $0.kind == .charge }.map { e in
            let left = Schedule.daysUntil(e.date, from: today)
            return Renewal(service: e.service, date: e.date, daysLeft: left,
                           cancelBy: left >= 1 ? cal.date(byAdding: .day, value: -1, to: e.date) : nil,
                           amount: e.amount)
        }
    }

    /// The service as if it had never been cancelled (to ask "when would it have charged?").
    private static func asActive(_ s: Service) -> Service {
        var a = s
        a.status = .active
        a.cancelRequested = nil
        return a
    }

    /// First day a charge would no longer be expected: the end of the notice
    /// period when there is one, otherwise the day after cancelling.
    static func effectiveEnd(_ s: Service) -> Date? {
        guard let c = Schedule.parseDay(s.cancelledOn) else { return nil }
        let after = cal.date(byAdding: .day, value: 1, to: c) ?? c
        guard let e = Schedule.parseDay(s.endsOn) else { return after }
        return max(e, after)
    }

    /// Charges on file on/after the effective end (a charge during a notice
    /// period, before `ends_on`, is expected and not flagged).
    static func lateCharges(_ s: Service) -> [Charge] {
        guard let end = effectiveEnd(s) else { return [] }
        return s.charges.filter { c in c.amount > 0 && (Schedule.parseDay(c.date).map { $0 >= end } ?? false) }
    }

    static func watch(_ ledger: Ledger, today: Date) -> [WatchItem] {
        let items: [WatchItem] = ledger.cancelled.compactMap { s in
            guard let cancelled = Schedule.parseDay(s.cancelledOn), let end = effectiveEnd(s) else { return nil }
            let late = lateCharges(s)
            guard Schedule.daysUntil(today, from: cancelled) <= watchDays || !late.isEmpty else { return nil }
            let would = Schedule.nextCharge(for: asActive(s), from: end)
            if would == nil && late.isEmpty { return nil }
            let status: WatchStatus
            if !late.isEmpty { status = .chargedAfterCancel }
            else if let w = would, Schedule.daysUntil(w, from: today) >= -watchGraceDays { status = .watching }
            else { status = .clear }
            return WatchItem(service: s, wouldCharge: would, status: status, lateCharges: late)
        }
        let rank: [WatchStatus: Int] = [.chargedAfterCancel: 0, .watching: 1, .clear: 2]
        return items.sorted {
            (rank[$0.status]!, $0.wouldCharge ?? .distantFuture, $0.service.name)
                < (rank[$1.status]!, $1.wouldCharge ?? .distantFuture, $1.service.name)
        }
    }

    static func savings(_ ledger: Ledger, today: Date, sinceDays: Int = 30) -> Savings {
        let since = cal.date(byAdding: .day, value: -sinceDays, to: today) ?? today
        var items: [Cancellation] = []
        for s in ledger.cancelled {
            guard let c = Schedule.parseDay(s.cancelledOn), c >= since, c <= today, let end = effectiveEnd(s) else { continue }
            let a = asActive(s)
            guard let m = a.monthlyEquivalent(on: c), m > 0 else { continue }
            let avoided = end <= today ? Schedule.chargeDates(for: a, from: end, through: today).count : 0
            let kept = max(0, (s.amount ?? 0) * Double(avoided) - lateCharges(s).map(\.amount).reduce(0, +))
            items.append(Cancellation(service: s, on: c, monthly: (m * 100).rounded() / 100, kept: (kept * 100).rounded() / 100))
        }
        items.sort { ($0.monthly, $1.service.name) > ($1.monthly, $0.service.name) }
        let closing = ledger.closing.compactMap { $0.monthlyEquivalent(on: today) }.reduce(0, +)
        return Savings(since: since, items: items,
                       monthly: (items.map(\.monthly).reduce(0, +) * 100).rounded() / 100,
                       kept: (items.map(\.kept).reduce(0, +) * 100).rounded() / 100,
                       closingMonthly: (closing * 100).rounded() / 100)
    }

    /// Monthly cost removed per calendar month of cancellation, oldest first.
    static func cutsByMonth(_ ledger: Ledger, today: Date, months: Int = 6) -> [(month: String, monthly: Double)] {
        let first = Schedule.clampedDate(year: cal.component(.year, from: today),
                                         month: cal.component(.month, from: today) - (months - 1), day: 1) ?? today
        var sums: [String: Double] = [:]
        for s in ledger.cancelled {
            guard let c = Schedule.parseDay(s.cancelledOn), c >= first, c <= today,
                  let m = asActive(s).monthlyEquivalent(on: c), m > 0 else { continue }
            sums[Schedule.monthKey(c), default: 0] += m
        }
        return (0..<months).compactMap { k in
            guard let d = cal.date(byAdding: .month, value: k, to: first) else { return nil }
            let key = Schedule.monthKey(d)
            return (key, ((sums[key] ?? 0) * 100).rounded() / 100)
        }
    }

    /// "Slack Pro — Studio" → "slack pro"; "ImprovMX (2nd account)" → "improvmx".
    static func baseName(_ name: String) -> String {
        var s = name.lowercased()
        s = s.replacingOccurrences(of: #"\([^)]*\)"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\$[0-9.,]+"#, with: " ", options: .regularExpression)
        if let r = s.range(of: " — ") { s = String(s[..<r.lowerBound]) }
        s = s.replacingOccurrences(of: "[\"“”']", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Active, not-closing items that do the same job: a `group` the user set,
    /// or the same service more than once (by `baseName`).
    static func cutGroups(_ ledger: Ledger, today: Date) -> [CutGroup] {
        var buckets: [String: (name: String, auto: Bool, members: [Service])] = [:]
        for s in ledger.active where !s.isClosing {
            guard let m = s.monthlyEquivalent(on: today), m > 0 else { continue }
            let key = s.group.map { "group:" + $0.lowercased() } ?? "same:" + baseName(s.name)
            buckets[key, default: (s.group ?? s.name, s.group == nil, [])].members.append(s)
        }
        let r2 = { (v: Double) in (v * 100).rounded() / 100 }
        return buckets.values.filter { $0.members.count >= 2 }.map { b in
            let costs = b.members.map { $0.monthlyEquivalent(on: today) ?? 0 }
            let members = zip(b.members, costs).sorted { ($0.1, $1.0.name) > ($1.1, $0.0.name) }.map(\.0)
            let total = costs.reduce(0, +)
            let name = b.auto ? (b.members.map(\.name).min { ($0.count, $0) < ($1.count, $1) } ?? b.name) : b.name
            return CutGroup(name: name, auto: b.auto, members: members, monthly: r2(total),
                            saveMin: r2(total - (costs.max() ?? 0)), saveMax: r2(total - (costs.min() ?? 0)))
        }
        .sorted { ($0.monthly, $1.name) > ($1.monthly, $0.name) }
    }

    /// Pending refund claims across the ledger (any status).
    static func refunds(_ ledger: Ledger) -> [(service: Service, claim: RefundClaim)] {
        ledger.services.flatMap { s in s.refunds.map { (s, $0) } }
            .sorted { ($0.claim.isPending ? 0 : 1, $0.claim.opened ?? "", $0.service.name)
                    < ($1.claim.isPending ? 0 : 1, $1.claim.opened ?? "", $1.service.name) }
    }

    static func pendingRefundTotal(_ ledger: Ledger) -> Double {
        (refunds(ledger).filter(\.claim.isPending).map(\.claim.amount).reduce(0, +) * 100).rounded() / 100
    }

    struct BurnSlice: Hashable, Identifiable {
        var id: String { key }
        let key: String
        let label: String
        let monthly: Double
        let count: Int
        let share: Double
    }

    struct BurnBreakdown: Equatable {
        let totalMonthly: Double
        let fixedMonthly: Double
        let usageMonthly: Double
        let multiMonthMonthly: Double
        let prepaidTermMonthly: Double
        let byCategory: [BurnSlice]
        let byAccount: [BurnSlice]
        let byCard: [BurnSlice]
        let unmappedCardCount: Int
        let medianMonthly: Double
        let averageMonthly: Double
        let top5Share: Double
        let top5Names: [String]
        let top10Share: Double
        let under10Count: Int
        let under10Monthly: Double
    }

    /// Single-pass structural breakdown of active recurring burn:
    /// cadence mix (fixed monthly vs usage vs multi-month vs prepaid term),
    /// category share, account attribution, payment card concentration, and plan distribution.
    static func burnBreakdown(_ ledger: Ledger, today: Date) -> BurnBreakdown {
        let r2 = { (v: Double) in (v * 100).rounded() / 100 }
        var priced: [(Service, Double)] = []
        priced.reserveCapacity(ledger.services.count)

        var fixedMo = 0.0
        var usageMo = 0.0
        var multiMo = 0.0
        var termMo = 0.0
        var unmappedCards = 0

        var catAcc: [String: (Double, Int)] = [:]
        var acctAcc: [String: (Double, Int)] = [:]
        var cardAcc: [String: (Double, Int)] = [:]

        for s in ledger.services where s.status == .active {
            if s.amount != nil, (s.card ?? "").isEmpty {
                unmappedCards += 1
            }
            guard let m = s.monthlyEquivalent(on: today) else { continue }
            priced.append((s, m))

            switch s.cadence {
            case .usage:
                usageMo += m
            case .term:
                termMo += m
            case .quarterly, .semiannual, .annual:
                multiMo += m
            case .monthly, .biweekly, .topup, .other:
                fixedMo += m
            }

            catAcc[s.category, default: (0, 0)].0 += m
            catAcc[s.category, default: (0, 0)].1 += 1

            let acctKey = s.account ?? "unknown"
            acctAcc[acctKey, default: (0, 0)].0 += m
            acctAcc[acctKey, default: (0, 0)].1 += 1

            let rawCard = s.card ?? "unknown"
            cardAcc[rawCard, default: (0, 0)].0 += m
            cardAcc[rawCard, default: (0, 0)].1 += 1
        }

        priced.sort { $0.1 == $1.1 ? $0.0.name < $1.0.name : $0.1 > $1.1 }
        let total = priced.map(\.1).reduce(0, +)
        let denom = max(total, 0.0001)

        let sliceOrder: (BurnSlice, BurnSlice) -> Bool = { a, b in
            a.monthly == b.monthly ? a.key < b.key : a.monthly > b.monthly
        }

        var byCategory: [BurnSlice] = []
        byCategory.reserveCapacity(catAcc.count)
        for (k, v) in catAcc {
            let sh = total > 0 ? v.0 / denom : 0
            byCategory.append(BurnSlice(key: k, label: k, monthly: r2(v.0), count: v.1, share: sh))
        }
        byCategory.sort(by: sliceOrder)

        var byAccount: [BurnSlice] = []
        byAccount.reserveCapacity(acctAcc.count)
        for (k, v) in acctAcc {
            let sh = total > 0 ? v.0 / denom : 0
            byAccount.append(BurnSlice(key: k, label: k, monthly: r2(v.0), count: v.1, share: sh))
        }
        byAccount.sort(by: sliceOrder)

        var byCard: [BurnSlice] = []
        byCard.reserveCapacity(cardAcc.count)
        for (k, v) in cardAcc {
            let isDigits = !k.isEmpty && k != "unknown" && k.allSatisfy({ $0.isNumber })
            let lbl = isDigits ? "card ···· \(k)" : k
            let sh = total > 0 ? v.0 / denom : 0
            byCard.append(BurnSlice(key: k, label: lbl, monthly: r2(v.0), count: v.1, share: sh))
        }
        byCard.sort(by: sliceOrder)

        let asc = priced.map(\.1).sorted()
        let median: Double
        if asc.isEmpty {
            median = 0
        } else if asc.count % 2 == 1 {
            median = asc[asc.count / 2]
        } else {
            median = (asc[asc.count / 2 - 1] + asc[asc.count / 2]) / 2
        }

        let top5 = total > 0 ? priced.prefix(5).map(\.1).reduce(0, +) / denom : 0
        let top10 = total > 0 ? priced.prefix(10).map(\.1).reduce(0, +) / denom : 0
        let under10 = priced.filter { $0.1 < 10 }

        return BurnBreakdown(
            totalMonthly: r2(total),
            fixedMonthly: r2(fixedMo),
            usageMonthly: r2(usageMo),
            multiMonthMonthly: r2(multiMo),
            prepaidTermMonthly: r2(termMo),
            byCategory: byCategory,
            byAccount: byAccount,
            byCard: byCard,
            unmappedCardCount: unmappedCards,
            medianMonthly: r2(median),
            averageMonthly: priced.isEmpty ? 0 : r2(total / Double(priced.count)),
            top5Share: top5,
            top5Names: priced.prefix(5).map(\.0.name),
            top10Share: top10,
            under10Count: under10.count,
            under10Monthly: r2(under10.map(\.1).reduce(0, +))
        )
    }
}

/// Numbers from JSONSerialization: rejects booleans, NaN/±inf and non-numbers.
enum Raw {
    /// Largest amount (USD) accepted for a plan or a charge; anything bigger is
    /// a typo and is reported instead of being summed into the totals.
    static let maxAmount = 10_000_000.0

    static func number(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }

    static func int(_ v: Any?) -> Int? {
        guard let d = number(v), d == d.rounded(), abs(d) < 1e9 else { return nil }
        return Int(d)
    }
}

/// Serializes exactly like Python's `json.dumps(obj, indent=2, sort_keys=True)`
/// (ASCII-escaped, shortest float repr, `200.0` stays `200.0`), which is how
/// cli/recurring writes the file. A save from the app therefore changes only the
/// bytes of what was edited — JSONSerialization would rewrite 19.99 as
/// 19.989999999999998 everywhere.
enum PyJSON {
    static func dumps(_ value: Any) throws -> String {
        var out = ""
        try write(value, indent: 0, into: &out)
        return out
    }

    private static func write(_ v: Any, indent: Int, into out: inout String) throws {
        let pad = String(repeating: " ", count: indent + 2), close = String(repeating: " ", count: indent)
        switch v {
        case let s as String:
            out += string(s)
        case let n as NSNumber:
            out += try number(n)
        case is NSNull:
            out += "null"
        case let a as [Any]:
            guard !a.isEmpty else { out += "[]"; return }
            out += "[\n"
            for (i, x) in a.enumerated() {
                out += pad
                try write(x, indent: indent + 2, into: &out)
                out += i < a.count - 1 ? ",\n" : "\n"
            }
            out += close + "]"
        case let d as [String: Any]:
            guard !d.isEmpty else { out += "{}"; return }
            // Python sorts keys by code point.
            let keys = d.keys.sorted { $0.unicodeScalars.map(\.value).lexicographicallyPrecedes($1.unicodeScalars.map(\.value)) }
            out += "{\n"
            for (i, k) in keys.enumerated() {
                out += pad + string(k) + ": "
                try write(d[k]!, indent: indent + 2, into: &out)
                out += i < keys.count - 1 ? ",\n" : "\n"
            }
            out += close + "}"
        default:
            throw LedgerError.malformed("unsupported value \(type(of: v))")
        }
    }

    private static func number(_ n: NSNumber) throws -> String {
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
        if n is NSDecimalNumber { return n.stringValue }          // integers too big for Int64
        guard CFNumberIsFloatType(n) else { return n.stringValue } // plain integer
        let d = n.doubleValue
        guard d.isFinite else { throw LedgerError.malformed("non-finite number") }
        return float(d)
    }

    /// Python's float repr: shortest round-trip digits, fixed notation when the
    /// decimal exponent is in (-4, 16], otherwise `1e+16` / `1e-05`.
    static func float(_ d: Double) -> String {
        if d == 0 { return d.sign == .minus ? "-0.0" : "0.0" }
        var s = d.description                      // Swift also prints shortest round-trip digits
        let negative = s.hasPrefix("-")
        if negative { s.removeFirst() }
        var exp = 0
        if let e = s.firstIndex(of: "e") {
            exp = Int(s[s.index(after: e)...])!
            s = String(s[..<e])
        }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        let whole = String(parts[0])
        var digits = Array(whole + (parts.count > 1 ? String(parts[1]) : ""))
        var point = whole.count + exp              // value = 0.d1d2d3… × 10^point
        while digits.first == "0" { digits.removeFirst(); point -= 1 }
        while digits.last == "0" { digits.removeLast() }
        let n = digits.count
        let body: String
        if point > -4 && point <= 16 {
            if point <= 0 {
                body = "0." + String(repeating: "0", count: -point) + String(digits)
            } else if point < n {
                body = String(digits[..<point]) + "." + String(digits[point...])
            } else {
                body = String(digits) + String(repeating: "0", count: point - n) + ".0"
            }
        } else {
            let e = point - 1
            body = String(digits[0]) + (n > 1 ? "." + String(digits[1...]) : "")
                + "e" + (e < 0 ? "-" : "+") + (abs(e) < 10 ? "0" : "") + String(abs(e))
        }
        return (negative ? "-" : "") + body
    }

    /// ensure_ascii=True escaping, as Python does it.
    private static func string(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if (0x20...0x7E).contains(u.value) {
                    out.unicodeScalars.append(u)
                } else if u.value > 0xFFFF {
                    let v = u.value - 0x10000
                    out += hex(0xD800 + (v >> 10)) + hex(0xDC00 + (v & 0x3FF))
                } else {
                    out += hex(u.value)
                }
            }
        }
        return out + "\""
    }

    private static func hex(_ v: UInt32) -> String {
        let h = String(v, radix: 16)
        return "\\u" + String(repeating: "0", count: 4 - h.count) + h
    }
}

enum LedgerError: LocalizedError {
    case malformed(String), notFound(String), duplicateID(String, Int), unsafePath(String)
    var errorDescription: String? {
        switch self {
        case .malformed(let why): return "the file isn't valid (\(why)) — fix it before changing anything from the app"
        case .notFound(let id): return "no service with id \(id)"
        case .duplicateID(let id, let n): return "id \(id) is used by \(n) services — give each a unique id first"
        case .unsafePath(let p): return "refusing to write through \(p)"
        }
    }
}

enum LedgerFile {
    /// ~/.recurring/subscriptions.json. `--ledger <path>` is honoured only
    /// together with `--snapshot` (a read-only render), and the RECURRING_FILE
    /// environment override only in debug builds, so nothing inherited by the
    /// installed app can redirect where it writes.
    static var url: URL {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--snapshot"), let i = args.firstIndex(of: "--ledger"), i + 1 < args.count {
            return URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath)
        }
        #if DEBUG
        if let p = ProcessInfo.processInfo.environment["RECURRING_FILE"], !p.isEmpty {
            return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".recurring/subscriptions.json")
    }

    static func load(from url: URL) throws -> Ledger {
        let data = try Data(contentsOf: url)
        return Ledger(raw: try JSONSerialization.jsonObject(with: data))
    }

    /// The one real file behind `url` (symlinks resolved). Lock, backup and
    /// write paths all derive from it — cli/recurring does the same — so two
    /// spellings of the same file always share one lock.
    static func canonical(_ url: URL) -> URL { url.resolvingSymlinksInPath() }

    /// Cancel or reactivate one service: the same transition as `set_status` in
    /// cli/recurring (clears `cancel_requested`; reactivating also clears
    /// `cancelled_on` and `ends_on`).
    static func setStatus(_ url: URL, id: String, cancelled: Bool, today: Date) throws {
        let day = Schedule.isoDay(today)
        try patch(url, id: id) { o in
            o.removeValue(forKey: "cancel_requested")
            if cancelled {
                o["status"] = "cancelled"
                o["cancelled_on"] = day
            } else {
                o["status"] = "active"
                o.removeValue(forKey: "cancelled_on")
                o.removeValue(forKey: "ends_on")
            }
        }
    }

    /// Toggle `cancel_requested` on an active service: mirrors `recurring closing ID [--clear]`.
    static func setClosing(_ url: URL, id: String, closing: Bool, today: Date) throws {
        let day = Schedule.isoDay(today)
        try patch(url, id: id) { o in
            let st = (o["status"] as? String) ?? "active"
            guard st == "active" else {
                throw LedgerError.malformed("service \(id) is \(st), not active")
            }
            if closing {
                o["cancel_requested"] = day
            } else {
                o.removeValue(forKey: "cancel_requested")
            }
        }
    }

    /// Clear `check` flag on a reviewed service: mirrors `recurring set ID check=`.
    static func clearCheck(_ url: URL, id: String) throws {
        try patch(url, id: id) { o in
            o.removeValue(forKey: "check")
        }
    }

    /// Read-modify-write of ONE service, under the lock the CLI also takes:
    /// re-reads the current file (so edits made since the app last looked are
    /// kept), changes only that service's raw JSON object (unknown fields
    /// survive), backs the old file up to `.bak`, then replaces it atomically with
    /// a 0600 file in the CLI's exact format. Refuses to touch a file that doesn't
    /// parse, and an id that matches no service or more than one.
    static func patch(_ url: URL, id: String, _ mutate: (inout [String: Any]) throws -> Void) throws {
        let file = canonical(url)
        try withLock(file) {
            let data = try Data(contentsOf: file)
            guard var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw LedgerError.malformed("not a JSON object")
            }
            guard var list = root["services"] as? [Any] else { throw LedgerError.malformed("no services list") }
            let matches = list.indices.filter { i in
                (list[i] as? [String: Any]).map(Service.id(ofRaw:)) == id
            }
            guard matches.count <= 1 else { throw LedgerError.duplicateID(id, matches.count) }
            guard let i = matches.first, var svc = list[i] as? [String: Any] else { throw LedgerError.notFound(id) }
            try mutate(&svc)
            list[i] = svc
            root["services"] = list
            let out = Data((try PyJSON.dumps(root) + "\n").utf8)
            try writeSecurely(data, to: backupURL(for: file))
            try writeSecurely(out, to: file)
        }
    }

    static func backupURL(for url: URL) -> URL { url.appendingPathExtension("bak") }

    static func lockURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).lock")
    }

    /// Exclusive advisory lock on `.subscriptions.json.lock` next to the
    /// canonical file; cli/recurring takes the same lock with fcntl.flock, so
    /// the app and CLI never interleave a read-modify-write.
    static func withLock<T>(_ url: URL, _ body: () throws -> T) throws -> T {
        try ensurePrivateDirectory(url.deletingLastPathComponent())
        let fd = open(lockURL(for: url).path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw LedgerError.unsafePath(lockURL(for: url).path) }
        defer { flock(fd, LOCK_UN); close(fd) }
        flock(fd, LOCK_EX)
        return try body()
    }

    /// Creates the directory 0700 if missing (never loosens an existing one).
    static func ensurePrivateDirectory(_ dir: URL) throws {
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
    }

    /// Writes to a fresh 0600 temp file (O_EXCL, so it is never readable by
    /// others even briefly), flushes it to disk, then renames it over `url`.
    /// Symlinks are NOT followed: rename replaces a link at `url` with the
    /// file itself, so a planted `.bak` or snapshot link can't redirect the
    /// write elsewhere. (Callers resolve the ledger path once, via `canonical`.)
    static func writeSecurely(_ data: Data, to url: URL, durableSync: Bool = true) throws {
        let dir = url.deletingLastPathComponent()
        try ensurePrivateDirectory(dir)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(getpid()).\(UUID().uuidString.prefix(8)).tmp")
        let fd = open(tmp.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw LedgerError.unsafePath(tmp.path) }
        var ok = false
        defer { if !ok { unlink(tmp.path) } }
        var offset = 0
        let complete = data.withUnsafeBytes { buf -> Bool in
            while offset < buf.count {
                let n = write(fd, buf.baseAddress! + offset, buf.count - offset)
                if n < 0 { if errno == EINTR { continue }; return false }
                offset += n
            }
            return true
        }
        let synced = durableSync ? (fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0) : true
        close(fd)
        guard complete, synced else { throw CocoaError(.fileWriteUnknown) }
        guard rename(tmp.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        ok = true
        if durableSync {
            let dfd = open(dir.path, O_RDONLY)                     // persist the rename itself
            if dfd >= 0 { fsync(dfd); close(dfd) }
        }
    }
}
