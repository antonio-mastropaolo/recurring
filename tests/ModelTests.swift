// Standalone checks for RecurringApp/Sources/Model.swift. Run: ./scripts/test.sh
import Foundation

var failures = 0
func expect(_ cond: Bool, _ msg: String, line: Int = #line) {
    if !cond { failures += 1; print("FAIL line \(line): \(msg)") }
}
func day(_ s: String) -> Date { Schedule.parseDay(s)! }
func ledger(_ json: String) -> Ledger { Ledger(raw: try! JSONSerialization.jsonObject(with: Data(json.utf8))) }
let today = day("2026-10-07")

// Monthly on a fixed day
let spotify = Service(id: "spotify", name: "Spotify", category: "Life", amount: 12.99, billingDay: 14)
expect(Schedule.nextCharge(for: spotify, from: today) == day("2026-10-14"), "same-month charge")
expect(Schedule.nextCharge(for: spotify, from: day("2026-10-14")) == day("2026-10-14"), "charge day counts as today")
expect(Schedule.nextCharge(for: spotify, from: day("2026-10-15")) == day("2026-11-14"), "rolls to next month")
expect(Schedule.nextCharge(for: spotify, from: day("2026-12-20")) == day("2027-01-14"), "rolls over the year")

// Day 31 clamps per month without drifting
let kimi = Service(id: "kimi", name: "Kimi", category: "AI", amount: 199, billingDay: 31)
let kd = Schedule.chargeDates(for: kimi, from: day("2026-11-05"), through: day("2027-01-31"))
expect(kd == [day("2026-11-30"), day("2026-12-31"), day("2027-01-31")], "31st clamps then returns: \(kd.map(Schedule.isoDay))")

// Monthly with no billing_day falls back to last_charged's day
var cursor = Service(id: "cursor", name: "Cursor", category: "Dev", amount: 60, lastCharged: "2026-10-01")
expect(Schedule.nextCharge(for: cursor, from: today) == day("2026-11-01"), "day from last_charged")
cursor.lastCharged = nil
expect(Schedule.nextCharge(for: cursor, from: today) == nil, "no day known → no schedule")

// Annual: anchored on last charge / billing month
let consensus = Service(id: "consensus", name: "Consensus", category: "AI", amount: 86.40, cadence: .annual, lastCharged: "2026-09-09")
expect(Schedule.nextCharge(for: consensus, from: today) == day("2027-09-09"), "annual from last charge")
expect(abs(consensus.monthlyEquivalent(on: today)! - 7.20) < 1e-9, "annual spread over 12 months")
let costco = Service(id: "costco", name: "Costco", category: "Life", amount: 65, cadence: .annual, billingDay: 1, billingMonth: 3)
expect(Schedule.nextCharge(for: costco, from: today) == day("2027-03-01"), "annual from billing month")

// Every 6 months / every 2 weeks
let iscanner = Service(id: "isc", name: "iScanner", category: "Life", amount: 9.99, cadence: .semiannual, lastCharged: "2026-06-16")
expect(Schedule.nextCharge(for: iscanner, from: today) == day("2026-12-16"), "semiannual")
let gym = Service(id: "gym", name: "Gym", category: "Life", amount: 16.99, cadence: .biweekly, lastCharged: "2026-09-28")
expect(Schedule.chargeDates(for: gym, from: today, through: day("2026-10-31")) == [day("2026-10-12"), day("2026-10-26")], "biweekly dates")

// Prepaid term + domain grouping + yearly equivalent of a 2-year registration
let zai = Service(id: "zai", name: "Z.ai", category: "AI", amount: 120, cadence: .term, termStart: "2026-03-01", termEnd: "2027-03-01")
expect(zai.termIsRunning(on: today) && Schedule.nextCharge(for: zai, from: today) == nil, "term running, no renewal")
expect(zai.monthlyEquivalent(on: day("2027-03-02")) == nil, "expired term costs nothing")
let dom2 = Service(id: "d2", name: "helix.ai", category: "Infra", plan: "domain, 2 years", amount: 160, cadence: .term,
                   termStart: "2026-06-03", termEnd: "2028-06-03")
