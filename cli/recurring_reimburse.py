#!/usr/bin/env python3
"""Deterministic Cloud/API Receipt Reimbursement Packet Engine (`recurring wm-cloud` / `recurring reimburse`).

Implements the end-to-end receipt reimbursement pipeline deterministically and headlessly:
  1. Harvests real receipt PDFs across configured Gmail, iCloud IMAP, Exchange/OWA, and local portal cache
     within [start_date, end_date] (preferring Receipt*.pdf over unpaid Invoice*.pdf).
  2. Validates every source PDF (%PDF header, >=1KB, page count >=1, paid-vs-unpaid text check).
  3. Deduplicates against previously sent batches (double-submission guard) and flags non-reimbursable items.
  4. Enforces 1:1 IT approval pairing per provider (blocking unapproved providers unless overridden)
     and flags receipts dated prior to a provider's IT approval date.
  5. Compiles one joined PDF per provider (`receipts-<provider>-<start>_<end>.pdf`), runs the 5-point
     anti-hallucination verification gate (`claimed == embedded PDF pages`), packages `<slug>.zip` with
     `<slug>/<provider>/{receipts-..., approval-...}`, writes `approval-notice.txt` (never auto-sends),
     and updates `~/.recurring/reimburse_state.json` (0600, O_NOFOLLOW, flock) for the SwiftUI app.
"""
from __future__ import annotations

import argparse
import base64
import contextlib
import datetime as dt
import email
import email.policy
import email.utils
import fcntl
import hashlib
import imaplib
import ipaddress
import json
import os
import re
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from datetime import date, timedelta
from pathlib import Path
from typing import Any

# ── Paths & Atomic 0600/0700 File Hygiene ─────────────────────────────────────

MAX_PDF_BYTES = 15 * 1024 * 1024
MIN_PDF_BYTES = 1024
SAFE_SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}$")
DATE_ISO_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")

CHROME_PATHS = (
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
)


def state_root() -> Path:
    env_file = os.environ.get("RECURRING_FILE")
    if env_file:
        return Path(env_file).expanduser().resolve().parent
    return (Path.home() / ".recurring").resolve()


def reimburse_config_path() -> Path:
    override = os.environ.get("RECURRING_REIMBURSE_CONFIG")
    if override:
        return Path(override).expanduser()
    return state_root() / "reimburse_config.json"


def reimburse_state_path() -> Path:
    return state_root() / "reimburse_state.json"


def ensure_private_dir(p: Path) -> Path:
    p.mkdir(parents=True, exist_ok=True)
    st = os.lstat(p)
    if os.path.islink(p):
        raise RuntimeError(f"Refusing symlink directory: {p}")
    if (st.st_mode & 0o777) != 0o700:
        os.chmod(p, 0o700)
    return p


def atomic_write_bytes(path: Path, data: bytes, mode: int = 0o600) -> None:
    ensure_private_dir(path.parent)
    if path.exists() and path.is_symlink():
        raise RuntimeError(f"Refusing to overwrite symlink: {path}")
    lock_path = path.parent / f".{path.name}.lock"
    flags = os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0)
    lfd = os.open(str(lock_path), flags, 0o600)
    try:
        fcntl.flock(lfd, fcntl.LOCK_EX)
        fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
        try:
            os.fchmod(fd, mode)
            view = memoryview(data)
            written = 0
            while written < len(view):
                written += os.write(fd, view[written:])
            os.fsync(fd)
            os.close(fd)
            fd = -1
            os.replace(tmp_name, str(path))
        except Exception:
            if fd >= 0:
                with contextlib.suppress(OSError):
                    os.close(fd)
            with contextlib.suppress(OSError):
                os.unlink(tmp_name)
            raise
    finally:
        with contextlib.suppress(OSError):
            fcntl.flock(lfd, fcntl.LOCK_UN)
        with contextlib.suppress(OSError):
            os.close(lfd)


def atomic_write_json(path: Path, obj: Any) -> None:
    payload = (json.dumps(obj, indent=2, sort_keys=True) + "\n").encode("utf-8")
    atomic_write_bytes(path, payload, mode=0o600)


def sanitize_slug(raw: str, fallback: str = "item") -> str:
    cleaned = re.sub(r"[^a-zA-Z0-9._-]+", "-", raw.strip()).strip("-._").lower()[:60]
    if not cleaned or not SAFE_SLUG_RE.match(cleaned):
        return fallback
    return cleaned


# ── Canonical Provider Registry (Single Source of Truth) ──────────────────────
# Ordering matters: gemini, google-ai-ultra, and firebase MUST precede google-cloud.

PROVIDERS: list[tuple[str, str, tuple[str, ...], re.Pattern[str]]] = [
    ("anthropic", "Anthropic (Claude)", ("anthropic.com",), re.compile(r"anthropic|claude", re.I)),
    ("openai", "OpenAI", ("openai.com",), re.compile(r"openai|chatgpt|gpt-", re.I)),
    ("openrouter", "OpenRouter", ("openrouter.ai",), re.compile(r"openrouter", re.I)),
    ("aws", "Amazon Web Services", ("aws.amazon.com",), re.compile(r"\baws\b|amazon web services", re.I)),
    ("gemini", "Google Gemini", ("ai.google.dev", "makersuite.google.com", "aistudio.google.com"), re.compile(r"gemini|generative language api|google ai studio", re.I)),
    ("google-ai-ultra", "Google AI Ultra", (), re.compile(r"google ai ultra|google one.*200|199\.99.*google", re.I)),
    ("firebase", "Firebase", ("firebase.google.com",), re.compile(r"firebase", re.I)),
    ("google-cloud", "Google Cloud", ("cloud.google.com",), re.compile(r"google cloud|\bgcp\b|cloud\.google", re.I)),
    ("mistral", "Mistral AI", ("mistral.ai",), re.compile(r"mistral", re.I)),
    ("huggingface", "Hugging Face", ("huggingface.co",), re.compile(r"hugging\s?face", re.I)),
    ("vercel", "Vercel", ("vercel.com",), re.compile(r"vercel", re.I)),
    ("railway", "Railway", ("railway.app", "railway.com"), re.compile(r"railway", re.I)),
    ("github", "GitHub", ("github.com",), re.compile(r"github", re.I)),
    ("cloudflare", "Cloudflare", ("cloudflare.com",), re.compile(r"cloudflare", re.I)),
    ("cohere", "Cohere", ("cohere.com", "cohere.ai"), re.compile(r"cohere", re.I)),
    ("perplexity", "Perplexity AI", ("perplexity.ai",), re.compile(r"perplexity", re.I)),
    ("xai", "xAI (Grok)", ("x.ai", "grok.com"), re.compile(r"grok|x\.ai|\bxai\b", re.I)),
    ("together-ai", "Together AI", ("together.ai", "together.xyz"), re.compile(r"together\s?ai|together\.(?:ai|xyz)", re.I)),
    ("replicate", "Replicate", ("replicate.com",), re.compile(r"replicate", re.I)),
    ("groq", "Groq", ("groq.com",), re.compile(r"\bgroq\b", re.I)),
    ("fireworks-ai", "Fireworks AI", ("fireworks.ai",), re.compile(r"fireworks\s?ai", re.I)),
    ("deepseek", "DeepSeek", ("deepseek.com",), re.compile(r"deepseek", re.I)),
    ("elevenlabs", "ElevenLabs", ("elevenlabs.io",), re.compile(r"elevenlabs|eleven\s?labs", re.I)),
    ("stability-ai", "Stability AI", ("stability.ai",), re.compile(r"stability\s?ai|stable\s?diffusion", re.I)),
    ("azure", "Microsoft Azure", ("azure.com",), re.compile(r"\bazure\b", re.I)),
    ("digitalocean", "DigitalOcean", ("digitalocean.com",), re.compile(r"digital\s?ocean", re.I)),
    ("flyio", "Fly.io", ("fly.io",), re.compile(r"\bfly\.io\b|\bflyio\b", re.I)),
    ("render", "Render", ("render.com",), re.compile(r"render\.com|render services", re.I)),
    ("linode", "Linode", ("linode.com",), re.compile(r"linode", re.I)),
    ("netlify", "Netlify", ("netlify.com",), re.compile(r"netlify", re.I)),
    ("supabase", "Supabase", ("supabase.com", "supabase.io"), re.compile(r"supabase", re.I)),
    ("abliteration", "Abliteration AI", ("abliteration.ai",), re.compile(r"abliteration", re.I)),
    ("autoglm", "AutoGLM / Z.ai", ("z.ai",), re.compile(r"autoglm|auto\s?glm|\bz\.ai\b", re.I)),
    ("mongodb", "MongoDB Atlas", ("mongodb.com",), re.compile(r"mongodb", re.I)),
    ("qualtrics", "Qualtrics", ("qualtrics.com",), re.compile(r"qualtrics", re.I)),
    ("overleaf", "Overleaf", ("overleaf.com",), re.compile(r"overleaf", re.I)),
    ("prolific", "Prolific", ("prolific.com", "prolific.co"), re.compile(r"prolific", re.I)),
    ("mathworks", "MathWorks (MATLAB)", ("mathworks.com",), re.compile(r"mathworks|matlab", re.I)),
    ("graphpad", "GraphPad Prism", ("graphpad.com",), re.compile(r"graphpad", re.I)),
    ("esri", "Esri (ArcGIS)", ("esri.com",), re.compile(r"\besri\b|arcgis", re.I)),
    ("spss", "IBM SPSS", (), re.compile(r"\bspss\b", re.I)),
    ("lambdalabs", "Lambda Labs", ("lambdalabs.com",), re.compile(r"lambda\s?labs", re.I)),
    ("runpod", "RunPod", ("runpod.io",), re.compile(r"runpod", re.I)),
    ("zotero", "Zotero", ("zotero.org",), re.compile(r"zotero", re.I)),
    ("moonshot", "Moonshot AI (Kimi)", ("moonshot.ai", "moonshot.cn"), re.compile(r"moonshot|\bkimi\b", re.I)),
    ("resend", "Resend", ("resend.com",), re.compile(r"\bresend\b", re.I)),
    ("cursor", "Cursor", ("cursor.com", "cursor.sh"), re.compile(r"\bcursor\b", re.I)),
    # Non-standard / personal / proxy categories (captured transparently so operator sees exclusions)
    ("apple", "Apple (iCloud)", ("email.apple.com",), re.compile(r"icloud|\bapple\b", re.I)),
    ("donutproxies", "DonutProxies", ("donutproxies.com",), re.compile(r"\bdonut\s*(?:ip|proxies)\b|donutproxies", re.I)),
    ("decodo", "Decodo", ("decodo.com",), re.compile(r"\bdecodo\b", re.I)),
    ("flamingohub", "FlamingoHub", ("flamingohub.com",), re.compile(r"flamingohub|flamingo hub", re.I)),
    ("nopecha", "NopeCHA", ("nopecha.com",), re.compile(r"nopecha", re.I)),
    ("twilio", "Twilio", ("twilio.com",), re.compile(r"\btwilio\b", re.I)),
    ("improvmx", "ImprovMX", ("improvmx.com",), re.compile(r"improvmx", re.I)),
]

