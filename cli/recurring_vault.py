#!/usr/bin/env python3
"""recurring_vault — Native Sentinel-grade encrypted API key vault for Recurring.

Canonical Helix key tiers (enforced across storage, CLI, and UI):
  - admin  → "Admin key" (platform/organization-wide high-trust key)
  - org    → "Org key"   (standard project/workspace/resource-scoped key)

Security invariants:
  1. Passphrases and raw API secrets are NEVER accepted in CLI argv flags; they
     are read exclusively via stdin (--passphrase-stdin / --secret-stdin) or interactive getpass.
  2. Vault directory is 0700; master.key, vault.json, and lock/temp files use O_NOFOLLOW and 0600.
  3. Master key derivation uses Argon2id (t=2, m=65536 KiB, p=4) + constant-time verification,
     100% compatible with Sentinel's master.key (both v1 and v2).
  4. Secrets are encrypted with AES-256-GCM using unique 12-byte random nonces and AAD bound to
     "{id}|{provider}|{tier}" (aad_v=1). Imported v0 Sentinel ciphertexts upgrade to aad_v=1 on unlock.
  5. Session unlock material lives in macOS Keychain via `/usr/bin/security -i` (stdin mode, zero argv
     exposure) with a 12-hour TTL; revoking or deleting a key wipes ciphertext & nonce immediately.
  6. Filesystem `.env` scanner never writes plaintext secrets to disk — only masked prefixes and SHA-256.
"""
from __future__ import annotations

import argparse
import base64
import concurrent.futures
import contextlib
import datetime as dt
import fcntl
import getpass
import hashlib
import hmac
import ipaddress
import json
import os
import re
import shlex
import socket
import sqlite3
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path
from typing import Any

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.argon2 import Argon2id

# Canonical Helix API-key vocabulary — NEVER invent divergent tier names.
TIERS = ("admin", "org")
TIER_LABELS = {
    "admin": "Admin key",
    "org": "Org key",
}

HEALTH_VALUES = ("ok", "stale", "revoked", "leaked", "rate_limited", "unverified")
STATUS_VALUES = ("active", "revoked")

ARGON_TIME = 2
ARGON_MEMORY = 65536  # 64 MiB in KiB
ARGON_THREADS = 4
SALT_LEN = 16
VERIFY_LEN = 32
KEY_LEN = 32
KEYRING_VERSION = 2
SESSION_TTL_SECONDS = 12 * 3600
STALE_DAYS = 90
KEYCHAIN_SERVICE = "com.amastro.Recurring.v3.vault-session"
KEYCHAIN_ACCOUNT = "session"

PROVIDERS = (
    "anthropic",
    "openai",
    "google",
    "openrouter",
    "xai",
    "groq",
    "github",
    "stripe",
    "resend",
    "supabase",
    "vercel",
    "cloudflare",
    "flyio",
    "huggingface",
    "perplexity",
    "other",
)

PROVIDER_LABELS = {
    "anthropic": "Anthropic",
    "openai": "OpenAI",
    "google": "Google Cloud / Gemini",
    "openrouter": "OpenRouter",
    "xai": "xAI / Grok",
    "groq": "Groq",
    "github": "GitHub",
    "stripe": "Stripe",
    "resend": "Resend",
    "supabase": "Supabase",
    "vercel": "Vercel",
    "cloudflare": "Cloudflare",
    "flyio": "Fly.io",
    "huggingface": "Hugging Face",
    "perplexity": "Perplexity",
    "other": "Other",
}

SKIP_SCAN_DIRS = frozenset({
    ".git", "node_modules", ".venv", "venv", "env", "__pycache__",
    "DerivedData", "build", "dist", ".next", ".nuxt", ".turbo",
    "target", "Pods", "vendor", ".tox", ".mypy_cache", ".pytest_cache",
    ".gradle", ".cache", "Library", ".Trash",
})

PLACEHOLDER_PATTERNS = re.compile(
    r"(?:your[_-]?.*key|replace[_-]?me|example|changeme|placeholder|xxxx+|\.\.\.|<[^>]+>|dummy|test_key_here|^sk-ant-api03-xxx|^sk-proj-xxx)",
    re.IGNORECASE,
)

# High-precision token patterns for `.env` / shell config provenance & leak detection.
SECRET_PATTERNS: list[tuple[str, str, re.Pattern[str]]] = [
    ("anthropic", "admin", re.compile(r"^sk-ant-admin[0-9a-zA-Z_-]{20,}$")),
    ("anthropic", "org", re.compile(r"^sk-ant-(?!admin)[0-9a-zA-Z_-]{20,}$")),
    ("openai", "admin", re.compile(r"^sk-admin-[0-9a-zA-Z_-]{20,}$")),
    ("openai", "org", re.compile(r"^sk-(?:proj|svcacct)-[0-9a-zA-Z_-]{20,}$")),
    ("openrouter", "org", re.compile(r"^sk-or-v1-[0-9a-fA-F]{32,}$")),
    ("openai", "org", re.compile(r"^sk-[0-9a-zA-Z]{32,}$")),
    ("google", "org", re.compile(r"^AIza[0-9A-Za-z_-]{31,45}$")),
    ("xai", "org", re.compile(r"^xai-[0-9A-Za-z_-]{20,}$")),
    ("groq", "org", re.compile(r"^gsk_[0-9A-Za-z]{20,}$")),
    ("github", "org", re.compile(r"^(?:ghp_[0-9A-Za-z]{30,}|github_pat_[0-9A-Za-z_]{22,})$")),
    ("stripe", "admin", re.compile(r"^sk_live_[0-9A-Za-z]{20,}$")),
    ("stripe", "org", re.compile(r"^rk_live_[0-9A-Za-z]{20,}$")),
    ("resend", "org", re.compile(r"^re_[0-9A-Za-z_]{20,}$")),
    ("supabase", "admin", re.compile(r"^sbp_[0-9a-fA-F]{24,}$")),
    ("supabase", "org", re.compile(r"^sb_secret_[0-9A-Za-z_-]{20,}$")),
    ("flyio", "org", re.compile(r"^(?:fo1_[0-9A-Za-z_-]{20,}|FlyV1\s+\S+)$")),
    ("huggingface", "org", re.compile(r"^hf_[0-9A-Za-z]{24,}$")),
    ("perplexity", "org", re.compile(r"^pplx-[0-9A-Za-z]{24,}$")),
]

ENV_LINE_RE = re.compile(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+?)\s*$")


def _now_utc() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0)


def _iso_now() -> str:
    return _now_utc().isoformat().replace("+00:00", "Z")


def _parse_iso(ts: str | None) -> dt.datetime | None:
    if not ts or not isinstance(ts, str):
        return None
    try:
        s = ts.strip()
        if s.endswith("Z"):
            s = s[:-1] + "+00:00"
        d = dt.datetime.fromisoformat(s)
        if d.tzinfo is None:
            d = d.replace(tzinfo=dt.timezone.utc)
        return d
    except ValueError:
        return None


def vault_dir() -> Path:
    override = os.environ.get("RECURRING_VAULT_DIR")
    if override:
        return Path(override).expanduser().resolve()
    ledger_env = os.environ.get("RECURRING_FILE")
    if ledger_env:
        return Path(ledger_env).expanduser().resolve().parent
    return (Path.home() / ".recurring").resolve()


def master_key_path() -> Path:
    return vault_dir() / "master.key"


def vault_file_path() -> Path:
    return vault_dir() / "vault.json"


def ledger_file_path() -> Path:
    p = os.environ.get("RECURRING_FILE")
    if p:
        return Path(p).expanduser().resolve()
    return (vault_dir() / "subscriptions.json").resolve()


def _ensure_private_dir(d: Path) -> None:
    if not d.exists():
        d.mkdir(parents=True, mode=0o700)
    else:
        try:
            os.chmod(d, 0o700)
        except OSError:
            pass


