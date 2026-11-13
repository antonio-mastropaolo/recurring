#!/usr/bin/env python3
"""recurring_sync — Hourly + real-time push invoice ingestion daemon & CLI for Recurring.

Supports multi-mailbox ingestion configured via `~/.recurring/sync_config.json` (or
auto-discovered from `~/.mail-mcp/tokens.json`):
  1. Gmail REST API + 20s `historyId` push delta + hourly sweep
  2. iCloud / standard IMAP over TLS + RFC 2177 `IMAP IDLE` instant push + hourly sweep
  3. Headless Exchange / OWA bridge (or auto-forwarded Exchange messages via Gmail)

All state files (`sync_state.json`, `seen_messages.json`, `sync_config.json`) are stored
with `0600` permissions and `O_NOFOLLOW` inside `~/.recurring` (or `Path(RECURRING_FILE).parent`).
Ledger updates acquire `.subscriptions.json.lock` and preserve Recurring's exact JSON format.
"""
from __future__ import annotations

import argparse
import base64
import calendar
import contextlib
import datetime as dt
import email
import email.header
import email.message
import email.utils
import fcntl
import html
import imaplib
import io
import json
import math
import os
import re
import select
import signal
import ssl
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from collections import defaultdict
from datetime import date, timedelta
from pathlib import Path
from typing import Any

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

# ── Paths & Secure Atomic I/O ────────────────────────────────────────────────

MAIL_MCP_TOKENS_PATH = Path.home() / ".mail-mcp" / "tokens.json"

BASE_GMAIL_SENDERS = (
    "stripe.com OR anthropic.com OR openai.com OR email.apple.com OR "
    "apple.com OR paypal.com OR vercel.com OR supabase.com OR fly.io OR "
    "cursor.sh OR cursor.com OR anysphere.inc OR x.ai OR grok.com OR z.ai OR "
    "cloudflare.com OR github.com OR huggingface.co OR tello.com OR "
    "siriusxm.com OR spotify.com OR google.com OR wellsfargo.com OR "
    "capitalone.com OR paywithextend.com OR privacy.com OR geico.com OR "
    "planetfitness.com OR myiclubonline.com OR grammarly.com OR contabo.com OR "
    "ovhcloud.com OR hinge.co OR roku.com OR jetty.com OR resident-link.com OR "
    "verizonwireless.com OR sezzle.com"
)


def build_gmail_billing_query(extra_senders: list[str] | None = None) -> str:
    senders = BASE_GMAIL_SENDERS
    if extra_senders:
        clean = [s.strip() for s in extra_senders if s and re.fullmatch(r"[A-Za-z0-9._@+-]+", s.strip())]
        if clean:
            senders = f"{senders} OR {' OR '.join(clean)}"
    return (
        "("
        'subject:("receipt" OR "invoice" OR "payment" OR "purchase was made" OR '
        '"subscription" OR "renewal" OR "billing" OR "charged" OR "refund" OR '
        '"statement" OR "automatic payment" OR "order confirmation" OR '
        '"Thank you for your Tello order" OR "Welcome to The X Subscription" OR '
        '"Subscription is Expiring" OR "changed its plan" OR "has been paused" OR '
        '"is suspended" OR "Card declined" OR "Insufficient funds notice" OR '
        '"scheduled auto policy payment") '
        f"OR from:({senders})"
        ") -in:chats -in:drafts"
    )


def _now_utc() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0)


def _iso_now() -> str:
    return _now_utc().isoformat().replace("+00:00", "Z")


def ledger_path() -> Path:
    p = os.environ.get("RECURRING_FILE")
    if p:
        return Path(p).expanduser().resolve()
    return (Path.home() / ".recurring" / "subscriptions.json").resolve()


def state_dir() -> Path:
    override = os.environ.get("RECURRING_SYNC_DIR")
    if override:
        return Path(override).expanduser().resolve()
    return ledger_path().parent


def sync_config_path() -> Path:
    return state_dir() / "sync_config.json"


def sync_state_path() -> Path:
    return state_dir() / "sync_state.json"


def seen_messages_path() -> Path:
    return state_dir() / "seen_messages.json"


def trigger_file_path() -> Path:
    return state_dir() / ".sync_trigger"


def _ensure_private_dir(d: Path) -> None:
    if not d.exists():
        d.mkdir(parents=True, mode=0o700)


def _write_securely(data: bytes, target: Path) -> None:
    _ensure_private_dir(target.parent)
    tmp = target.parent / f".{target.name}.{os.getpid()}.{uuid.uuid4().hex[:8]}.tmp"
    fd = os.open(tmp, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            try:
                fcntl.fcntl(f.fileno(), fcntl.F_FULLFSYNC)
            except (AttributeError, OSError):
                os.fsync(f.fileno())
        os.replace(tmp, target)
    except BaseException:
        if tmp.exists():
            with contextlib.suppress(OSError):
                tmp.unlink()
        raise
    dfd = os.open(target.parent, os.O_RDONLY)
    try:
        os.fsync(dfd)
    finally:
        os.close(dfd)


def _read_json_safe(path: Path, default: Any) -> Any:
    if not path.exists():
        return default
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd, "rb") as f:
            return json.loads(f.read().decode("utf-8"))
    except Exception:
        return default


