import json
import os
import stat
import subprocess
import sys
from pathlib import Path

import pytest

CLI = Path(__file__).resolve().parents[1] / "cli" / "recurring"


def run(tmp_path, *args, today="2026-10-07", check=True):
    env = {**os.environ, "RECURRING_FILE": str(tmp_path / "subs.json"), "RECURRING_TODAY": today}
    r = subprocess.run([sys.executable, str(CLI), *args], env=env, capture_output=True, text=True)
    if check and r.returncode != 0:
        raise AssertionError(r.stderr)
    return r


def ledger(tmp_path):
    return json.loads((tmp_path / "subs.json").read_text())


def test_add_list_total(tmp_path):
    run(tmp_path, "add", "Spotify", "--amount", "12.99", "--day", "14", "--category", "Life")
    run(tmp_path, "add", "Costco", "--amount", "65", "--cadence", "annual", "--month", "3", "--day", "1")
    run(tmp_path, "add", "Verizon Fios")  # unknown amount
    data = ledger(tmp_path)
    assert [s["id"] for s in data["services"]] == ["spotify", "costco", "verizon-fios"]
    assert data["services"][2]["amount_kind"] == "unknown"
    out = run(tmp_path, "total").stdout
    # 12.99 + 65/12 = 18.41; the unknown one is counted separately
    assert "$18.41/month" in out and "1 with no known amount" in out
    listing = run(tmp_path, "list").stdout
    assert "LIFE  $12.99/mo" in listing and "Spotify" in listing


def test_file_is_private_and_valid_json(tmp_path):
    run(tmp_path, "add", "X", "--amount", "1")
    mode = stat.S_IMODE((tmp_path / "subs.json").stat().st_mode)
    assert mode == 0o600


def test_duplicate_names_get_unique_ids(tmp_path):
    run(tmp_path, "add", "Vercel", "--amount", "20")
    run(tmp_path, "add", "Vercel", "--amount", "40")
    assert [s["id"] for s in ledger(tmp_path)["services"]] == ["vercel", "vercel-2"]


def test_cancel_and_reactivate(tmp_path):
    run(tmp_path, "add", "Spotify", "--amount", "12.99", "--day", "14")
    run(tmp_path, "cancel", "spotify")
    s = ledger(tmp_path)["services"][0]
    assert s["status"] == "cancelled" and s["cancelled_on"] == "2026-10-07"
    assert "$0.00/month" in run(tmp_path, "total").stdout
    bad = run(tmp_path, "reactivate", "spot", check=False)   # changes need the exact id
    assert bad.returncode != 0 and "did you mean: spotify" in bad.stderr
    run(tmp_path, "reactivate", "spotify")
    s = ledger(tmp_path)["services"][0]
    assert s["status"] == "active" and "cancelled_on" not in s


def test_set_types_and_clear(tmp_path):
    run(tmp_path, "add", "Asurion", "--day", "28")
    run(tmp_path, "set", "asurion", "amount=17.5", "amount_kind=approx", "billing_day=")
    s = ledger(tmp_path)["services"][0]
    assert s["amount"] == 17.5 and s["amount_kind"] == "approx" and "billing_day" not in s
    assert run(tmp_path, "set", "asurion", "bogus=1", check=False).returncode != 0
    assert run(tmp_path, "set", "asurion", "cadence=weekly", check=False).returncode != 0


@pytest.mark.parametrize("today,expected_first", [
    ("2026-10-07", "today"),       # billing day 7 → today
    ("2026-10-08", "Mon Nov 02"),  # day 2 already passed → next month
])
def test_upcoming_order(tmp_path, today, expected_first):
    run(tmp_path, "add", "A", "--amount", "1", "--day", "7")
    run(tmp_path, "add", "B", "--amount", "1", "--day", "2")
    out = run(tmp_path, "upcoming", "--days", "31", today=today).stdout.splitlines()
    assert out[0].startswith(expected_first)


def test_day_31_clamps_to_short_month(tmp_path):
    run(tmp_path, "add", "Kimi", "--amount", "199", "--day", "31")
    out = run(tmp_path, "upcoming", "--days", "3", today="2026-11-28").stdout
    assert out.startswith("Mon Nov 30")


def test_upcoming_window_excludes_far_dates(tmp_path):
    run(tmp_path, "add", "A", "--amount", "1", "--day", "20")
    assert "nothing scheduled" in run(tmp_path, "upcoming", "--days", "7").stdout


def test_bad_day_rejected(tmp_path):
    assert run(tmp_path, "add", "X", "--day", "32", check=False).returncode != 0


# ── v2: prepaid terms, 2-week cycles, unverified, charge history, report ──────

def test_term_is_amortized_and_expires(tmp_path):
    run(tmp_path, "add", "Coding plan", "--amount", "365.25", "--cadence", "term",
        "--start", "2026-09-21", "--end", "2027-09-21", "--category", "AI")
    out = run(tmp_path, "total").stdout
    # 365.25 over 365 days = 30.46/mo (same 30.436875-day month as Model.swift)
    assert out.startswith("$30.46/month"), out
    assert "prepaid ends" in run(tmp_path, "upcoming", "--days", "30", today="2027-09-01").stdout
    assert out_total(run(tmp_path, "total", today="2027-09-22").stdout) == 0.0


def out_total(text):
    return float(text.split("/month")[0].strip("$").replace(",", ""))


def test_term_needs_window(tmp_path):
    assert run(tmp_path, "add", "X", "--amount", "5", "--cadence", "term", check=False).returncode != 0


def test_biweekly(tmp_path):
    run(tmp_path, "add", "Gym", "--amount", "16.99", "--cadence", "biweekly")
    run(tmp_path, "set", "gym", "last_charged=2026-09-28")
    assert out_total(run(tmp_path, "total").stdout) == round(16.99 * 365.25 / 14 / 12, 2)
    lines = run(tmp_path, "upcoming", "--days", "30").stdout.splitlines()
    assert [l.split()[0:3] for l in lines] == [["Mon", "Oct", "12"], ["Mon", "Oct", "26"]]


def test_unverified_listed_not_counted(tmp_path):
    run(tmp_path, "add", "T-Mobile", "--amount", "80", "--day", "1", "--check", "last charge Jun 1")
    run(tmp_path, "set", "t-mobile", "status=unverified")
    assert "$0.00/month" in run(tmp_path, "total").stdout
    assert "1 unverified not counted" in run(tmp_path, "total").stdout
    assert "[unverified] t-mobile" in run(tmp_path, "needs").stdout
    assert run(tmp_path, "set", "t-mobile", "status=maybe", check=False).returncode != 0


def test_charge_records_history_and_updates_amount(tmp_path):
    run(tmp_path, "add", "Fly.io", "--cadence", "usage", "--day", "1")
    run(tmp_path, "charge", "fly-io", "88.38", "--date", "2026-09-01")
    run(tmp_path, "charge", "fly-io", "20.49", "--date", "2026-10-01")
    run(tmp_path, "charge", "fly-io", "-5.00", "--date", "2026-10-03", "--note", "refund")
    s = ledger(tmp_path)["services"][0]
    assert s["amount"] == 20.49 and s["last_charged"] == "2026-10-01" and s["amount_kind"] == "usage"
    assert [c["amount"] for c in s["charges"]] == [88.38, 20.49, -5.00]
    rep = run(tmp_path, "report", "--back", "1", "--ahead", "1").stdout
    assert "2026-09  charged $     88.38" in rep
    assert "2026-10  charged $     15.49" in rep        # 20.49 - 5.00 refund
    assert "2026-11  charged $      0.00   scheduled $     20.49" in rep