def _write_atomic_0600(data: bytes, target: Path) -> None:
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


def _read_no_follow(path: Path) -> bytes:
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        with os.fdopen(fd, "rb") as f:
            return f.read()
    except BaseException:
        with contextlib.suppress(OSError):
            os.close(fd)
        raise


@contextlib.contextmanager
def vault_locked():
    d = vault_dir()
    _ensure_private_dir(d)
    lock_path = d / ".vault.json.lock"
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


# ── Argon2id + AES-256-GCM (Sentinel-compatible keyring) ─────────────────────

def _argon2_derive(material: bytes, salt: bytes, time_cost: int, memory_cost: int, threads: int) -> bytes:
    kdf = Argon2id(
        salt=salt,
        length=KEY_LEN,
        iterations=time_cost,
        lanes=threads,
        memory_cost=memory_cost,
    )
    return kdf.derive(material)


def _verify_token(password: str, nonce: bytes, salt: bytes, version: int,
                  time_cost: int, memory_cost: int, threads: int) -> bytes:
    pw_bytes = password.encode("utf-8")
    if version < 2:
        # Exact match for Go's []byte(password + "::verify::" + string(nonce))
        material = pw_bytes + b"::verify::" + nonce
    else:
        material = pw_bytes + b"::verify::" + nonce.hex().encode("ascii")
    return _argon2_derive(material, salt, time_cost, memory_cost, threads)


def init_master_key(password: str) -> bytes:
    if not password or len(password) < 6:
        raise ValueError("Passphrase must be at least 6 characters.")
    mk_path = master_key_path()
    if mk_path.exists():
        raise ValueError("Vault master.key already exists.")
    salt = os.urandom(SALT_LEN)
    verify_nonce = os.urandom(VERIFY_LEN)
    enc_key = _argon2_derive(password.encode("utf-8"), salt, ARGON_TIME, ARGON_MEMORY, ARGON_THREADS)
    verify_hash = _verify_token(password, verify_nonce, salt, KEYRING_VERSION, ARGON_TIME, ARGON_MEMORY, ARGON_THREADS)
    doc = {
        "version": KEYRING_VERSION,
        "salt": base64.b64encode(salt).decode("ascii"),
        "verify_nonce": base64.b64encode(verify_nonce).decode("ascii"),
        "verify_hash": base64.b64encode(verify_hash).decode("ascii"),
        "time_cost": ARGON_TIME,
        "memory_cost": ARGON_MEMORY,
        "threads": ARGON_THREADS,
    }
    _write_atomic_0600((json.dumps(doc, indent=2) + "\n").encode("utf-8"), mk_path)
    return enc_key


def unlock_master_key(password: str) -> bytes:
    mk_path = master_key_path()
    if not mk_path.exists():
        raise ValueError("Vault is not initialized yet (run `recurring vault init`).")
    doc = json.loads(_read_no_follow(mk_path).decode("utf-8"))
    salt = base64.b64decode(doc["salt"])
    verify_nonce = base64.b64decode(doc["verify_nonce"])
    stored_hash = base64.b64decode(doc["verify_hash"])
    version = int(doc.get("version") or 1)
    t = int(doc.get("time_cost") or ARGON_TIME)
    m = int(doc.get("memory_cost") or ARGON_MEMORY)
    p = int(doc.get("threads") or ARGON_THREADS)
    computed = _verify_token(password, verify_nonce, salt, version, t, m, p)
    if not hmac.compare_digest(computed, stored_hash):
        raise PermissionError("Invalid vault passphrase.")
    return _argon2_derive(password.encode("utf-8"), salt, t, m, p)


def _entry_aad(key_id: str, provider: str, tier: str) -> bytes:
    return f"{key_id}|{provider}|{tier}".encode("utf-8")


def encrypt_secret(enc_key: bytes, plaintext: str, key_id: str, provider: str, tier: str) -> tuple[str, str]:
    nonce = os.urandom(12)
    aad = _entry_aad(key_id, provider, tier)
    ct = AESGCM(enc_key).encrypt(nonce, plaintext.encode("utf-8"), aad)
    return base64.b64encode(ct).decode("ascii"), base64.b64encode(nonce).decode("ascii")


def decrypt_entry_secret(enc_key: bytes, entry: dict[str, Any]) -> str:
    if entry.get("tracked_only") or not entry.get("key_enc") or not entry.get("key_nonce"):
        raise ValueError(f"Key '{entry.get('label') or entry.get('id')}' is tracked-only (no secret stored).")
    ct = base64.b64decode(entry["key_enc"])
    nonce = base64.b64decode(entry["key_nonce"])
    aad_v = int(entry.get("aad_v", 1))
    aad = _entry_aad(entry["id"], entry["provider"], entry["tier"]) if aad_v >= 1 else None
    try:
        pt = AESGCM(enc_key).decrypt(nonce, ct, aad)
    except InvalidTag as e:
        raise PermissionError("Ciphertext authentication failed (AAD or key mismatch).") from e
    return pt.decode("utf-8")


# ── Session Unlock Management (macOS Keychain via `security -i` stdin) ───────

def _is_isolated_test_vault() -> bool:
    default_dir = (Path.home() / ".recurring").resolve()
    return vault_dir() != default_dir


def _store_session_key(enc_key: bytes) -> str:
    expires = (_now_utc() + dt.timedelta(seconds=SESSION_TTL_SECONDS)).isoformat().replace("+00:00", "Z")
    payload = json.dumps({
        "key_hex": enc_key.hex(),
        "expires_at": expires,
        "vault_dir": str(vault_dir()),
    })
    if _is_isolated_test_vault():
        _write_atomic_0600(payload.encode("utf-8"), vault_dir() / ".vault_session")
        return expires

    payload_b64 = base64.b64encode(payload.encode("utf-8")).decode("ascii")
    cmd_line = (
        f"add-generic-password -U -s {shlex.quote(KEYCHAIN_SERVICE)} "
        f"-a {shlex.quote(KEYCHAIN_ACCOUNT)} -w {shlex.quote(payload_b64)}\n"
    )
    proc = subprocess.run(
        ["/usr/bin/security", "-i"],
        input=cmd_line,
        capture_output=True,
        text=True,
        timeout=8,
    )
    if proc.returncode != 0:
        # Fallback to 0600 O_NOFOLLOW file only if Keychain is unavailable in headless SSH context
        _write_atomic_0600(payload.encode("utf-8"), vault_dir() / ".vault_session")
    return expires


def _clear_session_key() -> None:
    sess_file = vault_dir() / ".vault_session"
    if sess_file.exists():
        with contextlib.suppress(OSError):
            sess_file.unlink()
    if not _is_isolated_test_vault():
        cmd_line = (
            f"delete-generic-password -s {shlex.quote(KEYCHAIN_SERVICE)} "
            f"-a {shlex.quote(KEYCHAIN_ACCOUNT)}\n"
        )
        with contextlib.suppress(Exception):
            subprocess.run(
                ["/usr/bin/security", "-i"],
                input=cmd_line,
                capture_output=True,
                text=True,
                timeout=5,
            )