PROVIDER_LABELS: dict[str, str] = {pid: lbl for pid, lbl, _, _ in PROVIDERS}
DEFAULT_EXCLUDED_PROVIDERS = {"donutproxies", "decodo", "flamingohub", "nopecha", "apple"}


def classify_provider(sender: str, subject: str, body_hint: str = "") -> str | None:
    hay = f"{sender} {subject} {body_hint[:600]}".lower()
    s_low = sender.lower()
    for pid, _, domains, rx in PROVIDERS:
        if rx.search(hay):
            return pid
        if any(d in s_low for d in domains):
            return pid
    return None


def provider_label(pid: str) -> str:
    return PROVIDER_LABELS.get(pid, pid.replace("-", " ").title())


# ── Configuration Loader ──────────────────────────────────────────────────────

def load_reimburse_config() -> dict[str, Any]:
    root = state_root()
    base_reimb = root / "reimbursements"
    default_cfg: dict[str, Any] = {
        "version": 1,
        "bundle_slug": "cloud-reimbursements",
        "organization": "Institution",
        "traveler": {
            "name": "Researcher",
            "employee_id": "",
            "position": "",
            "funding_worktag": "",
            "fund_number": "",
        },
        "approver": {
            "name": "Approver",
            "email": "",
        },
        "approvals_dir": str(base_reimb / "approvals"),
        "portal_dir": str(base_reimb / "portal"),
        "store_dir": str(base_reimb / "store"),
        "batches_dir": str(base_reimb / "batches"),
        "external_batches_dirs": [],
        "external_submissions_json": "",
        "cached_sources_dirs": [],
        "approval_aliases": {
            "xai": "approval-xai-supergrok",
        },
        "it_approvals": {},
        "excluded_providers": sorted(DEFAULT_EXCLUDED_PROVIDERS),
    }
    p = reimburse_config_path()
    if p.exists() and not p.is_symlink():
        try:
            raw = json.loads(p.read_text(encoding="utf-8"))
            if isinstance(raw, dict):
                for k, v in raw.items():
                    if isinstance(v, dict) and isinstance(default_cfg.get(k), dict):
                        merged = dict(default_cfg[k])
                        merged.update(v)
                        default_cfg[k] = merged
                    else:
                        default_cfg[k] = v
        except Exception:
            pass
    return default_cfg


# ── SSRF-Safe Public HTTPS Receipt Downloader ─────────────────────────────────

def _resolve_public_ips(hostname: str) -> list[str]:
    h = hostname.strip().lower().rstrip(".")
    if not h or "." not in h:
        raise ValueError(f"Non-public hostname: {hostname}")
    if h.endswith((".localhost", ".local", ".internal", ".lan", ".home", ".arpa")):
        raise ValueError(f"Forbidden local domain: {hostname}")
    infos = socket.getaddrinfo(h, 443, proto=socket.IPPROTO_TCP)
    ips: list[str] = []
    for info in infos:
        ip_str = info[4][0]
        ip_obj = ipaddress.ip_address(ip_str)
        if (
            ip_obj.is_private
            or ip_obj.is_loopback
            or ip_obj.is_link_local
            or ip_obj.is_multicast
            or ip_obj.is_reserved
            or ip_obj.is_unspecified
        ):
            raise ValueError(f"Blocked non-public IP {ip_str} for {hostname}")
        ips.append(ip_str)
    if not ips:
        raise ValueError(f"Could not resolve {hostname}")
    return ips


class _SafeHTTPSRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        parsed = urllib.parse.urlparse(newurl)
        if parsed.scheme.lower() != "https" or not parsed.hostname or parsed.username or parsed.password:
            raise urllib.error.URLError(f"Unsafe redirect blocked: {newurl}")
        _resolve_public_ips(parsed.hostname)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def download_safe_pdf(url: str, dest: Path) -> int:
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme.lower() != "https" or not parsed.hostname or parsed.username or parsed.password:
        raise ValueError(f"Refusing non-HTTPS or credentialed URL: {url}")
    _resolve_public_ips(parsed.hostname)

    opener = urllib.request.build_opener(_SafeHTTPSRedirectHandler())
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": "RecurringReceiptBot/3.0",
            "Accept": "application/pdf,*/*;q=0.8",
        },
    )
    with opener.open(req, timeout=18) as resp:
        chunks: list[bytes] = []
        total = 0
        while True:
            blk = resp.read(65536)
            if not blk:
                break
            total += len(blk)
            if total > MAX_PDF_BYTES:
                raise ValueError("PDF exceeds 15 MB safety limit")
            chunks.append(blk)
        buf = b"".join(chunks)

    if len(buf) < MIN_PDF_BYTES or buf[:4] != b"%PDF":
        raise ValueError("Downloaded payload is not a valid %PDF")
    atomic_write_bytes(dest, buf, mode=0o600)
    return len(buf)


# ── Sanitized Headless HTML-to-PDF Fallback (NEVER opens a visible browser) ───

DANGEROUS_TAG_RE = re.compile(
    r"<\s*(?:script|iframe|frame|frameset|object|embed|applet|audio|video|base)\b[^>]*>[\s\S]*?<\s*/\s*(?:script|iframe|frame|frameset|object|embed|applet|audio|video|base)\s*>",
    re.I,
)
DANGEROUS_SELF_RE = re.compile(r"<\s*(?:script|iframe|frame|object|embed|base|meta\s+http-equiv)\b[^>]*/?\s*>", re.I)
LOCAL_SCHEME_RE = re.compile(r"""(?P<attr>\b(?:src|href|background|poster)\s*=\s*['"]?)\s*(?:file|javascript|vbscript|data\s*:\s*text/html)\s*:[^'"\s>]*""", re.I)


def sanitize_receipt_html(html: str) -> str:
    """Strips active tags and file:/javascript: URLs so local rendering cannot read host files."""
    cleaned = DANGEROUS_TAG_RE.sub("", html)
    cleaned = DANGEROUS_SELF_RE.sub("", cleaned)
    cleaned = LOCAL_SCHEME_RE.sub(r'\g<attr>about:blank', cleaned)
    csp = '<meta http-equiv="Content-Security-Policy" content="default-src \'none\'; img-src https: data: cid:; style-src \'unsafe-inline\' https:; font-src https: data:;">'
    if "<head" in cleaned.lower():
        cleaned = re.sub(r"(<head[^>]*>)", rf"\1{csp}", cleaned, count=1, flags=re.I)
    else:
        cleaned = f"<!doctype html><html><head><meta charset='utf-8'>{csp}</head><body>{cleaned}</body></html>"
    return cleaned


