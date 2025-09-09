#!/usr/bin/env python3
import sys, json, subprocess, shlex, time, os
from typing import Any, Dict
try:
    import yaml
    import requests
except Exception as e:
    print("Missing dependency:", e)
    print("Install with: pip install requests pyyaml")
    sys.exit(2)

def deep_get(d: Dict[str, Any], key: str, default=None):
    cur = d
    for part in key.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return default
        cur = cur[part]
    return cur

def expand_vars(val, caps: Dict[str, Any]):
    """Expand ${var} in a string using captures or environment variables.
    If val is a dict or list, expand recursively.
    """
    if isinstance(val, str):
        out = val
        # Replace ${var} tokens
        # Simple approach: iterate over known caps and env
        for k, v in caps.items():
            out = out.replace('${%s}' % k, str(v))
        for k, v in os.environ.items():
            out = out.replace('${%s}' % k, v)
        return out
    elif isinstance(val, dict):
        return {k: expand_vars(v, caps) for k, v in val.items()}
    elif isinstance(val, list):
        return [expand_vars(v, caps) for v in val]
    return val

def get_totp_from_cmd(cmd: str) -> str:
    out = subprocess.check_output(shlex.split(cmd), timeout=5)
    return out.decode().strip()

def zimbra_login(session: requests.Session, base_url: str, verify_tls: bool, auth_cfg: Dict[str, Any]):
    """
    Do a JSON-SOAP AuthRequest to /service/soap to obtain:
      - ZM_AUTH_TOKEN cookie (added automatically by session)
      - csrfToken (returned in response), needed for POST/PUT/DELETE
    Supports optional 2FA (TOTP).
    """
    account = auth_cfg.get("account") or os.environ.get("SHIM_TEST_USER")
    password = auth_cfg.get("password") or os.environ.get("SHIM_TEST_PASSWORD")
    totp_code = auth_cfg.get("totp_code")
    totp_cmd = auth_cfg.get("totp_cmd")
    trusted_device = bool(auth_cfg.get("trusted_device", False))

    if not (account and password):
        raise RuntimeError("auth.account and auth.password are required")

    if totp_cmd and not totp_code:
        totp_code = get_totp_from_cmd(totp_cmd)

    url = f"{base_url.rstrip('/')}/service/soap"

    # JSON-SOAP envelope for AuthRequest
    # twoFactorCode key is honored when 2FA is enabled for the account
    body = {
        "Header": {},
        "Body": {
            "AuthRequest": {
                "_jsns": "urn:zimbraAccount",
                "account": {"by": "name", "_content": account},
                "password": password
            }
        }
    }
    if totp_code:
        body["Body"]["AuthRequest"]["twoFactorCode"] = totp_code
    if trusted_device:
        body["Body"]["AuthRequest"]["persistAuthTokenCookie"] = True
        body["Body"]["AuthRequest"]["deviceTrusted"] = True

    # Send as JSON (Zimbra supports JSON payloads on /service/soap)
    resp = session.post(url, json=body, verify=verify_tls, timeout=10,
                        headers={"Content-Type": "application/json"})
    resp.raise_for_status()
    j = resp.json()

    # Extract csrfToken (when available) from context
    csrf = deep_get(j, "Body.context.csrfToken") or deep_get(j, "Header.context.csrfToken")
    # Some versions return it in Body.AuthResponse.csrfToken
    if not csrf:
        csrf = deep_get(j, "Body.AuthResponse.csrfToken")

    # Session now has ZM_AUTH_TOKEN cookie if login succeeded
    if not session.cookies.get("ZM_AUTH_TOKEN"):
        raise RuntimeError("Login succeeded HTTP-wise but no ZM_AUTH_TOKEN cookie was set")

    return csrf