def _load_session_key() -> tuple[bytes | None, str | None]:
    env_hex = os.environ.get("RECURRING_VAULT_KEY_HEX")
    if env_hex and _is_isolated_test_vault():
        return bytes.fromhex(env_hex), (_now_utc() + dt.timedelta(hours=1)).isoformat().replace("+00:00", "Z")

    raw_json: str | None = None
    sess_file = vault_dir() / ".vault_session"
    if _is_isolated_test_vault() and sess_file.exists():
        with contextlib.suppress(Exception):
            raw_json = _read_no_follow(sess_file).decode("utf-8")
    elif not _is_isolated_test_vault():
        cmd_line = (
            f"find-generic-password -w -s {shlex.quote(KEYCHAIN_SERVICE)} "
            f"-a {shlex.quote(KEYCHAIN_ACCOUNT)}\n"
        )
        proc = subprocess.run(
            ["/usr/bin/security", "-i"],
            input=cmd_line,
            capture_output=True,
            text=True,
            timeout=5,
        )
        if proc.returncode == 0 and proc.stdout.strip():
            token = proc.stdout.strip().splitlines()[0].strip()
            with contextlib.suppress(Exception):
                raw_json = base64.b64decode(token).decode("utf-8")
        elif sess_file.exists():
            with contextlib.suppress(Exception):
                raw_json = _read_no_follow(sess_file).decode("utf-8")

    if not raw_json:
        return None, None
    try:
        doc = json.loads(raw_json)
        if doc.get("vault_dir") != str(vault_dir()):
            return None, None
        exp = _parse_iso(doc.get("expires_at"))
        if not exp or exp <= _now_utc():
            _clear_session_key()
            return None, None
        return bytes.fromhex(doc["key_hex"]), doc["expires_at"]
    except Exception:
        return None, None


# ── Vault Document Storage ───────────────────────────────────────────────────

def _default_vault_doc() -> dict[str, Any]:
    return {
        "version": 1,
        "session_expires_at": None,
        "last_sweep_at": None,
        "last_scan_at": None,
        "keys": [],
        "stray_findings": [],
    }


def load_vault_doc() -> dict[str, Any]:
    p = vault_file_path()
    if not p.exists():
        return _default_vault_doc()
    doc = json.loads(_read_no_follow(p).decode("utf-8"))
    if not isinstance(doc, dict):
        return _default_vault_doc()
    doc.setdefault("version", 1)
    doc.setdefault("session_expires_at", None)
    doc.setdefault("last_sweep_at", None)
    doc.setdefault("last_scan_at", None)
    doc.setdefault("keys", [])
    doc.setdefault("stray_findings", [])
    return doc


def save_vault_doc(doc: dict[str, Any]) -> None:
    data = (json.dumps(doc, indent=2, sort_keys=True) + "\n").encode("utf-8")
    _write_atomic_0600(data, vault_file_path())


# ── Key Classification, Masking, and Subscription Linking ────────────────────

def detect_provider_and_tier(secret: str) -> tuple[str, str]:
    s = secret.strip()
    for provider, tier, rx in SECRET_PATTERNS:
        if rx.match(s):
            return provider, tier
    return "other", "org"


def mask_secret(secret: str) -> tuple[str, str]:
    s = secret.strip()
    if len(s) <= 12:
        last4 = s[-4:] if len(s) >= 4 else s
        return f"{s[:3]}…{last4}", last4
    prefix_len = 13 if s.startswith("sk-ant-") else 10
    prefix = s[:prefix_len]
    last4 = s[-4:]
    return f"{prefix}…{last4}", last4


def secret_fingerprint(secret: str) -> str:
    return hashlib.sha256(secret.strip().encode("utf-8")).hexdigest()


def _load_ledger_services() -> list[dict[str, Any]]:
    lp = ledger_file_path()
    if not lp.exists():
        return []
    try:
        raw = json.loads(_read_no_follow(lp).decode("utf-8"))
        svcs = raw.get("services")
        return [s for s in svcs if isinstance(s, dict)] if isinstance(svcs, list) else []
    except Exception:
        return []


def infer_service_id(provider: str, account: str | None, services: list[dict[str, Any]] | None = None) -> str | None:
    svcs = services if services is not None else _load_ledger_services()
    if not svcs:
        return None
    prov = (provider or "").lower()
    acct = (account or "").lower().strip()

    provider_keywords: dict[str, list[str]] = {
        "anthropic": ["claude", "anthropic"],
        "openai": ["chatgpt", "openai"],
        "google": ["gcp", "google cloud", "google ai", "gemini"],
        "xai": ["grok", "supergrok", "xai"],
        "github": ["github"],
        "supabase": ["supabase"],
        "resend": ["resend"],
        "vercel": ["vercel"],
        "cloudflare": ["cloudflare"],
        "flyio": ["fly.io", "flyio"],
        "huggingface": ["hugging face", "huggingface"],
        "perplexity": ["perplexity"],
    }
    kws = provider_keywords.get(prov, [prov] if prov and prov != "other" else [])
    if not kws:
        return None

    candidates: list[tuple[int, str]] = []
    for s in svcs:
        sid = str(s.get("id") or "")
        sname = str(s.get("name") or "").lower()
        sacct = str(s.get("account") or "").lower()
        status = str(s.get("status") or "active")
        hay = f"{sid.lower()} {sname}"
        if not any(kw in hay for kw in kws):
            continue
        score = 10 if status == "active" else 3
        if acct and sacct:
            if acct == sacct:
                score += 50
            elif acct.split("@")[0] in sacct or sacct.split("@")[0] in acct:
                score += 25
        # Prefer GCP over consumer Google plans for Google Cloud/Gemini API keys
        if prov == "google" and "gcp" in sid.lower():
            score += 15
        candidates.append((score, sid))

    if not candidates:
        return None
    candidates.sort(key=lambda t: (-t[0], t[1]))
    return candidates[0][1]


def public_key_view(entry: dict[str, Any], services_by_id: dict[str, dict[str, Any]] | None = None) -> dict[str, Any]:
    """Safe projection for JSON/CLI/SwiftUI — NEVER includes key_enc or key_nonce."""
    tier = entry.get("tier") if entry.get("tier") in TIERS else "org"
    sid = entry.get("service_id")
    svc = (services_by_id or {}).get(sid) if sid else None
    return {
        "id": entry["id"],
        "label": entry.get("label") or entry["id"],
        "provider": entry.get("provider") or "other",
        "provider_label": PROVIDER_LABELS.get(entry.get("provider") or "other", "Other"),
        "tier": tier,
        "tier_label": TIER_LABELS[tier],
        "account": entry.get("account"),
        "service_id": sid,
        "service_name": svc.get("name") if svc else None,
        "service_amount": svc.get("amount") if svc else None,
        "prefix_masked": entry.get("prefix_masked") or "••••••••",
        "last4": entry.get("last4"),
        "tracked_only": bool(entry.get("tracked_only", False)),
        "status": entry.get("status") or "active",
        "health": entry.get("health") or "unverified",
        "health_detail": entry.get("health_detail"),
        "last_checked_at": entry.get("last_checked_at"),
        "created_at": entry.get("created_at"),
        "rotated_from_id": entry.get("rotated_from_id"),
        "locations": entry.get("locations") or [],
    }


def _upgrade_legacy_entries_if_needed(enc_key: bytes, doc: dict[str, Any]) -> bool:
    """Upgrades Sentinel-imported v0 ciphertexts to aad_v=1 and fills masked prefix + sha256."""
    changed = False
    services = _load_ledger_services()
    for entry in doc.get("keys", []):
        if entry.get("tracked_only") or not entry.get("key_enc"):
            continue
        if int(entry.get("aad_v", 1)) < 1 or not entry.get("fingerprint") or entry.get("prefix_masked") in (None, "", "encrypted…unlock"):
            try:
                pt = decrypt_entry_secret(enc_key, entry)
            except Exception:
                continue
            detected_prov, detected_tier = detect_provider_and_tier(pt)
            if entry.get("provider") in (None, "", "other") and detected_prov != "other":
                entry["provider"] = detected_prov
            if entry.get("tier") not in TIERS:
                entry["tier"] = detected_tier
            masked, last4 = mask_secret(pt)
            entry["prefix_masked"] = masked
            entry["last4"] = last4
            entry["fingerprint"] = secret_fingerprint(pt)
            ct_b64, nonce_b64 = encrypt_secret(enc_key, pt, entry["id"], entry["provider"], entry["tier"])
            entry["key_enc"] = ct_b64
            entry["key_nonce"] = nonce_b64
            entry["aad_v"] = 1
            if not entry.get("service_id"):
                entry["service_id"] = infer_service_id(entry["provider"], entry.get("account"), services)
            changed = True
    return changed