def test_cancel_with_ends_shows_wind_down(tmp_path):
    run(tmp_path, "add", "netcup", "--amount", "53.34", "--cadence", "other")
    run(tmp_path, "cancel", "netcup", "--ends", "2026-11-07")
    s = ledger(tmp_path)["services"][0]
    assert s["ends_on"] == "2026-11-07" and s["status"] == "cancelled"
    assert "service ends" in run(tmp_path, "upcoming", "--days", "40").stdout
    run(tmp_path, "reactivate", "netcup")
    assert "ends_on" not in ledger(tmp_path)["services"][0]


def test_annual_from_last_charge(tmp_path):
    run(tmp_path, "add", "Consensus", "--amount", "86.40", "--cadence", "annual")
    run(tmp_path, "set", "consensus", "last_charged=2026-09-09")
    assert out_total(run(tmp_path, "total").stdout) == 7.20
    assert run(tmp_path, "upcoming", "--days", "400").stdout.startswith("Thu Sep 09")


def test_closing_then_cancel(tmp_path):
    run(tmp_path, "add", "Gym", "--amount", "16.99", "--day", "12", "--check", "x")
    run(tmp_path, "closing", "gym", "--note", "notice sent")
    s = ledger(tmp_path)["services"][0]
    assert s["cancel_requested"] == "2026-10-07" and s["note"] == "notice sent"
    assert "$16.99/month" in run(tmp_path, "total").stdout          # still billing → still counted
    assert "[   closing] gym" in run(tmp_path, "needs").stdout
    assert "[     check] gym" not in run(tmp_path, "needs").stdout
    run(tmp_path, "cancel", "gym")
    s = ledger(tmp_path)["services"][0]
    assert s["status"] == "cancelled" and "cancel_requested" not in s
    assert run(tmp_path, "closing", "gym", check=False).returncode != 0


# ── adversarial-review fixes ──────────────────────────────────────────────────

import fcntl
import threading
import time

FIX = Path(__file__).resolve().parent / "fixtures"


def write_raw(tmp_path, obj):
    (tmp_path / "subs.json").write_text(json.dumps(obj))


def load_make_expected():
    import importlib.util
    spec = importlib.util.spec_from_file_location("make_expected", FIX / "make_expected.py")
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    return m


def test_parity_fixture_is_current_and_matches_hand_worked_values():
    """parity_expected.json (which ModelTests.swift checks the app against) must be
    what the CLI computes now — and the CLI must match values worked out by hand,
    so neither side is its own only oracle."""
    me = load_make_expected()
    got = me.expected(me.load_cli())
    assert got == json.loads((FIX / "parity_expected.json").read_text()), "run tests/fixtures/make_expected.py"
    by = {s["id"]: s for s in got["services"]}
    # today = 2026-10-08
    assert by["m31"]["next_charge"] == "2026-10-31" and by["m29"]["next_charge"] == "2026-10-29"
    assert by["bi"]["next_charge"] == "2026-10-12"                       # Sep 28 + 14 days
    assert by["bi"]["monthly"] == round(15.0 * 365.25 / 14 / 12, 2) == 32.61
    assert by["yr-anchor"]["next_charge"] == "2027-09-09" and by["yr-anchor"]["monthly"] == 7.5
    assert by["yr-month"]["next_charge"] == "2027-03-01"
    assert by["semi"]["next_charge"] == "2026-12-16"                     # Jun 16 + 6 months
    assert by["term1y"]["monthly"] == round(1200 / (365 / 30.436875), 2) == 100.07
    assert by["term2y"]["monthly"] == round(160 / (731 / 30.436875), 2) == 6.66
    assert by["usage"]["next_charge"] == "2026-10-08"                    # billing day 8 = today
    assert by["lastday"]["next_charge"] == "2026-11-01"                  # day taken from last_charged
    assert by["closing"]["next_charge"] == "2026-10-09" and by["closing"]["monthly"] == 25.0
    for gone in ("winding", "unver", "typo-cadence", "typo-status", "neg", "huge"):
        assert by[gone]["monthly"] is None, gone
    assert by["dupkey"]["name"] == "First name wins"                     # first duplicate key wins, like the app
    assert got["cash_flow"]["2026-10"]["charged"] == 33.5                # 18.50 − 5.00 refund + 20 charged after a cancel
    assert got["cash_flow"]["2026-09"]["charged"] == 1407.5              # 1200 + 75 + 50 + 8 + 12.50 + 20 + 12 + 30 (2e7 ignored)
    # insights
    assert got["watch"] == [["late", "charged_after_cancel", "2026-10-02", 20.0],   # charged Oct 2, 12 days after cancelling
                            ["watched", "watch", "2026-10-20", 0.0],                 # notice period to Oct 19, renews the 20th
                            ["gone", "clear", "2026-10-01", 0.0]]                    # would have charged Oct 1, nothing on file
    sv = got["savings_30d"]
    assert (sv["monthly"], sv["kept"], sv["closing"]) == (62.0, 12.0, 25.0)          # 30 + 20 + 12; Gone kept its Oct 1 $12
    assert got["cut_groups"] == [["AI chat", False, ["ai-1", "ai-2"], 120.0, 20.0, 100.0],
                                 ["Pipe category", True, ["pipe", "pipe-2"], 16.0, 8.0, 8.0]]
    assert got["refunds"]["pending"] == 82.5                                         # 75 requested + 7.50 open; the won $10 is done
    assert got["cuts_by_month"][-1] == ["2026-10", 30.0] and got["cuts_by_month"][0] == ["2026-05", 5.0]
    assert ["2026-10-09", "closing", 1, "2026-10-08"] in got["renewals_30d"]         # cancel by the day before


def test_unknown_fields_survive_cli_writes_and_backup(tmp_path):
    write_raw(tmp_path, {"version": 2, "top": "keep", "services": [
        {"id": "a", "name": "A", "amount": 1, "tags": ["keep"], "charges": [{"date": "2026-09-01", "amount": 1, "weird": True}]}]})
    run(tmp_path, "set", "a", "note=hi")
    d = ledger(tmp_path)
    assert d["top"] == "keep" and d["services"][0]["tags"] == ["keep"] and d["services"][0]["charges"][0]["weird"] is True
    assert (tmp_path / "subs.json.bak").exists()
    assert stat.S_IMODE((tmp_path / "subs.json.bak").stat().st_mode) == 0o600


def test_typos_are_flagged_not_counted(tmp_path):
    write_raw(tmp_path, {"version": 2, "services": [
        {"name": "Typo", "amount": 100, "cadence": "monthy", "billing_day": 1},
        {"name": "Canceled", "amount": 120, "status": "canceled"},
        {"name": "Str", "amount": "12.99"}]})
    assert "$0.00/month" in run(tmp_path, "total").stdout
    needs = run(tmp_path, "needs").stdout
    assert "cadence is not one of" in needs and "treated as unverified" in needs and "not a finite number" in needs


