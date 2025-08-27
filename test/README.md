pip install requests pyyaml

This directory provides a lightweight smoke test for the Z-Push Java Shim, aimed at administrators who want to verify the shim is reachable and functioning.

## What It Does
- Authenticates to mailboxd (optionally via JSON‑SOAP) to obtain `ZM_AUTH_TOKEN` and `csrfToken` when required.
- Detects the shim endpoint path and exercises key actions: `ping`, `authenticate`, `getfolders`, `getmessages`, and `getmessage`.
- Prints `[PASS]/[FAIL]` per step and exits non‑zero on failure (good for CI or health checks).

## How It Works
- Python 3 + `requests` and `pyyaml`.
- Uses `test/shim-tests.yml` for configuration.
- Tries `POST` to `"/service/extension/zpush-shim"` then `"/service/zpush-shim"` for `action=ping` to find the active path.
- If available, adds `X-Zimbra-Csrf-Token` to POST requests.

Note about dev mode
- When using the standalone dev server (`make run-dev`), there is no `/service/soap` endpoint. The test prints a warning like `404 Client Error: Not Found for url: http://127.0.0.1:8081/service/soap` and continues. This is expected and harmless in dev mode.

## Requirements
- Python 3.8+
- `pip install requests pyyaml`
- A test user account (prefer an app password when 2FA is enabled)

Optional (no Zimbra installed):
- Run the standalone dev server and test against it:
  ```bash
  make run-dev                      # starts http://127.0.0.1:8081/service/extension/zpush-shim
  make test-dev                     # runs tests against test/shim-tests-dev.yml
  ```

## Quick Start
1) Configure `test/shim-tests.yml`:
```
base_url: "http://localhost:8080"   # or https://mail.example.com
shim_paths:
  - "/service/extension/zpush-shim"
  - "/service/zpush-shim"
account: "user@example.com"
password: "APP_OR_USER_PASSWORD"
verify_tls: false                    # true in production
preferred_folder: "Inbox"
messages_limit: 10
getmessage_format: "html"
```

2) Run the tests:
```
chmod +x test/run_shim_tests.sh test/test_shim_endpoints.py
./test/run_shim_tests.sh
# or
./test/test_shim_endpoints.py -c test/shim-tests.yml
```

3) Interpret results:
- Success: All steps show `[PASS]` with a final `Summary: N/N passed, 0 failed` and exit code 0.
- Partial data: If no messages exist, `getmessage` is skipped (not a failure).
- Failure: Non‑zero exit code; review printed error and server logs.

## Troubleshooting
- 404/401 on ping: Verify the shim JAR is deployed and mailboxd is running.
- 404 on `/service/soap` in dev mode: Expected — the standalone server only exposes `/service/extension/zpush-shim` and the tests proceed without SOAP.
- TLS issues: Use `verify_tls: false` only in labs with self-signed certs.
- Auth problems: Use an app-specific password for 2FA accounts.
- Empty folders: Use an active user or adjust `preferred_folder`.

## Related Tool (Optional)
`rest_harness.py` + `tests.yml` let you define arbitrary mailboxd REST checks. It’s separate from the shim tests but useful for broader endpoint validation.

Example configs for the REST harness
- `test/tests.yml` ships with placeholders (not real endpoints).
- `test/tests-shim.yml` is ready-to-run against the shim using mailboxd on loopback:
  ```bash
  make test-rest REST_CFG=test/tests-shim.yml
  ```

## Targets at a Glance
- `make test-shim`: Runs the dedicated shim test script (`test_shim_endpoints.py`). Uses `test/shim-tests.yml` (edit for your host/creds as needed). Suitable for mailboxd or the standalone dev server.
- `make test-rest-shim`: Runs the generic REST harness against shim endpoints using `test/tests-shim.yml`. Good for quick shim checks via the generic runner.
- `make test-rest`: Runs the generic REST harness with `test/tests.yml` (placeholders by default). Override with `REST_CFG` to point at your own YAML:
  ```bash
  make test-rest REST_CFG=test/my-endpoints.yml
  ```

Note: The default `test/tests.yml` contains example endpoints and will 404 unless you replace them with real paths for your deployment. This is expected when using it unmodified.

## Helper Scripts (Single-Step Auth)
- `test/shim-auth-token.sh`: Performs SOAP login and authenticates to the shim using header `X-Zimbra-Auth-Token` in one go. Useful when you want a single command during testing.
- `test/shim-auth-cookie.sh`: Cookie-based authenticate after a SOAP login (respects CSRF when present).
- `test/shim-auth-password.sh`: Username/password authenticate (URL-encoded; prompts for password when not provided via env).

Recommendation
- Keep using the harness for CI-style runs.
- Use the helper scripts or Make targets for quick manual checks while iterating locally:
  - `make auth-token` → runs `test/shim-auth-token.sh`
  - `make auth-cookie` → runs `test/shim-auth-cookie.sh`
  - `make auth-password` → runs `test/shim-auth-password.sh`