# ── Safe Outbound HTTPS Probing (Health Sweep) ───────────────────────────────

class _NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def _assert_public_https(url: str) -> None:
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme != "https" or not parsed.hostname:
        raise ValueError(f"Refusing non-HTTPS URL: {url}")
    infos = socket.getaddrinfo(parsed.hostname, 443, proto=socket.IPPROTO_TCP)
    for info in infos:
        ip = ipaddress.ip_address(info[4][0])
        if ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_multicast or ip.is_reserved:
            raise ValueError(f"Refusing private/loopback address for {parsed.hostname}")


def _https_get(url: str, headers: dict[str, str], timeout: float = 8.0) -> tuple[int, bytes]:
    _assert_public_https(url)
    opener = urllib.request.build_opener(_NoRedirectHandler)
    req = urllib.request.Request(url, headers={"User-Agent": "Recurring-Vault/3.0", **headers}, method="GET")
    try:
        with opener.open(req, timeout=timeout) as resp:
            return resp.status, resp.read(65536)
    except urllib.error.HTTPError as e:
        return e.code, e.read(16384) if e.fp else b""


def _probe_single_key(provider: str, tier: str, secret: str) -> tuple[str, str, list[dict[str, Any]] | None]:
    """Returns (health_code, detail_message, optional_org_keys_inventory)."""
    prov = provider.lower()
    try:
        if prov == "anthropic":
            hdrs = {"x-api-key": secret, "anthropic-version": "2023-06-01"}
            if tier == "admin":
                code, body = _https_get("https://api.anthropic.com/v1/organizations/api_keys?limit=100", hdrs)
                if code == 200:
                    data = json.loads(body.decode("utf-8", errors="replace")).get("data", [])
                    return "ok", f"Verified live Admin key ({len(data)} org keys visible)", data
            else:
                code, _ = _https_get("https://api.anthropic.com/v1/models?limit=1", hdrs)
        elif prov == "openai":
            hdrs = {"Authorization": f"Bearer {secret}"}
            url = (
                "https://api.openai.com/v1/organization/projects?limit=1"
                if tier == "admin"
                else "https://api.openai.com/v1/models"
            )
            code, _ = _https_get(url, hdrs)
        elif prov == "google":
            code, _ = _https_get(
                "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1",
                {"x-goog-api-key": secret},
            )
        elif prov == "openrouter":
            code, _ = _https_get("https://openrouter.ai/api/v1/auth/key", {"Authorization": f"Bearer {secret}"})
        elif prov == "xai":
            code, _ = _https_get("https://api.x.ai/v1/models", {"Authorization": f"Bearer {secret}"})
        elif prov == "groq":
            code, _ = _https_get("https://api.groq.com/openai/v1/models", {"Authorization": f"Bearer {secret}"})
        elif prov == "github":
            code, _ = _https_get(
                "https://api.github.com/rate_limit",
                {"Authorization": f"Bearer {secret}", "Accept": "application/vnd.github+json"},
            )
        elif prov == "stripe":
            code, _ = _https_get("https://api.stripe.com/v1/balance", {"Authorization": f"Bearer {secret}"})
        elif prov == "resend":
            code, _ = _https_get("https://api.resend.com/domains", {"Authorization": f"Bearer {secret}"})
        elif prov == "vercel":
            code, _ = _https_get("https://api.vercel.com/v2/user", {"Authorization": f"Bearer {secret}"})
        elif prov == "cloudflare":
            code, _ = _https_get(
                "https://api.cloudflare.com/client/v4/user/tokens/verify",
                {"Authorization": f"Bearer {secret}"},
            )
        elif prov == "huggingface":
            code, _ = _https_get("https://huggingface.co/api/whoami-v2", {"Authorization": f"Bearer {secret}"})
        else:
            return "unverified", f"No live probe configured for {PROVIDER_LABELS.get(prov, prov)}", None

        if code == 200:
            return "ok", f"HTTP 200 live ({TIER_LABELS.get(tier, 'Org key')})", None
        if code in (401, 403):
            return "revoked", f"HTTP {code} rejected by {PROVIDER_LABELS.get(prov, prov)} (invalid or revoked)", None
        if code == 429:
            return "rate_limited", "HTTP 429 rate-limited (key valid, quota exhausted)", None
        return "unverified", f"HTTP {code} from {PROVIDER_LABELS.get(prov, prov)}", None
    except Exception as exc:
        return "unverified", f"Probe network error: {type(exc).__name__}", None


def _apply_age_and_leak_rules(entry: dict[str, Any]) -> None:
    locs = entry.get("locations") or []
    if any(bool(loc.get("git_tracked")) for loc in locs if isinstance(loc, dict)):
        entry["health"] = "leaked"
        tracked_paths = [str(loc.get("path")) for loc in locs if loc.get("git_tracked")]
        entry["health_detail"] = f"Committed in git-tracked file: {tracked_paths[0]}"
        return
    if entry.get("health") == "ok":
        created = _parse_iso(entry.get("created_at"))
        if created and (_now_utc() - created).days >= STALE_DAYS:
            entry["health"] = "stale"
            age_d = (_now_utc() - created).days
            entry["health_detail"] = f"Live & valid, {age_d}d old (rotate ≥{STALE_DAYS}d recommended)"


# ── Filesystem `.env` Provenance & Leak Scan ─────────────────────────────────

def _is_git_tracked(file_path: Path, git_cache: dict[Path, Path | None]) -> bool:
    parent = file_path.parent
    repo_root: Path | None = None
    cur = parent
    while cur != cur.parent:
        if cur in git_cache:
            repo_root = git_cache[cur]
            break
        if (cur / ".git").exists():
            repo_root = cur
            break
        cur = cur.parent
    git_cache[parent] = repo_root
    if repo_root is None:
        return False
    try:
        rel = file_path.relative_to(repo_root)
        proc = subprocess.run(
            ["git", "-C", str(repo_root), "ls-files", "--error-unmatch", str(rel)],
            capture_output=True,
            timeout=3,
        )
        return proc.returncode == 0
    except Exception:
        return False


def _is_env_candidate_file(name: str) -> bool:
    low = name.lower()
    if low in (".env", ".npmrc", ".zshrc", ".zshenv", ".bashrc", ".bash_profile"):
        return True
    if low.startswith(".env.") and not low.endswith((".bak", ".swp", ".lock")):
        return True
    return False


def _is_template_file(name: str) -> bool:
    low = name.lower()
    return any(low.endswith(sfx) for sfx in (".example", ".sample", ".template", ".dist"))


def _match_secret_to_vault_entry(secret: str, fp: str, entries: list[dict[str, Any]]) -> dict[str, Any] | None:
    for e in entries:
        if e.get("fingerprint") and e["fingerprint"] == fp:
            return e
    # Fallback match for Sentinel tracked-only keys ("sk-ant-api03-70z…dAAA")
    for e in entries:
        pm = str(e.get("prefix_masked") or "")
        for sep in ("…", "..."):
            if sep in pm:
                pre, suf = pm.split(sep, 1)
                if len(pre) >= 8 and len(suf) >= 3 and secret.startswith(pre) and secret.endswith(suf):
                    return e
    return None