def test_malformed_values_do_not_crash(tmp_path):
    write_raw(tmp_path, {"version": 2, "services": [
        {"name": "A", "amount": 9, "charges": [{"date": 20261005, "amount": 1}, {"date": "2026-09-01"}, 7]},
        {"amount": 3}, "junk"]})
    for cmd in ("total", "list", "report", "upcoming", "needs"):
        assert run(tmp_path, cmd).returncode == 0


def test_broken_file_is_never_overwritten(tmp_path):
    (tmp_path / "subs.json").write_text("{ broken")
    r = run(tmp_path, "add", "X", "--amount", "1", check=False)
    assert r.returncode != 0 and "isn't valid JSON" in r.stderr
    assert (tmp_path / "subs.json").read_text() == "{ broken"


def test_nan_and_ranges_rejected(tmp_path):
    run(tmp_path, "add", "X", "--amount", "1", "--day", "1")
    for args in (("charge", "x", "nan"), ("charge", "x", "inf"), ("set", "x", "amount=nan"),
                 ("set", "x", "billing_month=13"), ("set", "x", "billing_day=0"), ("set", "x", "last_charged=20261005"),
                 ("add", "Y", "--month", "13"), ("add", "Z", "--amount", "inf")):
        assert run(tmp_path, *args, check=False).returncode != 0, args
    (tmp_path / "subs.json").write_text('{"version":2,"services":[{"name":"N","amount":NaN}]}')
    r = run(tmp_path, "total", check=False)
    assert r.returncode != 0 and "isn't valid JSON" in r.stderr


def test_duplicate_charge_refused_unless_forced(tmp_path):
    run(tmp_path, "add", "Fly", "--amount", "20.49", "--day", "1")
    run(tmp_path, "charge", "fly", "20.49", "--date", "2026-10-01")
    assert run(tmp_path, "charge", "fly", "20.49", "--date", "2026-10-01", check=False).returncode != 0
    run(tmp_path, "charge", "fly", "20.49", "--date", "2026-10-01", "--force")
    assert len(ledger(tmp_path)["services"][0]["charges"]) == 2


def test_bad_today_override(tmp_path):
    r = run(tmp_path, "total", today="10/07/2026", check=False)
    assert r.returncode != 0 and "RECURRING_TODAY must be YYYY-MM-DD" in r.stderr


def test_new_directory_is_private(tmp_path):
    env = {**os.environ, "RECURRING_FILE": str(tmp_path / "new" / "subs.json"), "RECURRING_TODAY": "2026-10-07"}
    subprocess.run([sys.executable, str(CLI), "add", "X", "--amount", "1"], env=env, check=True, capture_output=True)
    assert stat.S_IMODE((tmp_path / "new").stat().st_mode) == 0o700