def render_html_to_pdf_headless(html: str, dest: Path) -> int:
    chrome_bin = next((c for c in CHROME_PATHS if os.path.exists(c)), None)
    if not chrome_bin:
        raise RuntimeError("No headless Chromium/Chrome binary available for HTML-to-PDF fallback")

    safe_html = sanitize_receipt_html(html)
    tmp_dir = Path(tempfile.mkdtemp(prefix="recurring-rcpt-"))
    os.chmod(tmp_dir, 0o700)
    try:
        html_file = tmp_dir / "receipt.html"
        pdf_tmp = tmp_dir / "out.pdf"
        html_file.write_text(safe_html, encoding="utf-8")
        os.chmod(html_file, 0o600)

        subprocess.run(
            [
                chrome_bin,
                "--headless=new",
                "--disable-gpu",
                "--disable-javascript",
                "--disable-extensions",
                "--disable-background-networking",
                "--no-pdf-header-footer",
                "--virtual-time-budget=6000",
                f"--print-to-pdf={pdf_tmp}",
                f"file://{html_file}",
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=25,
            check=True,
        )
        buf = pdf_tmp.read_bytes()
        if len(buf) < MIN_PDF_BYTES or buf[:4] != b"%PDF":
            raise RuntimeError("Headless HTML render did not produce a valid %PDF")
        atomic_write_bytes(dest, buf, mode=0o600)
        return len(buf)
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


# ── Deterministic PDF Inspector & Paid-Receipt Verifier ───────────────────────

RECEIPT_REF_PATTERNS = (
    re.compile(r"Receipt\s*(?:number|#)\s*[:#]?\s*([A-Z0-9]{3,}(?:-[A-Z0-9]{3,})+)", re.I),
    re.compile(r"#\s*([0-9]{4}-[0-9]{4}(?:-[0-9]{4})?)"),
    re.compile(r"\b(SOP\.[0-9]{4}-[0-9]{4}-[0-9]{4}-[0-9]+(?:\.\.[0-9]+)?)\b"),
    re.compile(r"\b([A-Z]{4,10}-[0-9]{4,6})\b"),
    re.compile(r"\b(INV[0-9]{6,})\b"),
    re.compile(r"Invoice\s*(?:number|#)\s*[:#]?\s*([A-Z0-9]{4,}(?:-[A-Z0-9]{2,})+)", re.I),
)

PAID_AMOUNT_PATTERNS = (
    re.compile(r"Amount\s+paid[\s\S]{0,160}?\$\s*([\d,]+\.\d{2})\b", re.I),
    re.compile(r"\$\s*([\d,]+\.\d{2})\s+paid\s+on\b", re.I),
    re.compile(r"Total\s+paid[\s\S]{0,120}?\$\s*([\d,]+\.\d{2})\b", re.I),
    re.compile(r"Payment\s+(?:amount|received)[\s\S]{0,120}?\$\s*([\d,]+\.\d{2})\b", re.I),
    re.compile(r"Total\s*(?:USD)?[\s\S]{0,120}?\$\s*([\d,]+\.\d{2})\b", re.I),
)


def extract_receipt_ref(text: str, fallback: str = "") -> str:
    for rx in RECEIPT_REF_PATTERNS:
        m = rx.search(text)
        if m:
            return m.group(1).strip().upper()
    return fallback.strip()


def canonical_receipt_key(provider: str, rdate: str, ref: str, fallback: str = "") -> str:
    """Unique receipt key; scopes recurring Google Play base order IDs (`SOP.*` without `..N`) by date."""
    p = provider.strip().lower()
    r = ref.strip().upper()
    if r:
        if r.startswith("SOP.") and ".." not in r:
            return f"{p}:{rdate}:{r}"
        return f"{p}:{r}"
    return f"{p}:{rdate}:{fallback}"


def extract_paid_amount_from_text(text: str) -> float | None:
    for rx in PAID_AMOUNT_PATTERNS:
        for m in rx.finditer(text):
            val = float(m.group(1).replace(",", ""))
            if val > 0:
                return round(val, 2)
    # Fallback: first non-zero dollar figure that is NOT preceded by "credits added" or "balance due $0"
    for m in re.finditer(r"\$\s*([\d,]+\.\d{2})\b", text):
        ctx_before = text[max(0, m.start() - 45):m.start()].lower()
        ctx_after = text[m.end():m.end() + 45].lower()
        if "credit" in ctx_before or "credit" in ctx_after:
            continue
        val = float(m.group(1).replace(",", ""))
        if 0 < val <= 100_000:
            return round(val, 2)
    return None


def inspect_pdf_file(path: Path) -> dict[str, Any]:
    """Deterministically validates a PDF and inspects its page count + paid-vs-unpaid wording."""
    if not path.exists() or not path.is_file() or path.is_symlink():
        return {"ok": False, "bytes": 0, "pages": 0, "text": "", "reason": "missing_or_symlink"}
    buf = path.read_bytes()
    if len(buf) < MIN_PDF_BYTES:
        return {"ok": False, "bytes": len(buf), "pages": 0, "text": "", "reason": f"too_small_{len(buf)}B"}
    if buf[:4] != b"%PDF":
        return {"ok": False, "bytes": len(buf), "pages": 0, "text": "", "reason": "not_pdf_magic"}
    try:
        from pypdf import PdfReader
        reader = PdfReader(str(path))
        pages = len(reader.pages)
        if pages < 1:
            return {"ok": False, "bytes": len(buf), "pages": 0, "text": "", "reason": "zero_pages"}
        texts: list[str] = []
        for p in reader.pages[:6]:
            with contextlib.suppress(Exception):
                texts.append(p.extract_text() or "")
        joined = "\n".join(texts)
    except Exception as exc:
        return {"ok": False, "bytes": len(buf), "pages": 0, "text": "", "reason": f"unreadable:{exc}"}

    low = joined.lower()
    has_amount_due = bool(re.search(r"\bamount\s+due\b", low))
    has_zero_due = bool(re.search(r"(?:amount|balance)\s+due[\s:$]*0\.00\b", low))
    has_paid_marker = bool(
        re.search(r"\b(?:amount\s+paid|date\s+paid|paid\s+on|payment\s+received|receipt\s+from|receipt\s+#|payment\s+method)\b", low)
        or has_zero_due
    )
    is_unpaid_invoice = has_amount_due and not has_paid_marker

    return {
        "ok": True,
        "bytes": len(buf),
        "pages": pages,
        "text": joined,
        "is_unpaid_invoice": is_unpaid_invoice,
        "amount_hint": extract_paid_amount_from_text(joined),
        "ref_hint": extract_receipt_ref(joined),
        "sha256": hashlib.sha256(buf).hexdigest(),
        "reason": "",
    }


def inspect_approval_file(path: Path) -> dict[str, Any]:
    if not path.exists() or not path.is_file() or path.is_symlink():
        return {"ok": False, "bytes": 0, "magic": "none"}
    buf = path.read_bytes()
    if len(buf) < 512:
        return {"ok": False, "bytes": len(buf), "magic": "tiny"}
    if buf[:4] == b"%PDF":
        magic = "PDF"
    elif buf[:8] == b"\x89PNG\r\n\x1a\n":
        magic = "PNG"
    elif buf[:3] == b"\xff\xd8\xff":
        magic = "JPEG"
    else:
        return {"ok": False, "bytes": len(buf), "magic": "unknown"}
    return {"ok": True, "bytes": len(buf), "magic": magic}


# ── Approvals Inventory & Double-Submission History ───────────────────────────

def resolve_approvals_inventory(cfg: dict[str, Any]) -> dict[str, dict[str, Any]]:
    """Maps provider_id -> approval file & ticket metadata."""
    approvals_dir = Path(str(cfg.get("approvals_dir") or "")).expanduser()
    aliases: dict[str, str] = {str(k): str(v) for k, v in (cfg.get("approval_aliases") or {}).items()}
    meta_map: dict[str, Any] = cfg.get("it_approvals") or {}

    files_by_stem: dict[str, Path] = {}
    if approvals_dir.is_dir():
        for f in sorted(approvals_dir.iterdir()):
            if f.is_file() and not f.is_symlink() and f.suffix.lower() in (".pdf", ".png", ".jpg", ".jpeg"):
                files_by_stem[f.stem.lower()] = f

    inventory: dict[str, dict[str, Any]] = {}
    all_pids = {pid for pid, _, _, _ in PROVIDERS} | set(meta_map.keys()) | set(aliases.keys())
    for pid in sorted(all_pids):
        meta = meta_map.get(pid) if isinstance(meta_map.get(pid), dict) else {}
        candidates = [f"approval-{pid}"]
        if pid in aliases:
            candidates.insert(0, aliases[pid].lower())
        matched_file: Path | None = None
        for stem in candidates:
            if stem in files_by_stem:
                chk = inspect_approval_file(files_by_stem[stem])
                if chk["ok"]:
                    matched_file = files_by_stem[stem]
                    break
        status = str(meta.get("status") or ("approved" if matched_file else "missing"))
        if not matched_file and status == "approved":
            status = "missing_file"
        inventory[pid] = {
            "provider": pid,
            "label": provider_label(pid),
            "status": status,
            "ticket": str(meta.get("ticket") or ""),
            "approved_on": str(meta.get("approved_on") or ""),
            "note": str(meta.get("note") or ""),
            "file": str(matched_file) if matched_file else None,
            "filename": matched_file.name if matched_file else None,
        }
    return inventory


def load_sent_history(cfg: dict[str, Any]) -> tuple[dict[str, str], str | None]:
    """Returns (map of normalized receipt_ref -> sent_batch_id, latest_sent_end_date)."""
    sent_refs: dict[str, str] = {}
    latest_sent_date: str | None = None

    sub_status_by_pkg: dict[str, str] = {}
    ext_sub_path = str(cfg.get("external_submissions_json") or "").strip()
    if ext_sub_path:
        sp = Path(ext_sub_path).expanduser()
        if sp.is_file():
            with contextlib.suppress(Exception):
                doc = json.loads(sp.read_text(encoding="utf-8"))
                for row in doc.get("submissions") or []:
                    pkg = str(row.get("package_id") or "")
                    st = str(row.get("status") or "")
                    if pkg and st:
                        # If any submission record marks package as 'sent', keep 'sent'
                        if sub_status_by_pkg.get(pkg) != "sent":
                            sub_status_by_pkg[pkg] = st

    batch_roots = [Path(str(cfg.get("batches_dir") or "")).expanduser()]
    for extra in cfg.get("external_batches_dirs") or []:
        if extra:
            batch_roots.append(Path(str(extra)).expanduser())

    for root in batch_roots:
        if not root.is_dir():
            continue
        for bdir in sorted(root.iterdir()):
            if not bdir.is_dir():
                continue
            pkg_id = bdir.name
            local_meta_file = bdir / "submission_status.json"
            pkg_status = sub_status_by_pkg.get(pkg_id, "")
            if local_meta_file.is_file():
                with contextlib.suppress(Exception):
                    pkg_status = str(json.loads(local_meta_file.read_text()).get("status") or pkg_status)
            # Only treat explicitly 'sent' batches as already-submitted (never block on unsent drafts!)
            if pkg_status != "sent":
                continue

            man_file = bdir / "manifest.json"
            if not man_file.is_file():
                continue
            with contextlib.suppress(Exception):
                rows = json.loads(man_file.read_text(encoding="utf-8"))
                if not isinstance(rows, list):
                    continue
                for r in rows:
                    rdate = str(r.get("date") or "")[:10]
                    rprov = str(r.get("provider") or "")
                    if DATE_ISO_RE.match(rdate):
                        if latest_sent_date is None or rdate > latest_sent_date:
                            latest_sent_date = rdate
                    ref = extract_receipt_ref(f"{r.get('receipt_ref', '')} {r.get('subject', '')} {Path(str(r.get('file') or '')).stem}")
                    if ref:
                        ck = canonical_receipt_key(rprov, rdate, ref)
                        sent_refs[ck] = pkg_id
                        if not (ref.upper().startswith("SOP.") and ".." not in ref):
                            sent_refs[ref.upper()] = pkg_id
    return sent_refs, latest_sent_date


# ── Receipt Harvester (Mailboxes + Local Portal / Cached Sources) ─────────────

NON_RECEIPT_SUBJECT_RE = re.compile(
    r"unsuccessful|declined|failed|turned off|deprecation|privacy|security update|"
    r"sign-in|verification code|welcome to|two-factor|2fa|feedback|"
    r"credits?\s+was\s+added|api\s+credits?\s+added",
    re.I,
)
RECEIPT_SUBJECT_RE = re.compile(
    r"receipt|invoice|payment\s+confirmation|order\s+receipt|thanks\s+for\s+your\s+purchase|statement|credit\s+note|refund",
    re.I,
)


def is_candidate_receipt_email(sender: str, subject: str) -> bool:
    s_low = sender.lower()
    if re.search(r"news\.|newsletter|marketing@|noreply@notify|hello@news", s_low):
        return False
    if NON_RECEIPT_SUBJECT_RE.search(subject):
        return False
    return bool(RECEIPT_SUBJECT_RE.search(subject))


def extract_pdf_url_from_html(html: str) -> str | None:
    unescaped = html.replace("&amp;", "&")
    orig_urls = [m.group(1) for m in re.finditer(r'originalsrc="([^"]+)"', unescaped, re.I)]
    direct_urls = [m.group(0) for m in re.finditer(r'https://[^\s"\'<>]+', unescaped, re.I)]
    for u in orig_urls + direct_urls:
        if (
            re.search(r"pay\.stripe\.com/invoice/.+/pdf", u)
            or re.search(r"invoicedata\.stripe\.com/invoice_receipt_file_url/", u)
            or re.search(r"stripe\.com/.+/pdf(?:\?|$)", u)
        ):
            return u
    return None


def _pick_best_pdf_attachment(attachments: list[tuple[str, bytes]]) -> tuple[str, bytes] | None:
    """Prefers Receipt*.pdf over Invoice*.pdf when an email attaches both (e.g. Supabase, OpenAI)."""
    valid = [(fn, data) for fn, data in attachments if len(data) >= MIN_PDF_BYTES and data[:4] == b"%PDF"]
    if not valid:
        return None
    for fn, data in valid:
        if "receipt" in fn.lower():
            return fn, data
    for fn, data in valid:
        if "invoice" not in fn.lower():
            return fn, data
    return valid[0]


def harvest_local_pdf_dir(
    folder: Path,
    start_date: str,
    end_date: str,
    source_tag: str = "portal",
    only_providers: set[str] | None = None,
) -> list[dict[str, Any]]:
    """Ingests pre-fetched or fixture PDFs named `<provider>_<YYYY-MM-DD>_<amount>_<ref>.pdf` or arbitrary PDFs."""
    out: list[dict[str, Any]] = []
    if not folder.is_dir():
        return out
    fname_rx = re.compile(r"^([a-z0-9-]+)_(\d{4}-\d{2}-\d{2})_(-?\d+\.\d{2})_(.+)\.pdf$", re.I)
    for f in sorted(folder.iterdir()):
        if not f.is_file() or f.is_symlink() or f.suffix.lower() != ".pdf":
            continue
        info = inspect_pdf_file(f)
        if not info["ok"]:
            continue
        m = fname_rx.match(f.name)
        if m:
            prov = m.group(1).lower()
            rdate = m.group(2)
            amt = float(m.group(3))
            ref = extract_receipt_ref(m.group(4), fallback=m.group(4))
        else:
            prov = classify_provider("", f.stem, info["text"]) or "other"
            dm = re.search(r"(\d{4}-\d{2}-\d{2})", f.stem)
            rdate = dm.group(1) if dm else end_date
            amt = info["amount_hint"] or 0.0
            ref = info["ref_hint"] or sanitize_slug(f.stem, "pdf").upper()

        if prov == "other":
            continue
        if only_providers and prov not in only_providers:
            continue
        if rdate < start_date or rdate > end_date:
            continue

        out.append({
            "provider": prov,
            "date": rdate,
            "amount": round(amt, 2),
            "kind": "refund" if amt < 0 else "charge",
            "subject": f"{provider_label(prov)} receipt #{ref}",
            "receipt_ref": ref,
            "mailbox": source_tag,
            "pdf_source": source_tag,
            "file": str(f.resolve()),
            "bytes": info["bytes"],
            "pages": info["pages"],
            "is_unpaid_invoice": info["is_unpaid_invoice"],
            "sha256": info["sha256"],
        })
    return out


def harvest_live_mailboxes(
    cfg: dict[str, Any],
    start_date: str,
    end_date: str,
    store_dir: Path,
    only_providers: set[str] | None = None,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """Harvests real receipt PDFs across configured Gmail and iCloud IMAP mailboxes."""
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import recurring_sync as rs

    ensure_private_dir(store_dir)
    accts, env = rs._load_decrypted_mail_tokens()
    expected = rs.get_expected_mailboxes(accts)
    g_cid = env.get("MAIL_MCP_GOOGLE_CLIENT_ID", "")
    g_sec = env.get("MAIL_MCP_GOOGLE_CLIENT_SECRET", "")

    since_dt = date.fromisoformat(start_date)
    until_dt = date.fromisoformat(end_date)
    # Query 2 days earlier on server search to avoid UTC timezone edge misses, then filter strictly
    query_since = (since_dt - timedelta(days=2)).strftime("%Y/%m/%d")
    gmail_q = (
        f"after:{query_since} before:{(until_dt + timedelta(days=2)).strftime('%Y/%m/%d')} "
        "(receipt OR invoice OR \"payment confirmation\" OR \"order receipt\" OR \"credit note\")"
    )

    raw_candidates: list[dict[str, Any]] = []
    mailbox_telemetry: list[dict[str, Any]] = []

    for mbox in expected:
        mkey = mbox["key"]
        memail = mbox["email"]
        mprov = mbox["provider"]
        if mbox.get("forward_via"):
            mailbox_telemetry.append({"email": memail, "provider": mprov, "status": "forwarded", "count": 0})
            continue

        cred = accts.get(mkey)
        if not cred or not cred.get("refreshToken"):
            mailbox_telemetry.append({"email": memail, "provider": mprov, "status": "missing_credentials", "count": 0})
            continue

        if mprov == "gmail":
            if not g_cid or not g_sec:
                mailbox_telemetry.append({"email": memail, "provider": "gmail", "status": "missing_oauth_client", "count": 0})
                continue
            try:
                client = rs.GmailProvider(memail, cred["refreshToken"], g_cid, g_sec)
                ids: list[str] = []
                page_tok: str | None = None
                while len(ids) < 600:
                    params: dict[str, Any] = {"q": gmail_q, "maxResults": min(100, 600 - len(ids))}
                    if page_tok:
                        params["pageToken"] = page_tok
                    res = client._get_json("messages", params)
                    batch = [str(x["id"]) for x in (res.get("messages") or []) if x.get("id")]
                    ids.extend(batch)
                    page_tok = res.get("nextPageToken")
                    if not page_tok or not batch:
                        break

                matched_here = 0
                for mid in ids:
                    msg = client._get_json(f"messages/{mid}", {"format": "full"})
                    internal_ms = int(msg.get("internalDate") or 0)
                    mdate = (
                        dt.datetime.fromtimestamp(internal_ms / 1000.0, tz=dt.timezone.utc).date().isoformat()
                        if internal_ms > 0
                        else start_date
                    )
                    if mdate < start_date or mdate > end_date:
                        continue
                    payload = msg.get("payload") or {}
                    headers = {str(h.get("name") or "").lower(): str(h.get("value") or "") for h in (payload.get("headers") or [])}
                    subj = headers.get("subject", "")
                    _, from_em = email.utils.parseaddr(headers.get("from", ""))
                    if not is_candidate_receipt_email(from_em, subj):
                        continue

                    plain_parts: list[str] = []
                    html_parts: list[str] = []
                    att_specs: list[tuple[str, str]] = []

                    def walk(part: dict[str, Any]) -> None:
                        mime = str(part.get("mimeType") or "").lower()
                        fn = str(part.get("filename") or "")
                        body = part.get("body") or {}
                        b64 = body.get("data")
                        aid = body.get("attachmentId")
                        if mime == "text/plain" and b64:
                            plain_parts.append(base64.urlsafe_b64decode(b64 + "===").decode("utf-8", errors="replace"))
                        elif mime == "text/html" and b64:
                            html_parts.append(base64.urlsafe_b64decode(b64 + "===").decode("utf-8", errors="replace"))
                        elif (mime == "application/pdf" or fn.lower().endswith(".pdf")) and aid:
                            if int(body.get("size") or 0) <= MAX_PDF_BYTES:
                                att_specs.append((fn or "receipt.pdf", str(aid)))
                        for sub in part.get("parts") or []:
                            if isinstance(sub, dict):
                                walk(sub)

                    walk(payload)
                    html_body = "\n".join(html_parts)
                    text_body = "\n".join(plain_parts) or rs.html_to_text(html_body)
                    prov = classify_provider(from_em, subj, text_body)
                    if not prov:
                        continue
                    if only_providers and prov not in only_providers:
                        continue

                    matched_here += 1
                    raw_candidates.append({
                        "provider": prov,
                        "date": mdate,
                        "subject": subj,
                        "sender": from_em,
                        "mailbox": memail,
                        "message_id": mid,
                        "html": html_body,
                        "text": text_body,
                        "has_attachments": bool(att_specs),
                        "_gmail_client": client,
                        "_gmail_atts": att_specs,
                        "_raw_atts": [],
                    })
                mailbox_telemetry.append({"email": memail, "provider": "gmail", "status": "ok", "count": matched_here})
            except Exception as exc:
                mailbox_telemetry.append({"email": memail, "provider": "gmail", "status": f"error:{exc}", "count": 0})

        elif mprov == "icloud":
            try:
                app_pw = str(cred.get("refreshToken") or "")
                tenant = cred.get("tenant")
                host = "imap.mail.me.com"
                user = memail.split("@")[0] if memail.endswith(("@icloud.com", "@me.com", "@mac.com")) else memail
                if tenant and "|" in str(tenant):
                    h, u = str(tenant).split("|", 1)
                    host, user = h or host, u or user
                ctx = ssl.create_default_context()
                conn = imaplib.IMAP4_SSL(host, 993, ssl_context=ctx, timeout=20)
                matched_here = 0
                try:
                    conn.login(user, app_pw)
                    conn.select("INBOX", readonly=True)
                    imap_since = (since_dt - timedelta(days=1)).strftime("%d-%b-%Y")
                    typ, data = conn.uid("search", None, f'(SINCE "{imap_since}")')
                    uids = (data[0].decode("ascii", errors="ignore").split() if typ == "OK" and data and data[0] else [])
                    for uid in uids[-400:]:
                        ftyp, fdata = conn.uid("fetch", uid, "(BODY.PEEK[])")
                        if ftyp != "OK" or not fdata:
                            continue
                        raw_bytes = next((item[1] for item in fdata if isinstance(item, tuple) and isinstance(item[1], bytes)), None)
                        if not raw_bytes:
                            continue
                        emsg = email.message_from_bytes(raw_bytes, policy=email.policy.default)
                        subj = str(emsg.get("subject", ""))
                        _, from_em = email.utils.parseaddr(str(emsg.get("from", "")))
                        dt_hdr = emsg.get("date")
                        try:
                            mdate = email.utils.parsedate_to_datetime(str(dt_hdr)).date().isoformat() if dt_hdr else start_date
                        except Exception:
                            mdate = start_date
                        if mdate < start_date or mdate > end_date:
                            continue
                        if not is_candidate_receipt_email(from_em, subj):
                            continue

                        plain_parts = []
                        html_parts = []
                        raw_atts: list[tuple[str, bytes]] = []
                        for part in emsg.walk():
                            ctype = part.get_content_type().lower()
                            fn = part.get_filename() or ""
                            if ctype == "text/plain" and not fn:
                                with contextlib.suppress(Exception):
                                    plain_parts.append(str(part.get_content()))
                            elif ctype == "text/html" and not fn:
                                with contextlib.suppress(Exception):
                                    html_parts.append(str(part.get_content()))
                            elif ctype == "application/pdf" or fn.lower().endswith(".pdf"):
                                payload_bytes = part.get_payload(decode=True)
                                if isinstance(payload_bytes, bytes) and len(payload_bytes) <= MAX_PDF_BYTES:
                                    raw_atts.append((fn or "receipt.pdf", payload_bytes))

                        html_body = "\n".join(html_parts)
                        text_body = "\n".join(plain_parts) or rs.html_to_text(html_body)
                        prov = classify_provider(from_em, subj, text_body)
                        if not prov or (only_providers and prov not in only_providers):
                            continue
                        matched_here += 1
                        raw_candidates.append({
                            "provider": prov,
                            "date": mdate,
                            "subject": subj,
                            "sender": from_em,
                            "mailbox": memail,
                            "message_id": f"icloud-{uid}",
                            "html": html_body,
                            "text": text_body,
                            "has_attachments": bool(raw_atts),
                            "_gmail_client": None,
                            "_gmail_atts": [],
                            "_raw_atts": raw_atts,
                        })
                finally:
                    with contextlib.suppress(Exception):
                        conn.logout()
                mailbox_telemetry.append({"email": memail, "provider": "icloud", "status": "ok", "count": matched_here})
            except Exception as exc:
                mailbox_telemetry.append({"email": memail, "provider": "icloud", "status": f"error:{exc}", "count": 0})

    # Deduplicate candidates across mailboxes (prefer messages carrying PDF attachments)
    deduped: dict[str, dict[str, Any]] = {}
    for c in raw_candidates:
        ref = extract_receipt_ref(f"{c['subject']}\n{c['text'][:800]}")
        key = canonical_receipt_key(c["provider"], c["date"], ref, fallback=c["subject"].lower()[:48])
        prev = deduped.get(key)
        if not prev or (c["has_attachments"] and not prev["has_attachments"]):
            deduped[key] = c

    harvested: list[dict[str, Any]] = []
    for c in deduped.values():
        is_refund = bool(re.search(r"credit\s+note|refund", c["subject"], re.I))
        amt = extract_paid_amount_from_text(f"{c['subject']}\n{c['text']}\n{c['html']}") or 0.0
        if is_refund and amt > 0:
            amt = -amt

        ref = extract_receipt_ref(f"{c['subject']}\n{c['text'][:1200]}", fallback=c["message_id"][-12:].upper())
        safe_ref = re.sub(r"[^A-Za-z0-9._-]+", "", ref)[:28] or "RCPT"
        tmp_dest = store_dir / f"{c['provider']}_{c['date']}_{abs(amt):.2f}_{safe_ref}.pdf"

        pdf_source = "none"
        # 1. Attachment PDF (prefer Receipt*.pdf over Invoice*.pdf)
        atts: list[tuple[str, bytes]] = list(c["_raw_atts"])
        if c["_gmail_client"] and c["_gmail_atts"]:
            # Sort so receipt*.pdf downloads first
            ordered_specs = sorted(c["_gmail_atts"], key=lambda x: (0 if "receipt" in x[0].lower() else 1, x[0]))
            for fn, aid in ordered_specs:
                with contextlib.suppress(Exception):
                    ares = c["_gmail_client"]._get_json(f"messages/{c['message_id']}/attachments/{aid}")
                    if ares.get("data"):
                        atts.append((fn, base64.urlsafe_b64decode(str(ares["data"]) + "===")))
        chosen = _pick_best_pdf_attachment(atts)
        if chosen:
            atomic_write_bytes(tmp_dest, chosen[1], mode=0o600)
            pdf_source = "attachment"

        # 2. Safe HTTPS Stripe / hosted PDF link
        if pdf_source == "none" and c["html"]:
            url = extract_pdf_url_from_html(c["html"])
            if url:
                with contextlib.suppress(Exception):
                    download_safe_pdf(url, tmp_dest)
                    pdf_source = "stripe-link"

        # 3. Sanitized Headless HTML-to-PDF fallback
        if pdf_source == "none" and (c["html"] or c["text"]):
            html_doc = c["html"] if c["html"] else f"<pre>{c['text']}</pre>"
            with contextlib.suppress(Exception):
                render_html_to_pdf_headless(html_doc, tmp_dest)
                pdf_source = "html-render"

        info = inspect_pdf_file(tmp_dest) if pdf_source != "none" else {
            "ok": False, "bytes": 0, "pages": 0, "is_unpaid_invoice": False, "amount_hint": None, "ref_hint": "", "sha256": ""
        }
        # Reconcile amount/ref from actual PDF text when email body omitted amount (e.g. attachment-only receipts)
        if info["ok"]:
            if amt == 0.0 and info["amount_hint"]:
                amt = -info["amount_hint"] if is_refund else info["amount_hint"]
            if info["ref_hint"] and c["message_id"][-8:].upper() in ref:
                ref = info["ref_hint"]
                safe_ref = re.sub(r"[^A-Za-z0-9._-]+", "", ref)[:28] or safe_ref
            final_dest = store_dir / f"{c['provider']}_{c['date']}_{abs(amt):.2f}_{safe_ref}.pdf"
            if final_dest != tmp_dest:
                os.replace(tmp_dest, final_dest)
        else:
            final_dest = tmp_dest

        harvested.append({
            "provider": c["provider"],
            "date": c["date"],
            "amount": round(amt, 2),
            "kind": "refund" if amt < 0 else "charge",
            "subject": c["subject"],
            "receipt_ref": ref,
            "mailbox": c["mailbox"],
            "pdf_source": pdf_source if info["ok"] else f"FAIL:{info.get('reason', 'no_pdf')}",
            "file": str(final_dest.resolve()) if info["ok"] else None,
            "bytes": info["bytes"],
            "pages": info["pages"],
            "is_unpaid_invoice": bool(info.get("is_unpaid_invoice")),
            "sha256": info.get("sha256", ""),
        })

    return harvested, mailbox_telemetry


# ── Cover Sheet & Per-Provider PDF Compiler ───────────────────────────────────

def _render_cover_pdf_bytes(
    organization: str,
    provider_lbl: str,
    period_start: str,
    period_end: str,
    traveler: dict[str, Any],
    receipts: list[dict[str, Any]],
    subtotal: float,
) -> bytes:
    """Renders a crisp US-Letter provider cover sheet via PyMuPDF (`fitz`)."""
    import fitz

    doc = fitz.open()
    page = doc.new_page(width=612, height=792)
    accent = (0.07, 0.34, 0.25)
    gold = (0.72, 0.55, 0.10)
    ink = (0.12, 0.13, 0.15)
    muted = (0.45, 0.47, 0.50)
    rule = (0.83, 0.84, 0.86)

    y = 54.0
    page.draw_rect(fitz.Rect(56, y, 62, y + 24), color=accent, fill=accent)
    page.insert_text((72, y + 14), f"{organization} — Cloud & API Services Reimbursement", fontsize=14, fontname="hebo", color=accent)
    page.insert_text((72, y + 27), f"{provider_lbl} · itemized receipts compiled for reimbursement", fontsize=9.5, fontname="helv", color=muted)
    y += 52

    fields = [
        ("Claimant", str(traveler.get("name") or "—")),
        ("Employee ID", str(traveler.get("employee_id") or "—")),
        ("Funding Worktag", str(traveler.get("funding_worktag") or traveler.get("fund_number") or "—")),
        ("Period", f"{period_start}  to  {period_end}"),
        ("Provider", provider_lbl),
    ]
    for k, v in fields:
        if not v or v == "—":
            continue
        page.insert_text((56, y), k, fontsize=9, fontname="hebo", color=muted)
        page.insert_text((160, y), v, fontsize=10, fontname="helv", color=ink)
        y += 16

    y += 12
    page.draw_line((56, y), (556, y), color=rule, width=1)
    y += 15
    page.insert_text((56, y), "DATE", fontsize=8.5, fontname="hebo", color=muted)
    page.insert_text((136, y), "REFERENCE / DESCRIPTION", fontsize=8.5, fontname="hebo", color=muted)
    page.insert_text((485, y), "AMOUNT", fontsize=8.5, fontname="hebo", color=muted)
    y += 7
    page.draw_line((56, y), (556, y), color=rule, width=1)
    y += 17

    for r in receipts[:22]:
        desc = f"#{r.get('receipt_ref') or '—'} · {(r.get('subject') or '')[:44]}"
        page.insert_text((56, y), str(r.get("date") or "—"), fontsize=9.5, fontname="helv", color=ink)
        page.insert_text((136, y), desc, fontsize=9.5, fontname="helv", color=ink)
        page.insert_text((485, y), f"${float(r['amount']):,.2f}", fontsize=9.5, fontname="hebo", color=ink)
        y += 17

    y += 6
    page.draw_line((56, y), (556, y), color=gold, width=1.5)
    y += 20
    page.insert_text((56, y), f"{provider_lbl.upper()} SUBTOTAL ({len(receipts)} receipt{'s' if len(receipts) != 1 else ''})", fontsize=10.5, fontname="hebo", color=accent)
    page.insert_text((475, y), f"${subtotal:,.2f}", fontsize=12, fontname="hebo", color=accent)

    out = doc.tobytes()
    doc.close()
    return out


def compile_provider_pdf(
    receipts: list[dict[str, Any]],
    out_pdf_path: Path,
    with_cover: bool,
    organization: str,
    provider_lbl: str,
    period_start: str,
    period_end: str,
    traveler: dict[str, Any],
) -> int:
    """Concatenates validated source PDFs for one provider into `out_pdf_path` and returns total pages."""
    from io import BytesIO
    from pypdf import PdfReader, PdfWriter

    writer = PdfWriter()
    subtotal = round(sum(float(r["amount"]) for r in receipts), 2)

    if with_cover:
        cover_bytes = _render_cover_pdf_bytes(
            organization=organization,
            provider_lbl=provider_lbl,
            period_start=period_start,
            period_end=period_end,
            traveler=traveler,
            receipts=receipts,
            subtotal=subtotal,
        )
        cover_reader = PdfReader(BytesIO(cover_bytes))
        for p in cover_reader.pages:
            writer.add_page(p)

    for r in receipts:
        src_reader = PdfReader(str(r["file"]))
        for p in src_reader.pages:
            writer.add_page(p)

    buf = BytesIO()
    writer.write(buf)
    raw = buf.getvalue()
    atomic_write_bytes(out_pdf_path, raw, mode=0o600)
    return len(writer.pages)


# ── 5-Point Deterministic Anti-Hallucination & 1:1 Pairing Gate ───────────────

def verify_batch(batch_dir: Path, require_approvals: bool = True) -> dict[str, Any]:
    """Proves at the source & byte level that claimed receipts == embedded PDF pages and 1:1 approvals."""
    manifest_path = batch_dir / "manifest.json"
    packet_path = batch_dir / "packet.json"
    violations: list[str] = []
    warnings: list[str] = []

    if not manifest_path.is_file():
        return {"passed": False, "violations": [f"Missing manifest.json in {batch_dir}"], "warnings": [], "groups": []}
    if not packet_path.is_file():
        return {"passed": False, "violations": [f"Missing packet.json in {batch_dir}"], "warnings": [], "groups": []}

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    packet = json.loads(packet_path.read_text(encoding="utf-8"))
    cover_pages = int(packet.get("cover_pages") or 0)

    seen_files: dict[str, str] = {}
    src_pages_by_prov: dict[str, int] = {}
    count_by_prov: dict[str, int] = {}
    sum_by_prov: dict[str, float] = {}

    for r in manifest:
        prov = str(r.get("provider") or "")
        tag = f"{prov} {r.get('date')} ${float(r.get('amount') or 0):.2f} #{r.get('receipt_ref', '')}"
        count_by_prov[prov] = count_by_prov.get(prov, 0) + 1
        sum_by_prov[prov] = round(sum_by_prov.get(prov, 0.0) + float(r.get("amount") or 0.0), 2)

        fpath_str = str(r.get("file") or "")
        if not fpath_str:
            violations.append(f"Counted receipt has null file -> {tag}")
            continue
        fpath = Path(fpath_str)
        chk = inspect_pdf_file(fpath)
        if not chk["ok"]:
            violations.append(f"Invalid source PDF ({chk['reason']}) -> {fpath.name} ({tag})")
            continue
        if isinstance(r.get("pages"), int) and r["pages"] != chk["pages"]:
            violations.append(f"Manifest page count ({r['pages']}) != disk pages ({chk['pages']}) -> {fpath.name}")
        if fpath_str in seen_files:
            violations.append(f"Source file collision on {fpath.name}: {seen_files[fpath_str]} vs {tag}")
        else:
            seen_files[fpath_str] = tag

        src_pages_by_prov[prov] = src_pages_by_prov.get(prov, 0) + chk["pages"]

    group_checks: list[dict[str, Any]] = []
    for g in packet.get("groups") or []:
        prov = str(g.get("provider") or "")
        claimed = len(g.get("receipts") or [])
        man_rows = count_by_prov.get(prov, 0)
        if claimed != man_rows:
            violations.append(f"{prov}: packet claims {claimed} receipts but manifest has {man_rows}")

        man_sum = sum_by_prov.get(prov, 0.0)
        g_sum = float(g.get("subtotal_usd") or 0.0)
        if abs(g_sum - man_sum) >= 0.005:
            violations.append(f"{prov}: subtotal ${g_sum:.2f} != manifest sum ${man_sum:.2f}")

        src_pages = src_pages_by_prov.get(prov, 0)
        expected_pages = cover_pages + src_pages
        pdf_path = Path(str(g.get("pdf_path") or ""))
        out_chk = inspect_pdf_file(pdf_path)
        if not out_chk["ok"]:
            violations.append(f"{prov}: compiled PDF invalid/missing -> {pdf_path}")
            out_pages = 0
        else:
            out_pages = out_chk["pages"]
            if b"could not be embedded" in pdf_path.read_bytes():
                violations.append(f"{prov}: compiled PDF contains placeholder page -> {pdf_path.name}")
            if out_pages != expected_pages:
                violations.append(
                    f"{prov}: compiled PDF has {out_pages} pages, expected {expected_pages} "
                    f"({cover_pages} cover + {src_pages} source)"
                )

        app_path_str = str(g.get("approval_bundle_path") or g.get("approval_path") or "")
        app_ok = False
        if app_path_str:
            achk = inspect_approval_file(Path(app_path_str))
            app_ok = achk["ok"]
        if require_approvals and not app_ok:
            violations.append(f"{prov}: missing verified 1:1 IT approval artifact in packet")
        elif not app_ok:
            warnings.append(f"{prov}: no IT approval artifact attached (override active)")

        group_checks.append({
            "provider": prov,
            "claimed_receipts": claimed,
            "source_pages": src_pages,
            "compiled_pages": out_pages,
            "expected_pages": expected_pages,
            "approval_ok": app_ok,
            "status": "OK" if (out_pages == expected_pages and (app_ok or not require_approvals)) else "FAIL",
        })

    man_total = round(sum(float(r.get("amount") or 0.0) for r in manifest), 2)
    pkt_total = float(packet.get("total_usd") or 0.0)
    if abs(pkt_total - man_total) >= 0.005:
        violations.append(f"Packet total ${pkt_total:.2f} != manifest total ${man_total:.2f}")
    if int(packet.get("receipt_count") or 0) != len(manifest):
        violations.append(f"Packet receipt_count {packet.get('receipt_count')} != manifest rows {len(manifest)}")

    return {
        "passed": len(violations) == 0,
        "violations": violations,
        "warnings": warnings,
        "manifest_receipts": len(manifest),
        "manifest_total_usd": man_total,
        "total_source_pages": sum(src_pages_by_prov.values()),
        "total_compiled_pages": sum(g["compiled_pages"] for g in group_checks),
        "groups": group_checks,
    }


# ── End-to-End Deterministic Packet Builder ───────────────────────────────────

def build_draft_notice(cfg: dict[str, Any], packet: dict[str, Any], zip_filename: str) -> dict[str, str]:
    approver = cfg.get("approver") or {}
    traveler = cfg.get("traveler") or {}
    org = str(cfg.get("organization") or "Institution")
    approver_name = str(approver.get("name") or "Approver").split(",")[0].strip()
    first_name = approver_name.split()[0] if approver_name else "there"
    to_email = str(approver.get("email") or "")
    trav_name = str(traveler.get("name") or "Researcher")
    emp_id = str(traveler.get("employee_id") or "")
    worktag = str(traveler.get("funding_worktag") or "")
    fund_no = str(traveler.get("fund_number") or "")

    period = packet["period"]
    total = float(packet["total_usd"])
    rcount = int(packet["receipt_count"])

    lines = [
        f"  - {g['label']}: ${float(g['subtotal_usd']):,.2f} ({len(g['receipts'])} receipt{'s' if len(g['receipts']) != 1 else ''}"
        + (f", ticket #{g['approval_ticket']}" if g.get("approval_ticket") else "")
        + ")"
        for g in packet["groups"]
    ]
    fund_line = ""
    if fund_no and worktag:
        fund_line = f"Funding worktag: {worktag} (Fund #{fund_no})\n"
    elif worktag:
        fund_line = f"Funding worktag: {worktag}\n"
    elif fund_no:
        fund_line = f"Fund to use: #{fund_no}\n"

    emp_suffix = f" (Employee ID {emp_id})" if emp_id else ""
    subject = f"API & Cloud Services Reimbursement — {trav_name} — {period['start']} to {period['end']} — ${total:,.2f}"

    body = (
        f"Hi {first_name},\n\n"
        f"Please find attached {zip_filename}, containing the compiled receipts and paired IT approvals "
        f"for API and cloud services covering {period['start']} to {period['end']} ({org} research/instructional use).\n\n"
        f"Summary by provider:\n"
        + "\n".join(lines)
        + f"\n\n  TOTAL: ${total:,.2f}  ({rcount} receipt{'s' if rcount != 1 else ''})\n\n"
        + fund_line
        + f"Claimant: {trav_name}{emp_suffix}\n\n"
        f"Each provider folder inside {zip_filename} holds one combined paid-receipts PDF alongside its "
        f"matching IT approval file. Please let me know if anything else is needed.\n\n"
        f"Many thanks,\n{trav_name.split()[0] if trav_name else trav_name}"
    )
    return {"to": to_email, "subject": subject, "attachment": zip_filename, "body": body}


def build_reimbursement_packet(
    since_date: str | None = None,
    until_date: str | None = None,
    only_providers: set[str] | None = None,
    with_cover: bool = False,
    include_unapproved: bool = False,
    from_folder: Path | None = None,
) -> dict[str, Any]:
    cfg = load_reimburse_config()
    approvals_inv = resolve_approvals_inventory(cfg)
    sent_refs, latest_sent_date = load_sent_history(cfg)

    today_iso = date.today().isoformat()
    end_iso = until_date if (until_date and DATE_ISO_RE.match(until_date)) else today_iso
    if since_date and DATE_ISO_RE.match(since_date):
        start_iso = since_date
    elif latest_sent_date:
        start_iso = (date.fromisoformat(latest_sent_date) + timedelta(days=1)).isoformat()
    else:
        start_iso = (date.fromisoformat(end_iso) - timedelta(days=30)).isoformat()

    if start_iso > end_iso:
        start_iso = end_iso

    store_dir = ensure_private_dir(Path(str(cfg["store_dir"])).expanduser())
    portal_dir = Path(str(cfg["portal_dir"])).expanduser()
    batches_dir = ensure_private_dir(Path(str(cfg["batches_dir"])).expanduser())

    # 1. Harvest candidate receipts
    candidates: list[dict[str, Any]] = []
    mailbox_telemetry: list[dict[str, Any]] = []

    if from_folder is not None:
        candidates.extend(harvest_local_pdf_dir(from_folder, start_iso, end_iso, "folder", only_providers))
    else:
        # Cached local portal & prior unsent sources first (preserves portal-pulled ChatGPT/SuperGrok PDFs)
        candidates.extend(harvest_local_pdf_dir(portal_dir, start_iso, end_iso, "portal", only_providers))
        for extra_src in cfg.get("cached_sources_dirs") or []:
            if extra_src:
                candidates.extend(harvest_local_pdf_dir(Path(str(extra_src)).expanduser(), start_iso, end_iso, "cached", only_providers))
        live_rows, mailbox_telemetry = harvest_live_mailboxes(cfg, start_iso, end_iso, store_dir, only_providers)
        candidates.extend(live_rows)

    # Deduplicate across portal/cached + live mailbox harvest by canonical receipt key
    merged_by_key: dict[str, dict[str, Any]] = {}
    for item in candidates:
        ref_key = canonical_receipt_key(
            item["provider"],
            item["date"],
            str(item.get("receipt_ref") or ""),
            fallback=f"{item['amount']:.2f}",
        )
        existing = merged_by_key.get(ref_key)
        if not existing:
            merged_by_key[ref_key] = item
        elif not existing.get("file") and item.get("file"):
            merged_by_key[ref_key] = item

    # 2. Classify into Included vs Blocked (Missing Approval) vs Excluded (Double-submit / Non-reimbursable / Unpaid)
    excluded_provs = {str(x).lower() for x in (cfg.get("excluded_providers") or [])}
    included: list[dict[str, Any]] = []
    blocked_unapproved: list[dict[str, Any]] = []
    excluded: list[dict[str, Any]] = []
    pre_approval_warnings: list[dict[str, Any]] = []

    for r in sorted(merged_by_key.values(), key=lambda x: (x["provider"], x["date"], x.get("receipt_ref", ""))):
        prov = r["provider"]
        ref_up = str(r.get("receipt_ref") or "").upper()
        ck_key = canonical_receipt_key(prov, r["date"], ref_up)
        amt = float(r.get("amount") or 0.0)

        matched_sent = sent_refs.get(ck_key) or (
            sent_refs.get(ref_up) if (ref_up and not (ref_up.startswith("SOP.") and ".." not in ref_up)) else None
        )
        if matched_sent:
            excluded.append({**r, "reason": f"already_submitted ({matched_sent})"})
            continue
        if prov in excluded_provs:
            excluded.append({**r, "reason": "non_reimbursable_category"})
            continue
        if r.get("kind") == "refund" or amt < 0:
            excluded.append({**r, "reason": "refund_credit"})
            continue
        if amt <= 0.0:
            excluded.append({**r, "reason": "zero_amount"})
            continue
        if r.get("is_unpaid_invoice"):
            excluded.append({**r, "reason": "unpaid_invoice_amount_due"})
            continue
        if not r.get("file") or int(r.get("pages") or 0) < 1:
            excluded.append({**r, "reason": f"missing_valid_pdf ({r.get('pdf_source', 'none')})"})
            continue

        app_info = approvals_inv.get(prov) or {}
        has_approval_file = bool(app_info.get("file")) and app_info.get("status") == "approved"
        if not has_approval_file and not include_unapproved:
            reason = "pending_it_approval" if app_info.get("status") == "pending" else "missing_it_approval"
            blocked_unapproved.append({
                **r,
                "reason": reason,
                "ticket": app_info.get("ticket", ""),
            })
            continue

        approved_on = str(app_info.get("approved_on") or "")
        pre_approval = bool(DATE_ISO_RE.match(approved_on) and r["date"] < approved_on)
        row_clean = {**r, "pre_approval_date": pre_approval, "approved_on": approved_on}
        if pre_approval:
            pre_approval_warnings.append({
                "provider": prov,
                "label": provider_label(prov),
                "date": r["date"],
                "approved_on": approved_on,
                "amount": amt,
                "receipt_ref": r.get("receipt_ref", ""),
            })
        included.append(row_clean)

    # 3. Materialize Batch Folder, Copy Source PDFs (unique filenames), Compile Per-Provider PDFs & ZIP
    tag = f"{start_iso}_{end_iso}"
    batch_name = f"{end_iso}-reimbursement"
    batch_dir = ensure_private_dir(batches_dir / batch_name)
    sources_dir = ensure_private_dir(batch_dir / "sources")
    build_dir = ensure_private_dir(batch_dir / "build")
    bundle_slug = sanitize_slug(str(cfg.get("bundle_slug") or "cloud-reimbursements"), "cloud-reimbursements")
    bundle_root = ensure_private_dir(batch_dir / bundle_slug)

    # Clean stale build/bundle artifacts inside this batch dir before writing fresh ones
    for sub in (build_dir, bundle_root):
        for child in list(sub.iterdir()):
            if child.is_dir() and not child.is_symlink():
                shutil.rmtree(child)
            else:
                with contextlib.suppress(OSError):
                    child.unlink()

    manifest_rows: list[dict[str, Any]] = []
    by_provider: dict[str, list[dict[str, Any]]] = {}

    for idx, r in enumerate(included):
        src_orig = Path(str(r["file"]))
        safe_ref = re.sub(r"[^A-Za-z0-9._-]+", "", str(r.get("receipt_ref") or f"R{idx+1}"))[:28] or f"R{idx+1}"
        local_src = sources_dir / f"{r['provider']}_{r['date']}_{float(r['amount']):.2f}_{safe_ref}.pdf"
        if local_src.resolve() != src_orig.resolve():
            atomic_write_bytes(local_src, src_orig.read_bytes(), mode=0o600)
        row_entry = {
            "provider": r["provider"],
            "date": r["date"],
            "amount": round(float(r["amount"]), 2),
            "kind": "charge",
            "subject": r["subject"],
            "receipt_ref": r.get("receipt_ref", ""),
            "mailbox": r.get("mailbox", ""),
            "pdf_source": r.get("pdf_source", "attachment"),
            "file": str(local_src.resolve()),
            "bytes": int(r["bytes"]),
            "pages": int(r["pages"]),
            "pre_approval_date": bool(r.get("pre_approval_date")),
        }
        manifest_rows.append(row_entry)
        by_provider.setdefault(r["provider"], []).append(row_entry)

    # Sort provider groups by subtotal descending (matching ops-receipts convention)
    groups: list[dict[str, Any]] = []
    for prov, items in sorted(
        by_provider.items(),
        key=lambda kv: (-round(sum(x["amount"] for x in kv[1]), 2), kv[0]),
    ):
        items_sorted = sorted(items, key=lambda x: (x["date"], x.get("receipt_ref", "")))
        subtotal = round(sum(x["amount"] for x in items_sorted), 2)
        src_pages = sum(int(x["pages"]) for x in items_sorted)
        lbl = provider_label(prov)

        compiled_name = f"receipts-{prov}-{tag}.pdf"
        build_pdf = build_dir / compiled_name
        compiled_pages = compile_provider_pdf(
            receipts=items_sorted,
            out_pdf_path=build_pdf,
            with_cover=with_cover,
            organization=str(cfg.get("organization") or "Institution"),
            provider_lbl=lbl,
            period_start=start_iso,
            period_end=end_iso,
            traveler=cfg.get("traveler") or {},
        )

        prov_bundle_dir = ensure_private_dir(bundle_root / sanitize_slug(prov, "provider"))
        bundled_pdf = prov_bundle_dir / compiled_name
        atomic_write_bytes(bundled_pdf, build_pdf.read_bytes(), mode=0o600)

        app_info = approvals_inv.get(prov) or {}
        app_src = Path(str(app_info["file"])) if app_info.get("file") else None
        bundled_app: Path | None = None
        if app_src and app_src.is_file():
            bundled_app = prov_bundle_dir / app_src.name
            atomic_write_bytes(bundled_app, app_src.read_bytes(), mode=0o600)

        groups.append({
            "provider": prov,
            "label": lbl,
            "subtotal_usd": subtotal,
            "receipt_count": len(items_sorted),
            "source_pages": src_pages,
            "compiled_pages": compiled_pages,
            "pdf_path": str(bundled_pdf.resolve()),
            "pdf_filename": compiled_name,
            "approval_status": app_info.get("status", "missing"),
            "approval_ticket": app_info.get("ticket", ""),
            "approval_approved_on": app_info.get("approved_on", ""),
            "approval_filename": bundled_app.name if bundled_app else None,
            "approval_bundle_path": str(bundled_app.resolve()) if bundled_app else None,
            "pre_approval_count": sum(1 for x in items_sorted if x.get("pre_approval_date")),
            "receipts": items_sorted,
        })

    generated_at = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    total_usd = round(sum(g["subtotal_usd"] for g in groups), 2)
    zip_filename = f"{bundle_slug}.zip"
    zip_path = batch_dir / zip_filename

    packet: dict[str, Any] = {
        "version": 1,
        "generated_at": generated_at,
        "batch_id": batch_name,
        "batch_dir": str(batch_dir.resolve()),
        "bundle_slug": bundle_slug,
        "zip_path": str(zip_path.resolve()) if groups else None,
        "zip_filename": zip_filename,
        "period": {"start": start_iso, "end": end_iso},
        "cover_pages": 1 if with_cover else 0,
        "total_usd": total_usd,
        "receipt_count": len(manifest_rows),
        "provider_count": len(groups),
        "groups": groups,
        "blocked_unapproved": blocked_unapproved,
        "excluded": excluded,
        "pre_approval_warnings": pre_approval_warnings,
        "mailbox_telemetry": mailbox_telemetry,
    }

    atomic_write_json(batch_dir / "manifest.json", manifest_rows)
    atomic_write_json(batch_dir / "packet.json", packet)

    # 4. Run Mandatory 5-Point Anti-Hallucination Gate BEFORE building final ZIP / marking passed
    gate = verify_batch(batch_dir, require_approvals=not include_unapproved)
    packet["verification"] = gate

    if groups and gate["passed"]:
        tmp_zip = batch_dir / f".{zip_filename}.tmp"
        with zipfile.ZipFile(tmp_zip, "w", compression=zipfile.ZIP_DEFLATED) as zf:
            for g in groups:
                p_slug = sanitize_slug(g["provider"], "provider")
                zf.write(g["pdf_path"], arcname=f"{bundle_slug}/{p_slug}/{g['pdf_filename']}")
                if g.get("approval_bundle_path") and g.get("approval_filename"):
                    zf.write(g["approval_bundle_path"], arcname=f"{bundle_slug}/{p_slug}/{g['approval_filename']}")
        os.chmod(tmp_zip, 0o600)
        os.replace(tmp_zip, zip_path)

    notice = build_draft_notice(cfg, packet, zip_filename)
    packet["draft_notice"] = notice
    notice_txt = (
        f"To: {notice['to']}\n"
        f"Subject: {notice['subject']}\n"
        f"Attachment: {notice['attachment']}\n\n"
        f"{notice['body']}\n"
    )
    atomic_write_bytes(batch_dir / "approval-notice.txt", notice_txt.encode("utf-8"), mode=0o600)
    atomic_write_json(batch_dir / "packet.json", packet)

    # 5. Persist Audit README.md inside batch folder
    readme_lines = [
        f"# {batch_name} ({start_iso} -> {end_iso})",
        "",
        "Draft only — never sent automatically.",
        "",
        f"- **Verification Gate:** `{'PASS' if gate['passed'] else 'FAIL'}` "
        f"({gate['manifest_receipts']} receipts, {gate['total_source_pages']} source pages -> {gate['total_compiled_pages']} compiled pages)",
        f"- **Total Reimbursable:** `${total_usd:,.2f}` across `{len(groups)}` approved provider(s)",
        f"- **Bundle Archive:** `{zip_filename}`",
        "",
        "## Provider Pairing",
        "",
        "| Provider | Receipts | Pages | Subtotal | Approval Artifact | Status |",
        "| :--- | ---: | ---: | ---: | :--- | :--- |",
    ]
    for g in groups:
        readme_lines.append(
            f"| {g['label']} | {g['receipt_count']} | {g['compiled_pages']} | ${g['subtotal_usd']:,.2f} | "
            f"{g.get('approval_filename') or 'MISSING'} {('#' + g['approval_ticket']) if g.get('approval_ticket') else ''} | "
            f"{'OK' if g.get('approval_bundle_path') else 'MISSING'} |"
        )
    if blocked_unapproved:
        readme_lines += ["", "## Blocked (Missing / Pending IT Approval)", ""]
        for b in blocked_unapproved:
            readme_lines.append(f"- {provider_label(b['provider'])} ({b['date']}): ${float(b['amount']):,.2f} — `{b['reason']}` ({b.get('receipt_ref', '')})")
    if excluded:
        readme_lines += ["", "## Excluded / Deduped", ""]
        for ex in excluded:
            readme_lines.append(f"- {provider_label(ex['provider'])} ({ex['date']}): ${float(ex['amount']):,.2f} — `{ex['reason']}` ({ex.get('receipt_ref', '')})")
    atomic_write_bytes(batch_dir / "README.md", ("\n".join(readme_lines) + "\n").encode("utf-8"), mode=0o600)

    # 6. Update ~/.recurring/reimburse_state.json so the SwiftUI app updates live (<80ms)
    save_reimburse_state(cfg, approvals_inv, latest_sent_date, latest_packet=packet)
    return packet


def save_reimburse_state(
    cfg: dict[str, Any] | None = None,
    approvals_inv: dict[str, dict[str, Any]] | None = None,
    latest_sent_date: str | None = None,
    latest_packet: dict[str, Any] | None = None,
) -> dict[str, Any]:
    if cfg is None:
        cfg = load_reimburse_config()
    if approvals_inv is None:
        approvals_inv = resolve_approvals_inventory(cfg)
    if latest_sent_date is None:
        _, latest_sent_date = load_sent_history(cfg)

    batches_dir = Path(str(cfg.get("batches_dir") or "")).expanduser()
    recent_batches: list[dict[str, Any]] = []
    if batches_dir.is_dir():
        for bdir in sorted(batches_dir.iterdir(), reverse=True):
            pfile = bdir / "packet.json"
            if pfile.is_file():
                with contextlib.suppress(Exception):
                    pkt = json.loads(pfile.read_text(encoding="utf-8"))
                    if latest_packet is None:
                        latest_packet = pkt
                    recent_batches.append({
                        "batch_id": pkt.get("batch_id", bdir.name),
                        "batch_dir": str(bdir.resolve()),
                        "zip_path": pkt.get("zip_path"),
                        "start": (pkt.get("period") or {}).get("start", ""),
                        "end": (pkt.get("period") or {}).get("end", ""),
                        "total_usd": pkt.get("total_usd", 0.0),
                        "receipt_count": pkt.get("receipt_count", 0),
                        "provider_count": pkt.get("provider_count", 0),
                        "passed": bool((pkt.get("verification") or {}).get("passed", False)),
                        "generated_at": pkt.get("generated_at", ""),
                    })

    default_since = (
        (date.fromisoformat(latest_sent_date) + timedelta(days=1)).isoformat()
        if latest_sent_date and DATE_ISO_RE.match(latest_sent_date)
        else (date.today() - timedelta(days=30)).isoformat()
    )
    approved_list = [
        v for v in approvals_inv.values()
        if v.get("file") or v.get("ticket") or v.get("status") in ("approved", "pending")
    ]
    state_doc = {
        "version": 1,
        "updated_at": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "organization": cfg.get("organization", "Institution"),
        "bundle_slug": cfg.get("bundle_slug", "cloud-reimbursements"),
        "approver_name": (cfg.get("approver") or {}).get("name", ""),
        "approver_email": (cfg.get("approver") or {}).get("email", ""),
        "funding_worktag": (cfg.get("traveler") or {}).get("funding_worktag", ""),
        "fund_number": (cfg.get("traveler") or {}).get("fund_number", ""),
        "last_sent_date": latest_sent_date,
        "default_since_date": default_since,
        "approvals": sorted(approved_list, key=lambda x: (0 if x.get("file") else 1, x["provider"])),
        "latest_packet": latest_packet,
        "recent_batches": recent_batches[:12],
    }
    atomic_write_json(reimburse_state_path(), state_doc)
    return state_doc


# ── CLI Entrypoint (`recurring wm-cloud` / `recurring reimburse`) ─────────────

def _print_packet_summary(pkt: dict[str, Any]) -> None:
    gate = pkt.get("verification") or {}
    period = pkt.get("period") or {}
    status_str = "PASS" if gate.get("passed") else "FAIL"
    print(f"CLOUD REIMBURSEMENT PACKET — {period.get('start')} -> {period.get('end')}  [GATE: {status_str}]")
    print("=" * 84)
    if not pkt.get("groups"):
        print("  No reimbursable approved receipts found in this date window.")
    else:
        print(f"  {'PROVIDER':<24} {'RCPTS':>5} {'PAGES':>7} {'SUBTOTAL':>12}  {'APPROVAL ARTIFACT'}")
        print("  " + "-" * 78)
        for g in pkt["groups"]:
            app_lbl = g.get("approval_filename") or "MISSING"
            if g.get("approval_ticket"):
                app_lbl += f" (#{g['approval_ticket']})"
            print(
                f"  {g['label']:<24} {g['receipt_count']:>5} {g['compiled_pages']:>7} "
                f"${float(g['subtotal_usd']):>10,.2f}  {app_lbl}"
            )
        print("  " + "-" * 78)
        print(
            f"  {'TOTAL':<24} {pkt['receipt_count']:>5} {gate.get('total_compiled_pages', 0):>7} "
            f"${float(pkt['total_usd']):>10,.2f}"
        )
    if pkt.get("pre_approval_warnings"):
        print(f"\n  Pre-approval date warnings ({len(pkt['pre_approval_warnings'])}):")
        for w in pkt["pre_approval_warnings"]:
            print(f"    ! {w['label']} {w['date']} (${w['amount']:.2f}) precedes approval {w['approved_on']}")
    if pkt.get("blocked_unapproved"):
        print(f"\n  Blocked — missing/pending IT approval ({len(pkt['blocked_unapproved'])}):")
        for b in pkt["blocked_unapproved"]:
            print(f"    x {provider_label(b['provider']):<22} {b['date']}  ${float(b['amount']):>8.2f}  [{b['reason']}]")
    if pkt.get("excluded"):
        print(f"\n  Excluded / already submitted ({len(pkt['excluded'])}):")
        for ex in pkt["excluded"][:15]:
            print(f"    - {provider_label(ex['provider']):<22} {ex['date']}  ${float(ex['amount']):>8.2f}  [{ex['reason']}]")
    if pkt.get("zip_path") and gate.get("passed"):
        print(f"\n  ZIP Archive : {pkt['zip_path']}")
    print(f"  Draft Notice: {Path(pkt['batch_dir']) / 'approval-notice.txt'} (never sent automatically)")
    if not gate.get("passed"):
        for v in gate.get("violations") or []:
            print(f"  GATE VIOLATION: {v}", file=sys.stderr)


def main(argv: list[str] | None = None) -> int:
    args_list = list(sys.argv[1:] if argv is None else argv)
    # Default subcommand when user runs `recurring wm-cloud --since 2026-10-19` directly
    subcommands = {"build", "status", "verify", "approvals"}
    if not args_list or args_list[0].startswith("-"):
        args_list = ["build"] + args_list
    elif args_list[0] not in subcommands and args_list[0] not in ("-h", "--help"):
        # Allow `recurring wm-cloud 2026-10-19` shorthand!
        if DATE_ISO_RE.match(args_list[0]):
            args_list = ["build", "--since", args_list[0]] + args_list[1:]

    p = argparse.ArgumentParser(prog="recurring reimburse", description="Deterministic Cloud/API Receipt Packet Engine")
    sub = p.add_subparsers(dest="subcmd", required=True)

    pb = sub.add_parser("build", help="Harvest receipts for [since..until], pair approvals, compile PDFs + ZIP, and run verify gate")
    pb.add_argument("--since", default=None, help="Start date YYYY-MM-DD (defaults to day after last sent batch)")
    pb.add_argument("--until", default=None, help="End date YYYY-MM-DD (defaults to today)")
    pb.add_argument("--providers", default="", help="Optional comma-separated provider IDs")
    pb.add_argument("--cover", action="store_true", help="Prepend a 1-page itemized cover sheet to each provider PDF")
    pb.add_argument("--include-unapproved", action="store_true", help="Include providers without an IT approval file")
    pb.add_argument("--from-folder", default=None, help="Build deterministically from a local folder of PDFs (offline/test mode)")
    pb.add_argument("--json", action="store_true", help="Emit JSON output")

    ps = sub.add_parser("status", help="Show reimbursement configuration, approval inventory, and latest packet state")
    ps.add_argument("--json", action="store_true")

    pv = sub.add_parser("verify", help="Run the 5-point anti-hallucination & 1:1 approval gate on a batch folder")
    pv.add_argument("batch_dir", nargs="?", default=None, help="Batch directory (defaults to latest batch)")
    pv.add_argument("--allow-unapproved", action="store_true")
    pv.add_argument("--json", action="store_true")

    pa = sub.add_parser("approvals", help="List configured IT approvals and verified artifact files")
    pa.add_argument("--json", action="store_true")

    ns = p.parse_args(args_list)

    if ns.subcmd == "status":
        st = save_reimburse_state()
        if ns.json:
            print(json.dumps(st, indent=2))
        else:
            print(f"Organization : {st['organization']}  (bundle: {st['bundle_slug']}.zip)")
            print(f"Default Since: {st['default_since_date']}  (last sent: {st['last_sent_date'] or 'none'})")
            print(f"IT Approvals : {sum(1 for a in st['approvals'] if a.get('file'))} verified artifact(s)")
            if st.get("latest_packet"):
                print()
                _print_packet_summary(st["latest_packet"])
        return 0

    if ns.subcmd == "approvals":
        cfg = load_reimburse_config()
        inv = resolve_approvals_inventory(cfg)
        rows = [v for v in inv.values() if v.get("file") or v.get("ticket") or v.get("status") != "missing"]
        if ns.json:
            print(json.dumps(rows, indent=2))
        else:
            for r in rows:
                mark = "OK" if r.get("file") else r["status"].upper()
                tkt = f"#{r['ticket']}" if r.get("ticket") else "—"
                print(f"  [{mark:<12}] {r['label']:<24} {tkt:<10} {r.get('filename') or '(no file)'}")
        return 0

    if ns.subcmd == "verify":
        cfg = load_reimburse_config()
        if ns.batch_dir:
            bdir = Path(ns.batch_dir).expanduser()
        else:
            st = save_reimburse_state(cfg)
            lp = st.get("latest_packet") or {}
            if not lp.get("batch_dir"):
                print("No reimbursement batch found to verify.", file=sys.stderr)
                return 1
            bdir = Path(str(lp["batch_dir"]))
        gate = verify_batch(bdir, require_approvals=not ns.allow_unapproved)
        if ns.json:
            print(json.dumps(gate, indent=2))
        else:
            print(f"VERIFY GATE: {'PASS' if gate['passed'] else 'FAIL'} ({bdir})")
            for g in gate.get("groups") or []:
                print(
                    f"  {g['provider']:<18} receipts={g['claimed_receipts']:<3} "
                    f"src_pages={g['source_pages']:<3} out_pages={g['compiled_pages']:<3} "
                    f"approval={'OK' if g['approval_ok'] else 'MISSING'} -> {g['status']}"
                )
            for v in gate.get("violations") or []:
                print(f"  ✗ {v}", file=sys.stderr)
        return 0 if gate["passed"] else 1

    if ns.subcmd == "build":
        only = {s.strip().lower() for s in ns.providers.split(",") if s.strip()} or None
        folder = Path(ns.from_folder).expanduser() if ns.from_folder else None
        pkt = build_reimbursement_packet(
            since_date=ns.since,
            until_date=ns.until,
            only_providers=only,
            with_cover=bool(ns.cover),
            include_unapproved=bool(ns.include_unapproved),
            from_folder=folder,
        )
        gate_ok = bool((pkt.get("verification") or {}).get("passed", False))
        if ns.json:
            print(json.dumps(pkt, indent=2))
        else:
            _print_packet_summary(pkt)
        return 0 if gate_ok else 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