expect(dom2.isDomain && abs(dom2.yearlyEquivalent(on: today)! - 160.0 / 2) < 0.2, "2-year domain counts ~half per year: \(dom2.yearlyEquivalent(on: today)!)")
let workspace = Service(id: "gw", name: "Workspace", category: "Infra", plan: "Google Workspace — custom domain", amount: 6)
expect(!workspace.isDomain, "a monthly plan mentioning 'domain' is not a domain registration")

// Closing / ending / unverified
var gymC = gym; gymC.cancelRequested = "2026-10-07"; gymC.check = "notice sent"
expect(gymC.isClosing && Ledger(version: 2, services: [gymC]).needsLook.isEmpty && gymC.monthlyEquivalent(on: today) != nil, "closing")
let netcup = Service(id: "netcup", name: "netcup", category: "Infra", amount: 53.34, status: .cancelled, cancelledOn: "2026-09-17", endsOn: "2026-11-04")
expect(netcup.isEnding(on: today) && netcup.monthlyEquivalent(on: today) == nil, "ending, not counted")
let tmo = Service(id: "tmo", name: "T-Mobile", category: "Life", amount: 80, billingDay: 1, status: .unverified)
expect(tmo.monthlyEquivalent(on: today) == nil && Schedule.nextCharge(for: tmo, from: today) == nil, "unverified not counted")

// Strict dates (same rule as the CLI)
expect(Schedule.parseDay("20261005") == nil && Schedule.parseDay("2026-W41-1") == nil, "compact/week dates rejected")
expect(Schedule.parseDay("2026-02-30") == nil && Schedule.parseDay("2026-13-01") == nil, "impossible dates rejected")
expect(Schedule.parseDay("2026-10-08T09:30:00") == day("2026-10-08"), "time suffix ignored")

