"""Regenerates parity_expected.json from parity.json using cli/recurring.

Both test suites check against the output: tests/test_cli.py (which also asserts
hand-worked values, so the CLI isn't its own only oracle) and tests/ModelTests.swift
(the app). Run after changing the fixture or the scheduling rules:
    python3 tests/fixtures/make_expected.py
"""
import importlib.machinery
import importlib.util
import json
from datetime import date
from pathlib import Path

HERE = Path(__file__).resolve().parent
TODAY = date(2026, 10, 8)


def load_cli():
    loader = importlib.machinery.SourceFileLoader("recurring_cli", str(HERE.parent.parent / "cli" / "recurring"))
    spec = importlib.util.spec_from_loader("recurring_cli", loader)
    m = importlib.util.module_from_spec(spec)
    loader.exec_module(m)
    return m


def expected(m) -> dict:
    services, issues = m.normalize(m.decode((HERE / "parity.json").read_text()))
    r2 = lambda v: None if v is None else m.r2(v)
    return {
        "today": TODAY.isoformat(),
        "services": [{"id": s["id"], "name": s["name"], "status": s["status"], "cadence": s["cadence"],
                      "amount": s["amount"],
                      "next_charge": (lambda d: d.isoformat() if d else None)(m.next_charge(s, TODAY)),
                      "monthly": r2(m.monthly_equivalent(s, TODAY)), "charges": len(s["charges"])}
                     for s in services],
        "monthly_total": round(m.monthly_total(services, TODAY), 2),
        "events_7d": [[d.isoformat(), k, s["id"]] for d, k, s in m.events(services, TODAY, 7)],
        "cash_flow": m.cash_flow(services, TODAY, 4, 11),
        "issues": issues,
        "renewals_30d": [[r["date"].isoformat(), r["service"]["id"], r["days_left"],
                          r["cancel_by"].isoformat() if r["cancel_by"] else None] for r in m.renewals(services, TODAY, 30)],
        "watch": [[w["service"]["id"], w["status"], w["would_charge"].isoformat() if w["would_charge"] else None,
                   r2(w["late_total"])] for w in m.watch(services, TODAY)],
        "savings_30d": (lambda sv: {"monthly": sv["monthly"], "kept": sv["kept"], "closing": sv["closing"],
                                    "items": [[i["service"]["id"], i["monthly"], i["kept"]] for i in sv["items"]]})(
            m.savings(services, TODAY, 30)),
        "cuts_by_month": [[k, v] for k, v in m.cuts_by_month(services, TODAY, 6)],
        "cut_groups": [[g["name"], g["auto"], [s["id"] for s in g["members"]], g["monthly"], g["save_min"], g["save_max"]]
                       for g in m.cut_groups(services, TODAY)],
        "refunds": {"pending": m.pending_refund_total(services),
                    "claims": [[s["id"], c["amount"], c["status"]] for s, c in m.refund_claims(services)]},
    }


if __name__ == "__main__":
    (HERE / "parity_expected.json").write_text(json.dumps(expected(load_cli()), indent=1) + "\n")
    print("wrote", HERE / "parity_expected.json")