@contextlib.contextmanager
def ledger_locked():
    path = ledger_path()
    _ensure_private_dir(path.parent)
    fd = os.open(path.parent / f".{path.name}.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def encode_ledger(raw: dict[str, Any]) -> bytes:
    return (json.dumps(raw, indent=2, sort_keys=True, allow_nan=False) + "\n").encode("utf-8")


# ── Sync Config & Generic Vendor Rules ───────────────────────────────────────

def _R(rx: str, mbox: str | None = None, amounts: set[float] | None = None,
       src: set[str] | None = None, dom: set[int] | None = None, dates: list[str] | None = None) -> dict[str, Any]:
    return {"rx": rx, "mbox": mbox, "amounts": amounts, "src": src, "dom": dom, "dates": dates}


RECEIPTISH = {"receipt", "invoice", "payment_confirmation", "refund", "other", "failed_payment", "renewal_notice", "cancellation"}

DEFAULT_RULES: dict[str, list[dict[str, Any]]] = {
    "_anthropic": [_R(r"anthropic|claude")],
    "google-ai-ultra": [_R(r"ai ultra|g1ai|google one")],
    "supergrok": [
        _R(r"supergrok|your old plan is canceled"),
        _R(r"grok|x\.ai|xai", amounts={99.0, 99.99, 33.02}),
    ],
    "x-subscription": [
        _R(r"the x subscription|x\.com/settings/subscription"),
        _R(r"\bx\.ai\b|\bxai\b|\bgrok\b", amounts={100.0, 200.0}),
    ],
    "_xai-other": [
        _R(r"grok|x\.ai|xai|spacexai", src={"other", "failed_payment", "renewal_notice", "cancellation", "refund"}),
    ],
    "muse-code": [_R(r"muse code|metapay.*muse")],
    "ollama-pro": [_R(r"ollama")],
    "huggingface": [_R(r"hugging ?face")],
    "autoglm": [_R(r"autoglm|remaining time on base|unused time on lite")],
    "zai-glm": [_R(r"jingsheng|z\.ai|zhipu|bigmodel|glm coding")],
    "consensus": [_R(r"consensus")],
    "freepik": [_R(r"freepik|magnific")],
    "chatgpt-pro": [
        _R(r"openai.*chatgpt subscr|chatgpt subscr", amounts={40.0, 200.0}),
        _R(r"openai", amounts={200.0}, src={"failed_payment"}),
        _R(r"chatgpt pro"),
    ],
    "chatgpt-plus": [_R(r"chatgpt", amounts={19.99, 20.0, 21.20}), _R(r"chatgpt", src={"bank_alert"})],
    "_openai-other": [_R(r"openai|chatgpt")],
    "gamma": [_R(r"\bgamma\b")],
    "kimi": [_R(r"moonshot|kimi|novascent")],
    "cursor-usage": [_R(r"cursor usage")],
    "cursor": [_R(r"cursor|anysphere")],
    "1password": [_R(r"1password")],
    "_vercel-other": [_R(r"vercel")],
    "supabase": [_R(r"\bsupabase\b")],
    "flyio": [_R(r"fly\.io|fly io|flyio")],
    "google-voice": [_R(r"google workspace|voice starter|google voice")],
    "gcp": [_R(r"google ?\*?cloud|cloud platform|google payments.*cloud")],
    "github": [_R(r"github")],
    "slack": [_R(r"\bslack\b")],
    "hunter": [_R(r"hunter")],
    "resend": [_R(r"resend")],
    "improvmx": [_R(r"improvmx")],
    "_shopify-other": [_R(r"shopify")],
    "contabo": [_R(r"contabo")],
    "ovh": [_R(r"\bovh\b|ovhcloud")],
    "termius": [_R(r"termius")],
    "burner": [_R(r"burner")],
    "apple-developer": [_R(r"developer program")],
    "netcup": [_R(r"netcup")],
    "hetzner": [_R(r"hetzner")],
    "godaddy": [_R(r"godaddy")],
    "cloudflare-plan": [_R(r"cloudflare", amounts={5.0})],
    "_cloudflare": [_R(r"cloudflare")],
    "nopecha": [_R(r"nopecha")],
    "proxy-cheap": [_R(r"proxy-?cheap")],
    "decodo-res-10gb": [_R(r"decodo|data troops", amounts={35.0}), _R(r"residential 10 ?gb")],
    "decodo-25gb": [_R(r"decodo|data troops", amounts={81.25, 56.87}), _R(r"decodo.*25 ?gb|25 ?gb.*decodo|residential 25 ?gb")],
    "decodo-10gb": [_R(r"decodo|data troops", amounts={27.5}), _R(r"decodo.*10 ?gb|10 ?gb.*decodo")],
    "decodo-2gb": [_R(r"decodo|data troops", amounts={7.5}), _R(r"decodo.*\b2 ?gb|\b2 ?gb.*decodo")],
    "_decodo-other": [_R(r"decodo|data troops")],
    "nikeshoebot": [_R(r"nike ?shoe ?bot|nikeshoebot")],
    "geico": [_R(r"geico")],
    "medvidi": [_R(r"medvidi")],
    "planet-fitness-annual": [_R(r"planet fitness|excelfitness", amounts={49.0})],
    "planet-fitness": [_R(r"planet fitness|excelfitness|myiclubonline")],
    "golds-gym-annual": [_R(r"gold'?s gym|golds gym", amounts={49.99, 69.99})],
    "golds-gym": [_R(r"gold'?s gym|golds gym")],
    "renters-insurance": [_R(r"renters|assurant|agi\*")],
    "jetty-deposit": [_R(r"jetty insurance|jetty deposit")],
    "resident-link": [_R(r"resident-?link")],
    "nordvpn": [_R(r"nord")],
    "tello": [_R(r"\btello\b")],
    "verizon-wireless": [_R(r"vzwrlss|verizon wireless")],
    "amazon-prime": [_R(r"amazon prime pmts|prime membership", amounts={14.99})],
    "amazon-prime-25": [_R(r"amazon prime", amounts={5.61, 5.69, 5.83})],
    "amazon-digital-19": [_R(r"amazon digital", amounts={11.99})],
    "asurion": [_R(r"asurion"), _R(r"amazon digital", amounts={17.5, 17.59})],
    "_amazon-digital-other": [_R(r"amazon digital")],
    "spotify": [_R(r"spotify")],
    "paramount-plus": [_R(r"cbs interactive|paramount\+")],
    "goodrx": [_R(r"goodrx gold")],
    "dashpass": [_R(r"dashpass")],
    "one-medical": [_R(r"onemed|one medical")],
    "siriusxm": [_R(r"sirius|sxm\*")],
    "uber-one": [_R(r"uber one|uberone", amounts={3.99})],
    "icloud-plus": [_R(r"icloud\+")],
    "amazon-photos": [_R(r"amazon photos|100 gb monthly plan.*1\.99")],
    "hingex": [_R(r"hingex|hinge.*subscription")],
    "iscanner": [_R(r"iscanner")],
    "tmobile": [_R(r"t-?mobile")],
    "netflix": [_R(r"netflix")],
    "sezzle-anywhere": [_R(r"sezzle\W*anywhere")],
    "ifood": [_R(r"ifood|ifd\*")],
    "education-app": [_R(r"education monthly")],
    "verizon-fios": [_R(r"verizon|fios")],
    "ring": [_R(r"\bring\b(?!central)", amounts={10.59, 7.77})],
    "homeaglow": [_R(r"homeaglow", amounts={59.0})],
    "overleaf": [_R(r"overleaf|digital science")],
    "grammarly-pro": [_R(r"grammarly")],
    "copilot-money": [_R(r"copilot money|copilot: track")],
    "acm": [_R(r"acm online renewal|renewal_receipt@acm|acm membership")],
    "ieee": [_R(r"ieee membership|ieee.*(renew|dues)")],
    "upwork": [_R(r"upwork", amounts={19.99})],
    "_upwork-other": [_R(r"upwork")],
    "costco": [_R(r"costco.*member|member.*costco")],
    "flagstop": [_R(r"flagstop")],
    "privacy-com-pro": [_R(r"team privacy|privacy pro")],
    "figma": [_R(r"figma")],
    "perplexity": [_R(r"perplexity")],
    "poshmark-weekly": [_R(r"poshmark", amounts={10.0, 9.69})],
    "_poshmark-other": [_R(r"poshmark")],
    "rentamac": [_R(r"rent a mac")],
    "kckd": [_R(r"kckd")],
}

IGNORE_PATTERNS = [
    r"prepaid extra usage", r"one-time credit purchase", r"auto recharge extra usage",
    r"\$500 usd in api credits", r"perplexity credits",
    r"sezzle.*installment|installment \d+ of \d+",
    r"rose purchase", r"superboost",
    r"openrouter", r"twilio", r"iproyal", r"donut", r"flamingo", r"bird ?prox",
    r"bright ?data", r"sonetel", r"abliteration", r"runpod",
    r"doordash(?!dashpass| dashpass|.*dashpass)", r"homeaglow (tip|txn|caras|prem)",
    r"circle medical", r"klarna", r"affirm", r"sezzle\*?balance", r"credit one",
    r"paypal pay ?monthly", r"capital one autopay",
    r"amazon mktplace pmts", r"amazon retail", r"\bwawa\b", r"\btarget t-\d+",
    r"sezzle.*united airlines", r"united airlines",
    r"\buber\s+\*trip|\buber\s+\*eats",
]

STRENGTH = {
    "receipt": 4, "invoice": 3, "apple_receipt": 4, "payment_confirmation": 4,
    "paypal": 3, "card_alert": 3, "bank_alert": 3, "google_play": 4, "refund": 4,
    "failed_payment": 0, "renewal_notice": 0, "cancellation": 0, "other": 0,
}


def load_sync_config() -> dict[str, Any]:
    raw = _read_json_safe(sync_config_path(), {})
    return raw if isinstance(raw, dict) else {}


def get_active_rules() -> dict[str, list[dict[str, Any]]]:
    cfg = load_sync_config()
    custom_raw = cfg.get("custom_rules")
    merged: dict[str, list[dict[str, Any]]] = {}
    if isinstance(custom_raw, dict):
        for sid, rlist in custom_raw.items():
            if not isinstance(rlist, list):
                continue
            parsed_list: list[dict[str, Any]] = []
            for item in rlist:
                if not isinstance(item, dict) or not item.get("rx"):
                    continue
                parsed_list.append({
                    "rx": str(item["rx"]),
                    "mbox": item.get("mbox"),
                    "amounts": {round(float(x), 2) for x in item["amounts"]} if item.get("amounts") is not None else None,
                    "src": set(item["src"]) if item.get("src") is not None else None,
                    "dom": {int(x) for x in item["dom"]} if item.get("dom") is not None else None,
                    "dates": list(item["dates"]) if item.get("dates") else None,
                })
            if parsed_list:
                merged[str(sid)] = parsed_list
    for sid, rlist in DEFAULT_RULES.items():
        if sid not in merged:
            merged[sid] = rlist
    return merged


# ── Credential Loading (`~/.mail-mcp/tokens.json` + `.env`) ──────────────────

def _load_mail_mcp_env() -> dict[str, str]:
    out: dict[str, str] = {}
    cfg = load_sync_config()
    env_path_str = os.environ.get("RECURRING_MAIL_ENV") or cfg.get("mail_mcp_env_path")
    candidates = [Path(env_path_str).expanduser()] if env_path_str else [
        Path.home() / ".mail-mcp" / ".env",
        state_dir() / "mail.env",
    ]
    for ep in candidates:
        if ep.exists():
            for raw_line in ep.read_text(encoding="utf-8", errors="replace").splitlines():
                line = raw_line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                val = v.strip()
                if len(val) >= 2 and val[0] == val[-1] and val[0] in ("'", '"'):
                    val = val[1:-1]
                out[k.strip()] = val
            break
    for k in ("MAIL_MCP_TOKEN_KEY", "MAIL_MCP_GOOGLE_CLIENT_ID", "MAIL_MCP_GOOGLE_CLIENT_SECRET"):
        if os.environ.get(k):
            out[k] = os.environ[k]
    return out


def _load_decrypted_mail_tokens() -> tuple[dict[str, dict[str, Any]], dict[str, str]]:
    env = _load_mail_mcp_env()
    raw_key = env.get("MAIL_MCP_TOKEN_KEY", "")
    if not raw_key or not MAIL_MCP_TOKENS_PATH.exists():
        return {}, env
    key = bytes.fromhex(raw_key) if re.fullmatch(r"[0-9a-fA-F]{64}", raw_key) else base64.b64decode(raw_key)
    blob = json.loads(MAIL_MCP_TOKENS_PATH.read_text(encoding="utf-8"))
    pt = AESGCM(key).decrypt(
        base64.b64decode(blob["iv"]),
        base64.b64decode(blob["ciphertext"]) + base64.b64decode(blob["tag"]),
        None,
    )
    store = json.loads(pt.decode("utf-8"))
    accts = store.get("accounts", store)
    return {k: v for k, v in accts.items() if isinstance(v, dict)}, env


def get_expected_mailboxes(accts: dict[str, dict[str, Any]] | None = None) -> list[dict[str, Any]]:
    cfg = load_sync_config()
    raw_list = cfg.get("mailboxes")
    if isinstance(raw_list, list) and raw_list:
        out: list[dict[str, Any]] = []
        for item in raw_list:
            if isinstance(item, dict) and item.get("email") and item.get("provider"):
                em = str(item["email"])
                prov = str(item["provider"])
                out.append({
                    "key": str(item.get("key") or f"{prov}:{em}"),
                    "email": em,
                    "provider": prov,
                    "forward_via": str(item["forward_via"]) if item.get("forward_via") else None,
                })
        if out:
            return out
    if accts is None:
        accts, _ = _load_decrypted_mail_tokens()
    discovered: list[dict[str, Any]] = []
    for key in sorted(accts.keys()):
        if ":" in key:
            prov, em = key.split(":", 1)
            if prov in ("gmail", "icloud") and "@" in em:
                discovered.append({"key": key, "email": em, "provider": prov, "forward_via": None})
    return discovered


# ── Email Body / HTML / PDF Extraction & Structured Charge Parsing ───────────

TAG_STRIP_RE = re.compile(r"<(script|style)[^>]*>.*?</\1>", re.IGNORECASE | re.DOTALL)
BLOCK_TAG_RE = re.compile(r"</?(?:p|div|tr|td|th|li|br|h[1-6]|table|section)[^>]*>", re.IGNORECASE)
ANY_TAG_RE = re.compile(r"<[^>]+>")
WS_RE = re.compile(r"[ \t\r\f\v\u00a0\u2007\u202f]+")
ZERO_WIDTH_RE = re.compile(r"[\u200b-\u200f\u202a-\u202e\u2060\u2066-\u2069\ufeff\u034f\u00ad]")
SPACED_USD_DEC_RE = re.compile(r"\$\s*([0-9]{1,6}(?:,[0-9]{3})*)\s*\.\s*([0-9]{2})\b")
LOOKS_HTML_RE = re.compile(r"<(?:!doctype|html|body|table|tr|td|div|p|span|br)\b", re.I)

MONTH_MAP = {
    "jan": 1, "january": 1, "feb": 2, "february": 2, "mar": 3, "march": 3,
    "apr": 4, "april": 4, "may": 5, "jun": 6, "june": 6, "jul": 7, "july": 7,
    "aug": 8, "august": 8, "sep": 9, "sept": 9, "september": 9, "oct": 10, "october": 10,
    "nov": 11, "november": 11, "dec": 12, "december": 12,
}


def clean_email_text(raw: str) -> str:
    if not raw:
        return ""
    txt = raw
    if LOOKS_HTML_RE.search(txt):
        txt = html_to_text(txt)
    else:
        txt = html.unescape(txt)
    txt = ZERO_WIDTH_RE.sub("", txt)
    txt = SPACED_USD_DEC_RE.sub(r"$\1.\2", txt)
    lines = [WS_RE.sub(" ", ln).strip() for ln in txt.splitlines()]
    return "\n".join(ln for ln in lines if ln)


def html_to_text(raw_html: str) -> str:
    if not raw_html:
        return ""
    cleaned = TAG_STRIP_RE.sub(" ", raw_html)
    cleaned = BLOCK_TAG_RE.sub("\n", cleaned)
    cleaned = ANY_TAG_RE.sub(" ", cleaned)
    cleaned = html.unescape(cleaned)
    cleaned = ZERO_WIDTH_RE.sub("", cleaned)
    cleaned = SPACED_USD_DEC_RE.sub(r"$\1.\2", cleaned)
    lines = [WS_RE.sub(" ", ln).strip() for ln in cleaned.splitlines()]
    return "\n".join(ln for ln in lines if ln)


def _parse_flexible_date(raw_date: str, ref_date: date) -> date | None:
    s = (raw_date or "").strip().rstrip(".,;")
    if not s:
        return None
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}", s):
        with contextlib.suppress(ValueError):
            return date.fromisoformat(s)
    m_slash = re.fullmatch(r"(\d{1,2})/(\d{1,2})/(\d{2,4})", s)
    if m_slash:
        mo, dy, yr = int(m_slash.group(1)), int(m_slash.group(2)), int(m_slash.group(3))
        if yr < 100:
            yr += 2000
        with contextlib.suppress(ValueError):
            return date(yr, mo, dy)
    m_named = re.fullmatch(r"([A-Za-z]+)\.?\s+(\d{1,2})(?:,\s*(\d{4}))?", s)
    if m_named:
        mo = MONTH_MAP.get(m_named.group(1).lower())
        dy = int(m_named.group(2))
        yr = int(m_named.group(3)) if m_named.group(3) else ref_date.year
        if mo:
            with contextlib.suppress(ValueError):
                cand = date(yr, mo, dy)
                if not m_named.group(3) and cand < (ref_date - timedelta(days=30)):
                    cand = date(yr + 1, mo, dy)
                return cand
    return None


def extract_pdf_text(pdf_bytes: bytes) -> str:
    if not pdf_bytes:
        return ""
    try:
        from pypdf import PdfReader
        reader = PdfReader(io.BytesIO(pdf_bytes))
        chunks = []
        for page in reader.pages[:4]:
            chunks.append(page.extract_text() or "")
        return "\n".join(chunks)
    except Exception:
        return ""


