# Shim Test Internals (For Developers)

This document explains how the Python-based shim tests work so a junior developer can safely extend them, add new cases, or fix bugs without deep prior Python experience.

## Purpose & Files
- `test_shim_endpoints.py`: Main test runner that exercises shim endpoints (`ping`, `authenticate`, `getfolders`, `getmessages`, `getmessage`).
- `shim-tests.yml`: Configuration (server URL, credentials, options).
- `run_shim_tests.sh`: Small shell wrapper to run the Python script.
- Legacy: `rest_harness.py` + `tests.yml` are generic mailboxd REST tests (separate tool).

## High-Level Flow
1. Load YAML config (`shim-tests.yml`).
2. Optionally perform a JSON-SOAP login to `/service/soap` to obtain `ZM_AUTH_TOKEN` and (often) `csrfToken`.
   - In dev mode (standalone server), `/service/soap` does not exist. The script logs a warning (HTTP 404) and continues — this is expected and safe.
3. Detect a working shim path by POSTing `action=ping` to each candidate path.
4. POST to shim endpoints in order and validate JSON results.
5. Print [PASS]/[FAIL] lines and exit with a non‑zero status if any step fails.

## Key Concepts (Plain English)
- YAML: Human-friendly config file format (key: value). The script reads it with `yaml.safe_load`.
- Session: A reusable HTTP client from `requests.Session()` that stores cookies.
- JSON-SOAP login: Mailboxd accepts JSON bodies at `/service/soap` to return the `ZM_AUTH_TOKEN` cookie and often `csrfToken`.
- CSRF header: If present, the script adds `X-Zimbra-Csrf-Token` to subsequent POSTs automatically.

## Code Walkthrough
- Entry point: `main()`
  - Parses `--config` (default: `test/shim-tests.yml`).
  - Reads `base_url`, `account`, `password`, `verify_tls`, and preferences.
  - Creates a `requests.Session` (stores cookies, headers).

- SOAP Login: `zimbra_json_soap_login(session, base_url, verify_tls, account, password)`
  - POSTs a JSON body to `/service/soap` → expects `ZM_AUTH_TOKEN` cookie.
  - Extracts `csrfToken` from the JSON response if available and returns it.
  - On failure, the script continues (shim may work without this, but some setups require it).

- Shim Discovery: `choose_shim_path(session, base_url, paths, verify_tls)`
  - Tries each configured path (default `"/service/extension/zpush-shim"`, then `"/service/zpush-shim"`).
  - Sends `action=ping`; returns the first path that responds with HTTP 200.

- Assertions: `require(cond, msg)`
  - Raises an `AssertionError` with a clear message when expectations aren’t met.

- Endpoint Tests (happy-path)
  - `ping`: sanity check and connectivity.
  - `authenticate`: expects an `authToken` (and optionally `accountId`).
  - `getfolders`: returns a JSON list; selects a target folder (prefers "Inbox").
  - `getmessages`: returns a JSON list for the chosen folder; collects the first message id (if any).
  - `getmessage`: fetches that message; verifies the id matches and body format preference.

- Output & Exit Code
  - Prints `[PASS]`/`[FAIL]` per step and a summary.
  - Exits `0` on success; `1` on any failure (good for CI/CD).

## Adding New Tests (Step‑by‑Step)
1. Decide on the shim action (e.g., `getuserinfo`, `getcontacts`).
2. After existing steps in `main()`, add a new block:
   ```python
   try:
       r = post({"action": "getuserinfo", "authToken": auth_token})
       require(r.ok, f"getuserinfo failed: HTTP {r.status_code}")
       j = r.json()
       require("timezone" in j, "missing timezone in user info")
       print("[PASS] getuserinfo")
   except Exception as e:
       failures += 1
       print(f"[FAIL] getuserinfo -> {e}")
   ```
3. Add any new config fields to `shim-tests.yml` if required.
4. Keep checks minimal-but-meaningful (status code, expected keys/values).

## Writing Negative Tests (Optional)
- Intentionally invalid input (e.g., wrong token) to confirm a 401/403.
- Example:
  ```python
  r = post({"action": "getfolders", "authToken": "bad"})
  require(r.status_code in (401, 403), "expected unauthorized status")
  ```
- Place negative tests after the happy-path sequence to keep output readable.

## Debugging Tips
- Print response body on failure: add `print(r.text[:500])` in exception paths.
- Enable `requests` logging:
  ```python
  import logging
  logging.basicConfig(level=logging.DEBUG)
  ```
- Validate server: `curl -v <base_url>/service/soap` should respond; shim path should accept POST.

## Common Pitfalls
- Wrong `base_url`: must point at mailboxd (e.g., `http://host:8080` or `https://host`).
- 2FA accounts: prefer app‑specific passwords for unattended tests.
- Self‑signed certs in labs: set `verify_tls: false` in `shim-tests.yml`.
- Empty mailboxes: `getmessages` may return an empty list → `getmessage` is skipped (not a failure).

## Style & Conventions
- Keep new tests short and readable; reuse helpers (`require`, `post`).
- Prefer explicit checks on status codes and key fields.
- Fail fast with clear messages so admins can triage quickly.

## Safe Refactors
- Factor repeated `post({...})` blocks into small helpers if the file grows.
- Avoid global state beyond what’s already present (session, tokens).
- Keep CLI and YAML keys backward compatible when possible.