// Lenient-but-honest reading: bad values are dropped and reported, never guessed
let messy = ledger(#"""
{"version":2,"services":[
 {"name":"Typo","amount":100,"cadence":"monthy","status":"canceled"},
 {"name":"Strings","amount":"12.99","billing_day":"15"},
 {"name":"Charges","amount":9,"charges":[{"date":"2026-09-01","amount":9},{"date":"2026-09-02","amount":"x"},7]},
 "not an object",
 {"id":"x","name":"A"},{"id":"x","name":"B"}
]}
"""#)
let typo = messy.services[0]
expect(typo.cadence == .other && typo.status == .unverified && typo.monthlyEquivalent(on: today) == nil, "typo'd enums are not counted")
expect(messy.services[1].amount == nil && messy.services[1].billingDay == nil, "string numbers rejected")
expect(messy.services[2].charges.count == 1, "one bad charge drops only itself: \(messy.services[2].charges.count)")
expect(messy.services.count == 5 && messy.issues.count == 8, "issues: \(messy.issues)")
expect(Insights.baseName("Slack Pro — Studio") == "slack pro" && Insights.baseName("ImprovMX (2nd account)") == "improvmx"
       && Insights.baseName("Apple (debit card) $4.99") == "apple" && Insights.baseName("\"Amazon Prime\" add-on (25th)") == "amazon prime add-on",
       "baseName: \(Insights.baseName("\"Amazon Prime\" add-on (25th)"))")
let amounts = ledger(#"{"services":[{"name":"N","amount":-5},{"name":"H","amount":2e7},{"name":"C","amount":1,"charges":[{"date":"2026-09-01","amount":2e7}]}]}"#)
expect(amounts.services.allSatisfy { $0.amount == nil || $0.amount == 1 } && amounts.services[2].charges.isEmpty
       && amounts.issues.count == 3, "negative / out-of-range amounts are flagged, not summed: \(amounts.issues)")

// Cash flow: a '|' in a category can't corrupt buckets
let pipe = Service(id: "p", name: "P", category: "Dev | Tools", amount: 8.0, billingDay: 1,
                   charges: [Charge(date: "2026-09-01", amount: 8.0)])
let pb = CashFlow.buckets(Ledger(version: 2, services: [pipe]), today: today, monthsBack: 2, monthsAhead: 2)
expect(pb.allSatisfy { $0.category == "Dev | Tools" }, "category kept intact")
expect(pb.first { $0.month == "2026-09" }?.projected == false && pb.first { $0.month == "2026-11" }?.projected == true, "charged vs scheduled kept")

// URL safety
var link = spotify
for bad in ["file:///etc/passwd", "javascript:alert(1)", "http://www.spotify.com", "https://spotify.com@evil.example/login", "https://",
            "https://localhost/billing", "https://127.0.0.1/x", "https://10.0.0.8/", "https://[::1]/", "https://router.local/", "https://intranet/"] {
    link.manageURL = bad; expect(link.safeManageURL == nil, "rejected \(bad)")
}
link.manageURL = "https://www.spotify.com/account"; expect(link.manageHost == "www.spotify.com", "https allowed")

// Account disambiguation for duplicate active plan names (fixes "Claude Max 20x" ambiguity)
let cmLab  = Service(id: "cm-lab", name: "Claude Max 20x", category: "AI", amount: 200, account: "lab@acme.dev")
let cmOps  = Service(id: "cm-ops", name: "Claude Max 20x", category: "AI", amount: 200, account: "ops@acme.dev")
let cmOld  = Service(id: "cm-old", name: "Claude Max 20x", category: "AI", amount: 200, account: "old@example.com", status: .cancelled)
let solo   = Service(id: "solo", name: "Cursor", category: "Dev", amount: 60, account: "alex@example.com")
expect(cmLab.disambiguatedName(among: [cmLab, cmOps, cmOld, solo]) == "Claude Max 20x · lab", "disambiguates active siblings")
expect(cmOps.disambiguatedName(among: [cmLab, cmOps, cmOld, solo]) == "Claude Max 20x · ops", "disambiguates second sibling")
expect(solo.disambiguatedName(among: [cmLab, cmOps, cmOld, solo]) == "Cursor", "unique active name stays clean")
expect(cmLab.disambiguatedName(among: [cmLab, cmOld]) == "Claude Max 20x", "cancelled sibling does not force suffix")

// Explicit `next_renewal` floor: trials, policy shifts, and credit-covered windows
let sxmCredit = Service(id: "siriusxm", name: "SiriusXM", category: "Life", amount: 6.29, billingDay: 13, nextRenewal: "2027-04-13")
expect(Schedule.nextCharge(for: sxmCredit, from: day("2026-11-13")) == day("2027-04-13"), "credit window skips until next_renewal")
expect(Schedule.nextCharge(for: sxmCredit, from: day("2027-04-14")) == day("2027-05-13"), "rolls monthly once past next_renewal")
let onepassTrial = Service(id: "1password", name: "1Password", category: "Infra", amount: 4.99, billingDay: 18, nextRenewal: "2026-11-18")
expect(Schedule.nextCharge(for: onepassTrial, from: day("2026-11-13")) == day("2026-11-18"), "trial bills on next_renewal")

// Writes: re-read under lock, patch one service, keep unknown fields, back up, 0600, refuse broken files
let base = FileManager.default.temporaryDirectory.appendingPathComponent("recurring-test-\(UUID())")
let dir = base.appendingPathComponent("sub")
let file = dir.appendingPathComponent("subscriptions.json")
func rawFile() -> [String: Any] { try! JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any] }
let seed: [String: Any] = ["version": 2, "top": "keep", "services": [
    ["id": "a", "name": "A — café", "amount": 19.99, "cancel_requested": "2026-10-01", "tags": ["keep"],
     "charges": [["date": "2026-09-01", "amount": 4.35, "weird": true]]],
    ["id": "b", "name": "B", "amount": 200.0, "billing_day": 3]]]
try! LedgerFile.writeSecurely(Data((try! PyJSON.dumps(seed) + "\n").utf8), to: file)
let dirMode = (try! FileManager.default.attributesOfItem(atPath: dir.path))[.posixPermissions] as! Int
expect(dirMode == 0o700, "new directory is 0700: \(String(dirMode, radix: 8))")
// Another writer (the CLI) adds a charge after the app loaded its copy:
let stale = try! LedgerFile.load(from: file)
var rawNow = rawFile()
var list = rawNow["services"] as! [[String: Any]]
list[1]["charges"] = [["date": "2026-10-01", "amount": 2.0]]
rawNow["services"] = list
try! LedgerFile.writeSecurely(Data((try! PyJSON.dumps(rawNow) + "\n").utf8), to: file)
expect(stale.services[1].charges.isEmpty, "app copy is stale")
let beforeText = try! String(contentsOf: file, encoding: .utf8)
try! LedgerFile.setStatus(file, id: "a", cancelled: true, today: day("2026-10-07"))
let afterText = try! String(contentsOf: file, encoding: .utf8)
let after = rawFile()
let svcs = after["services"] as! [[String: Any]]
expect(after["top"] as? String == "keep" && (svcs[0]["tags"] as? [String]) == ["keep"], "unknown fields survive")
expect(((svcs[0]["charges"] as? [[String: Any]])?.first?["weird"] as? Bool) == true, "unknown charge fields survive")
expect(svcs[0]["status"] as? String == "cancelled" && svcs[0]["cancelled_on"] as? String == "2026-10-07"
       && svcs[0]["cancel_requested"] == nil, "cancel = same transition as the CLI")
expect((svcs[1]["charges"] as? [[String: Any]])?.count == 1, "the other writer's charge was NOT lost")
// Only the edited lines change: amounts keep their short form (19.99, not 19.989999999999998)
let lineDiff = afterText.split(separator: "\n").difference(from: beforeText.split(separator: "\n"))
func changed(_ c: CollectionDifference<Substring>.Change) -> String {
    switch c { case .insert(_, let e, _), .remove(_, let e, _): return String(e) }
}
expect(lineDiff.removals.map(changed) == [#"      "cancel_requested": "2026-10-01","#]
       && Set(lineDiff.insertions.map(changed)) == [#"      "cancelled_on": "2026-10-07","#, #"      "status": "cancelled","#],
       "a status change touches only its own lines: \(lineDiff.map { "\($0)" })")
expect(afterText.contains("\"amount\": 19.99,") && afterText.contains("\"amount\": 4.35,") && afterText.contains("\"amount\": 200.0,")
       && afterText.contains(#""name": "A \u2014 caf\u00e9","#), "numbers and text keep the CLI's exact format")
try! LedgerFile.setStatus(file, id: "a", cancelled: false, today: day("2026-10-08"))
let back = (rawFile()["services"] as! [[String: Any]])[0]
expect(back["status"] as? String == "active" && back["cancelled_on"] == nil, "reactivate clears cancelled_on")
let fileMode = (try! FileManager.default.attributesOfItem(atPath: file.path))[.posixPermissions] as! Int
expect(fileMode == 0o600, "file is 0600")
expect(FileManager.default.fileExists(atPath: LedgerFile.backupURL(for: file).path), "backup written")

// Duplicate ids: the app refuses, like the CLI, instead of changing the first match
var dupRaw = rawFile(); var dupList = dupRaw["services"] as! [[String: Any]]
dupList.append(["id": "a", "name": "A again", "amount": 1.0]); dupRaw["services"] = dupList
try! LedgerFile.writeSecurely(Data((try! PyJSON.dumps(dupRaw) + "\n").utf8), to: file)
let dupBefore = try! Data(contentsOf: file)
var dupRefused = false
do { try LedgerFile.setStatus(file, id: "a", cancelled: true, today: today) } catch LedgerError.duplicateID(_, 2) { dupRefused = true } catch {}
expect(dupRefused && (try! Data(contentsOf: file)) == dupBefore, "duplicate id refused, file untouched")

// Symlinks: a planted .bak link is replaced, never followed; a linked ledger locks next to the real file
let victim = base.appendingPathComponent("victim.txt")
try! Data("do not touch".utf8).write(to: victim)
let bak = LedgerFile.backupURL(for: file)
try? FileManager.default.removeItem(at: bak)
try! FileManager.default.createSymbolicLink(at: bak, withDestinationURL: victim)
dupRaw["services"] = Array(dupList.dropLast()); try! LedgerFile.writeSecurely(Data((try! PyJSON.dumps(dupRaw) + "\n").utf8), to: file)
try! LedgerFile.setStatus(file, id: "b", cancelled: true, today: today)
let bakType = (try! FileManager.default.attributesOfItem(atPath: bak.path))[.type] as? FileAttributeType
expect((try! String(contentsOf: victim, encoding: .utf8)) == "do not touch" && bakType == .typeRegular, "backup symlink not followed")
let linkDir = base.appendingPathComponent("elsewhere")
try! FileManager.default.createDirectory(at: linkDir, withIntermediateDirectories: true)
let linkedLedger = linkDir.appendingPathComponent("ledger-link.json")
try! FileManager.default.createSymbolicLink(at: linkedLedger, withDestinationURL: file)
try! LedgerFile.setStatus(linkedLedger, id: "b", cancelled: false, today: today)
expect(FileManager.default.fileExists(atPath: LedgerFile.lockURL(for: file).path)
       && !FileManager.default.fileExists(atPath: LedgerFile.lockURL(for: linkedLedger).path)
       && (try! FileManager.default.destinationOfSymbolicLink(atPath: linkedLedger.path)) == file.path,
       "a linked ledger shares the real file's lock and the link survives")

try! Data("{ broken".utf8).write(to: file)
var refused = false
do { try LedgerFile.setStatus(file, id: "a", cancelled: false, today: today) } catch { refused = true }
expect(refused && (try! String(contentsOf: file, encoding: .utf8)) == "{ broken", "a broken file is never overwritten")
try? FileManager.default.removeItem(at: base)

// O(N) disambiguatedNames(), Insights.burnBreakdown(), and optimistic + persisted closing/clearCheck mutations
do {
    let bday = day("2026-11-13")
    let raw: [String: Any] = [
        "version": 2,
        "services": [
            ["id": "c1", "name": "Claude Max 20x", "category": "AI", "amount": 200.0, "cadence": "monthly", "status": "active",
             "account": "ops@acme.dev", "card": "4242", "check": "verify billing day"],
            ["id": "c2", "name": "Claude Max 20x", "category": "AI", "amount": 200.0, "cadence": "monthly", "status": "active",
             "account": "alex@example.com", "card": "4242"],
            ["id": "c3", "name": "Claude Max 20x", "category": "AI", "amount": 200.0, "cadence": "monthly", "status": "cancelled",
             "account": "old@example.com", "cancelled_on": "2026-10-01"],
            ["id": "fly", "name": "Fly.io", "category": "Infra", "amount": 35.0, "amount_kind": "estimate", "cadence": "usage",
             "status": "active", "account": "ops@acme.dev"],
            ["id": "dom", "name": "acme.dev", "category": "Infra", "amount": 120.0, "cadence": "annual", "status": "active",
             "card": "9999"],
            ["id": "zai", "name": "Z.ai GLM", "category": "AI", "amount": 365.24, "cadence": "term",
             "term_start": "2026-01-01", "term_end": "2027-01-01", "status": "active", "card": "4242"],
            ["id": "tiny", "name": "iCloud+", "category": "Consumer", "amount": 2.99, "cadence": "monthly", "status": "active",
             "card": "4242"],
        ],
    ]
    var led = Ledger(raw: raw)
    let map = led.disambiguatedNames()
    for s in led.services {
        expect(map[s.id] == s.disambiguatedName(among: led.services), "disambiguatedNames parity for \(s.id)")
    }
    expect(map["c1"] == "Claude Max 20x · ops" && map["fly"] == "Fly.io", "duplicate names disambiguated, unique names plain")

    let bd = Insights.burnBreakdown(led, today: bday)
    expect(bd.fixedMonthly == 402.99, "burnBreakdown fixedMonthly: \(bd.fixedMonthly)")
    expect(bd.usageMonthly == 35.0, "burnBreakdown usageMonthly: \(bd.usageMonthly)")
    expect(bd.multiMonthMonthly == 10.0, "burnBreakdown multiMonthMonthly: \(bd.multiMonthMonthly)")
    expect(abs(bd.prepaidTermMonthly - 30.46) < 0.05, "burnBreakdown prepaidTermMonthly: \(bd.prepaidTermMonthly)")
    expect(bd.unmappedCardCount == 1, "burnBreakdown unmappedCardCount: \(bd.unmappedCardCount)")
    expect(bd.under10Count == 1 && bd.under10Monthly == 2.99, "burnBreakdown under-$10 tail")
    expect(bd.byCategory.first?.key == "AI" && bd.byCard.first?.key == "4242", "burnBreakdown top category & card")

    // Optimistic + disk round-trip for setClosing & clearCheck
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("rec-mut-\(UUID().uuidString)")
    let tmpFile = tmpDir.appendingPathComponent("subs.json")
    try! LedgerFile.ensurePrivateDirectory(tmpDir)
    try! LedgerFile.writeSecurely(Data((try! PyJSON.dumps(raw) + "\n").utf8), to: tmpFile)

    expect(led.applyClosing(id: "c2", closing: true, today: bday), "applyClosing true")
    expect(led.services.first(where: { $0.id == "c2" })?.cancelRequested == "2026-11-13", "optimistic cancelRequested set")
    try! LedgerFile.setClosing(tmpFile, id: "c2", closing: true, today: bday)
    expect(try! LedgerFile.load(from: tmpFile).services.first(where: { $0.id == "c2" })?.isClosing == true, "disk setClosing true")

    expect(led.applyClosing(id: "c2", closing: false, today: bday), "applyClosing false")
    try! LedgerFile.setClosing(tmpFile, id: "c2", closing: false, today: bday)
    expect(try! LedgerFile.load(from: tmpFile).services.first(where: { $0.id == "c2" })?.isClosing == false, "disk setClosing false")

    expect(led.applyClearCheck(id: "c1"), "applyClearCheck")
    expect(led.services.first(where: { $0.id == "c1" })?.check == nil, "optimistic check cleared")
    try! LedgerFile.clearCheck(tmpFile, id: "c1")
    expect(try! LedgerFile.load(from: tmpFile).services.first(where: { $0.id == "c1" })?.check == nil, "disk clearCheck")
    try? FileManager.default.removeItem(at: tmpDir)
}

// Parity with the CLI: same fixture, same answers (expected values come from cli/recurring)
if let pdir = ProcessInfo.processInfo.environment["PARITY_DIR"] {
    let fx = URL(fileURLWithPath: pdir)
    let led = try! LedgerFile.load(from: fx.appendingPathComponent("parity.json"))
    let exp = try! JSONSerialization.jsonObject(with: Data(contentsOf: fx.appendingPathComponent("parity_expected.json"))) as! [String: Any]
    let ref = day(exp["today"] as! String)
    let es = exp["services"] as! [[String: Any]]
    expect(led.services.count == es.count, "parity: service count \(led.services.count) vs \(es.count)")
    for (s, e) in zip(led.services, es) {
        let tag = "parity \(s.id)"
        expect(s.id == e["id"] as? String && s.name == e["name"] as? String, "\(tag): id/name \(s.name)")
        expect(s.status.rawValue == e["status"] as? String, "\(tag): status \(s.status) vs \(e["status"] ?? "")")
        expect(s.cadence.rawValue == e["cadence"] as? String, "\(tag): cadence")
        expect(s.amount == Raw.number(e["amount"]), "\(tag): amount \(String(describing: s.amount))")
        expect(s.charges.count == e["charges"] as? Int, "\(tag): charges \(s.charges.count)")
        let next = Schedule.nextCharge(for: s, from: ref).map(Schedule.isoDay)
        expect(next == e["next_charge"] as? String, "\(tag): next \(next ?? "nil") vs \(e["next_charge"] ?? "nil")")
        let m = s.monthlyEquivalent(on: ref).map { ($0 * 100).rounded() / 100 }
        expect(m == Raw.number(e["monthly"]), "\(tag): monthly \(String(describing: m)) vs \(e["monthly"] ?? "nil")")
    }
    expect(abs(led.monthlyTotal(on: ref) - (exp["monthly_total"] as! Double)) < 0.005,
           "parity total \(led.monthlyTotal(on: ref)) vs \(exp["monthly_total"]!)")
    let ev = Schedule.events(led, from: ref, within: 7).map { [Schedule.isoDay($0.date), $0.kind.rawValue, $0.service.id] }
    expect(ev == exp["events_7d"] as! [[String]], "parity events \(ev)")
    var months: [String: (Double, Double)] = [:]
    for b in CashFlow.buckets(led, today: ref, monthsBack: 4, monthsAhead: 11) {
        var v = months[b.month] ?? (0, 0)
        if b.projected { v.1 += b.amount } else { v.0 += b.amount }
        months[b.month] = v
    }
    let ecf = exp["cash_flow"] as! [String: [String: Double]]
    expect(Set(months.keys) == Set(ecf.keys), "parity cash-flow months \(months.keys.sorted()) vs \(ecf.keys.sorted())")
    for (k, e) in ecf {
        let v = months[k] ?? (0, 0)
        expect(abs(v.0 - e["charged"]!) < 0.02 && abs(v.1 - e["scheduled"]!) < 0.02, "parity cash flow \(k): \(v) vs \(e)")
    }
    // Insights
    let iso = { (d: Date?) in d.map(Schedule.isoDay) }
    let rn = Insights.renewals(led, from: ref, within: 30).map { [Schedule.isoDay($0.date), $0.service.id, "\($0.daysLeft)", iso($0.cancelBy) ?? "nil"] }
    let ern = (exp["renewals_30d"] as! [[Any]]).map { r in [r[0] as! String, r[1] as! String, "\(r[2] as! Int)", (r[3] as? String) ?? "nil"] }
    expect(rn == ern, "parity renewals\n  app: \(rn.prefix(4))\n  cli: \(ern.prefix(4))")
    let wt = Insights.watch(led, today: ref).map { [$0.service.id, $0.status.rawValue, iso($0.wouldCharge) ?? "nil", String(format: "%.2f", $0.lateTotal)] }
    let ewt = (exp["watch"] as! [[Any]]).map { w in [w[0] as! String, w[1] as! String, (w[2] as? String) ?? "nil", String(format: "%.2f", Raw.number(w[3]) ?? -1)] }
    expect(wt == ewt, "parity watch\n  app: \(wt)\n  cli: \(ewt)")
    let sv = Insights.savings(led, today: ref, sinceDays: 30)
    let esv = exp["savings_30d"] as! [String: Any]
    expect(sv.monthly == Raw.number(esv["monthly"]) && sv.kept == Raw.number(esv["kept"]) && sv.closingMonthly == Raw.number(esv["closing"]),
           "parity savings totals \(sv.monthly) \(sv.kept) \(sv.closingMonthly) vs \(esv)")
    let svi = sv.items.map { "\($0.service.id) \($0.monthly) \($0.kept)" }
    let esvi = (esv["items"] as! [[Any]]).map { "\($0[0] as! String) \(Raw.number($0[1])!) \(Raw.number($0[2])!)" }
    expect(svi == esvi, "parity savings items \(svi) vs \(esvi)")
    let cbm = Insights.cutsByMonth(led, today: ref, months: 6).map { "\($0.month) \($0.monthly)" }
    let ecbm = (exp["cuts_by_month"] as! [[Any]]).map { "\($0[0] as! String) \(Raw.number($0[1])!)" }
    expect(cbm == ecbm, "parity cuts by month \(cbm) vs \(ecbm)")
    let cg = Insights.cutGroups(led, today: ref).map { "\($0.name)|\($0.auto)|\($0.members.map(\.id))|\($0.monthly)|\($0.saveMin)|\($0.saveMax)" }
    let ecg = (exp["cut_groups"] as! [[Any]]).map { "\($0[0] as! String)|\($0[1] as! Bool)|\($0[2] as! [String])|\(Raw.number($0[3])!)|\(Raw.number($0[4])!)|\(Raw.number($0[5])!)" }
    expect(cg == ecg, "parity cut groups\n  app: \(cg)\n  cli: \(ecg)")
    let erf = exp["refunds"] as! [String: Any]
    expect(Insights.pendingRefundTotal(led) == Raw.number(erf["pending"]), "parity pending refunds \(Insights.pendingRefundTotal(led))")
    let rf = Insights.refunds(led).map { "\($0.service.id) \($0.claim.amount) \($0.claim.status.rawValue)" }
    let erfc = (erf["claims"] as! [[Any]]).map { "\($0[0] as! String) \(Raw.number($0[1])!) \($0[2] as! String)" }
    expect(rf == erfc, "parity refund claims \(rf) vs \(erfc)")

    let expIssues = exp["issues"] as! [String]
    expect(led.issues == expIssues, "parity issues differ:\n  app: \(led.issues)\n  cli: \(expIssues)")

    // The app writes byte-for-byte what Python's json.dumps(indent=2, sort_keys=True) writes
    let sampleURL = fx.appendingPathComponent("pyjson_sample.json")
    let sampleText = try! String(contentsOf: sampleURL, encoding: .utf8)
    let redumped = try! PyJSON.dumps(JSONSerialization.jsonObject(with: Data(contentsOf: sampleURL))) + "\n"
    expect(redumped == sampleText, "PyJSON matches Python's output for the sample")
    if redumped != sampleText {
        for (a, b) in zip(redumped.split(separator: "\n"), sampleText.split(separator: "\n")) where a != b { print("  app: \(a)\n  py:  \(b)"); break }
    }
} else {
    print("(PARITY_DIR not set — parity checks skipped)")
}
if let path = ProcessInfo.processInfo.environment["PYJSON_RANDOM"] {
    // Random doubles written by Python: the app must print every one the same way.
    let text = try! String(contentsOfFile: path, encoding: .utf8)
    let again = try! PyJSON.dumps(JSONSerialization.jsonObject(with: Data(text.utf8))) + "\n"
    let mismatches = zip(again.split(separator: "\n"), text.split(separator: "\n")).filter { $0 != $1 }
    expect(again.count == text.count && mismatches.isEmpty, "random floats: \(mismatches.count) differ, e.g. \(mismatches.prefix(3))")
}

print(failures == 0 ? "ModelTests: all passed" : "ModelTests: \(failures) failed")
exit(failures == 0 ? 0 : 1)