REFUND_AMOUNT_PATTERNS = [
    re.compile(r"Total refunded[^\n$]{0,40}\$\s*([0-9]{1,6}(?:,[0-9]{3})*\.[0-9]{2})", re.I),
    re.compile(r"Amount refunded\s*:?\s*\$\s*([0-9]{1,6}(?:,[0-9]{3})*\.[0-9]{2})", re.I),
    re.compile(r"Refund from [^\n$]{1,60}\$\s*([0-9]{1,6}(?:,[0-9]{3})*\.[0-9]{2})", re.I),
    re.compile(r"refunded:\s*\$?([0-9]{1,6}(?:,[0-9]{3})*\.[0-9]{2})", re.I),
]

AMOUNT_ANCHORED_PATTERNS = [
    re.compile(r"Authorization Amount:\s*\$\s*([0-9]{1,6}(?:,[0-9]{3})*\.[0-9]{2})", re.I),
    re.compile(r"Amount paid\s*\$\s*([0-9]{1,6}(?:,[0-9]{3})*\.[0-9]{2})", re.I),
    re.compile(r"Amount charged\s*:?\s*\$\s*([0-9]{1,6}(?:,[0-9]{3})*\.[0-9]{2})", re.I),
    re.compile(r"Total paid\s*:?\s*\$\s*([0-9]{1,6}(?:,[0-9]{3})*\.[0-9]{2})", re.I),
    re.compile(r"Receipt from [^\n$]{1,60}\$\s*([0-9]{1,6}(?:,[0-9]{3})*\.[0-9]{2})\s+Paid", re.I),
    re.compile(r"Transaction [Aa]mount\s*:?\s*\$\s*([0-9]{1,6}(?:,[0-9]{3})*\.[0-9]{2})", re.I),
    re.compile(r"You sent a payment of\s*\$\s*([0-9]{1,6}(?:,[0-9]{3})*\.[0-9]{2})\s*USD", re.I),
    re.compile(r"submitted an order in the amount of\s*\$\s*([0-9]{1,6}(?:,[0-9]{3})*\.[0-9]{2})\s*USD", re.I),
    re.compile(r"\bTOTAL\s+\$\s*([0-9]{1,6}(?:,[0-9]{3})*\.[0-9]{2})", re.I),
    re.compile(r"\bTotal\s*:?\s*\$\s*([0-9]{1,6}(?:,[0-9]{3})*\.[0-9]{2})", re.I),
    re.compile(r"charged\s+\$\s*([0-9]{1,6}(?:,[0-9]{3})*\.[0-9]{2})", re.I),
    re.compile(r"payment of\s+\$\s*([0-9]{1,6}(?:,[0-9]{3})*\.[0-9]{2})", re.I),
]

ANY_USD_RE = re.compile(r"(?:USD\s*\$?|\$)\s*([0-9]{1,5}(?:,[0-9]{3})*\.[0-9]{2})")
CARD_ALERT_MERCHANT_RE = re.compile(
    r"Merchant(?: Name)?:\s*([^\n\r]+?)(?:\s+Authorization Amount:|\s+Amount:|\s+Date:|$)",
    re.I,
)
STRIPE_SUBJECT_RE = re.compile(r"Your receipt from\s+(.+?)(?:\s+#([A-Z0-9-]{4,}))?$", re.I)
PAYPAL_MERCHANT_RE = re.compile(r"(?:Payment to|paid|Automatic payment:?)\s+([A-Za-z0-9 .,&'*-]{2,50})", re.I)
CARD_LAST4_RE = re.compile(r"(?:ending in|Visa|Mastercard|Amex|Discover|method\s*-)\s*(\d{4})\b", re.I)
REF_RE = re.compile(r"#([A-Z0-9]{4,}(?:-[A-Z0-9]{4,})+)")


def _parse_amount(text: str, *, is_refund: bool = False) -> float | None:
    patterns = (REFUND_AMOUNT_PATTERNS + AMOUNT_ANCHORED_PATTERNS) if is_refund else AMOUNT_ANCHORED_PATTERNS
    for rx in patterns:
        m = rx.search(text)
        if m:
            val = float(m.group(1).replace(",", ""))
            if 0 < val <= 50000:
                return round(val, 2)
    # Fallback: first non-zero USD figure in body/subject
    for m in ANY_USD_RE.finditer(text):
        val = float(m.group(1).replace(",", ""))
        if 0 < val <= 50000:
            return round(val, 2)
    return None


def _extract_next_renewal_and_recurring_amount(text: str, ref_date: date) -> tuple[date | None, float | None]:
    # 1. SpaceX / The X Subscription: "automatically renews on Dec 07, 2026 for 200.00 USD monthly"
    m_x = re.search(
        r"automatically renews on\s+([A-Za-z]+\.?\s+\d{1,2},\s*\d{4})\s+for\s+\$?([0-9]{1,5}(?:,[0-9]{3})*\.[0-9]{2})\s*(?:USD)?",
        text,
        re.I,
    )
    if m_x:
        return _parse_flexible_date(m_x.group(1), ref_date), round(float(m_x.group(2).replace(",", "")), 2)

    # 2. Grammarly / annual reminders: "renew for another 12 months on December 17, 2026 for $144.00"
    m_gr = re.search(
        r"renew[^\n.]{0,40}?\bon\s+([A-Za-z]+\.?\s+\d{1,2},\s*\d{4})\s+for\s+\$([0-9]{1,5}(?:,[0-9]{3})*\.[0-9]{2})",
        text,
        re.I,
    )
    if m_gr:
        return _parse_flexible_date(m_gr.group(1), ref_date), round(float(m_gr.group(2).replace(",", "")), 2)

    # 3. GEICO scheduled auto-pay: "Payment Date: 12/06/2026 ... Scheduled Payment: $172.51"
    m_geico = re.search(
        r"Payment Date:\s*(\d{1,2}/\d{1,2}/\d{4}).{0,120}?Scheduled Payment:\s*\$([0-9]{1,5}(?:,[0-9]{3})*\.[0-9]{2})",
        text,
        re.I | re.S,
    )
    if m_geico:
        return _parse_flexible_date(m_geico.group(1), ref_date), round(float(m_geico.group(2).replace(",", "")), 2)

    # 4. Anthropic / Tello / Meta: "The next charge will be on Dec 9, 2026", "Next billing date: 11/29/2026", "Next payment: Dec 10, 2026"
    for rx in (
        r"next charge will be on\s+([A-Za-z]+\.?\s+\d{1,2},\s*\d{4}|\d{1,2}/\d{1,2}/\d{4})",
        r"Next billing date:\s*([A-Za-z]+\.?\s+\d{1,2},\s*\d{4}|\d{1,2}/\d{1,2}/\d{4})",
        r"Next payment:\s*([A-Za-z]+\.?\s+\d{1,2},\s*\d{4}|\d{1,2}/\d{1,2}/\d{4})",
    ):
        m = re.search(rx, text, re.I)
        if m:
            d = _parse_flexible_date(m.group(1), ref_date)
            if d:
                return d, None
    return None, None