def run_tests(cfg: Dict[str, Any]) -> int:
    base_url = (os.environ.get("SHIM_TEST_BASE_URL") or cfg.get("base_url", "")).rstrip("/")
    # Allow SHIM_TEST_VERIFY_TLS to override verify flag ("0"/"false"/"no" -> False)
    env_vtls = os.environ.get("SHIM_TEST_VERIFY_TLS")
    if env_vtls is not None:
        verify_tls = str(env_vtls).lower() not in {"0", "false", "no"}
    else:
        verify_tls = bool(cfg.get("verify_tls", True))

    defaults = cfg.get("defaults", {})
    default_headers = defaults.get("headers", {}) or {}
    tests = cfg.get("tests", [])
    if not tests:
        print("No tests found."); return 1

    session = requests.Session()
    session.headers.update(default_headers)

    # 1) Login first (sets cookie; get csrf for mutating verbs)
    auth_cfg = cfg.get("auth", {}) or {}
    csrf_token = None
    if auth_cfg:
        csrf_token = zimbra_login(session, base_url, verify_tls, auth_cfg)

    passed = 0; failed = 0; t0 = time.time()
    captures: Dict[str, Any] = {}

    for ix, t in enumerate(tests, 1):
        name = t.get("name", f"test_{ix}")
        method = (t.get("method", "GET") or "GET").upper()
        path = t.get("path", "")
        # Expand variables in path and headers using captures/env
        url = path if path.startswith("http") else f"{base_url}{expand_vars(path, captures)}"
        headers = expand_vars({**default_headers, **(t.get("headers") or {})}, captures)

        # If mutating method, include CSRF header when we have it
        if method in {"POST", "PUT", "PATCH", "DELETE"} and csrf_token:
            headers.setdefault("X-Zimbra-Csrf-Token", csrf_token)

        body = t.get("body")
        data_kw = {}
        if body is not None:
            if headers.get("Content-Type", "").startswith("application/json") or isinstance(body, dict):
                data_kw["json"] = expand_vars(body, captures)
            else:
                data_kw["data"] = expand_vars(body, captures)

        expect = t.get("expect", {}) or {}
        exp_status = expect.get("status")
        exp_contains = expect.get("contains")
        exp_json = expect.get("json")

        try:
            resp = session.request(method, url, headers=headers, verify=verify_tls, timeout=15, **data_kw)
            ok = True; reasons = []

            if exp_status is not None and resp.status_code != int(exp_status):
                ok = False; reasons.append(f"status {resp.status_code} != {exp_status}")

            text = resp.text or ""
            if exp_contains is not None and exp_contains not in text:
                ok = False; reasons.append(f"missing substring '{exp_contains}'")

            if exp_json is not None:
                try:
                    j = resp.json()
                except Exception:
                    ok = False; reasons.append("response is not valid JSON"); j = {}
                if isinstance(exp_json, dict):
                    for k, v in exp_json.items():
                        actual = deep_get(j, k) if "." in k else j.get(k)
                        if actual != v:
                            ok = False; reasons.append(f"json.{k} = {actual!r} != {v!r}")

            if ok:
                passed += 1
                print(f"[PASS] {name} ({method} {url})")
            else:
                failed += 1
                print(f"[FAIL] {name} ({method} {url}) -> {', '.join(reasons)}")
                # Avoid backslashes inside f-string expressions (Py3.6 restriction)
                preview = (text[:200] or "").replace("\n", "\\n")
                print(f"       body: {preview}...")

            # Capture variables from JSON if requested
            cap = t.get("capture") or {}
            if cap:
                try:
                    j = resp.json()
                    for dest, src in cap.items():
                        captures[dest] = deep_get(j, src, j.get(src))
                except Exception:
                    pass

        except requests.RequestException as e:
            failed += 1
            print(f"[ERROR] {name} ({method} {url}) -> {e}")

    dt = time.time() - t0
    total = passed + failed
    print(f"\nSummary: {passed}/{total} passed, {failed} failed in {dt:.2f}s")
    return 0 if failed == 0 else 1

def main():
    if len(sys.argv) != 2:
        print("Usage: ./rest_harness.py tests.yaml"); sys.exit(2)
    with open(sys.argv[1], "r") as f:
        cfg = yaml.safe_load(f)
    sys.exit(run_tests(cfg))

if __name__ == "__main__":
    main()