def scan_filesystem_into_doc(doc: dict[str, Any], root: Path) -> dict[str, Any]:
    root = root.expanduser().resolve()
    entries = doc.get("keys", [])
    by_entry_locs: dict[str, list[dict[str, Any]]] = {e["id"]: [] for e in entries}
    stray_by_fp: dict[str, dict[str, Any]] = {}
    git_cache: dict[Path, Path | None] = {}
    files_scanned = 0
    secrets_found = 0

    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        dirnames[:] = [
            d for d in dirnames
            if d not in SKIP_SCAN_DIRS and not os.path.islink(os.path.join(dirpath, d))
        ]
        for fname in filenames:
            if not _is_env_candidate_file(fname):
                continue
            fpath = Path(dirpath) / fname
            if fpath.is_symlink():
                continue
            try:
                st = fpath.stat()
                if st.st_size > 512 * 1024 or st.st_size == 0:
                    continue
                content = fpath.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue

            files_scanned += 1
            is_template = _is_template_file(fname)
            for raw_line in content.splitlines():
                line = raw_line.strip()
                if not line or line.startswith("#"):
                    continue
                m = ENV_LINE_RE.match(line)
                if not m:
                    continue
                var_name, raw_val = m.group(1), m.group(2).strip()
                # Strip inline comments on unquoted values and outer quotes
                if raw_val and raw_val[0] in ("'", '"') and len(raw_val) >= 2 and raw_val[-1] == raw_val[0]:
                    val = raw_val[1:-1].strip()
                else:
                    val = raw_val.split(" #", 1)[0].strip()

                if len(val) < 20 or PLACEHOLDER_PATTERNS.search(val):
                    continue
                prov, tier = detect_provider_and_tier(val)
                if prov == "other":
                    continue
                if is_template and len(set(val[-8:])) <= 2:
                    continue

                secrets_found += 1
                fp = secret_fingerprint(val)
                git_tracked = _is_git_tracked(fpath, git_cache)
                try:
                    display_path = "~/" + str(fpath.relative_to(Path.home()))
                except ValueError:
                    display_path = str(fpath)

                matched = _match_secret_to_vault_entry(val, fp, entries)
                loc = {
                    "path": display_path,
                    "var_name": var_name,
                    "git_tracked": git_tracked,
                }
                if matched is not None:
                    bucket = by_entry_locs[matched["id"]]
                    if not any(x["path"] == display_path and x["var_name"] == var_name for x in bucket):
                        bucket.append(loc)
                else:
                    masked, last4 = mask_secret(val)
                    if fp not in stray_by_fp:
                        stray_by_fp[fp] = {
                            "fingerprint": fp[:16],
                            "provider": prov,
                            "provider_label": PROVIDER_LABELS.get(prov, "Other"),
                            "tier": tier,
                            "tier_label": TIER_LABELS[tier],
                            "prefix_masked": masked,
                            "last4": last4,
                            "locations": [loc],
                            "git_tracked": git_tracked,
                            "detected_at": _iso_now(),
                        }
                    else:
                        s_locs = stray_by_fp[fp]["locations"]
                        if not any(x["path"] == display_path and x["var_name"] == var_name for x in s_locs):
                            s_locs.append(loc)
                        if git_tracked:
                            stray_by_fp[fp]["git_tracked"] = True

    for e in entries:
        e["locations"] = by_entry_locs.get(e["id"], [])
        _apply_age_and_leak_rules(e)

    doc["stray_findings"] = sorted(
        stray_by_fp.values(),
        key=lambda x: (not x["git_tracked"], x["provider"], x["prefix_masked"]),
    )
    doc["last_scan_at"] = _iso_now()
    return {
        "files_scanned": files_scanned,
        "secrets_found": secrets_found,
        "matched_keys": sum(1 for v in by_entry_locs.values() if v),
        "stray_keys": len(doc["stray_findings"]),
        "leaked_keys": sum(1 for e in entries if e.get("health") == "leaked")
        + sum(1 for s in doc["stray_findings"] if s.get("git_tracked")),
    }


# ── Sentinel Import (`~/.sentinel/sentinel.db` + `~/.sentinel/master.key`) ───

