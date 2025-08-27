#!/usr/bin/env python3
"""
End-to-end tests for the Z-Push Zimbra Java Shim endpoints.

What this script verifies (happy-path):
  - ping: basic reachability of the shim endpoint
  - authenticate: can obtain an authToken (and optionally accountId)
  - getfolders: lists folders; picks a target folder for message tests
  - getmessages: lists messages in the chosen folder (may be empty)
  - getmessage: fetches a specific message (only when one exists)

Configuration:
  - YAML file (default: test/shim-tests.yml) with keys:
      base_url: "http://localhost:8080"    # mailboxd base URL
      shim_paths:                           # optional; discovery order
        - "/service/extension/zpush-shim"
        - "/service/zpush-shim"
      account: "user@example.com"          # test account
      password: "APP_OR_USER_PASSWORD"     # prefer app password if 2FA
      protocol: "eas"                      # shim’s expected protocol string
      verify_tls: false                     # true in production (HTTPS)
      preferred_folder: "Inbox"             # target folder preference
      messages_limit: 10                    # list size
      getmessage_format: "html"             # or "plain"

Notes:
  - The script optionally performs a JSON-SOAP AuthRequest to /service/soap to
    obtain ZM_AUTH_TOKEN and csrfToken. Some setups require CSRF for POSTs; the
    script will attach X-Zimbra-Csrf-Token when available.
  - Clear PASS/FAIL lines and a non-zero exit on failure make this suitable for CI.
"""
import argparse
import sys
import time
from typing import Any, Dict, List, Optional

try:
    import yaml
    import requests
except Exception as e:
    # Friendly guidance for missing runtime dependencies
    print("Missing dependency:", e)
    print("Install with: pip install requests pyyaml")
    sys.exit(2)


def deep_get(d: Dict[str, Any], key: str, default=None):
    """Safely navigate a nested dict using a dotted key (e.g., "a.b.c")."""
    cur = d
    for part in key.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return default
        cur = cur[part]
    return cur


def zimbra_json_soap_login(session: requests.Session, base_url: str, verify_tls: bool, account: str, password: str) -> Optional[str]:
    """
    Perform a JSON-SOAP AuthRequest to obtain a login cookie and (optionally) CSRF token.

    Effect:
      - On success, session stores the ZM_AUTH_TOKEN cookie for mailboxd.
      - Returns the csrfToken string when present, else None.
    """
    url = f"{base_url.rstrip('/')}/service/soap"
    body = {
        "Header": {},
        "Body": {
            "AuthRequest": {
                "_jsns": "urn:zimbraAccount",
                "account": {"by": "name", "_content": account},
                "password": password,
            }
        },
    }
    resp = session.post(url, json=body, verify=verify_tls, timeout=15, headers={"Content-Type": "application/json"})
    resp.raise_for_status()
    j = resp.json()
    csrf = deep_get(j, "Body.context.csrfToken") or deep_get(j, "Header.context.csrfToken")
    if not csrf:
        csrf = deep_get(j, "Body.AuthResponse.csrfToken")
    if not session.cookies.get("ZM_AUTH_TOKEN"):
        raise RuntimeError("SOAP login succeeded but ZM_AUTH_TOKEN cookie was not set")
    return csrf


def choose_shim_path(session: requests.Session, base_url: str, paths: List[str], verify_tls: bool) -> str:
    """Try each candidate shim path by posting action=ping; return the first that works."""
    last_err = None
    for p in paths:
        url = f"{base_url.rstrip('/')}{p}"
        try:
            r = session.post(url, data={"action": "ping"}, verify=verify_tls, timeout=10)
            if r.ok:
                return p
            last_err = f"HTTP {r.status_code}"
        except requests.RequestException as e:
            last_err = str(e)
    raise RuntimeError(f"No working shim path found from {paths} (last error: {last_err})")


def require(cond: bool, msg: str):
    """Lightweight assertion helper that raises a clear error message."""
    if not cond:
        raise AssertionError(msg)