def parse_billing_message(
    *,
    mailbox: str,
    message_id: str,
    msg_date: date,
    from_name: str,
    from_email: str,
    subject: str,
    body_text: str,
    pdf_text: str = "",
    auto_forward_senders: set[str] | None = None,
) -> list[dict[str, Any]]:
    """Extracts 0 or more normalized billing event rows from a single email."""
    subj = clean_email_text(subject or "").replace("\n", " ").strip()
    body_clean = clean_email_text(body_text or "")
    pdf_clean = clean_email_text(pdf_text or "")

    cfg = load_sync_config()
    fwd_senders = auto_forward_senders
    if fwd_senders is None:
        raw_fwd = cfg.get("auto_forward_senders") or []
        fwd_senders = {str(x).strip().lower() for x in raw_fwd if x}

    # Unwrap Exchange / institutional auto-forwards (`from: <configured>`, subject `FW: ...`)
    eff_mailbox = mailbox
    eff_from_name = from_name
    eff_from_email = from_email
    sender_low = (from_email or "").strip().lower()
    if sender_low and sender_low in fwd_senders and re.match(r"^(?:fw|fwd):\s*", subj, re.I):
        eff_mailbox = sender_low
        subj = re.sub(r"^(?:fw|fwd):\s*", "", subj, count=1, flags=re.I).strip()
        m_inner_from = re.search(r"From:\s*([^\n<]{1,80}?)\s*<([^>\s]+@[^>\s]+)>", body_clean)
        if m_inner_from:
            eff_from_name = m_inner_from.group(1).strip().strip('"')
            eff_from_email = m_inner_from.group(2).strip()

    if "[sandbox]" in subj.lower() or "[test]" in subj.lower():
        return []

    combined = "\n".join(x for x in (subj, body_clean, pdf_clean) if x).strip()
    low = combined.lower()
    from_low = f"{eff_from_name} <{eff_from_email}>".lower()

    # Special handling: Wells Fargo Insufficient funds notice lists actual PAID recurring ACH/debit items
    if "insufficient funds notice" in subj.lower() and "wellsfargo" in from_low:
        wf_card = str(cfg.get("default_wf_card") or "").strip() or None
        wf_items = re.findall(
            r"RECURRING PAYMENT AUTHORIZED ON\s+(\d{1,2}/\d{1,2})\s+([A-Z0-9 *&.'/-]{2,40}?)\s+\$([0-9]{1,5}(?:,[0-9]{3})*\.[0-9]{2})\s+PAID",
            combined,
            re.I,
        )
        out_wf: list[dict[str, Any]] = []
        for idx, (mmdd, merch, amt_s) in enumerate(wf_items):
            d_tx = _parse_flexible_date(f"{mmdd}/{msg_date.year}", msg_date) or msg_date
            merch_s = merch.strip()
            out_wf.append({
                "mailbox": eff_mailbox,
                "message_id": f"{message_id}#wf{idx}" if len(wf_items) > 1 else message_id,
                "source": "bank_alert",
                "status": "paid",
                "date": d_tx.isoformat(),
                "_date": d_tx,
                "merchant": merch_s,
                "amount": round(float(amt_s.replace(",", "")), 2),
                "card": wf_card,
                "ref": None,
                "items": f"WF recurring payment {merch_s}",
                "subject": subj[:160],
                "_text": f"{merch_s} {subj}".lower(),
            })
        return out_wf

    # Special handling: SpaceX / xAI old plan cancellation + prorated refund in one email
    if re.search(r"your old plan is canceled", subj, re.I):
        rows_old: list[dict[str, Any]] = []
        m_ref_amt = re.search(r"refunded:\s*\$?([0-9]{1,5}(?:,[0-9]{3})*\.[0-9]{2})\s*USD", combined, re.I)
        if m_ref_amt:
            rows_old.append({
                "mailbox": eff_mailbox,
                "message_id": f"{message_id}#refund",
                "source": "refund",
                "status": "refunded",
                "date": msg_date.isoformat(),
                "_date": msg_date,
                "merchant": eff_from_name or "xAI",
                "amount": -round(float(m_ref_amt.group(1).replace(",", "")), 2),
                "card": None,
                "ref": None,
                "items": subj[:140],
                "subject": subj[:160],
                "_text": f"supergrok {subj} {body_clean[:240]}".lower(),
            })
        rows_old.append({
            "mailbox": eff_mailbox,
            "message_id": f"{message_id}#cancel",
            "source": "cancellation",
            "status": "cancelled",
            "date": msg_date.isoformat(),
            "_date": msg_date,
            "merchant": eff_from_name or "xAI",
            "amount": None,
            "card": None,
            "ref": None,
            "ends_on": None,
            "items": subj[:140],
            "subject": subj[:160],
            "_text": f"supergrok {subj} {body_clean[:240]}".lower(),
        })
        return rows_old

    # Apple "Your Subscription is Expiring" cancellation notice
    if re.search(r"^your subscription is expiring", subj, re.I) and "apple.com" in from_low:
        m_exp = re.search(r"expires on\s+([A-Za-z]+\.?\s+\d{1,2}(?:,\s*\d{4})?)", combined, re.I)
        ends_d = _parse_flexible_date(m_exp.group(1), msg_date) if m_exp else None
        amt_exp = _parse_amount(combined)
        return [{
            "mailbox": eff_mailbox,
            "message_id": message_id,
            "source": "cancellation",
            "status": "cancelled",
            "date": msg_date.isoformat(),
            "_date": msg_date,
            "merchant": "Apple (App Store / iTunes)",
            "amount": amt_exp,
            "card": "Apple",
            "ref": None,
            "ends_on": ends_d.isoformat() if ends_d else None,
            "items": body_clean[:140],
            "subject": subj[:160],
            "_text": f"apple {subj} {body_clean[:300]}".lower(),
        }]

    # Direct merchant cancellation / plan deactivation emails
    if (
        re.search(r"subscription was canceled|subscription has been canceled", subj, re.I)
        or ("has changed its plan" in subj.lower() and "changed from basic to inactive" in low)
    ):
        return [{
            "mailbox": eff_mailbox,
            "message_id": message_id,
            "source": "cancellation",
            "status": "cancelled",
            "date": msg_date.isoformat(),
            "_date": msg_date,
            "merchant": (eff_from_name or subj)[:80],
            "amount": None,
            "card": None,
            "ref": None,
            "ends_on": None,
            "items": body_clean[:140],
            "subject": subj[:160],
            "_text": f"{eff_from_name} {subj} {body_clean[:280]}".lower(),
        }]

    # Determine source & status
    status = "paid"
    source = "other"

    if re.search(
        r"payment failed|couldn'?t process your payment|unable to charge|card (?:was )?declined|"
        r"past due|unsuccessful payment|payment .{1,40} was unsuccessful|"
        r"subscription access has been paused|\bis suspended\b|update your payment method to keep",
        low,
    ):
        source = "failed_payment"
        status = "failed"
    elif re.search(r"purchase was made with|transaction alert|card ending in .* was charged|authorization amount:", low):
        source = "card_alert" if "purchase was made with" in low else "bank_alert"
        status = "authorized"
    elif "email.apple.com" in from_low or re.search(r"^your (?:receipt|purchases) from apple", subj, re.I):
        source = "apple_receipt"
    elif "paypal.com" in from_low:
        source = "paypal"
    elif "google play" in low and ("order receipt" in low or "googleplay" in from_low):
        source = "google_play"
    elif re.search(r"\brefund(?:ed)?\b|\bcredit note\b", subj.lower()) and not re.search(r"refund policy|non-refundable", low):
        source = "refund"
        status = "refunded"
    elif re.search(
        r"^your receipt from\b|receipt for your payment|payment receipt|amount paid\s*\$|"
        r"amount charged\s*:?\s*\$|^welcome to the x subscription\b|^thank you for your tello order",
        low,
    ):
        source = "receipt"
    elif re.search(r"payment confirmation|thank you for your payment|payment received", low):
        source = "payment_confirmation"
    elif re.search(r"\binvoice\b", subj.lower()):
        if re.search(r"amount paid\s*\$|\$[1-9]|\bpaid on\b|\bstatus:\s*paid\b", low):
            source = "invoice"
        else:
            source = "invoice"
            status = "invoice_only"
    elif re.search(
        r"will renew|upcoming renewal|renews on|subscription renewal reminder|"
        r"scheduled auto policy payment|subscription is confirmed",
        low,
    ):
        source = "renewal_notice"
        status = "scheduled"
    else:
        return []

    # Apple bundled receipts can contain multiple distinct app subscriptions + explicit Renews date
    if source == "apple_receipt":
        apple_items = re.findall(
            r"([A-Za-z0-9][^\n$]{2,90}?)\s+(?:Renews\s+([A-Za-z]+\s+\d{1,2},\s+\d{4})\s+)?\$\s*([0-9]{1,4}\.[0-9]{2})",
            body_clean or combined,
        )
        filtered = [
            (desc.strip(), ren_str.strip(), float(amt))
            for desc, ren_str, amt in apple_items
            if not re.search(r"\b(?:subtotal|total|tax|billing|credit|apple account)\b", desc, re.I)
        ]
        if filtered:
            rows = []
            for idx, (desc, ren_str, amt) in enumerate(filtered):
                ren_d = _parse_flexible_date(ren_str, msg_date) if ren_str else None
                rows.append({
                    "mailbox": eff_mailbox,
                    "message_id": f"{message_id}#{idx}" if len(filtered) > 1 else message_id,
                    "source": "apple_receipt",
                    "status": "paid",
                    "date": msg_date.isoformat(),
                    "_date": msg_date,
                    "merchant": "Apple (App Store / iTunes)",
                    "amount": round(amt, 2),
                    "card": None,
                    "ref": None,
                    "next_renewal": ren_d.isoformat() if ren_d else None,
                    "recurring_amount": None,
                    "is_proration": False,
                    "items": desc[:140],
                    "subject": subj[:160],
                    "_text": f"apple {subj} {desc}".lower(),
                })
            return rows

    amt = _parse_amount(combined, is_refund=(source == "refund"))
    if amt is None and source not in ("failed_payment", "renewal_notice"):
        return []
    if source == "refund" and amt is not None:
        amt = -abs(amt)

    next_ren_d, rec_amt = _extract_next_renewal_and_recurring_amount(combined, msg_date)
    is_proration = bool(re.search(r"remaining time on|unused time on|prorated", low))

    # Extract merchant
    merchant = (eff_from_name or "").strip()
    m_card = CARD_ALERT_MERCHANT_RE.search(combined)
    m_stripe = STRIPE_SUBJECT_RE.search(subj)
    m_pp = PAYPAL_MERCHANT_RE.search(subj) or PAYPAL_MERCHANT_RE.search(combined[:500])
    if m_card:
        merchant = m_card.group(1).strip()
    elif m_stripe:
        merchant = m_stripe.group(1).strip()
    elif source == "paypal" and m_pp:
        merchant = m_pp.group(1).strip()
    elif not merchant or merchant.lower() in ("stripe", "billing", "no-reply", "noreply", "receipts"):
        merchant = subj[:64]

    ref = None
    if m_stripe and m_stripe.group(2):
        ref = m_stripe.group(2)
    else:
        m_ref = REF_RE.search(subj) or REF_RE.search(combined[:800])
        if m_ref:
            ref = m_ref.group(1)

    m_last4 = CARD_LAST4_RE.search(combined)
    card = m_last4.group(1) if m_last4 else None

    snippet = " ".join((body_clean or pdf_clean)[:360].split())
    wide_body = " ".join((body_clean or pdf_clean)[:1600].split())
    text_blob = f"{merchant} {subj} {snippet}".lower()

    return [{
        "mailbox": eff_mailbox,
        "message_id": message_id,
        "source": source,
        "status": status,
        "date": msg_date.isoformat(),
        "_date": msg_date,
        "merchant": merchant[:80],
        "amount": amt,
        "card": card,
        "ref": ref,
        "next_renewal": next_ren_d.isoformat() if next_ren_d else None,
        "recurring_amount": rec_amt,
        "is_proration": is_proration,
        "items": snippet[:140],
        "subject": subj[:160],
        "_text": text_blob,
        "_wide_text": f"{merchant} {subj} {wide_body}".lower(),
    }]


def match_row_to_service_id(row: dict[str, Any], services_by_id: dict[str, dict[str, Any]]) -> str | None:
    text = row["_text"]
    ignore_hay = row.get("_wide_text") or text
    if any(re.search(rx, ignore_hay) for rx in IGNORE_PATTERNS):
        return "_ignored"

    hits: list[str] = []
    for iid, rule_list in get_active_rules().items():
        for ru in rule_list:
            if ru["mbox"] and ru["mbox"] not in (row.get("mailbox") or ""):
                continue
            if ru["src"] and row.get("source") not in ru["src"]:
                continue
            if ru["amounts"] is not None:
                if row.get("amount") is None or round(abs(row["amount"]), 2) not in ru["amounts"]:
                    continue
            if ru.get("dates"):
                if not row["_date"] or not any(
                    abs((row["_date"] - date.fromisoformat(x)).days) <= 1 for x in ru["dates"]
                ):
                    continue
            if ru["dom"]:
                if not row["_date"] or not any(abs(row["_date"].day - x) <= 1 for x in ru["dom"]):
                    continue
            if re.search(ru["rx"], text):
                hits.append(iid)
                break

    # Prefer concrete ledger service IDs over `_collector` buckets
    concrete = [h for h in hits if not h.startswith("_") and h in services_by_id]
    if concrete:
        return concrete[0]
    if hits:
        bucket = hits[0]
        if bucket == "_vercel-other" and "vercel-personal" in services_by_id:
            return "vercel-personal"
        if bucket == "_tello-other" and "tello" in services_by_id:
            return "tello"
        # Account-aware disambiguation for generic vendor buckets (e.g., `_anthropic`, `_openai-other`)
        vendor_kw = {
            "_anthropic": ("claude", "anthropic"),
            "_openai-other": ("chatgpt", "openai"),
            "_vercel-other": ("vercel",),
            "_cloudflare": ("cloudflare",),
            "_shopify-other": ("shopify",),
        }.get(bucket)
        if vendor_kw:
            mbox_low = (row.get("mailbox") or "").lower()
            acct_matches = [
                sid for sid, svc in services_by_id.items()
                if any(k in f"{sid} {svc.get('name', '')}".lower() for k in vendor_kw)
                and svc.get("account")
                and str(svc["account"]).lower() == mbox_low
            ]
            if len(acct_matches) == 1:
                return acct_matches[0]
            active_acct = [sid for sid in acct_matches if services_by_id[sid].get("status") == "active"]
            if len(active_acct) == 1:
                return active_acct[0]
        return bucket

    # Dynamic fallback for newly added services in `subscriptions.json`!
    best_id: str | None = None
    best_score = 0
    for sid, svc in services_by_id.items():
        name_clean = re.sub(r"\([^)]*\)", "", str(svc.get("name") or "")).strip().lower()
        if len(name_clean) < 4:
            continue
        if name_clean in text:
            score = 10 + (5 if svc.get("status") == "active" else 0)
            sacct = str(svc.get("account") or "").lower()
            if sacct and sacct in (row.get("mailbox") or "").lower():
                score += 20
            samt = svc.get("amount")
            if isinstance(samt, (int, float)) and row.get("amount") is not None and abs(samt - abs(row["amount"])) < 0.01:
                score += 15
            if score > best_score:
                best_score = score
                best_id = sid
    return best_id


# ── Gmail Direct REST Provider (Fast + History Push Delta) ───────────────────

