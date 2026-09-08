#!/usr/bin/env python3
"""Sync upstream vLLM model context limits into a running Bifrost config store.

Bifrost lists models by querying each provider key's upstream `/v1/models`
endpoint but drops the vLLM `max_model_len` field before serving `/v1/models`
to clients, so a self-hosted vLLM provider never reports context lengths. This
script repairs that by doing three things, using the REAL endpoint URLs stored
(encrypted) in the Bifrost config store:

  1. Query each enabled `vllm` provider key's upstream for the served model
     name(s) and `max_model_len`.
  2. If the upstream model name differs from the configured model name
     (`config_keys.vllm_model_name`), update it (and any explicit model list
     entry that referenced the old name).
  3. Upsert a catalog row in `governance_model_pricing`
     (provider=vllm, mode=chat) so the context limit shows up in future
     `/v1/models` responses (Bifrost's list-models enrichment reads this table).

Secrets are NEVER embedded in this file. At runtime it reads what it needs from
the container/host configuration:

  * Bifrost config-store DB      -> /etc/bifrost/config.db   (env BIFROST_DB)
  * Encryption passphrase + admin -> /etc/bifrost/env          (env BIFROST_ENV)
    (fallback: `docker inspect` on the container's Config.Env)
  * Container name for restart    -> "bifrost"                 (env BIFROST_CONTAINER)

The Argon2id + AES-256-GCM scheme matches framework/encrypt in maximhq/bifrost
(fixed salt "bifrost-encryption-v1-salt-2024", time=1, mem=64MiB, threads=4,
32-byte key; base64 ciphertext = 12-byte nonce || ciphertext || tag).

Requirements on the host: python3, python3-argon2, python3-cryptography.

Usage:

    sudo python3 sync-bifrost-vllm.py            # dry run: show what would change
    sudo python3 sync-bifrost-vllm.py --commit   # apply + restart the container
    sudo python3 sync-bifrost-vllm.py --commit --no-reload   # apply, no restart

Must run as root (the config-store dir is root-owned and the container restart
needs docker). Run it on the Bifrost host, not inside the container.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import sqlite3
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from typing import Optional

try:
    from argon2.low_level import Type as Argon2Type
    from argon2.low_level import hash_secret_raw
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
except ImportError as exc:  # pragma: no cover - host precondition
    sys.exit(f"missing dependency: {exc}. Install python3-argon2 python3-cryptography")

SALT = b"bifrost-encryption-v1-salt-2024"
PROVIDER = "vllm"
CATALOG_MODE = "chat"

DEFAULT_DB = "/etc/bifrost/config.db"
DEFAULT_ENV = "/etc/bifrost/env"
DEFAULT_CONTAINER = "bifrost"


def env_or(key: str, default: str) -> str:
    return os.environ.get(key, default)


def load_passphrase(env_path: str, container: str) -> str:
    """Read BIFROST_ENCRYPTION_KEY from the env file or container env."""
    if os.path.isfile(env_path):
        with open(env_path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line.startswith("#") or "=" not in line:
                    continue
                key, _, value = line.partition("=")
                if key.strip() == "BIFROST_ENCRYPTION_KEY":
                    return value.strip()
    try:
        out = subprocess.run(
            ["docker", "inspect", container, "--format", "{{range .Config.Env}}{{println .}}{{end}}"],
            capture_output=True,
            text=True,
            check=False,
        )
        if out.returncode == 0:
            for line in out.stdout.splitlines():
                if "=" in line:
                    k, _, v = line.partition("=")
                    if k == "BIFROST_ENCRYPTION_KEY":
                        return v.strip()
    except FileNotFoundError:
        pass
    sys.exit("could not find BIFROST_ENCRYPTION_KEY (checked env file and container env)")


def derive_key(passphrase: str) -> bytes:
    return hash_secret_raw(
        passphrase.encode(),
        SALT,
        time_cost=1,
        memory_cost=64 * 1024,
        parallelism=4,
        hash_len=32,
        type=Argon2Type.ID,
    )


def decrypt(secret: Optional[str], key: bytes) -> Optional[str]:
    if not secret:
        return None
    data = base64.b64decode(secret)
    if len(data) < 13:
        return None
    return AESGCM(key).decrypt(data[:12], data[12:], None).decode("utf-8")


def sql_now() -> str:
    # Mirror the RFC3339-ish format Bifrost/GORM stores: no 'T', "+00:00" suffix.
    now = datetime.now(timezone.utc)
    return now.strftime("%Y-%m-%d %H:%M:%S.%f")[:-3] + "+00:00"


def extract_entries(body) -> list[dict]:
    if isinstance(body, list):
        return body
    if isinstance(body, dict):
        for candidate in ("data", "models"):
            value = body.get(candidate)
            if isinstance(value, list):
                return value
    return []


def entry_id(entry: dict) -> Optional[str]:
    if not isinstance(entry, dict):
        return None
    for candidate in ("id", "name"):
        value = entry.get(candidate)
        if isinstance(value, str) and value:
            return value
    return None


def probe_models(base_url: str, api_key: Optional[str]) -> tuple[list[tuple[str, int]], Optional[str]]:
    """Fetch {id, max_model_len} from an upstream OpenAI-compatible server.

    Returns ([(model_id, max_model_len), ...], endpoint_used). Tolerant of the
    URL carrying an optional /v1 suffix. Returns ([], None) when unreachable.
    """
    base = base_url.rstrip("/")
    if base.endswith("/v1"):
        origin = base[: -len("/v1")]
        candidates = [base + "/models", origin + "/v1/models"]
    else:
        candidates = [base + "/v1/models", base + "/models"]

    for endpoint in dict.fromkeys(candidates):  # dedupe, keep order
        req = urllib.request.Request(endpoint, headers={"Accept": "application/json"})
        if api_key:
            req.add_header("Authorization", f"Bearer {api_key}")
        try:
            with urllib.request.urlopen(req, timeout=8) as resp:
                if resp.status != 200:
                    continue
                body = json.load(resp)
        except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError, OSError, json.JSONDecodeError):
            continue

        found = []
        for entry in extract_entries(body):
            mid = entry_id(entry)
            mml = entry.get("max_model_len")
            if mid and isinstance(mml, int) and mml > 0:
                found.append((mid, mml))
        if found:
            return found, endpoint
    return [], None


def collect_keys(conn: sqlite3.Connection) -> list[dict]:
    rows = conn.execute(
        """
        SELECT id, name, enabled, vllm_url, vllm_model_name, models_json, value
        FROM config_keys
        WHERE provider = ?
        ORDER BY id
        """,
        (PROVIDER,),
    ).fetchall()
    keys = []
    for row in rows:
        models = None
        if row[5]:
            try:
                parsed = json.loads(row[5])
                if isinstance(parsed, list):
                    models = parsed
            except json.JSONDecodeError:
                models = None
        keys.append(
            {
                "id": row[0],
                "name": row[1],
                "enabled": bool(row[2]),
                "url_enc": row[3],
                "model_enc": None,
                "model_name": row[4],
                "models_json": models,
                "value_enc": row[6],
                "api_key": None,
                "url": None,
                "upstream": [],  # [(model_id, max_model_len)]
                "exposed": [],   # model_ids this key will actually list
                "primary": None,
                "new_primary": None,
            }
        )
    return keys


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--commit", action="store_true", help="apply changes (default is dry-run)")
    parser.add_argument("--no-reload", action="store_true", help="do not restart the container on --commit")
    args = parser.parse_args()

    if args.commit and os.geteuid() != 0:
        sys.exit("--commit requires root (sudo) to write the config store and restart the container")

    db_path = env_or("BIFROST_DB", DEFAULT_DB)
    env_path = env_or("BIFROST_ENV", DEFAULT_ENV)
    container = env_or("BIFROST_CONTAINER", DEFAULT_CONTAINER)

    passphrase = load_passphrase(env_path, container)
    key = derive_key(passphrase)

    conn = sqlite3.connect(db_path, timeout=15)
    conn.execute("PRAGMA busy_timeout=15000")

    keys = collect_keys(conn)
    conn.close()

    enabled = [k for k in keys if k["enabled"]]
    if not enabled:
        print("no enabled vllm provider keys found")
        return 1

    # 1) Decrypt the real URLs and query each upstream.
    for k in enabled:
        k["url"] = decrypt(k["url_enc"], key)
        k["api_key"] = decrypt(k["value_enc"], key)
        if not k["url"]:
            print(f"  !! {k['name']}: no vllm_url, skipping")
            continue
        models, endpoint = probe_models(k["url"], k["api_key"])
        k["upstream_endpoint"] = endpoint
        k["upstream"] = models
        print(f"== {k['name']}  ({k['url']})")
        if endpoint is None:
            print(f"   !! could not reach upstream, skipping")
            continue
        for mid, mml in models:
            print(f"   {mid}  max_model_len={mml}")

    # Work out the exposed model set per key (models_json filter, else all).
    for k in enabled:
        if not k["upstream"]:
            continue
        upstream_ids = [mid for mid, _ in k["upstream"]]
        allow = k["models_json"]
        if allow and allow != ["*"]:
            exposed = [mid for mid in upstream_ids if mid in allow]
            if not exposed and len(upstream_ids) == 1:
                # Config model list is stale relative to the single served model.
                exposed = upstream_ids
        else:
            exposed = upstream_ids
        k["exposed"] = exposed
        k["primary"] = k["model_name"]
        k["new_primary"] = exposed[0] if exposed else None

    # Context per model: max across endpoints (deterministic if duplicated).
    context_by_model: dict[str, int] = {}
    for k in enabled:
        for mid, mml in k["upstream"]:
            context_by_model[mid] = max(context_by_model.get(mid, 0), mml)

    # Build the catalog rows we want.
    wanted_rows = {}
    for k in enabled:
        for mid in k["exposed"]:
            if mid in context_by_model:
                wanted_rows[(mid, PROVIDER, CATALOG_MODE)] = context_by_model[mid]

    # --------------------------------------------------------------- plan ---
    print("\n--- plan ---")
    key_changes = []
    for k in enabled:
        if not k["upstream"]:
            continue
        renamed = k["new_primary"] and k["new_primary"] != k["model_name"]
        if renamed:
            print(f"UPDATE config_keys {k['name']}: vllm_model_name {k['model_name']!r} -> {k['new_primary']!r}")
        else:
            print(f"config_keys {k['name']}: vllm_model_name OK ({k['model_name']!r})")
        key_changes.append((k, renamed))

    for (model, prov, mode), ctx in sorted(wanted_rows.items()):
        print(f"CATALOG upsert: {model} ({prov}/{mode}) context_length={ctx}")
    print("changes:", len([c for c in key_changes if c[1]]), "key renames,",
          len(wanted_rows), "catalog rows")
    if not args.commit:
        print("\n(dry run — rerun with --commit to apply)")
        return 0

    # ------------------------------------------------------------- apply ---
    conn = sqlite3.connect(db_path, timeout=15)
    conn.execute("PRAGMA busy_timeout=15000")
    touched = False

    active_models = {mid for k in enabled for mid in k["exposed"]}

    for k, renamed in key_changes:
        if not renamed:
            continue
        # Replace the old name with the new one in an explicit allow list.
        new_models = k["models_json"]
        if new_models and new_models != ["*"]:
            new_models = [k["new_primary"] if m == k["model_name"] else m for m in new_models]
        conn.execute(
            "UPDATE config_keys SET vllm_model_name = ?, models_json = ?, updated_at = ? WHERE id = ?",
            (k["new_primary"],
             json.dumps(new_models) if new_models is not None else None,
             sql_now(),
             k["id"]),
        )
        # The old catalog row (if any) is removed by the reconcile step below.
        touched = True

    for (model, prov, mode), ctx in sorted(wanted_rows.items()):
        conn.execute(
            """
            INSERT INTO governance_model_pricing
                (model, base_model, provider, mode, context_length,
                 max_input_tokens, max_output_tokens, is_deprecated)
            VALUES (?, NULL, ?, ?, ?, ?, NULL, 0)
            ON CONFLICT(model, provider, mode) DO UPDATE SET
                context_length = excluded.context_length,
                max_input_tokens = excluded.max_input_tokens,
                max_output_tokens = NULL,
                is_deprecated = 0
            """,
            (model, prov, mode, ctx, ctx),
        )
        touched = True

    conn.commit()
    print("\ncatalog rows now present for provider vllm:")
    for r in conn.execute(
        "SELECT model, provider, mode, context_length, max_input_tokens "
        "FROM governance_model_pricing WHERE provider = ? AND mode = ? ORDER BY model",
        (PROVIDER, CATALOG_MODE),
    ):
        print("   ", r)
    conn.close()

    # Drop stale catalog rows that are no longer exposed by any enabled key
    # (only rows this script owns: vllm/chat). Only when every enabled key was
    # reachable — otherwise a temporarily-down endpoint would lose its rows.
    failed = [k for k in enabled if not k["upstream"]]
    if not failed:
        conn = sqlite3.connect(db_path, timeout=15)
        conn.execute("PRAGMA busy_timeout=15000")
        cur = conn.execute(
            "SELECT model FROM governance_model_pricing WHERE provider = ? AND mode = ?",
            (PROVIDER, CATALOG_MODE),
        )
        stale = [row[0] for row in cur.fetchall() if row[0] not in active_models]
        for model in stale:
            conn.execute(
                "DELETE FROM governance_model_pricing WHERE model = ? AND provider = ? AND mode = ?",
                (model, PROVIDER, CATALOG_MODE),
            )
            print(f"catalog: removed stale row for {model}")
        conn.commit()
        conn.close()
        touched = touched or bool(stale)
    else:
        print(f"note: {len(failed)} key(s) unreachable — skipped stale-row cleanup")

    if not args.no_reload:
        if not touched:
            print("\nno changes — skipping container restart")
        else:
            print(f"\nrestarting container {container} ...")
            subprocess.run(["docker", "restart", container], check=True)
            for _ in range(60):
                out = subprocess.run(
                    ["docker", "inspect", container, "--format", "{{.State.Health.Status}}"],
                    capture_output=True,
                    text=True,
                    check=False,
                ).stdout.strip()
                if out in ("healthy", ""):
                    break
                time.sleep(1)
            print(f"container {container} restarted")
    elif touched:
        print("\n--no-reload given: restart the container manually to load changes")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