def test_writes_wait_for_the_shared_lock(tmp_path):
    """While another writer (the app) holds .subs.json.lock, a CLI write blocks — no interleaving."""
    run(tmp_path, "add", "X", "--amount", "1")
    lock = os.open(tmp_path / ".subs.json.lock", os.O_CREAT | os.O_RDWR, 0o600)
    fcntl.flock(lock, fcntl.LOCK_EX)
    env = {**os.environ, "RECURRING_FILE": str(tmp_path / "subs.json"), "RECURRING_TODAY": "2026-10-07"}
    proc = subprocess.Popen([sys.executable, str(CLI), "add", "Y", "--amount", "2"], env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    time.sleep(1.0)
    assert proc.poll() is None, "CLI must wait for the lock"
    # simulate the app's write while it holds the lock
    d = ledger(tmp_path); d["services"][0]["note"] = "app wrote this"
    (tmp_path / "subs.json").write_text(json.dumps(d))
    fcntl.flock(lock, fcntl.LOCK_UN); os.close(lock)
    assert proc.wait(timeout=10) == 0
    names = {s["name"]: s for s in ledger(tmp_path)["services"]}
    assert names["X"].get("note") == "app wrote this" and "Y" in names   # neither write lost


def test_charge_refuses_malformed_charges_field(tmp_path):
    write_raw(tmp_path, {"version": 2, "services": [{"id": "a", "name": "A", "amount": 1, "charges": {"import": "keep this"}}]})
    before = (tmp_path / "subs.json").read_text()
    r = run(tmp_path, "charge", "a", "10", check=False)
    assert r.returncode != 0 and "not a list" in r.stderr and "Traceback" not in r.stderr
    assert (tmp_path / "subs.json").read_text() == before


def test_add_refuses_malformed_services_container(tmp_path):
    for bad in ({}, None, "x"):
        write_raw(tmp_path, {"version": 2, "services": bad})
        before = (tmp_path / "subs.json").read_text()
        r = run(tmp_path, "add", "X", "--amount", "1", check=False)
        assert r.returncode != 0 and "services is not a list" in r.stderr and "Traceback" not in r.stderr
        assert (tmp_path / "subs.json").read_text() == before


def test_reader_rules_match_the_app(tmp_path):
    big = "9" * 400
    for text in ('{"services":[{"name":"A","amount":%s}]}' % big, '{"services":[{"name":"A","amount":1e999}]}'):
        (tmp_path / "subs.json").write_text(text)
        r = run(tmp_path, "total", check=False)
        assert r.returncode != 0 and "isn't valid JSON" in r.stderr and "Traceback" not in r.stderr
    (tmp_path / "subs.json").write_bytes(b"\xef\xbb\xbf" + b'{"services":[{"name":"A","amount":5,"billing_day":1}]}')
    assert "$5.00/month" in run(tmp_path, "total").stdout                      # BOM accepted, like JSONSerialization
    (tmp_path / "subs.json").write_text('{"services":[{"name":"A","amount":5,"amount":500,"billing_day":1}]}')
    assert "$5.00/month" in run(tmp_path, "total").stdout                      # first duplicate key wins


def test_amount_limits(tmp_path):
    write_raw(tmp_path, {"version": 2, "services": [
        {"name": "Neg", "amount": -5, "billing_day": 1}, {"name": "Huge", "amount": 1e308, "billing_day": 1},
        {"name": "Ok", "amount": 7.5, "billing_day": 1}]})
    assert "$7.50/month" in run(tmp_path, "total").stdout
    needs = run(tmp_path, "needs").stdout
    assert "is negative" in needs and "out of range" in needs
    assert run(tmp_path, "charge", "ok", "20000000", check=False).returncode != 0


def test_month_end_charge_keeps_the_billing_day(tmp_path):
    write_raw(tmp_path, {"version": 2, "services": [{"id": "k", "name": "K", "amount": 199, "cadence": "monthly",
                                                     "last_charged": "2027-01-31"}]})
    run(tmp_path, "charge", "k", "199", "--date", "2027-02-28", today="2027-02-28")
    s = ledger(tmp_path)["services"][0]
    assert s["billing_day"] == 31 and s["last_charged"] == "2027-02-28"
    assert "Wed Mar 31" in run(tmp_path, "upcoming", "--days", "40", today="2027-03-01").stdout


def test_symlinked_ledger_shares_the_real_lock_and_backup_links_are_not_followed(tmp_path):
    real = tmp_path / "real"; real.mkdir()
    write_raw(real, {"version": 2, "services": [{"id": "a", "name": "A", "amount": 1}]})
    (real / "subs.json").rename(real / "subscriptions.json")
    victim = tmp_path / "victim.txt"; victim.write_text("do not touch")
    (real / "subscriptions.json.bak").symlink_to(victim)
    alias = tmp_path / "alias"; alias.mkdir()
    (alias / "subs.json").symlink_to(real / "subscriptions.json")
    run(alias, "set", "a", "note=x")
    assert victim.read_text() == "do not touch" and not (real / "subscriptions.json.bak").is_symlink()
    assert (real / ".subscriptions.json.lock").exists() and not (alias / ".subs.json.lock").exists()
    assert (alias / "subs.json").is_symlink()                                 # the link itself survives
    assert json.loads((real / "subscriptions.json").read_text())["services"][0]["note"] == "x"


def test_cli_output_format_is_what_the_app_writes(tmp_path):
    """Swift PyJSON.dumps is checked against pyjson_sample.json; this pins that the
    sample is exactly the CLI's format."""
    import importlib.machinery, importlib.util
    loader = importlib.machinery.SourceFileLoader("rec2", str(CLI))
    spec = importlib.util.spec_from_loader("rec2", loader); m = importlib.util.module_from_spec(spec); loader.exec_module(m)
    text = (FIX / "pyjson_sample.json").read_text()
    assert m.encode(m.decode(text)) == text


def test_refund_claims_cli(tmp_path):
    run(tmp_path, "add", "Store", "--amount", "39", "--day", "3")
    run(tmp_path, "refund", "store", "273", "--note", "billed after closing")
    assert "$273.00 pending" in run(tmp_path, "watch").stdout
    run(tmp_path, "refund", "store", "--status", "requested")
    assert "requested" in run(tmp_path, "watch").stdout
    run(tmp_path, "refund", "store", "--status", "won", today="2026-10-20")
    c = ledger(tmp_path)["services"][0]["refunds"][0]
    assert (c["status"], c["resolved"], c["amount"]) == ("won", "2026-10-20", 273.0)
    assert "$0.00 pending" in run(tmp_path, "watch").stdout
    assert run(tmp_path, "refund", "store", "--status", "won", check=False).returncode != 0   # nothing pending
    assert run(tmp_path, "refund", "store", "-5", check=False).returncode != 0


def test_insight_commands_run_on_real_shapes(tmp_path):
    write_raw(tmp_path, json.loads((FIX / "parity.json").read_text()))
    for cmd in (("renewals",), ("watch",), ("savings",), ("cut",), ("renewals", "--min", "50")):
        r = run(tmp_path, *cmd, today="2026-10-08")
        assert r.returncode == 0 and "Traceback" not in r.stderr, cmd
    assert "charged after cancel" in run(tmp_path, "watch", today="2026-10-08").stdout
    assert "AI chat" in run(tmp_path, "cut", today="2026-10-08").stdout
    run(tmp_path, "set", "ai-1", "group=")                                            # leaving the group dissolves it
    assert "AI chat" not in run(tmp_path, "cut", today="2026-10-08").stdout


# ── v3: Observatory Vault (Admin key / Org key) & Invoice Sync ───────────────

def run_v3(tmp_path, *args, stdin_text=None, check=True):
    env = {
        **os.environ,
        "RECURRING_FILE": str(tmp_path / "subs.json"),
        "RECURRING_VAULT_DIR": str(tmp_path / "vault"),
        "RECURRING_SYNC_DIR": str(tmp_path / "sync"),
        "RECURRING_TODAY": "2026-11-13",
    }
    r = subprocess.run(
        [sys.executable, str(CLI), *args],
        env=env,
        input=stdin_text,
        capture_output=True,
        text=True,
    )
    if check and r.returncode != 0:
        raise AssertionError(f"cmd={args}\nstdout={r.stdout}\nstderr={r.stderr}")
    return r


def test_vault_lifecycle_crypto_and_helix_tier_parity(tmp_path):
    pw = "observatory-test-passphrase-2026\n"
    run_v3(tmp_path, "vault", "init", "--passphrase-stdin", stdin_text=pw)

    vdir = tmp_path / "vault"
    assert stat.S_IMODE(vdir.stat().st_mode) == 0o700
    assert stat.S_IMODE((vdir / "master.key").stat().st_mode) == 0o600
    assert stat.S_IMODE((vdir / "vault.json").stat().st_mode) == 0o600

    # Non-Helix tier names are rejected
    bad_tier = run_v3(
        tmp_path, "vault", "add", "--provider", "anthropic", "--label", "bad",
        "--tier", "platform", "--secret-stdin", stdin_text=("sk-ant-" + "admin01-abcdef1234567890abcdef\n"), check=False
    )
    assert bad_tier.returncode != 0

    # Auto-detects Admin key vs Org key when --tier is omitted
    admin_secret = "sk-ant-" + "admin01-AdminSecretMaterial9876543210"
    org_secret = "sk-ant-" + "api03-OrgSecretMaterial1234567890abcd"
    a_out = json.loads(run_v3(
        tmp_path, "vault", "add", "--provider", "anthropic", "--label", "acme-admin",
        "--secret-stdin", "--json", stdin_text=admin_secret + "\n"
    ).stdout)
    o_out = json.loads(run_v3(
        tmp_path, "vault", "add", "--provider", "anthropic", "--label", "acme-org",
        "--secret-stdin", "--json", stdin_text=org_secret + "\n"
    ).stdout)
    assert a_out["tier"] == "admin" and a_out["tier_label"] == "Admin key"
    assert o_out["tier"] == "org" and o_out["tier_label"] == "Org key"

    # Listing never exposes ciphertext or plaintext secrets
    listed_raw = run_v3(tmp_path, "vault", "list", "--json").stdout
    assert admin_secret not in listed_raw and org_secret not in listed_raw
    assert "key_enc" not in listed_raw

    # Secret retrieval & rotation wipe old ciphertext
    got_sec = run_v3(tmp_path, "vault", "secret", o_out["id"]).stdout.strip()
    assert got_sec == org_secret

    rotated_secret = "sk-ant-" + "api03-RotatedSecretMaterial9999999999"
    rot_out = json.loads(run_v3(
        tmp_path, "vault", "rotate", o_out["id"], "--secret-stdin", "--json", stdin_text=rotated_secret + "\n"
    ).stdout)
    new_id = rot_out["id"]
    assert rot_out["rotated_from_id"] == o_out["id"]
    assert run_v3(tmp_path, "vault", "secret", o_out["id"], check=False).returncode != 0  # old ciphertext wiped
    assert run_v3(tmp_path, "vault", "secret", new_id).stdout.strip() == rotated_secret

    # Lock blocks secret access; wrong passphrase fails; AAD tamper fails
    run_v3(tmp_path, "vault", "lock")
    assert run_v3(tmp_path, "vault", "secret", new_id, check=False).returncode != 0
    assert run_v3(tmp_path, "vault", "unlock", "--passphrase-stdin", stdin_text="wrong-passphrase\n", check=False).returncode != 0
    run_v3(tmp_path, "vault", "unlock", "--passphrase-stdin", stdin_text=pw)
    assert run_v3(tmp_path, "vault", "secret", new_id).stdout.strip() == rotated_secret

    # Tamper with tier in vault.json -> AES-GCM AAD mismatch on decryption
    vfile = vdir / "vault.json"
    vdoc = json.loads(vfile.read_text())
    for k in vdoc["keys"]:
        if k["id"] == new_id:
            k["tier"] = "admin"
    vfile.write_text(json.dumps(vdoc))
    tampered = run_v3(tmp_path, "vault", "secret", new_id, check=False)
    assert tampered.returncode != 0


def test_vault_env_scan_persists_zero_plaintext(tmp_path):
    pw = "scan-passphrase-2026\n"
    run_v3(tmp_path, "vault", "init", "--passphrase-stdin", stdin_text=pw)
    vaulted_val = "sk-ant-" + "api03-VaultedKeyForScanCheck1234567890"
    stray_val = "sk-" + "proj-StrayPlaintextKeyNeverPersistMe987654321"
    run_v3(
        tmp_path, "vault", "add", "--provider", "anthropic", "--label", "scan-target",
        "--secret-stdin", stdin_text=vaulted_val + "\n"
    )

    proj = tmp_path / "sample_repo"
    proj.mkdir()
    (proj / ".env").write_text(f"ANTHROPIC_API_KEY={vaulted_val}\nOPENAI_API_KEY={stray_val}\n")

    scan_res = json.loads(run_v3(tmp_path, "vault", "scan", str(proj), "--json").stdout)
    assert scan_res["matched_keys"] == 1
    assert scan_res["stray_keys"] == 1

    raw_vault_disk = (tmp_path / "vault" / "vault.json").read_text()
    assert vaulted_val not in raw_vault_disk
    assert stray_val not in raw_vault_disk


def test_sync_collapses_receipt_and_card_alert_and_protects_term_amount(tmp_path):
    from datetime import date
    sys.path.insert(0, str(CLI.parent))
    import recurring_sync as rs

    write_raw(tmp_path, {
        "version": 2,
        "as_of": "2026-10-07",
        "services": [
            {"id": "resend", "name": "Resend", "category": "Dev", "amount": 20.0, "cadence": "monthly", "status": "active", "charges": []},
            {"id": "zai-glm", "name": "Z.ai GLM", "category": "AI", "amount": 1270.08, "cadence": "term",
             "term_start": "2026-09-01", "term_end": "2027-09-01", "status": "active", "charges": []},
        ],
    })
    os.environ["RECURRING_FILE"] = str(tmp_path / "subs.json")
    try:
        # 1. Sandbox receipt must be ignored
        sandbox_rows = rs.parse_billing_message(
            mailbox="alex@example.com",
            message_id="m_sbx",
            msg_date=date(2026, 11, 1),
            from_name="Resend",
            from_email="receipts@stripe.com",
            subject="[Sandbox] Your receipt from Resend #1111-2222",
            body_text="Amount paid $20.00",
        )
        assert sandbox_rows == []

        # 2. Real Stripe receipt + card alert on same charge collapse into 1 ledger charge
        r1 = rs.parse_billing_message(
            mailbox="alex@example.com",
            message_id="m_rec",
            msg_date=date(2026, 11, 1),
            from_name="Resend",
            from_email="receipts@stripe.com",
            subject="Your receipt from Resend #2207-2453",
            body_text="Receipt from Resend $20.00 Paid November 1, 2026",
        )
        r2 = rs.parse_billing_message(
            mailbox="alex@example.com",
            message_id="m_card",
            msg_date=date(2026, 11, 1),
            from_name="Capital One",
            from_email="capitalone@notification.capitalone.com",
            subject="A new purchase was made with corporate card",
            body_text="Merchant: RESEND Authorization Amount: $20.00 card ending in 4242",
        )
        # 3. Auxiliary receipt on a prepaid `term` service does not overwrite term amount
        r3 = rs.parse_billing_message(
            mailbox="alex@example.com",
            message_id="m_zai",
            msg_date=date(2026, 10, 29),
            from_name="Z.ai",
            from_email="billing@z.ai",
            subject="Your receipt from Z.ai #2252-7484",
            body_text="Amount paid $7.02",
        )
        res = rs.apply_ingested_rows_to_ledger(r1 + r2 + r3, ref_today=date(2026, 11, 13))
        assert len(res["added_charges"]) == 2
        updated = ledger(tmp_path)
        by_id = {s["id"]: s for s in updated["services"]}
        assert updated["as_of"] == "2026-11-13"
        assert len(by_id["resend"]["charges"]) == 1
        assert by_id["resend"]["card"] == "4242"
        assert by_id["zai-glm"]["amount"] == 1270.08
        assert len(by_id["zai-glm"]["charges"]) == 1
    finally:
        os.environ.pop("RECURRING_FILE", None)


def test_sync_spacex_x_subscription_apple_expiry_extend_html_and_exchange_forwards(tmp_path):
    from datetime import date
    sys.path.insert(0, str(CLI.parent))
    import recurring_sync as rs

    (tmp_path / "sync_config.json").write_text(
        json.dumps({"auto_forward_senders": ["alex@university.edu"]}),
        encoding="utf-8",
    )

    write_raw(tmp_path, {
        "version": 2,
        "as_of": "2026-10-07",
        "services": [
            {"id": "supergrok", "name": "Grok SuperGrok Plus", "category": "AI & LLM", "amount": 99.99,
             "cadence": "monthly", "billing_day": 17, "status": "active",
             "last_charged": "2026-10-17", "charges": [{"date": "2026-10-17", "amount": 99.99}]},
            {"id": "x-subscription", "name": "The X Subscription", "category": "AI & LLM", "amount": 100.0,
             "cadence": "monthly", "billing_day": 7, "status": "active", "charges": []},
            {"id": "autoglm", "name": "AutoGLM", "category": "AI & LLM", "amount": 20.0,
             "cadence": "monthly", "billing_day": 14, "status": "active",
             "last_charged": "2026-10-14", "charges": [{"date": "2026-10-14", "amount": 6.0}]},
            {"id": "zai-glm", "name": "Z.ai GLM", "category": "AI & LLM", "amount": 1270.08,
             "cadence": "term", "term_start": "2026-09-01", "term_end": "2027-09-01", "status": "active", "charges": []},
            {"id": "amazon-photos", "name": "Amazon Photos 100 GB", "category": "Consumer & personal",
             "amount": 1.99, "cadence": "monthly", "billing_day": 20, "status": "active", "charges": []},
            {"id": "termius", "name": "Termius Pro", "category": "Infra & dev tools",
             "amount": 15.0, "cadence": "monthly", "billing_day": 24, "status": "active", "charges": []},
            {"id": "claude-max-icloud", "name": "Claude Ultra", "category": "AI & LLM",
             "amount": 200.0, "cadence": "monthly", "billing_day": 19, "status": "cancelled",
             "cancelled_on": "2026-10-19", "account": "alex@icloud.example", "charges": []},
            {"id": "claude-max-edu", "name": "Claude Team (Research Labs)", "category": "AI & LLM",
             "amount": 120.0, "cadence": "monthly", "billing_day": 12, "status": "active",
             "account": "alex@university.edu", "last_charged": "2026-10-12", "charges": []},
            {"id": "spotify", "name": "Spotify Premium", "category": "Consumer & personal",
             "amount": 12.99, "cadence": "monthly", "billing_day": 14, "status": "active", "charges": []},
        ],
    })
    os.environ["RECURRING_FILE"] = str(tmp_path / "subs.json")
    try:
        rows = []
        # 1. SpaceX / xAI: Welcome to The X Subscription ($100 promo, renews Dec 7 at $200/mo)
        rows += rs.parse_billing_message(
            mailbox="alex@example.com",
            message_id="m_x_welcome",
            msg_date=date(2026, 11, 7),
            from_name="xAI",
            from_email="noreply@x.ai",
            subject="Welcome to The X Subscription",
            body_text=(
                "Invoice INV-2026-0109 Plan: Ultra Amount charged: $100.00 USD "
                "Your monthly X Subscription automatically renews on Dec 07, 2026 for 200.00 USD monthly "
                "unless you cancel by Dec 06, 2026. Visa ending in 4242"
            ),
        )
        # 2. SpaceX / xAI: Old SuperGrok canceled + $33.02 prorated refund
        rows += rs.parse_billing_message(
            mailbox="alex@example.com",
            message_id="m_x_old_cancel",
            msg_date=date(2026, 11, 7),
            from_name="xAI",
            from_email="noreply@x.ai",
            subject="Your old plan is canceled. Welcome to The X Subscription",
            body_text="SuperGrok Plus: canceled, and the unused part of your current period refunded: 33.02 USD.",
        )
        # 3. AutoGLM prorated upgrade (must go to autoglm, NOT zai-glm, and must NOT overwrite $20.00 Base amount)
        rows += rs.parse_billing_message(
            mailbox="alex@example.com",
            message_id="m_autoglm_upg",
            msg_date=date(2026, 10, 30),
            from_name="Z.ai",
            from_email="invoice+statements@z.ai",
            subject="Your receipt from Z.ai #2252-7484",
            body_text=(
                "Invoice INV-AGLM-0003 AutoGLM Remaining time on Base after 29 Oct 2026 $10.03 "
                "Unused time on Lite after 29 Oct 2026 -$3.01 Amount paid $7.02"
            ),
        )
        # 4. Apple bundled receipt on Oct 24 with explicit Renews Nov 20 + Nov 7 expiry notice on Amazon Photos
        rows += rs.parse_billing_message(
            mailbox="alex@icloud.example",
            message_id="m_apple_oct24",
            msg_date=date(2026, 10, 24),
            from_name="Apple",
            from_email="no_reply@email.apple.com",
            subject="Your receipt from Apple.",
            body_text=(
                "Amazon Photos: 100 GB Monthly Plan Renews November 20, 2026 $1.99\n"
                "Termius Pro Monthly (Monthly) Renews November 20, 2026 $15.00\n"
                "TOTAL $16.99"
            ),
        )
        rows += rs.parse_billing_message(
            mailbox="alex@icloud.example",
            message_id="m_apple_exp",
            msg_date=date(2026, 11, 7),
            from_name="Apple",
            from_email="no_reply@email.apple.com",
            subject="Your Subscription is Expiring",
            body_text="Amazon Photos 100 GB Monthly Plan (1 month) - $1.99/month expires on November 20.",
        )
        # 5. Claude iCloud reactivation on Nov 9 with explicit next charge Dec 9
        rows += rs.parse_billing_message(
            mailbox="alex@icloud.example",
            message_id="m_claude_ic_nov9",
            msg_date=date(2026, 11, 9),
            from_name="Anthropic, PBC",
            from_email="invoice+statements@mail.anthropic.com",
            subject="Your receipt from Anthropic, PBC #2704-5560-6078",
            body_text="Claude Ultra Amount paid $200.00 The next charge will be on Dec 9, 2026.",
        )
        # 6. Institutional Exchange FW: auto-forward unwrap (prorated seat addition + Nov 13 pause)
        rows += rs.parse_billing_message(
            mailbox="alex@example.com",
            message_id="m_edu_fw_seat",
            msg_date=date(2026, 11, 9),
            from_name="Rivera, Alex",
            from_email="alex@university.edu",
            subject="FW: Your receipt from Anthropic, PBC #2866-1624-6550",
            body_text=(
                "From: Anthropic, PBC <invoice+statements@mail.anthropic.com>\n"
                "Remaining time on Research Labs Premium after 09 Nov 2026 Amount paid $1.85"
            ),
        )
        rows += rs.parse_billing_message(
            mailbox="alex@example.com",
            message_id="m_edu_fw_pause",
            msg_date=date(2026, 11, 13),
            from_name="Rivera, Alex",
            from_email="alex@university.edu",
            subject="FW: Your subscription access has been paused",
            body_text="From: Anthropic <no-reply@mail.anthropic.com>\nYour subscription access has been paused.",
        )
        # 7. Extend HTML-in-plain + \u2060 word joiners + spaced decimal
        rows += rs.parse_billing_message(
            mailbox="alex@example.com",
            message_id="m_extend_html",
            msg_date=date(2026, 10, 15),
            from_name="Extend",
            from_email="support@paywithextend.com",
            subject="A purchase was made with virtual card",
            body_text="<html><body><div>Merchant\u2060 Name: Spotify P480DD2DBA</div><div>Authorization Amount: $12\u2060 .99</div></body></html>",
        )
        # 8. Stripe refund receipt listing original $99.99 before $33.02 refunded + Tello bidi-isolate receipt + Exchange FW prepaid extra usage
        rows += rs.parse_billing_message(
            mailbox="alex@example.com",
            message_id="m_xai_stripe_ref",
            msg_date=date(2026, 11, 7),
            from_name="Grok xAI",
            from_email="invoice+statements@stripe.com",
            subject="Your refund from Grok xAI #3008-3290",
            body_text="Refund from Grok xAI $33.02 Total $99.99 Amount paid $99.99 Total refunded without credit note $33.02",
        )
        tello_rows = rs.parse_billing_message(
            mailbox="alex@example.com",
            message_id="m_tello_bidi",
            msg_date=date(2026, 10, 31),
            from_name="Tello.com",
            from_email="customerservice@tello.com",
            subject="Thank you for your Tello order!",
            body_text="Order No. 121715812 Custom Plan \u2066$15\u2069 Next billing date: 11/29/2026 Taxes \u2066$1.11\u2069 Total:\n\u2066$16.11\u2069",
        )
        assert len(tello_rows) == 1 and tello_rows[0]["amount"] == 16.11 and tello_rows[0]["next_renewal"] == "2026-11-29"
        rows += rs.parse_billing_message(
            mailbox="alex@example.com",
            message_id="m_edu_fw_prepaid",
            msg_date=date(2026, 11, 10),
            from_name="Rivera, Alex",
            from_email="alex@university.edu",
            subject="FW: Your receipt from Anthropic, PBC #2668-2852-3570",
            body_text=("From: Anthropic, PBC <invoice+statements@mail.anthropic.com>\n" + ("x " * 180) + "\nPrepaid extra usage, Team plan Amount paid $20.00"),
        )

        rs.apply_ingested_rows_to_ledger(rows, ref_today=date(2026, 11, 13))
        by_id = {s["id"]: s for s in ledger(tmp_path)["services"]}

        assert by_id["supergrok"]["status"] == "cancelled"
        assert by_id["supergrok"]["cancelled_on"] == "2026-11-07"
        assert [c["amount"] for c in by_id["supergrok"]["charges"]] == [99.99, -33.02]

        assert by_id["x-subscription"]["amount"] == 200.0
        assert by_id["x-subscription"]["next_renewal"] == "2026-12-07"
        assert by_id["x-subscription"]["charges"][0]["amount"] == 100.0

        assert by_id["autoglm"]["amount"] == 20.0
        assert any(c["amount"] == 7.02 for c in by_id["autoglm"]["charges"])
        assert by_id["zai-glm"]["charges"] == []

        assert by_id["amazon-photos"]["status"] == "cancelled"
        assert by_id["amazon-photos"]["ends_on"] == "2026-11-20"
        assert by_id["termius"]["billing_day"] == 20
        assert by_id["termius"]["next_renewal"] == "2026-11-20"

        assert by_id["claude-max-icloud"]["status"] == "active"
        assert by_id["claude-max-icloud"]["billing_day"] == 9
        assert by_id["claude-max-icloud"]["next_renewal"] == "2026-12-09"

        assert by_id["claude-max-edu"]["amount"] == 120.0
        assert [c["amount"] for c in by_id["claude-max-edu"]["charges"]] == [1.85]
        assert "2026-11-13" in by_id["claude-max-edu"]["check"]

        assert len(by_id["spotify"]["charges"]) == 1 and by_id["spotify"]["charges"][0]["amount"] == 12.99
    finally:
        os.environ.pop("RECURRING_FILE", None)


def test_next_renewal_floor_in_cli(tmp_path):
    write_raw(tmp_path, {
        "version": 2,
        "services": [
            {"id": "siriusxm", "name": "SiriusXM", "category": "Consumer", "amount": 6.29,
             "cadence": "monthly", "billing_day": 13, "next_renewal": "2027-04-13", "status": "active"},
            {"id": "1password", "name": "1Password", "category": "Infra", "amount": 4.99,
             "cadence": "monthly", "billing_day": 18, "next_renewal": "2026-11-18", "status": "active"},
        ],
    })
    up7 = run(tmp_path, "upcoming", "--days", "7", today="2026-11-13").stdout
    assert "SiriusXM" not in up7
    assert "1Password" in up7
    up_apr = run(tmp_path, "upcoming", "--days", "7", today="2027-04-10").stdout
    assert "SiriusXM" in up_apr


def test_report_burn_breakdown_json_and_closing_clear(tmp_path):
    write_raw(tmp_path, {
        "version": 2,
        "services": [
            {"id": "claude", "name": "Claude Max 20x", "category": "AI", "amount": 200.0,
             "cadence": "monthly", "billing_day": 18, "status": "active",
             "account": "ops@acme.dev", "card": "4242"},
            {"id": "fly", "name": "Fly.io", "category": "Infra", "amount": 35.0, "amount_kind": "estimate",
             "cadence": "usage", "status": "active", "account": "ops@acme.dev"},
            {"id": "domain", "name": "acme.dev", "category": "Infra", "amount": 120.0,
             "cadence": "annual", "status": "active", "card": "9999"},
        ],
    })
    rep_txt = run(tmp_path, "report", today="2026-11-13").stdout
    assert "CADENCE MIX" in rep_txt
    assert "BY CARD" in rep_txt

    rep_json = json.loads(run(tmp_path, "report", "--json", today="2026-11-13").stdout)
    bd = rep_json["burn_breakdown"]
    assert bd["total_monthly"] == 245.0
    assert bd["fixed_monthly"] == 200.0
    assert bd["usage_monthly"] == 35.0
    assert bd["multi_month_monthly"] == 10.0
    assert bd["unmapped_card_count"] == 1
    assert bd["by_card"][0]["key"] == "4242"

    run(tmp_path, "closing", "claude", "--note", "switching tiers", today="2026-11-13")
    by_id = {s["id"]: s for s in ledger(tmp_path)["services"]}
    assert by_id["claude"]["cancel_requested"] == "2026-11-13"

    run(tmp_path, "closing", "claude", "--clear", today="2026-11-13")
    by_id = {s["id"]: s for s in ledger(tmp_path)["services"]}
    assert by_id["claude"].get("cancel_requested") is None


def _make_pdf(path: Path, pages_text: list[str]) -> None:
    import fitz

    doc = fitz.open()
    for txt in pages_text:
        p = doc.new_page(width=612, height=792)
        p.insert_text((64, 96), txt, fontsize=12, fontname="helv")
        # Pad metadata/text so every fixture exceeds the 1024-byte real-%PDF floor
        p.insert_text((64, 140), "Verified test receipt fixture · " + ("0123456789ABCDEF " * 45), fontsize=8, fontname="helv")
    raw = doc.tobytes()
    doc.close()
    assert len(raw) >= 1024 and raw[:4] == b"%PDF"
    path.write_bytes(raw)


def _make_png_approval(path: Path) -> None:
    # Valid PNG magic + >512 bytes payload
    payload = b"\x89PNG\r\n\x1a\n" + (b"\x00" * 700)
    path.write_bytes(payload)


def test_wm_cloud_reimburse_packet_engine_and_guardrails(tmp_path):
    import zipfile

    write_raw(tmp_path, {"version": 2, "services": []})

    reimb_root = tmp_path / "reimbursements"
    approvals_dir = reimb_root / "approvals"
    batches_dir = reimb_root / "batches"
    ext_batches = tmp_path / "prior_batches"
    src_folder = tmp_path / "fixture_pdfs"
    for d in (approvals_dir, batches_dir, ext_batches, src_folder):
        d.mkdir(parents=True, exist_ok=True)

    # Seed verified 1:1 approval artifacts (including xai alias)
    _make_png_approval(approvals_dir / "approval-anthropic.png")
    _make_png_approval(approvals_dir / "approval-xai-supergrok.png")
    _make_pdf(approvals_dir / "approval-openrouter.pdf", ["IT Approval #427103 — OpenRouter"])
    _make_pdf(approvals_dir / "approval-supabase.pdf", ["IT Approval #666104 — Supabase"])
    _make_png_approval(approvals_dir / "approval-openai.png")

    # Seed prior submissions ledger: one 'sent' batch (blocks reuse) + one 'draft' batch (must NOT block!)
    sent_bdir = ext_batches / "2026-10-18-reimbursement"
    sent_bdir.mkdir()
    (sent_bdir / "manifest.json").write_text(json.dumps([
        {"provider": "anthropic", "date": "2026-10-14", "amount": 200.0, "receipt_ref": "9999-8888-7777", "subject": "Receipt #9999-8888-7777"}
    ]))
    draft_bdir = ext_batches / "2026-11-01-draft"
    draft_bdir.mkdir()
    (draft_bdir / "manifest.json").write_text(json.dumps([
        {"provider": "openrouter", "date": "2026-11-05", "amount": 15.0, "receipt_ref": "2028-4179", "subject": "Receipt #2028-4179"}
    ]))
    sub_json = tmp_path / "submissions.json"
    sub_json.write_text(json.dumps({
        "submissions": [
            {"package_id": "2026-10-18-reimbursement", "status": "sent"},
            {"package_id": "2026-11-01-draft", "status": "draft"},
        ]
    }))

    cfg_path = tmp_path / "reimburse_config.json"
    cfg_path.write_text(json.dumps({
        "version": 1,
        "bundle_slug": "acme-reimbursements",
        "organization": "Acme Research Lab",
        "traveler": {
            "name": "Alex Rivera",
            "employee_id": "100200300",
            "funding_worktag": "GR004200 — CS Start-Up",
            "fund_number": "420100",
        },
        "approver": {"name": "Taylor Morgan", "email": "finance@example.edu"},
        "approvals_dir": str(approvals_dir),
        "portal_dir": str(reimb_root / "portal"),
        "store_dir": str(reimb_root / "store"),
        "batches_dir": str(batches_dir),
        "external_batches_dirs": [str(ext_batches)],
        "external_submissions_json": str(sub_json),
        "approval_aliases": {"xai": "approval-xai-supergrok"},
        "it_approvals": {
            "anthropic": {"status": "approved", "ticket": "290101"},
            "xai": {"status": "approved", "ticket": "439102"},
            "openrouter": {"status": "approved", "ticket": "427103"},
            "supabase": {"status": "approved", "ticket": "666104", "approved_on": "2026-10-21"},
            "openai": {"status": "approved", "ticket": "256105"},
            "github": {"status": "pending", "note": "Ticket in progress"},
        },
    }))

    # Create candidate PDFs in src_folder
    _make_pdf(src_folder / "anthropic_2026-11-02_200.00_2704-5560-6078.pdf", [
        "Receipt from Anthropic, PBC #2704-5560-6078\nAmount paid $200.00\nDate paid Nov 2, 2026"
    ])
    _make_pdf(src_folder / "anthropic_2026-11-08_45.00_2759-9805-0732.pdf", [
        "Receipt from Anthropic, PBC #2759-9805-0732\nAmount paid $45.00",
        "Itemized API usage page 2",
    ])
    _make_pdf(src_folder / "xai_2026-11-06_100.00_1290-1858.pdf", [
        "Receipt from xAI #1290-1858\nAmount paid $100.00"
    ])
    _make_pdf(src_folder / "openrouter_2026-11-05_15.00_2028-4179.pdf", [
        "Receipt from OpenRouter #2028-4179\nAmount paid $15.00"
    ])
    # Pre-approval date warning (2026-10-15 < approved_on 2026-10-21)
    _make_pdf(src_folder / "supabase_2026-10-15_37.35_NOOBEN-00003.pdf", [
        "Receipt from Supabase #NOOBEN-00003\nAmount paid $37.35"
    ])
    # Unpaid invoice ("Amount due" with no paid marker) -> must be rejected!
    _make_pdf(src_folder / "openai_2026-11-04_20.00_INV998877.pdf", [
        "Invoice #INV998877\nAmount due $20.00\nPay online before Dec 4, 2026"
    ])
    # Already submitted in 2026-10-18-reimbursement -> must be deduped!
    _make_pdf(src_folder / "anthropic_2026-10-14_200.00_9999-8888-7777.pdf", [
        "Receipt from Anthropic #9999-8888-7777\nAmount paid $200.00"
    ])
    # Unapproved provider (pending ticket, no approval file) -> routed to blocked_unapproved!
    _make_pdf(src_folder / "github_2026-11-03_10.00_GH112233.pdf", [
        "Receipt from GitHub #GH112233\nPayment amount $10.00\nBalance due $0.00"
    ])

    res = run(
        tmp_path,
        "wm-cloud",
        "--since", "2026-10-12",
        "--until", "2026-11-12",
        "--from-folder", str(src_folder),
        "--json",
    )
    pkt = json.loads(res.stdout)
    assert pkt["verification"]["passed"] is True
    assert pkt["total_usd"] == 397.35
    assert pkt["receipt_count"] == 5
    assert pkt["provider_count"] == 4
    assert pkt["verification"]["total_source_pages"] == 6
    assert pkt["verification"]["total_compiled_pages"] == 6

    # Check blocked_unapproved, excluded reasons, and pre-approval warning
    assert len(pkt["blocked_unapproved"]) == 1
    assert pkt["blocked_unapproved"][0]["provider"] == "github"
    reasons = {e["provider"]: e["reason"] for e in pkt["excluded"]}
    assert "unpaid_invoice_amount_due" in reasons["openai"]
    assert "already_submitted" in reasons["anthropic"]
    assert len(pkt["pre_approval_warnings"]) == 1
    assert pkt["pre_approval_warnings"][0]["provider"] == "supabase"

    # Check structured ZIP archive (1:1 receipts PDF + approval artifact per provider)
    zip_path = Path(pkt["zip_path"])
    assert zip_path.is_file()
    with zipfile.ZipFile(zip_path) as zf:
        names = set(zf.namelist())
    assert "acme-reimbursements/anthropic/receipts-anthropic-2026-10-12_2026-11-12.pdf" in names
    assert "acme-reimbursements/anthropic/approval-anthropic.png" in names
    assert "acme-reimbursements/xai/approval-xai-supergrok.png" in names

    # Check 0600 state snapshot & draft notice
    state_file = tmp_path / "reimburse_state.json"
    assert state_file.is_file()
    assert (state_file.stat().st_mode & 0o777) == 0o600
    assert "finance@example.edu" in pkt["draft_notice"]["to"]

    # Test --cover mode adds +1 page per provider and still passes gate
    res_cov = run(
        tmp_path,
        "reimburse", "build",
        "--since", "2026-10-12",
        "--until", "2026-11-12",
        "--from-folder", str(src_folder),
        "--cover",
        "--json",
    )
    pkt_cov = json.loads(res_cov.stdout)
    assert pkt_cov["verification"]["passed"] is True
    assert pkt_cov["verification"]["total_compiled_pages"] == 6 + 4  # 6 source + 4 cover pages

    # Tamper with manifest page count -> anti-hallucination gate MUST fail (exit 1)
    man_path = Path(pkt_cov["batch_dir"]) / "manifest.json"
    man_rows = json.loads(man_path.read_text())
    man_rows[0]["pages"] = 99
    man_path.write_text(json.dumps(man_rows))
    bad = run(tmp_path, "reimburse", "verify", pkt_cov["batch_dir"], check=False)
    assert bad.returncode == 1
    assert "FAIL" in bad.stdout


def test_reimburse_security_sanitizer_and_ssrf():
    sys.path.insert(0, str(CLI.parent))
    import recurring_reimburse as rr

    dirty = (
        '<html><head><base href="file:///etc/"></head><body>'
        '<script>fetch("http://169.254.169.254")</script>'
        '<iframe src="file:///etc/passwd"></iframe>'
        '<a href="javascript:alert(1)">Pay</a>'
        '<img src="file:///Users/secret.png">'
        '<p>Amount paid $42.00</p></body></html>'
    )
    clean = rr.sanitize_receipt_html(dirty)
    assert "<script" not in clean.lower()
    assert "<iframe" not in clean.lower()
    assert "<base" not in clean.lower()
    assert "file://" not in clean.lower()
    assert "javascript:" not in clean.lower()
    assert "Content-Security-Policy" in clean
    assert "Amount paid $42.00" in clean

    for bad_host in ("localhost", "router.local", "metadata.internal", "127.0.0.1"):
        try:
            rr._resolve_public_ips(bad_host)
            assert False, f"Should have rejected {bad_host}"
        except ValueError:
            pass