class GmailProvider:
    def __init__(self, email_addr: str, refresh_token: str, client_id: str, client_secret: str):
        self.email = email_addr
        self.refresh_token = refresh_token
        self.client_id = client_id
        self.client_secret = client_secret
        self._access_token: str | None = None
        self._expires_at: float = 0.0

    def _token(self) -> str:
        now = time.time()
        if self._access_token and now < self._expires_at - 60:
            return self._access_token
        data = urllib.parse.urlencode({
            "client_id": self.client_id,
            "client_secret": self.client_secret,
            "refresh_token": self.refresh_token,
            "grant_type": "refresh_token",
        }).encode("utf-8")
        req = urllib.request.Request(
            "https://oauth2.googleapis.com/token",
            data=data,
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=12) as resp:
            tok = json.loads(resp.read().decode("utf-8"))
        self._access_token = tok["access_token"]
        self._expires_at = now + float(tok.get("expires_in", 3500))
        return self._access_token

    def _get_json(self, path: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        qs = ("?" + urllib.parse.urlencode(params, doseq=True)) if params else ""
        url = f"https://gmail.googleapis.com/gmail/v1/users/me/{path}{qs}"
        waits = (2.0, 6.0, 15.0, 30.0, 40.0)
        for attempt in range(len(waits) + 1):
            req = urllib.request.Request(
                url,
                headers={
                    "Authorization": f"Bearer {self._token()}",
                    "User-Agent": "Recurring-Sync/3.0",
                },
                method="GET",
            )
            try:
                with urllib.request.urlopen(req, timeout=15) as resp:
                    return json.loads(resp.read().decode("utf-8"))
            except urllib.error.HTTPError as e:
                body = ""
                with contextlib.suppress(Exception):
                    body = (e.read() or b"").decode("utf-8", errors="replace")
                if e.code in (403, 429, 500, 502, 503) and attempt < len(waits):
                    if e.code != 403 or "ratelimit" in body.lower() or "quota" in body.lower():
                        time.sleep(waits[attempt])
                        continue
                raise RuntimeError(f"HTTP {e.code} on {path}: {body[:160]}") from e
        raise RuntimeError(f"Retries exhausted on {path}")

    def current_history_id(self) -> str:
        prof = self._get_json("profile")
        return str(prof.get("historyId") or "")

    def changed_message_ids_since(self, start_history_id: str) -> tuple[list[str], str]:
        if not start_history_id:
            return [], self.current_history_id()
        msg_ids: list[str] = []
        seen: set[str] = set()
        page_token: str | None = None
        latest_hid = start_history_id
        try:
            while True:
                params: dict[str, Any] = {
                    "startHistoryId": start_history_id,
                    "historyTypes": "messageAdded",
                    "maxResults": 100,
                }
                if page_token:
                    params["pageToken"] = page_token
                res = self._get_json("history", params)
                if res.get("historyId"):
                    latest_hid = str(res["historyId"])
                for h in res.get("history") or []:
                    for added in h.get("messagesAdded") or []:
                        mid = str((added.get("message") or {}).get("id") or "")
                        if mid and mid not in seen:
                            seen.add(mid)
                            msg_ids.append(mid)
                page_token = res.get("nextPageToken")
                if not page_token:
                    break
        except urllib.error.HTTPError as e:
            if e.code == 404:
                # Expired historyId — caller will fall back to date sweep
                return [], self.current_history_id()
            raise
        return msg_ids, latest_hid

    def list_billing_message_ids(self, since_date: date, max_messages: int = 450) -> list[str]:
        extra_from = load_sync_config().get("extra_gmail_from")
        q = f"after:{since_date.strftime('%Y/%m/%d')} {build_gmail_billing_query(extra_from if isinstance(extra_from, list) else None)}"
        ids: list[str] = []
        page_token: str | None = None
        while len(ids) < max_messages:
            params: dict[str, Any] = {"q": q, "maxResults": min(100, max_messages - len(ids))}
            if page_token:
                params["pageToken"] = page_token
            res = self._get_json("messages", params)
            batch = [str(m["id"]) for m in (res.get("messages") or []) if m.get("id")]
            ids.extend(batch)
            page_token = res.get("nextPageToken")
            if not page_token or not batch:
                break
        return ids

    def fetch_parsed_rows(self, message_id: str) -> list[dict[str, Any]]:
        msg = self._get_json(f"messages/{message_id}", {"format": "full"})
        internal_ms = int(msg.get("internalDate") or 0)
        msg_date = (
            dt.datetime.fromtimestamp(internal_ms / 1000.0, tz=dt.timezone.utc).date()
            if internal_ms > 0
            else date.today()
        )
        payload = msg.get("payload") or {}
        headers = {str(h.get("name") or "").lower(): str(h.get("value") or "") for h in (payload.get("headers") or [])}
        subj = headers.get("subject", "")
        from_raw = headers.get("from", "")
        from_name, from_email = email.utils.parseaddr(from_raw)

        plain_parts: list[str] = []
        html_parts: list[str] = []
        pdf_attachments: list[tuple[str, str]] = []

        def walk(part: dict[str, Any]) -> None:
            mime = str(part.get("mimeType") or "").lower()
            fname = str(part.get("filename") or "")
            body = part.get("body") or {}
            data_b64 = body.get("data")
            att_id = body.get("attachmentId")
            if mime == "text/plain" and data_b64:
                plain_parts.append(base64.urlsafe_b64decode(data_b64 + "===").decode("utf-8", errors="replace"))
            elif mime == "text/html" and data_b64:
                html_parts.append(base64.urlsafe_b64decode(data_b64 + "===").decode("utf-8", errors="replace"))
            elif (mime == "application/pdf" or fname.lower().endswith(".pdf")) and att_id:
                if int(body.get("size") or 0) <= 2 * 1024 * 1024:
                    pdf_attachments.append((fname, str(att_id)))
            for sub in part.get("parts") or []:
                if isinstance(sub, dict):
                    walk(sub)

        walk(payload)
        raw_plain = "\n".join(plain_parts).strip()
        raw_html = "\n".join(html_parts).strip()
        if raw_plain and not LOOKS_HTML_RE.search(raw_plain):
            body_text = clean_email_text(raw_plain)
            if raw_html and len(body_text) < 40:
                body_text = html_to_text(raw_html)
        elif raw_html:
            body_text = html_to_text(raw_html)
        else:
            body_text = clean_email_text(raw_plain)

        pdf_text = ""
        if _parse_amount(f"{subj}\n{body_text}") is None and pdf_attachments:
            _, att_id = pdf_attachments[0]
            with contextlib.suppress(Exception):
                att = self._get_json(f"messages/{message_id}/attachments/{att_id}")
                if att.get("data"):
                    raw_pdf = base64.urlsafe_b64decode(str(att["data"]) + "===")
                    pdf_text = extract_pdf_text(raw_pdf)

        return parse_billing_message(
            mailbox=self.email,
            message_id=message_id,
            msg_date=msg_date,
            from_name=from_name,
            from_email=from_email,
            subject=subj,
            body_text=body_text,
            pdf_text=pdf_text,
        )


# ── iCloud Direct IMAP + TLS IMAP IDLE Provider ──────────────────────────────

def _decode_mime_header(val: str | None) -> str:
    if not val:
        return ""
    parts = email.header.decode_header(val)
    out = []
    for chunk, enc in parts:
        if isinstance(chunk, bytes):
            out.append(chunk.decode(enc or "utf-8", errors="replace"))
        else:
            out.append(str(chunk))
    return "".join(out)


def fetch_icloud_billing_rows(
    email_addr: str,
    app_password: str,
    since_date: date,
    seen_uids: set[str],
    tenant_spec: str | None = None,
) -> tuple[list[dict[str, Any]], int, list[str]]:
    """Connects to imap.mail.me.com:993, searches INBOX since `since_date`, parses new UIDs."""
    host = "imap.mail.me.com"
    user = email_addr.split("@")[0] if email_addr.endswith(("@icloud.com", "@me.com", "@mac.com")) else email_addr
    if tenant_spec:
        if "|" in tenant_spec:
            h, u = tenant_spec.split("|", 1)
            if h:
                host = h
            if u:
                user = u
        else:
            user = tenant_spec

    imap_since = since_date.strftime("%d-%b-%Y")
    ctx = ssl.create_default_context()
    rows: list[dict[str, Any]] = []
    new_uids: list[str] = []

    conn = imaplib.IMAP4_SSL(host, 993, ssl_context=ctx, timeout=20)
    try:
        conn.login(user, app_password)
        conn.select("INBOX", readonly=True)
        typ, data = conn.uid("SEARCH", None, f"(SINCE {imap_since})")
        if typ != "OK" or not data or not data[0]:
            return [], 0, []
        all_uids = [u.decode("ascii") for u in data[0].split() if u]
        unseen_uids = [u for u in all_uids if f"icloud:{u}" not in seen_uids]
        scanned = 0
        # Process newest-first, capped at 250 per pass
        for uid in reversed(unseen_uids[-250:]):
            typ_f, msg_data = conn.uid("FETCH", uid, "(RFC822)")
            if typ_f != "OK" or not msg_data:
                continue
            raw_bytes = next((item[1] for item in msg_data if isinstance(item, tuple) and isinstance(item[1], bytes)), None)
            if not raw_bytes:
                continue
            scanned += 1
            new_uids.append(f"icloud:{uid}")
            msg = email.message_from_bytes(raw_bytes)
            subj = _decode_mime_header(msg.get("Subject"))
            from_hdr = _decode_mime_header(msg.get("From"))
            from_name, from_email = email.utils.parseaddr(from_hdr)
            dt_hdr = msg.get("Date")
            msg_date = since_date
            if dt_hdr:
                with contextlib.suppress(Exception):
                    parsed_dt = email.utils.parsedate_to_datetime(dt_hdr)
                    msg_date = parsed_dt.date()

            plain_chunks: list[str] = []
            html_chunks: list[str] = []
            pdf_chunks: list[str] = []
            if msg.is_multipart():
                for part in msg.walk():
                    ctype = part.get_content_type().lower()
                    disp = str(part.get("Content-Disposition") or "").lower()
                    if ctype == "text/plain" and "attachment" not in disp:
                        payload = part.get_payload(decode=True)
                        if payload:
                            plain_chunks.append(payload.decode(part.get_content_charset() or "utf-8", errors="replace"))
                    elif ctype == "text/html" and "attachment" not in disp:
                        payload = part.get_payload(decode=True)
                        if payload:
                            html_chunks.append(payload.decode(part.get_content_charset() or "utf-8", errors="replace"))
                    elif ctype == "application/pdf":
                        payload = part.get_payload(decode=True)
                        if payload and len(payload) <= 2 * 1024 * 1024:
                            pdf_chunks.append(extract_pdf_text(payload))
            else:
                payload = msg.get_payload(decode=True)
                if payload:
                    txt = payload.decode(msg.get_content_charset() or "utf-8", errors="replace")
                    if msg.get_content_type().lower() == "text/html":
                        html_chunks.append(txt)
                    else:
                        plain_chunks.append(txt)

            raw_plain_ic = "\n".join(plain_chunks).strip()
            raw_html_ic = "\n".join(html_chunks).strip()
            if raw_plain_ic and not LOOKS_HTML_RE.search(raw_plain_ic):
                body_text = clean_email_text(raw_plain_ic)
                if raw_html_ic and len(body_text) < 40:
                    body_text = html_to_text(raw_html_ic)
            elif raw_html_ic:
                body_text = html_to_text(raw_html_ic)
            else:
                body_text = clean_email_text(raw_plain_ic)
            rows.extend(
                parse_billing_message(
                    mailbox=email_addr,
                    message_id=uid,
                    msg_date=msg_date,
                    from_name=from_name,
                    from_email=from_email,
                    subject=subj,
                    body_text=body_text,
                    pdf_text="\n".join(pdf_chunks),
                )
            )
        return rows, scanned, new_uids
    finally:
        with contextlib.suppress(Exception):
            conn.logout()


# ── Headless-Only Exchange OWA Adapter (NEVER launches visible browser) ──────

OWA_SUBPROCESS_CODE = r"""
import json, sys
from datetime import date
sys.path.insert(0, sys.argv[1])
import auth
import server_owa as owa

def _strictly_headless_token():
    data = auth.load_token()
    if auth.is_fresh(data):
        return data["token"]
    # HARD GLOBAL RULE: headless=True ONLY (visible browsers strictly banned).
    data = auth.refresh(headless=True)
    if auth.is_fresh(data):
        return data["token"]
    raise RuntimeError("reauth_needed")

auth.get_token = _strictly_headless_token
since_iso = sys.argv[2]
items = owa.list_recent_emails("inbox", limit=50)
recent = [m for m in items if str(m.get("received") or "")[:10] >= since_iso]
out = []
for m in recent:
    subj = str(m.get("subject") or "")
    low = subj.lower()
    if any(w in low for w in ("receipt", "invoice", "payment", "anthropic", "claude", "openai", "subscription", "refund", "billing", "charged")):
        detail = owa.read_email(m["id"])
        out.append(detail)
print(json.dumps({"ok": True, "scanned": len(recent), "messages": out}))
"""


def fetch_owa_rows(email_addr: str, since_date: date, seen_ids: set[str]) -> tuple[list[dict[str, Any]], int, list[str], str, str | None]:
    """Returns (rows, scanned_count, new_seen_keys, mailbox_status, detail_error)."""
    cfg = load_sync_config()
    py_str = os.environ.get("RECURRING_OUTLOOK_PYTHON") or cfg.get("outlook_mcp_python")
    owa_str = os.environ.get("RECURRING_OUTLOOK_OWA_DIR") or cfg.get("outlook_legacy_owa_dir")
    if not py_str or not owa_str:
        return [], 0, [], "unavailable", "OWA helper paths not configured in sync_config.json"
    owa_py = Path(py_str).expanduser()
    owa_dir = Path(owa_str).expanduser()
    if not owa_py.exists() or not owa_dir.exists():
        return [], 0, [], "unavailable", "outlook-mcp legacy_owa helper not installed"
    try:
        proc = subprocess.run(
            [str(owa_py), "-c", OWA_SUBPROCESS_CODE, str(owa_dir), since_date.isoformat()],
            capture_output=True,
            text=True,
            timeout=35,
        )
    except subprocess.TimeoutExpired:
        return [], 0, [], "reauth_needed", "Headless OWA refresh timed out (MFA session expired)"

    if proc.returncode != 0:
        err_txt = (proc.stderr or proc.stdout or "").strip()
        if "no Bearer captured" in err_txt or "reauth_needed" in err_txt:
            return (
                [],
                0,
                [],
                "reauth_needed",
                "SSO session expired — refresh OWA token; forwarded/card alerts via Gmail remain live",
            )
        return [], 0, [], "error", f"OWA bridge error: {err_txt.splitlines()[-1][:120] if err_txt else 'exit 1'}"

    try:
        payload = json.loads(proc.stdout.strip().splitlines()[-1])
    except Exception:
        return [], 0, [], "error", "Malformed JSON from OWA helper"

    rows: list[dict[str, Any]] = []
    new_keys: list[str] = []
    for m in payload.get("messages") or []:
        mid = str(m.get("id") or "")
        if not mid or f"owa:{mid}" in seen_ids:
            continue
        new_keys.append(f"owa:{mid}")
        rec = str(m.get("received") or "")[:10]
        try:
            d_obj = date.fromisoformat(rec)
        except ValueError:
            d_obj = since_date
        from_str = str(m.get("from") or "")
        from_name, from_email = email.utils.parseaddr(from_str)
        body = str(m.get("body") or "")
        rows.extend(
            parse_billing_message(
                mailbox=email_addr,
                message_id=mid,
                msg_date=d_obj,
                from_name=from_name,
                from_email=from_email or from_str,
                subject=str(m.get("subject") or ""),
                body_text=html_to_text(body) if "<" in body and ">" in body else body,
            )
        )
    return rows, int(payload.get("scanned") or 0), new_keys, "ok", None


# ── Deduplication & Ledger Reconciliation ────────────────────────────────────

def collapse_service_charges(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Collapses card_alert + merchant receipt within ±1 day & identical amount into 1 charge."""
    money_rows = [
        r for r in rows
        if r.get("amount") not in (None, 0)
        and r.get("_date") is not None
        and r.get("status") not in ("failed", "declined", "invoice_only", "scheduled", "cancelled")
        and r.get("source") not in ("failed_payment", "renewal_notice", "cancellation", "other")
    ]
    money_rows.sort(key=lambda r: r["_date"])
    groups: list[dict[str, Any]] = []
    for r in money_rows:
        for g in groups:
            if r["message_id"] in g["ids"] and abs(g["amount"] - r["amount"]) < 0.005:
                break
            if (
                abs(g["amount"] - r["amount"]) < 0.005
                and abs((g["date"] - r["_date"]).days) <= 1
                and r["message_id"] not in g["ids"]
                and (r["amount"] < 0 or r["source"] not in g["sources"])
            ):
                if r["amount"] > 0 and r.get("ref") and g["refs"] and r["ref"] not in g["refs"] and r["source"] == g["top_source"]:
                    continue
                g["sources"].add(r["source"])
                g["ids"].add(r["message_id"])
                if r.get("ref"):
                    g["refs"].add(r["ref"])
                if r.get("card") and not g.get("card"):
                    g["card"] = r["card"]
                if r.get("next_renewal") and not g.get("next_renewal"):
                    g["next_renewal"] = r["next_renewal"]
                if r.get("recurring_amount") and not g.get("recurring_amount"):
                    g["recurring_amount"] = r["recurring_amount"]
                if r.get("is_proration"):
                    g["is_proration"] = True
                if STRENGTH.get(r["source"], 0) > STRENGTH.get(g["top_source"], 0):
                    g["top_source"] = r["source"]
                    g["date"] = r["_date"]
                    g["subject"] = r["subject"]
                    g["mailbox"] = r["mailbox"]
                    if r.get("next_renewal"):
                        g["next_renewal"] = r["next_renewal"]
                    if r.get("recurring_amount"):
                        g["recurring_amount"] = r["recurring_amount"]
                break
        else:
            groups.append({
                "date": r["_date"],
                "amount": r["amount"],
                "sources": {r["source"]},
                "ids": {r["message_id"]},
                "refs": {r["ref"]} if r.get("ref") else set(),
                "card": r.get("card"),
                "next_renewal": r.get("next_renewal"),
                "recurring_amount": r.get("recurring_amount"),
                "is_proration": bool(r.get("is_proration")),
                "top_source": r["source"],
                "subject": r["subject"],
                "mailbox": r["mailbox"],
            })
    return groups


def _parse_day_safe(s: Any) -> date | None:
    if not isinstance(s, str) or len(s) < 10:
        return None
    try:
        return date.fromisoformat(s[:10])
    except ValueError:
        return None


def apply_ingested_rows_to_ledger(
    all_rows: list[dict[str, Any]],
    *,
    dry_run: bool = False,
    advance_as_of: bool = True,
    ref_today: date | None = None,
) -> dict[str, Any]:
    ref_day = ref_today or date.today()
    with ledger_locked():
        lp = ledger_path()
        if not lp.exists():
            raw: dict[str, Any] = {"version": 2, "currency": "USD", "services": []}
        else:
            raw = json.loads(lp.read_text(encoding="utf-8"))

        svcs = [s for s in (raw.get("services") or []) if isinstance(s, dict)]
        services_by_id = {str(s.get("id")): s for s in svcs if s.get("id")}

        by_service: dict[str, list[dict[str, Any]]] = defaultdict(list)
        unassigned: list[dict[str, Any]] = []

        for r in all_rows:
            sid = match_row_to_service_id(r, services_by_id)
            if sid == "_ignored":
                continue
            if sid and sid in services_by_id:
                by_service[sid].append(r)
            elif sid and sid.startswith("_"):
                # Collector row (e.g. generic card alert where specific account receipt also arrives)
                continue
            else:
                unassigned.append(r)

        added_events: list[dict[str, Any]] = []
        failed_alerts: list[dict[str, Any]] = []
        changed = False

        for sid, rows in by_service.items():
            svc = services_by_id[sid]
            existing_charges = svc.get("charges")
            if not isinstance(existing_charges, list):
                existing_charges = []

            collapsed = collapse_service_charges(rows)
            for g in collapsed:
                g_date: date = g["date"]
                g_amt: float = round(float(g["amount"]), 2)

                # Deduplicate against existing charges within ±2 days & exact cent match
                already = False
                for c in existing_charges:
                    if not isinstance(c, dict):
                        continue
                    cd = _parse_day_safe(c.get("date"))
                    ca = c.get("amount")
                    if cd and isinstance(ca, (int, float)) and abs(float(ca) - g_amt) < 0.005 and abs((cd - g_date).days) <= 2:
                        already = True
                        break
                if already:
                    continue

                src_label = "+".join(sorted(g["sources"]))
                ref_sfx = f" #{sorted(g['refs'])[0]}" if g["refs"] else ""
                note = f"Auto-synced ({src_label}{ref_sfx})"
                existing_charges.append({
                    "date": g_date.isoformat(),
                    "amount": g_amt,
                    "note": note,
                })
                existing_charges.sort(key=lambda c: str(c.get("date") or ""))
                svc["charges"] = existing_charges

                # Update status, billing_day, next_renewal, last_charged & amount for positive charges
                cur_last = _parse_day_safe(svc.get("last_charged"))
                cadence = str(svc.get("cadence") or "monthly")
                nr_day = _parse_day_safe(g.get("next_renewal"))

                if g_amt > 0 and svc.get("status") in ("cancelled", "unverified"):
                    c_on = _parse_day_safe(svc.get("cancelled_on"))
                    e_on = _parse_day_safe(svc.get("ends_on"))
                    eff_end = (
                        max(e_on, c_on + timedelta(days=1))
                        if (c_on and e_on)
                        else ((c_on + timedelta(days=1)) if c_on else e_on)
                    )
                    if svc.get("status") == "unverified" or (eff_end is not None and g_date >= eff_end):
                        svc["status"] = "active"
                        svc.pop("cancelled_on", None)
                        svc.pop("ends_on", None)
                        svc.pop("cancel_requested", None)
                        if cadence in ("monthly", "usage") and not g.get("is_proration"):
                            svc["billing_day"] = nr_day.day if nr_day else g_date.day

                if g_amt > 0 and (cur_last is None or g_date >= cur_last):
                    if (
                        cadence in ("monthly", "usage")
                        and svc.get("billing_day") is None
                        and cur_last
                        and cur_last.day > g_date.day
                        and g_date.day == calendar.monthrange(g_date.year, g_date.month)[1]
                    ):
                        svc["billing_day"] = cur_last.day
                    svc["last_charged"] = g_date.isoformat()
                    if nr_day:
                        svc["next_renewal"] = nr_day.isoformat()
                        if cadence in ("monthly", "usage"):
                            svc["billing_day"] = nr_day.day
                    else:
                        old_nr = _parse_day_safe(svc.get("next_renewal"))
                        if old_nr and g_date >= old_nr:
                            svc.pop("next_renewal", None)

                    # Update headline amount unless prorated mid-cycle delta or prepaid term
                    if g.get("recurring_amount") is not None and cadence != "term":
                        svc["amount"] = round(float(g["recurring_amount"]), 2)
                        if svc.get("amount_kind") in (None, "unknown"):
                            svc["amount_kind"] = "usage" if cadence == "usage" else "fixed"
                    elif not g.get("is_proration") and (
                        svc.get("amount") is None or cadence in ("usage", "monthly", "biweekly", "quarterly", "annual")
                    ):
                        if cadence != "term":
                            svc["amount"] = g_amt
                            if svc.get("amount_kind") in (None, "unknown"):
                                svc["amount_kind"] = "usage" if cadence == "usage" else "fixed"

                    # Clear stale payment-failed check once a newer positive charge succeeds
                    chk = str(svc.get("check") or "")
                    if chk.startswith(("Payment failed on ", "PAUSED ", "Renewal declined ")):
                        svc.pop("check", None)

                if g.get("card") and (not svc.get("card") or nr_day):
                    svc["card"] = g["card"]

                added_events.append({
                    "service_id": sid,
                    "service_name": svc.get("name") or sid,
                    "date": g_date.isoformat(),
                    "amount": g_amt,
                    "source": g["top_source"],
                    "mailbox": g["mailbox"],
                    "subject": g["subject"],
                    "ingested_at": _iso_now(),
                })
                changed = True

            # Apply cancellation / expiration notices when no newer positive charge exists
            cancels = [r for r in rows if r.get("source") == "cancellation" and r.get("_date") is not None]
            if cancels:
                latest_cancel = max(cancels, key=lambda r: r["_date"])
                has_newer_paid = any(
                    isinstance(c, dict)
                    and isinstance(c.get("amount"), (int, float))
                    and float(c["amount"]) > 0
                    and (_parse_day_safe(c.get("date")) or date.min) > latest_cancel["_date"]
                    for c in (svc.get("charges") or [])
                )
                if not has_newer_paid and svc.get("status") != "cancelled":
                    svc["status"] = "cancelled"
                    svc["cancelled_on"] = latest_cancel["date"]
                    svc.pop("cancel_requested", None)
                    if latest_cancel.get("ends_on"):
                        svc["ends_on"] = latest_cancel["ends_on"]
                    changed = True

            # Apply explicit schedule / renewal notices (e.g. GEICO policy schedule, Grammarly reminder)
            notices = [r for r in rows if r.get("source") == "renewal_notice" and r.get("_date") is not None]
            if notices and svc.get("status") == "active":
                latest_notice = max(notices, key=lambda r: r["_date"])
                cur_last = _parse_day_safe(svc.get("last_charged"))
                nr_notice = _parse_day_safe(latest_notice.get("next_renewal"))
                if nr_notice and (cur_last is None or latest_notice["_date"] >= cur_last):
                    if svc.get("next_renewal") != nr_notice.isoformat():
                        svc["next_renewal"] = nr_notice.isoformat()
                        changed = True
                    if str(svc.get("cadence") or "monthly") in ("monthly", "usage") and svc.get("billing_day") != nr_notice.day:
                        svc["billing_day"] = nr_notice.day
                        changed = True
                    if latest_notice.get("recurring_amount") is not None and svc.get("cadence") != "term":
                        new_rec_amt = round(float(latest_notice["recurring_amount"]), 2)
                        if svc.get("amount") != new_rec_amt:
                            svc["amount"] = new_rec_amt
                            changed = True

            # Record failed payment / pause / suspension signals on active subscriptions
            fails = [r for r in rows if r.get("source") == "failed_payment"]
            if fails and svc.get("status") == "active":
                latest_fail = max(fails, key=lambda r: r["_date"])
                cur_last = _parse_day_safe(svc.get("last_charged"))
                if cur_last is None or latest_fail["_date"] > cur_last:
                    existing_chk = str(svc.get("check") or "")
                    # Preserve rich operator/curated check note if already explicitly set
                    if not existing_chk.startswith(("PAUSED ", "SUSPENDED ", "Renewal declined ", "Billing account ")):
                        msg = f"Payment failed on {latest_fail['date']} ({latest_fail['subject'][:70]})"
                        if svc.get("check") != msg:
                            svc["check"] = msg
                            changed = True
                    failed_alerts.append({
                        "service_id": sid,
                        "service_name": svc.get("name") or sid,
                        "date": latest_fail["date"],
                        "amount": latest_fail.get("amount"),
                        "mailbox": latest_fail["mailbox"],
                        "subject": latest_fail["subject"],
                    })

        if advance_as_of and raw.get("as_of") != ref_day.isoformat():
            raw["as_of"] = ref_day.isoformat()
            changed = True

        if changed and not dry_run:
            if lp.exists():
                _write_securely(lp.read_bytes(), lp.with_name(lp.name + ".bak"))
            _write_securely(encode_ledger(raw), lp)

    # Identify unassigned subscription-like candidates
    unassigned_out: list[dict[str, Any]] = []
    for r in unassigned:
        if r.get("amount") in (None, 0) or float(r.get("amount") or 0) < 0 or r.get("status") in ("invoice_only", "scheduled", "failed", "refunded"):
            continue
        if re.search(r"subscri|member|renew|monthly|annual|pro\b|plus\b|cloud|ai\b", r["_text"]):
            unassigned_out.append({
                "date": r["date"],
                "merchant": r["merchant"],
                "amount": r["amount"],
                "mailbox": r["mailbox"],
                "source": r["source"],
                "subject": r["subject"],
            })

    return {
        "added_charges": added_events,
        "failed_alerts": failed_alerts,
        "unassigned_candidates": unassigned_out[:25],
        "as_of": raw.get("as_of"),
    }


# ── Full Multi-Mailbox Sync Pass ─────────────────────────────────────────────

def run_sync_pass(
    *,
    since_date: date | None = None,
    dry_run: bool = False,
    mode: str = "manual",
    daemon_pid: int | None = None,
    only_account_email: str | None = None,
) -> dict[str, Any]:
    prev_state = _read_json_safe(sync_state_path(), {})
    seen_doc = _read_json_safe(seen_messages_path(), {"seen": [], "gmail_history": {}})
    seen_set: set[str] = set(seen_doc.get("seen") or [])
    gmail_history: dict[str, str] = dict(seen_doc.get("gmail_history") or {})

    if since_date is None:
        lp = ledger_path()
        as_of_day = None
        if lp.exists():
            with contextlib.suppress(Exception):
                as_of_day = _parse_day_safe(json.loads(lp.read_text(encoding="utf-8")).get("as_of"))
        since_date = (as_of_day - timedelta(days=2)) if as_of_day else (date.today() - timedelta(days=40))

    accts, env = _load_decrypted_mail_tokens()
    expected_mailboxes = get_expected_mailboxes(accts)
    g_cid = env.get("MAIL_MCP_GOOGLE_CLIENT_ID", "")
    g_sec = env.get("MAIL_MCP_GOOGLE_CLIENT_SECRET", "")

    mailbox_statuses: dict[str, dict[str, Any]] = dict(prev_state.get("mailboxes") or {})
    collected_rows: list[dict[str, Any]] = []
    newly_seen: list[str] = []
    reachable_ok = 0

    for mb in expected_mailboxes:
        acct_key = mb["key"]
        email_addr = mb["email"]
        kind = mb["provider"]
        forward_via = mb.get("forward_via")
        if only_account_email and email_addr != only_account_email:
            continue
        t0 = time.time()
        if kind == "gmail":
            cred = accts.get(acct_key)
            if not cred or not cred.get("refreshToken") or not g_cid or not g_sec:
                mailbox_statuses[email_addr] = {
                    "email": email_addr,
                    "provider": "gmail",
                    "status": "reauth_needed",
                    "detail": "Missing Gmail OAuth token in ~/.mail-mcp/tokens.json",
                    "last_checked_at": _iso_now(),
                    "scanned_count": 0,
                    "matched_count": 0,
                }
                continue
            try:
                gp = GmailProvider(email_addr, cred["refreshToken"], g_cid, g_sec)
                # Use fast historyId delta when invoked by push watcher, else full date query
                used_delta = False
                if mode == "push_delta" and gmail_history.get(email_addr):
                    mids, new_hid = gp.changed_message_ids_since(gmail_history[email_addr])
                    gmail_history[email_addr] = new_hid
                    used_delta = True
                else:
                    mids = gp.list_billing_message_ids(since_date)
                    gmail_history[email_addr] = gp.current_history_id()

                unseen_mids = [m for m in mids if f"{email_addr}:{m}" not in seen_set]
                acct_rows: list[dict[str, Any]] = []
                pace = 0.10 if len(unseen_mids) > 40 else 0.0
                for idx_m, mid in enumerate(unseen_mids):
                    if pace and idx_m > 0:
                        time.sleep(pace)
                    rows_m = gp.fetch_parsed_rows(mid)
                    acct_rows.extend(rows_m)
                    collected_rows.extend(rows_m)
                    newly_seen.append(f"{email_addr}:{mid}")
                reachable_ok += 1
                mailbox_statuses[email_addr] = {
                    "email": email_addr,
                    "provider": "gmail",
                    "status": "idle_live" if daemon_pid else "ok",
                    "detail": f"{'Delta' if used_delta else 'Sweep'} OK ({int((time.time() - t0)*1000)}ms)",
                    "last_checked_at": _iso_now(),
                    "scanned_count": len(unseen_mids),
                    "matched_count": len(acct_rows),
                }
            except Exception as exc:
                mailbox_statuses[email_addr] = {
                    "email": email_addr,
                    "provider": "gmail",
                    "status": "error",
                    "detail": f"{type(exc).__name__}: {str(exc)[:100]}",
                    "last_checked_at": _iso_now(),
                    "scanned_count": 0,
                    "matched_count": 0,
                }

        elif kind == "icloud":
            cred = accts.get(acct_key)
            if not cred or not cred.get("refreshToken"):
                mailbox_statuses[email_addr] = {
                    "email": email_addr,
                    "provider": "icloud",
                    "status": "reauth_needed",
                    "detail": "Missing iCloud app-specific password in ~/.mail-mcp/tokens.json",
                    "last_checked_at": _iso_now(),
                    "scanned_count": 0,
                    "matched_count": 0,
                }
                continue
            try:
                ic_rows, scanned, ic_seen = fetch_icloud_billing_rows(
                    email_addr,
                    cred["refreshToken"],
                    since_date,
                    seen_set,
                    cred.get("tenant"),
                )
                collected_rows.extend(ic_rows)
                newly_seen.extend(ic_seen)
                reachable_ok += 1
                mailbox_statuses[email_addr] = {
                    "email": email_addr,
                    "provider": "icloud",
                    "status": "idle_live" if daemon_pid else "ok",
                    "detail": f"IMAP INBOX OK ({int((time.time() - t0)*1000)}ms)",
                    "last_checked_at": _iso_now(),
                    "scanned_count": scanned,
                    "matched_count": len(ic_rows),
                }
            except Exception as exc:
                mailbox_statuses[email_addr] = {
                    "email": email_addr,
                    "provider": "icloud",
                    "status": "error",
                    "detail": f"{type(exc).__name__}: {str(exc)[:100]}",
                    "last_checked_at": _iso_now(),
                    "scanned_count": 0,
                    "matched_count": 0,
                }

        elif kind == "owa":
            fwd_status = (mailbox_statuses.get(forward_via) or {}).get("status") if forward_via else None
            if forward_via and fwd_status in ("ok", "idle_live") and only_account_email != email_addr:
                forwarded_rows = [r for r in collected_rows if r.get("mailbox") == email_addr]
                reachable_ok += 1
                fwd_short = forward_via.split("@")[0]
                mailbox_statuses[email_addr] = {
                    "email": email_addr,
                    "provider": "owa",
                    "status": "idle_live" if daemon_pid else "ok",
                    "detail": f"Live via Gmail Exchange auto-forward ({fwd_short})",
                    "last_checked_at": _iso_now(),
                    "scanned_count": len(forwarded_rows),
                    "matched_count": len(forwarded_rows),
                }
            else:
                owa_rows, scanned, owa_seen, st, err_detail = fetch_owa_rows(email_addr, since_date, seen_set)
                collected_rows.extend(owa_rows)
                newly_seen.extend(owa_seen)
                if st == "ok":
                    reachable_ok += 1
                mailbox_statuses[email_addr] = {
                    "email": email_addr,
                    "provider": "owa",
                    "status": st,
                    "detail": err_detail or f"OWA INBOX OK ({int((time.time() - t0)*1000)}ms)",
                    "last_checked_at": _iso_now(),
                    "scanned_count": scanned,
                    "matched_count": len(owa_rows),
                }

    apply_res = apply_ingested_rows_to_ledger(
        collected_rows,
        dry_run=dry_run,
        advance_as_of=(reachable_ok > 0),
    )

    if not dry_run:
        merged_seen = list(dict.fromkeys([*(seen_doc.get("seen") or []), *newly_seen]))[-8000:]
        _write_securely(
            (json.dumps({"seen": merged_seen, "gmail_history": gmail_history}, indent=2) + "\n").encode("utf-8"),
            seen_messages_path(),
        )

        prev_events = prev_state.get("recent_events") if isinstance(prev_state.get("recent_events"), list) else []
        combined_events = (apply_res["added_charges"] + prev_events)[:60]
        next_hourly = (_now_utc() + dt.timedelta(seconds=3600)).isoformat().replace("+00:00", "Z")
        mailbox_order = [mb["email"] for mb in expected_mailboxes]
        state_doc = {
            "version": 1,
            "daemon_pid": daemon_pid or prev_state.get("daemon_pid"),
            "mode": "idle_push + hourly" if (daemon_pid or prev_state.get("daemon_pid")) else mode,
            "last_sync_at": _iso_now(),
            "next_hourly_at": next_hourly,
            "since_date": since_date.isoformat(),
            "as_of": apply_res["as_of"],
            "reachable_mailboxes": sum(
                1 for m in mailbox_statuses.values() if m.get("status") in ("ok", "idle_live")
            ),
            "total_mailboxes": len(expected_mailboxes),
            "mailbox_order": mailbox_order,
            "mailboxes": mailbox_statuses,
            "recent_events": combined_events,
            "failed_alerts": apply_res["failed_alerts"],
            "unassigned_candidates": apply_res["unassigned_candidates"] or prev_state.get("unassigned_candidates") or [],
        }
        _write_securely((json.dumps(state_doc, indent=2) + "\n").encode("utf-8"), sync_state_path())
    else:
        state_doc = {
            "dry_run": True,
            "since_date": since_date.isoformat(),
            "added_charges": apply_res["added_charges"],
            "failed_alerts": apply_res["failed_alerts"],
            "unassigned_candidates": apply_res["unassigned_candidates"],
            "mailboxes": mailbox_statuses,
        }

    return {
        "added_count": len(apply_res["added_charges"]),
        "added_charges": apply_res["added_charges"],
        "failed_alerts": apply_res["failed_alerts"],
        "unassigned_candidates": apply_res["unassigned_candidates"],
        "as_of": apply_res["as_of"],
        "mailboxes": mailbox_statuses,
        "state": state_doc,
    }


# ── Persistent Push + Hourly Daemon (`--daemon`) ─────────────────────────────

class SyncDaemon:
    def __init__(self, hourly_interval: int = 3600):
        self.hourly_interval = max(60, hourly_interval)
        self.stop_event = threading.Event()
        self.wake_lock = threading.Lock()
        self.pending_accounts: set[str] = set()
        self.force_full_sweep = False
        self.wake_event = threading.Event()

    def request_account_sync(self, email_addr: str) -> None:
        with self.wake_lock:
            self.pending_accounts.add(email_addr)
        self.wake_event.set()

    def request_full_sweep(self) -> None:
        with self.wake_lock:
            self.force_full_sweep = True
        self.wake_event.set()

    def _icloud_idle_loop(self, email_addr: str, app_password: str, tenant_spec: str | None) -> None:
        host = "imap.mail.me.com"
        user = email_addr.split("@")[0] if email_addr.endswith(("@icloud.com", "@me.com", "@mac.com")) else email_addr
        if tenant_spec and "|" not in tenant_spec:
            user = tenant_spec
        backoff = 5
        while not self.stop_event.is_set():
            conn = None
            try:
                ctx = ssl.create_default_context()
                conn = imaplib.IMAP4_SSL(host, 993, ssl_context=ctx, timeout=30)
                conn.login(user, app_password)
                conn.select("INBOX", readonly=True)
                backoff = 5

                while not self.stop_event.is_set():
                    tag = conn._new_tag().decode("ascii")
                    conn.send(f"{tag} IDLE\r\n".encode("ascii"))
                    line = conn.readline()
                    if not line.startswith(b"+"):
                        break
                    # RFC 2177: re-issue IDLE every 14 minutes (840s)
                    idle_deadline = time.time() + 840
                    pushed = False
                    while not self.stop_event.is_set() and time.time() < idle_deadline:
                        rlist, _, _ = select.select([conn.socket()], [], [], 2.0)
                        if rlist:
                            resp = conn.readline()
                            if not resp:
                                raise ConnectionError("iCloud IMAP socket closed")
                            if b"EXISTS" in resp or b"RECENT" in resp:
                                pushed = True
                                break
                    conn.send(b"DONE\r\n")
                    # Drain until tagged OK
                    for _ in range(10):
                        end_ln = conn.readline()
                        if not end_ln or end_ln.startswith(tag.encode("ascii")):
                            break
                    if pushed:
                        self.request_account_sync(email_addr)
            except Exception:
                self.stop_event.wait(backoff)
                backoff = min(backoff * 2, 120)
            finally:
                if conn is not None:
                    with contextlib.suppress(Exception):
                        conn.logout()

    def _gmail_history_watch_loop(self) -> None:
        """Polls lightweight Gmail `users.history.list` every 20s to catch new invoices immediately."""
        while not self.stop_event.wait(20.0):
            try:
                accts, env = _load_decrypted_mail_tokens()
                g_cid = env.get("MAIL_MCP_GOOGLE_CLIENT_ID", "")
                g_sec = env.get("MAIL_MCP_GOOGLE_CLIENT_SECRET", "")
                if not g_cid or not g_sec:
                    continue
                seen_doc = _read_json_safe(seen_messages_path(), {"seen": [], "gmail_history": {}})
                gh = seen_doc.get("gmail_history") or {}
                for mb in get_expected_mailboxes(accts):
                    if mb["provider"] != "gmail" or self.stop_event.is_set():
                        continue
                    email_addr = mb["email"]
                    cred = accts.get(mb["key"])
                    if not cred or not cred.get("refreshToken"):
                        continue
                    gp = GmailProvider(email_addr, cred["refreshToken"], g_cid, g_sec)
                    cur_hid = gp.current_history_id()
                    prev_hid = gh.get(email_addr)
                    if prev_hid and cur_hid and cur_hid != prev_hid:
                        self.request_account_sync(email_addr)
            except Exception:
                continue

    def _trigger_file_watch_loop(self) -> None:
        tf = trigger_file_path()
        last_mtime = tf.stat().st_mtime if tf.exists() else 0.0
        while not self.stop_event.wait(1.0):
            if tf.exists():
                try:
                    mt = tf.stat().st_mtime
                    if mt > last_mtime:
                        last_mtime = mt
                        self.request_full_sweep()
                except OSError:
                    pass

    def run(self) -> None:
        pid = os.getpid()
        for sig in (signal.SIGTERM, signal.SIGINT):
            signal.signal(sig, lambda *_: (self.stop_event.set(), self.wake_event.set()))

        # Initial full sweep on daemon boot
        with contextlib.suppress(Exception):
            run_sync_pass(mode="idle_push + hourly", daemon_pid=pid)

        accts, _ = _load_decrypted_mail_tokens()
        for mb in get_expected_mailboxes(accts):
            if mb["provider"] != "icloud":
                continue
            ic_cred = accts.get(mb["key"])
            if ic_cred and ic_cred.get("refreshToken"):
                t_ic = threading.Thread(
                    target=self._icloud_idle_loop,
                    args=(mb["email"], ic_cred["refreshToken"], ic_cred.get("tenant")),
                    daemon=True,
                    name=f"icloud-imap-idle-{mb['email'].split('@')[0]}",
                )
                t_ic.start()

        threading.Thread(target=self._gmail_history_watch_loop, daemon=True, name="gmail-delta-watch").start()
        threading.Thread(target=self._trigger_file_watch_loop, daemon=True, name="sync-trigger-watch").start()

        next_hourly = time.time() + self.hourly_interval
        while not self.stop_event.is_set():
            timeout = max(1.0, next_hourly - time.time())
            self.wake_event.wait(timeout=timeout)
            self.wake_event.clear()
            if self.stop_event.is_set():
                break

            with self.wake_lock:
                do_full = self.force_full_sweep or (time.time() >= next_hourly)
                accounts = set(self.pending_accounts)
                self.pending_accounts.clear()
                self.force_full_sweep = False

            if do_full:
                with contextlib.suppress(Exception):
                    run_sync_pass(mode="idle_push + hourly", daemon_pid=pid)
                next_hourly = time.time() + self.hourly_interval
            else:
                for email_addr in accounts:
                    with contextlib.suppress(Exception):
                        run_sync_pass(
                            mode="push_delta",
                            daemon_pid=pid,
                            only_account_email=email_addr,
                        )


# ── CLI Interface ────────────────────────────────────────────────────────────

def _pid_alive(pid: Any) -> bool:
    if not isinstance(pid, int) or pid <= 1:
        return False
    try:
        os.kill(pid, 0)
        return True
    except PermissionError:
        return True
    except OSError:
        return False


def build_sync_subparser(subparsers: argparse._SubParsersAction) -> argparse.ArgumentParser:
    ps = subparsers.add_parser("sync", help="Sync recurring invoices across all mailboxes (instant push + hourly)")
    ps.add_argument("--since", help="Sweep messages since YYYY-MM-DD (default: ledger as_of - 2 days)")
    ps.add_argument("--dry-run", action="store_true", help="Parse and match without modifying subscriptions.json")
    ps.add_argument("--status", action="store_true", help="Show current sync daemon & mailbox status")
    ps.add_argument("--trigger", action="store_true", help="Wake running sync daemon immediately (or run inline)")
    ps.add_argument("--daemon", action="store_true", help="Run persistent IMAP IDLE push + hourly sweep daemon")
    ps.add_argument("--interval", type=int, default=3600, help="Hourly full sweep interval in seconds (default 3600)")
    ps.add_argument("--json", action="store_true")
    return ps


def dispatch_sync(args: argparse.Namespace) -> None:
    if args.daemon:
        SyncDaemon(hourly_interval=args.interval).run()
        return

    if args.status:
        st = _read_json_safe(sync_state_path(), {})
        st["daemon_alive"] = _pid_alive(st.get("daemon_pid"))
        if args.json:
            print(json.dumps(st, indent=2))
            return
        daemon_txt = f"LIVE (pid {st.get('daemon_pid')})" if st["daemon_alive"] else "STOPPED"
        print(f"INVOICE SYNC — daemon {daemon_txt} · last sync {st.get('last_sync_at') or 'never'} · ledger as_of {st.get('as_of') or '?'}")
        for email_addr, m in (st.get("mailboxes") or {}).items():
            print(f"  [{m.get('status', '?'):<13}] {email_addr:<34} {m.get('detail') or ''}")
        return

    if args.trigger:
        st = _read_json_safe(sync_state_path(), {})
        if _pid_alive(st.get("daemon_pid")):
            _write_securely(_iso_now().encode("utf-8"), trigger_file_path())
            if args.json:
                print(json.dumps({"triggered_daemon": True, "daemon_pid": st.get("daemon_pid")}, indent=2))
            else:
                print(f"Triggered sync daemon (pid {st.get('daemon_pid')}).")
            return

    since_d = None
    if args.since:
        since_d = _parse_day_safe(args.since)
        if not since_d:
            sys.exit("--since must be YYYY-MM-DD")

    res = run_sync_pass(since_date=since_d, dry_run=args.dry_run, mode="manual")
    if args.json:
        print(json.dumps(res, indent=2))
        return

    print(
        f"SYNC COMPLETE (since {res['state']['since_date']}) → "
        f"{res['added_count']} new charges recorded · ledger as_of={res['as_of']}"
    )
    for email_addr, m in res["mailboxes"].items():
        print(
            f"  [{m.get('status', '?'):<13}] {email_addr:<34} "
            f"scanned={m.get('scanned_count', 0):<4} matched={m.get('matched_count', 0):<3} {m.get('detail') or ''}"
        )
    for c in res["added_charges"]:
        print(f"  + {c['date']}  {c['service_id']:<24} ${c['amount']:>8.2f}  ({c['source']} · {c['mailbox']})")
    for f in res["failed_alerts"]:
        print(f"  ! FAILED {f['date']}  {f['service_id']:<19} ({f['subject'][:60]})")


def main(argv: list[str] | None = None) -> None:
    p = argparse.ArgumentParser(prog="recurring-sync")
    sub = p.add_subparsers(dest="top")
    ps = build_sync_subparser(sub)
    args = ps.parse_args(argv)
    dispatch_sync(args)


if __name__ == "__main__":
    main()