def main():
    # Basic CLI with a single --config option for selecting a YAML file
    ap = argparse.ArgumentParser(description="Test Z-Push Zimbra Java Shim endpoints")
    ap.add_argument("-c", "--config", default="test/shim-tests.yml", help="Path to YAML config")
    args = ap.parse_args()

    # Load and validate configuration
    with open(args.config, "r") as f:
        cfg = yaml.safe_load(f)

    base_url: str = cfg.get("base_url", "").rstrip("/")
    verify_tls: bool = bool(cfg.get("verify_tls", True))
    shim_paths: List[str] = cfg.get("shim_paths") or ["/service/extension/zpush-shim", "/service/zpush-shim"]
    account: str = cfg.get("account")
    password: str = cfg.get("password")
    protocol: str = cfg.get("protocol", "eas")
    preferred_folder: str = cfg.get("preferred_folder", "Inbox")
    messages_limit: int = int(cfg.get("messages_limit", 10))
    getmessage_format: str = cfg.get("getmessage_format", "html")

    require(base_url, "base_url is required in config")
    require(account and password, "account and password are required in config")

    # HTTP session persists cookies and default headers across calls
    session = requests.Session()

    # Optional: JSON-SOAP login first to set cookie and csrf header if enforced
    csrf = None
    try:
        csrf = zimbra_json_soap_login(session, base_url, verify_tls, account, password)
        if csrf:
            session.headers["X-Zimbra-Csrf-Token"] = csrf
            print("[INFO] Obtained csrfToken via JSON-SOAP")
    except Exception as e:
        print(f"[WARN] SOAP login failed or not necessary: {e}")

    # Detect which shim path works
    shim_path = choose_shim_path(session, base_url, shim_paths, verify_tls)
    shim_url = f"{base_url}{shim_path}"
    print(f"[INFO] Using shim endpoint: {shim_url}")

    failures = 0

    def post(data: Dict[str, Any]) -> requests.Response:
        """Helper to post form-encoded data to the active shim endpoint."""
        return session.post(shim_url, data=data, verify=verify_tls, timeout=20)

    # 1) ping
    try:
        r = post({"action": "ping"})
        require(r.ok, f"ping failed: HTTP {r.status_code}")
        print("[PASS] ping")
    except Exception as e:
        failures += 1
        print(f"[FAIL] ping -> {e}")

    # 2) authenticate
    auth_token = None
    account_id = None
    try:
        r = post({
            "action": "authenticate",
            "username": account,
            "password": password,
            "protocol": protocol,
        })
        require(r.ok, f"authenticate failed: HTTP {r.status_code}")
        j = r.json()  # expected keys: authToken, accountId (implementation-dependent)
        # Accept either success True or presence of expected keys
        require(j.get("authToken") or j.get("data", {}).get("authToken"), "authToken missing in response")
        auth_token = j.get("authToken") or j.get("data", {}).get("authToken")
        account_id = j.get("accountId") or j.get("data", {}).get("accountId")
        print("[PASS] authenticate")
    except Exception as e:
        failures += 1
        print(f"[FAIL] authenticate -> {e}")

    # 2b) getuserinfo (requires auth token)
    try:
        require(auth_token, "auth_token not available; authenticate must pass")
        r = post({"action": "getuserinfo", "authToken": auth_token})
        require(r.ok, f"getuserinfo failed: HTTP {r.status_code}")
        j = r.json()
        # require at least accountId and displayName/name
        require(j.get("accountId") is not None, "accountId missing in userinfo")
        print("[PASS] getuserinfo")
    except Exception as e:
        failures += 1
        print(f"[FAIL] getuserinfo -> {e}")

    # 3) getfolders
    folders = []
    target_folder_id = None
    try:
        require(auth_token, "auth_token not available; authenticate must pass")
        payload = {"action": "getfolders", "authToken": auth_token}
        if account_id:
            payload["accountId"] = account_id
        r = post(payload)
        require(r.ok, f"getfolders failed: HTTP {r.status_code}")
        folders = r.json()  # expected: list of folder dicts
        require(isinstance(folders, list), "getfolders response is not a list")
        # pick preferred folder (Inbox) or first message view
        def is_inbox(item: Dict[str, Any]) -> bool:
            name = (item.get("name") or "").lower()
            return name == preferred_folder.lower()

        msg_folders = [f for f in folders if (f.get("view") or "message").startswith("message")]
        chosen = None
        for f in folders:
            if is_inbox(f):
                chosen = f; break
        if not chosen:
            chosen = msg_folders[0] if msg_folders else (folders[0] if folders else None)
        require(chosen is not None and (chosen.get("id") is not None), "Could not determine a target folder id")
        target_folder_id = chosen.get("id")
        print(f"[PASS] getfolders (selected folder id={target_folder_id})")
    except Exception as e:
        failures += 1
        print(f"[FAIL] getfolders -> {e}")

    # 4) getmessages
    messages = []
    first_msg_id = None
    try:
        require(auth_token and target_folder_id is not None, "Missing auth_token/folder id")
        payload = {
            "action": "getmessages",
            "authToken": auth_token,
            "folderId": str(target_folder_id),
            "limit": messages_limit,
        }
        r = post(payload)
        require(r.ok, f"getmessages failed: HTTP {r.status_code}")
        messages = r.json()  # expected: list of message dicts
        require(isinstance(messages, list), "getmessages response is not a list")
        if messages:
            first_msg_id = messages[0].get("id")
        print(f"[PASS] getmessages (returned {len(messages)} messages)")
    except Exception as e:
        failures += 1
        print(f"[FAIL] getmessages -> {e}")

    # 5) getmessage (only if we have a message id)
    try:
        if first_msg_id is None:
            print("[SKIP] getmessage (no messages available)")
        else:
            r = post({
                "action": "getmessage",
                "authToken": auth_token,
                "messageId": str(first_msg_id),
                "format": getmessage_format,
            })
            require(r.ok, f"getmessage failed: HTTP {r.status_code}")
            j = r.json()  # expected keys: id, subject, body, etc. (implementation-dependent)
            require(str(j.get("id")) == str(first_msg_id), "Returned message id does not match requested id")
            print("[PASS] getmessage")
    except Exception as e:
        failures += 1
        print(f"[FAIL] getmessage -> {e}")

    # Negative test: getuserinfo with bad token should not succeed
    try:
        r = post({"action": "getuserinfo", "authToken": "bad-token"})
        require(r.status_code in (401, 403, 500), f"expected unauthorized/denied status, got {r.status_code}")
        print("[PASS] getuserinfo (negative)")
    except Exception as e:
        failures += 1
        print(f"[FAIL] getuserinfo (negative) -> {e}")

    total = 5 + (1 if first_msg_id is not None else 0)
    passed = total - failures
    print(f"\nSummary: {passed}/{total} passed, {failures} failed")
    sys.exit(0 if failures == 0 else 1)


if __name__ == "__main__":
    main()