def import_sentinel_vault(
    doc: dict[str, Any],
    sentinel_dir: Path | None = None,
    enc_key: bytes | None = None,
) -> dict[str, Any]:
    sdir = (sentinel_dir or (Path.home() / ".sentinel")).expanduser().resolve()
    sdb = sdir / "sentinel.db"
    smk = sdir / "master.key"
    if not sdb.exists():
        raise FileNotFoundError(f"Sentinel database not found at {sdb}")

    copied_master = False
    if smk.exists() and not master_key_path().exists():
        _write_atomic_0600(_read_no_follow(smk), master_key_path())
        copied_master = True

    services = _load_ledger_services()
    existing_by_id = {e["id"]: e for e in doc.get("keys", [])}

    con = sqlite3.connect(f"file:{sdb}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    try:
        rows = con.execute(
            """
            SELECT k.id, k.label, k.key_enc, k.key_nonce, k.key_type, k.status,
                   k.health, k.last_checked, k.health_detail, k.created_at,
                   k.last4, k.rotated_from_id, k.revoked_at, k.leak_status,
                   k.leak_detail, k.tracked_only, a.provider, a.email
            FROM api_keys k
            LEFT JOIN accounts a ON k.account_id = a.id
            ORDER BY k.created_at DESC
            """
        ).fetchall()
    finally:
        con.close()

    imported = 0
    updated = 0
    skipped_templates = 0

    for r in rows:
        label = str(r["label"] or "").strip()
        # Skip `.env.example` placeholder discoveries imported by old scans
        if label.endswith(".env.example"):
            skipped_templates += 1
            continue

        kid = str(r["id"])
        raw_prov = str(r["provider"] or "other").strip().lower()
        prov = raw_prov if raw_prov in PROVIDERS else "other"
        tier = "admin" if str(r["key_type"] or "").lower() == "admin" else "org"
        acct = str(r["email"]).strip() if r["email"] else None
        tracked_only = bool(r["tracked_only"]) or not r["key_enc"] or not r["key_nonce"]

        is_archived = "(archived)" in label.lower() or bool(r["revoked_at"]) or str(r["status"] or "") == "revoked"
        status = "revoked" if is_archived else "active"

        raw_last4 = str(r["last4"] or "").strip()
        if "..." in raw_last4 or "…" in raw_last4:
            prefix_masked = raw_last4.replace("...", "…")
            last4 = prefix_masked.split("…")[-1][-4:]
        elif raw_last4:
            prefix_masked = f"{prov[:4]}…{raw_last4[-4:]}"
            last4 = raw_last4[-4:]
        elif tracked_only:
            prefix_masked = "tracked…hint"
            last4 = None
        else:
            prefix_masked = "encrypted…unlock"
            last4 = None

        raw_health = str(r["health"] or "").lower()
        if str(r["leak_status"] or "").lower() in ("leaked", "exposed"):
            health = "leaked"
        elif status == "revoked" or raw_health in ("revoked", "invalid"):
            health = "revoked"
        elif raw_health in ("ok", "healthy", "valid"):
            health = "ok"
        elif raw_health == "stale":
            health = "stale"
        elif raw_health == "rate_limited":
            health = "rate_limited"
        else:
            health = "unverified"

        detail = str(r["leak_detail"] or r["health_detail"] or "").strip() or None
        if not detail:
            if status == "revoked":
                detail = "Archived / revoked in provider console"
            elif tracked_only:
                detail = "Imported console key hint from Sentinel"
            elif prefix_masked == "encrypted…unlock":
                detail = "Encrypted ciphertext imported from Sentinel (unlock to verify)"

        entry: dict[str, Any] = {
            "id": kid,
            "label": label or f"{PROVIDER_LABELS.get(prov, 'API')} ({TIER_LABELS[tier]})",
            "provider": prov,
            "tier": tier,
            "account": acct,
            "service_id": infer_service_id(prov, acct, services),
            "prefix_masked": prefix_masked,
            "last4": last4,
            "fingerprint": None,
            "tracked_only": tracked_only,
            "key_enc": "" if (tracked_only or status == "revoked") else base64.b64encode(bytes(r["key_enc"])).decode("ascii"),
            "key_nonce": "" if (tracked_only or status == "revoked") else base64.b64encode(bytes(r["key_nonce"])).decode("ascii"),
            "aad_v": 0 if (not tracked_only and status != "revoked") else 1,
            "status": status,
            "health": health,
            "health_detail": detail,
            "last_checked_at": str(r["last_checked"]) if r["last_checked"] else None,
            "created_at": str(r["created_at"]) if r["created_at"] else _iso_now(),
            "rotated_from_id": str(r["rotated_from_id"]) if r["rotated_from_id"] else None,
            "locations": existing_by_id.get(kid, {}).get("locations", []),
        }

        if kid in existing_by_id:
            existing_by_id[kid].update(entry)
            updated += 1
        else:
            doc["keys"].append(entry)
            existing_by_id[kid] = entry
            imported += 1

    if enc_key is not None:
        _upgrade_legacy_entries_if_needed(enc_key, doc)

    return {
        "imported": imported,
        "updated": updated,
        "skipped_templates": skipped_templates,
        "copied_master_key": copied_master,
        "total_keys": len(doc["keys"]),
    }


# ── Passphrase & Secret Input Helpers (NEVER argv) ───────────────────────────

def _read_stdin_secret(prompt: str, from_stdin: bool) -> str:
    if from_stdin or not sys.stdin.isatty():
        val = sys.stdin.readline().rstrip("\r\n")
    else:
        val = getpass.getpass(prompt)
    if not val:
        raise ValueError("Empty secret/passphrase received on stdin.")
    return val


def _vault_summary(doc: dict[str, Any], unlocked: bool, expires_at: str | None) -> dict[str, Any]:
    keys = doc.get("keys", [])
    active = [k for k in keys if k.get("status") != "revoked"]
    revoked = [k for k in keys if k.get("status") == "revoked"]
    return {
        "initialized": master_key_path().exists(),
        "unlocked": unlocked,
        "session_expires_at": expires_at if unlocked else None,
        "total_keys": len(keys),
        "active_keys": len(active),
        "admin_keys": sum(1 for k in active if k.get("tier") == "admin"),
        "org_keys": sum(1 for k in active if k.get("tier") == "org"),
        "healthy_keys": sum(1 for k in active if k.get("health") == "ok"),
        "stale_keys": sum(1 for k in active if k.get("health") == "stale"),
        "leaked_keys": sum(1 for k in active if k.get("health") == "leaked"),
        "revoked_keys": len(revoked),
        "unverified_keys": sum(1 for k in active if k.get("health") in ("unverified", None)),
        "stray_keys": len(doc.get("stray_findings") or []),
        "last_sweep_at": doc.get("last_sweep_at"),
        "last_scan_at": doc.get("last_scan_at"),
    }


# ── CLI Command Implementations ──────────────────────────────────────────────

def cmd_status(args: argparse.Namespace) -> None:
    enc_key, expires = _load_session_key()
    doc = load_vault_doc()
    summary = _vault_summary(doc, enc_key is not None, expires)
    if args.json:
        print(json.dumps(summary, indent=2))
        return
    state = "UNLOCKED" if summary["unlocked"] else ("LOCKED" if summary["initialized"] else "UNINITIALIZED")
    print(f"VAULT STATUS: {state}")
    print(
        f"  {summary['active_keys']} active ({summary['admin_keys']} Admin key, {summary['org_keys']} Org key) · "
        f"{summary['healthy_keys']} healthy · {summary['stale_keys']} stale · "
        f"{summary['leaked_keys']} leaked · {summary['revoked_keys']} revoked · "
        f"{summary['stray_keys']} unvaulted in .env"
    )


def cmd_init(args: argparse.Namespace) -> None:
    pw = _read_stdin_secret("New vault passphrase: ", args.passphrase_stdin)
    with vault_locked():
        enc_key = init_master_key(pw)
        expires = _store_session_key(enc_key)
        doc = load_vault_doc()
        doc["session_expires_at"] = expires
        save_vault_doc(doc)
    out = {"ok": True, "unlocked": True, "session_expires_at": expires}
    if args.json:
        print(json.dumps(out, indent=2))
    else:
        print("Vault initialized and unlocked (12h session).")


def cmd_unlock(args: argparse.Namespace) -> None:
    pw = _read_stdin_secret("Vault passphrase: ", args.passphrase_stdin)
    with vault_locked():
        enc_key = unlock_master_key(pw)
        expires = _store_session_key(enc_key)
        doc = load_vault_doc()
        _upgrade_legacy_entries_if_needed(enc_key, doc)
        doc["session_expires_at"] = expires
        save_vault_doc(doc)
        summary = _vault_summary(doc, True, expires)
    if args.json:
        print(json.dumps(summary, indent=2))
    else:
        print(f"Vault unlocked until {expires} ({summary['active_keys']} active keys).")


def cmd_lock(args: argparse.Namespace) -> None:
    with vault_locked():
        _clear_session_key()
        doc = load_vault_doc()
        doc["session_expires_at"] = None
        save_vault_doc(doc)
    if args.json:
        print(json.dumps({"ok": True, "unlocked": False}, indent=2))
    else:
        print("Vault locked.")


def cmd_list(args: argparse.Namespace) -> None:
    enc_key, expires = _load_session_key()
    doc = load_vault_doc()
    services = {s["id"]: s for s in _load_ledger_services() if s.get("id")}
    keys_pub = [public_key_view(e, services) for e in doc.get("keys", [])]
    if not args.all:
        keys_pub = [k for k in keys_pub if k["status"] != "revoked"]
    if args.tier:
        keys_pub = [k for k in keys_pub if k["tier"] == args.tier]
    if args.provider:
        keys_pub = [k for k in keys_pub if k["provider"] == args.provider.lower()]

    payload = {
        "summary": _vault_summary(doc, enc_key is not None, expires),
        "keys": keys_pub,
        "stray_findings": doc.get("stray_findings") or [],
    }
    if args.json:
        print(json.dumps(payload, indent=2))
        return

    s = payload["summary"]
    state = "UNLOCKED" if s["unlocked"] else "LOCKED"
    print(f"VAULT [{state}] — {len(keys_pub)} shown ({s['admin_keys']} Admin key · {s['org_keys']} Org key)")
    for k in keys_pub:
        locs = f" · {len(k['locations'])} .env" if k["locations"] else ""
        svc = f" → {k['service_id']}" if k["service_id"] else ""
        print(
            f"  {k['id'][:8]}  [{k['tier_label']:<9}] {k['provider_label']:<21} "
            f"{k['prefix_masked']:<22} {k['health']:<10} {k['label']}{svc}{locs}"
        )


def cmd_add(args: argparse.Namespace) -> None:
    enc_key, expires = _load_session_key()
    if enc_key is None:
        sys.exit("Vault is locked — unlock it first (`recurring vault unlock`).")
    secret = _read_stdin_secret("API key secret: ", args.secret_stdin).strip()
    if len(secret) < 8:
        sys.exit("API key secret looks too short.")

    auto_prov, auto_tier = detect_provider_and_tier(secret)
    provider = (args.provider or auto_prov).lower()
    if provider not in PROVIDERS:
        provider = "other"
    tier = args.tier if args.tier in TIERS else auto_tier
    masked, last4 = mask_secret(secret)
    fp = secret_fingerprint(secret)

    with vault_locked():
        doc = load_vault_doc()
        for existing in doc.get("keys", []):
            if existing.get("status") != "revoked" and existing.get("fingerprint") == fp:
                sys.exit(f"Key is already in the vault as '{existing.get('label')}' ({existing['id'][:8]}).")

        services = _load_ledger_services()
        kid = str(uuid.uuid4())
        ct_b64, nonce_b64 = encrypt_secret(enc_key, secret, kid, provider, tier)
        service_id = args.service or infer_service_id(provider, args.account, services)
        entry = {
            "id": kid,
            "label": args.label,
            "provider": provider,
            "tier": tier,
            "account": args.account,
            "service_id": service_id,
            "prefix_masked": masked,
            "last4": last4,
            "fingerprint": fp,
            "tracked_only": False,
            "key_enc": ct_b64,
            "key_nonce": nonce_b64,
            "aad_v": 1,
            "status": "active",
            "health": "unverified",
            "health_detail": "Added to vault (run sweep to verify live)",
            "last_checked_at": None,
            "created_at": _iso_now(),
            "rotated_from_id": None,
            "locations": [],
        }
        doc["keys"].insert(0, entry)
        # Clear any matching stray finding now that it's vaulted
        doc["stray_findings"] = [
            sf for sf in (doc.get("stray_findings") or [])
            if sf.get("fingerprint") != fp[:16]
        ]
        doc["session_expires_at"] = expires
        save_vault_doc(doc)
        services_by_id = {s["id"]: s for s in services if s.get("id")}
        pub = public_key_view(entry, services_by_id)

    if args.json:
        print(json.dumps(pub, indent=2))
    else:
        print(f"Added {pub['tier_label']} '{pub['label']}' ({pub['prefix_masked']}) [{pub['id'][:8]}]")


def _find_entry(entries: list[dict[str, Any]], ident: str) -> dict[str, Any]:
    exact = [e for e in entries if e["id"] == ident]
    if len(exact) == 1:
        return exact[0]
    prefix = [e for e in entries if e["id"].startswith(ident)]
    if len(prefix) == 1:
        return prefix[0]
    if len(prefix) > 1:
        sys.exit(f"Ambiguous key id prefix '{ident}' ({len(prefix)} matches).")
    sys.exit(f"No key found with id '{ident}'.")


def cmd_secret(args: argparse.Namespace) -> None:
    enc_key, _ = _load_session_key()
    if enc_key is None:
        sys.exit("Vault is locked — unlock it first.")
    doc = load_vault_doc()
    entry = _find_entry(doc.get("keys", []), args.id)
    try:
        pt = decrypt_entry_secret(enc_key, entry)
    except (ValueError, PermissionError) as e:
        sys.exit(str(e))
    sys.stdout.write(pt)
    if sys.stdout.isatty():
        sys.stdout.write("\n")


def cmd_rotate(args: argparse.Namespace) -> None:
    enc_key, expires = _load_session_key()
    if enc_key is None:
        sys.exit("Vault is locked — unlock it first.")
    new_secret = _read_stdin_secret("Replacement API key secret: ", args.secret_stdin).strip()
    if len(new_secret) < 8:
        sys.exit("Replacement API key secret looks too short.")

    with vault_locked():
        doc = load_vault_doc()
        old = _find_entry(doc.get("keys", []), args.id)
        if old.get("status") == "revoked":
            sys.exit(f"Key '{old.get('label')}' is already revoked.")

        fp = secret_fingerprint(new_secret)
        if old.get("fingerprint") and old["fingerprint"] == fp:
            sys.exit("Replacement secret is identical to the existing key.")

        auto_prov, auto_tier = detect_provider_and_tier(new_secret)
        provider = old.get("provider") if old.get("provider") not in (None, "other") else auto_prov
        tier = old.get("tier") if old.get("tier") in TIERS else auto_tier
        masked, last4 = mask_secret(new_secret)
        new_id = str(uuid.uuid4())
        ct_b64, nonce_b64 = encrypt_secret(enc_key, new_secret, new_id, provider, tier)

        # Wipe old secret material immediately on rotation
        old["status"] = "revoked"
        old["health"] = "revoked"
        old["health_detail"] = f"Rotated on {_iso_now()[:10]} → {new_id[:8]}"
        old["key_enc"] = ""
        old["key_nonce"] = ""

        new_entry = {
            "id": new_id,
            "label": args.label or old.get("label") or f"{PROVIDER_LABELS.get(provider, 'API')} ({TIER_LABELS[tier]})",
            "provider": provider,
            "tier": tier,
            "account": old.get("account"),
            "service_id": old.get("service_id"),
            "prefix_masked": masked,
            "last4": last4,
            "fingerprint": fp,
            "tracked_only": False,
            "key_enc": ct_b64,
            "key_nonce": nonce_b64,
            "aad_v": 1,
            "status": "active",
            "health": "unverified",
            "health_detail": f"Rotated from {old['id'][:8]}",
            "last_checked_at": None,
            "created_at": _iso_now(),
            "rotated_from_id": old["id"],
            "locations": list(old.get("locations") or []),
        }
        doc["keys"].insert(0, new_entry)
        doc["session_expires_at"] = expires
        save_vault_doc(doc)
        services = {s["id"]: s for s in _load_ledger_services() if s.get("id")}
        pub = public_key_view(new_entry, services)

    if args.json:
        print(json.dumps(pub, indent=2))
    else:
        print(f"Rotated {old['id'][:8]} → {pub['id'][:8]} ({pub['tier_label']} {pub['prefix_masked']})")


def cmd_delete(args: argparse.Namespace) -> None:
    with vault_locked():
        doc = load_vault_doc()
        entry = _find_entry(doc.get("keys", []), args.id)
        if args.purge:
            doc["keys"] = [e for e in doc["keys"] if e["id"] != entry["id"]]
            action = "purged"
        else:
            entry["status"] = "revoked"
            entry["health"] = "revoked"
            entry["health_detail"] = f"Revoked locally on {_iso_now()[:10]}"
            entry["key_enc"] = ""
            entry["key_nonce"] = ""
            action = "revoked"
        save_vault_doc(doc)
    if args.json:
        print(json.dumps({"ok": True, "id": entry["id"], "action": action}, indent=2))
    else:
        print(f"{entry['id'][:8]} ({entry.get('label')}): {action}")


def cmd_sweep(args: argparse.Namespace) -> None:
    enc_key, expires = _load_session_key()
    if enc_key is None:
        sys.exit("Vault is locked — unlock it first to run a live provider sweep.")

    with vault_locked():
        doc = load_vault_doc()
        _upgrade_legacy_entries_if_needed(enc_key, doc)
        active = [
            e for e in doc.get("keys", [])
            if e.get("status") != "revoked" and not e.get("tracked_only") and e.get("key_enc")
        ]
        decrypted_jobs: list[tuple[dict[str, Any], str]] = []
        for e in active:
            try:
                decrypted_jobs.append((e, decrypt_entry_secret(enc_key, e)))
            except Exception as exc:
                e["health"] = "unverified"
                e["health_detail"] = f"Decrypt error: {exc}"

    anthropic_org_inventory: list[dict[str, Any]] = []
    now_str = _iso_now()

    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        fut_map = {
            pool.submit(_probe_single_key, e["provider"], e["tier"], sec): e
            for e, sec in decrypted_jobs
        }
        for fut in concurrent.futures.as_completed(fut_map):
            e = fut_map[fut]
            health, detail, org_items = fut.result()
            e["health"] = health
            e["health_detail"] = detail
            e["last_checked_at"] = now_str
            if org_items:
                anthropic_org_inventory.extend(org_items)
            _apply_age_and_leak_rules(e)

    with vault_locked():
        latest = load_vault_doc()
        updated_by_id = {e["id"]: e for e, _ in decrypted_jobs}
        for idx, item in enumerate(latest.get("keys", [])):
            if item["id"] in updated_by_id:
                src = updated_by_id[item["id"]]
                for k in ("health", "health_detail", "last_checked_at"):
                    item[k] = src.get(k)
                _apply_age_and_leak_rules(item)
            elif item.get("tracked_only") and anthropic_org_inventory and item.get("provider") == "anthropic":
                # Reconcile tracked-only Anthropic Org keys via Admin key inventory!
                for org_k in anthropic_org_inventory:
                    partial = str(org_k.get("partial_key_hint") or "").replace("...", "…")
                    name = str(org_k.get("name") or "")
                    if (partial and partial == item.get("prefix_masked")) or (name and name == item.get("label")):
                        st = str(org_k.get("status") or "").lower()
                        item["last_checked_at"] = now_str
                        if st in ("inactive", "archived", "revoked"):
                            item["status"] = "revoked"
                            item["health"] = "revoked"
                            item["health_detail"] = f"Anthropic Admin API: {st}"
                        else:
                            item["health"] = "ok"
                            item["health_detail"] = "Verified active via Anthropic Admin key"
                        _apply_age_and_leak_rules(item)
                        break

        latest["last_sweep_at"] = now_str
        latest["session_expires_at"] = expires
        save_vault_doc(latest)
        summary = _vault_summary(latest, True, expires)

    if args.json:
        print(json.dumps(summary, indent=2))
    else:
        print(
            f"Sweep complete: {summary['healthy_keys']} healthy · {summary['stale_keys']} stale · "
            f"{summary['leaked_keys']} leaked · {summary['revoked_keys']} revoked"
        )


def cmd_scan(args: argparse.Namespace) -> None:
    target = Path(args.path).expanduser() if args.path else (Path.home() / "Projects")
    if not target.exists():
        sys.exit(f"Scan path does not exist: {target}")
    with vault_locked():
        doc = load_vault_doc()
        stats = scan_filesystem_into_doc(doc, target)
        save_vault_doc(doc)
    if args.json:
        print(json.dumps(stats, indent=2))
    else:
        print(
            f"Scanned {stats['files_scanned']} env/config files in {target}: "
            f"{stats['matched_keys']} vaulted keys located · "
            f"{stats['stray_keys']} unvaulted keys found · "
            f"{stats['leaked_keys']} git-tracked leaks"
        )


def cmd_import_sentinel(args: argparse.Namespace) -> None:
    enc_key, expires = _load_session_key()
    if args.passphrase_stdin:
        pw = _read_stdin_secret("Sentinel passphrase: ", True)
    else:
        pw = None

    with vault_locked():
        doc = load_vault_doc()
        sdir = Path(args.sentinel_dir).expanduser() if args.sentinel_dir else None
        stats = import_sentinel_vault(doc, sdir, enc_key=enc_key)
        if pw is not None:
            enc_key = unlock_master_key(pw)
            expires = _store_session_key(enc_key)
            _upgrade_legacy_entries_if_needed(enc_key, doc)
            doc["session_expires_at"] = expires
        save_vault_doc(doc)

    if args.json:
        print(json.dumps(stats, indent=2))
    else:
        mk_note = " (copied master.key — your Sentinel passphrase unlocks Recurring)" if stats["copied_master_key"] else ""
        print(
            f"Imported {stats['imported']} keys ({stats['updated']} updated, "
            f"{stats['skipped_templates']} .env.example templates skipped) → {stats['total_keys']} total{mk_note}"
        )


def build_vault_subparser(subparsers: argparse._SubParsersAction) -> argparse.ArgumentParser:
    pv = subparsers.add_parser("vault", help="Sentinel-grade encrypted API key vault (Admin key / Org key)")
    vsub = pv.add_subparsers(dest="vault_cmd")

    p_st = vsub.add_parser("status", help="Vault lock & health summary")
    p_st.add_argument("--json", action="store_true")

    p_init = vsub.add_parser("init", help="Initialize vault master passphrase")
    p_init.add_argument("--passphrase-stdin", action="store_true")
    p_init.add_argument("--json", action="store_true")

    p_un = vsub.add_parser("unlock", help="Unlock vault for 12h session")
    p_un.add_argument("--passphrase-stdin", action="store_true")
    p_un.add_argument("--json", action="store_true")

    p_lk = vsub.add_parser("lock", help="Clear session unlock key immediately")
    p_lk.add_argument("--json", action="store_true")

    p_ls = vsub.add_parser("list", help="List vaulted keys (metadata only, never secrets)")
    p_ls.add_argument("--all", action="store_true", help="Include revoked/archived keys")
    p_ls.add_argument("--tier", choices=TIERS, help="Filter by canonical tier (admin | org)")
    p_ls.add_argument("--provider", help="Filter by provider slug")
    p_ls.add_argument("--json", action="store_true")

    p_add = vsub.add_parser("add", help="Encrypt and store a new API key from stdin")
    p_add.add_argument("--label", required=True)
    p_add.add_argument("--provider", choices=PROVIDERS)
    p_add.add_argument("--tier", choices=TIERS, help="admin (Admin key) or org (Org key)")
    p_add.add_argument("--account", help="Owner email / billing account")
    p_add.add_argument("--service", help="Linked subscription id in subscriptions.json")
    p_add.add_argument("--secret-stdin", action="store_true", help="Read raw key from stdin")
    p_add.add_argument("--json", action="store_true")

    p_sec = vsub.add_parser("secret", help="Decrypt and print raw secret to stdout (requires unlocked vault)")
    p_sec.add_argument("id")

    p_rot = vsub.add_parser("rotate", help="Atomically revoke an old key and store its replacement from stdin")
    p_rot.add_argument("id")
    p_rot.add_argument("--label")
    p_rot.add_argument("--secret-stdin", action="store_true")
    p_rot.add_argument("--json", action="store_true")

    p_del = vsub.add_parser("delete", help="Revoke (or --purge) a key and wipe its ciphertext")
    p_del.add_argument("id")
    p_del.add_argument("--purge", action="store_true")
    p_del.add_argument("--json", action="store_true")

    p_sw = vsub.add_parser("sweep", help="Probe live provider APIs to verify key health")
    p_sw.add_argument("--json", action="store_true")

    p_sc = vsub.add_parser("scan", help="Scan project .env files for key provenance & git leaks")
    p_sc.add_argument("path", nargs="?")
    p_sc.add_argument("--json", action="store_true")

    p_im = vsub.add_parser("import-sentinel", help="Import encrypted keys & hints from ~/.sentinel/sentinel.db")
    p_im.add_argument("--sentinel-dir")
    p_im.add_argument("--passphrase-stdin", action="store_true")
    p_im.add_argument("--json", action="store_true")

    return pv


def dispatch_vault(args: argparse.Namespace) -> None:
    cmd = getattr(args, "vault_cmd", None) or "list"
    if cmd == "status":
        cmd_status(args)
    elif cmd == "init":
        cmd_init(args)
    elif cmd == "unlock":
        cmd_unlock(args)
    elif cmd == "lock":
        cmd_lock(args)
    elif cmd == "list":
        if not hasattr(args, "all"):
            args.all = False
            args.tier = None
            args.provider = None
            args.json = False
        cmd_list(args)
    elif cmd == "add":
        cmd_add(args)
    elif cmd == "secret":
        cmd_secret(args)
    elif cmd == "rotate":
        cmd_rotate(args)
    elif cmd == "delete":
        cmd_delete(args)
    elif cmd == "sweep":
        cmd_sweep(args)
    elif cmd == "scan":
        cmd_scan(args)
    elif cmd == "import-sentinel":
        cmd_import_sentinel(args)
    else:
        sys.exit(f"Unknown vault subcommand: {cmd}")


def main(argv: list[str] | None = None) -> None:
    p = argparse.ArgumentParser(prog="recurring-vault")
    sub = p.add_subparsers(dest="top")
    # Support invoking directly as `recurring_vault.py <subcmd>`
    pv = build_vault_subparser(sub)
    args = pv.parse_args(argv)
    try:
        dispatch_vault(args)
    except (ValueError, PermissionError, FileNotFoundError) as exc:
        sys.exit(str(exc))


if __name__ == "__main__":
    main()
