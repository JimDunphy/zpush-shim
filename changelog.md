# Changelog

This document lists the changes introduced during the recent iteration, with reasons and impacts, so contributors and admins can see what was added and why.

## 2025-09-09 (1.0.1 — versioning, test UX, zsync docs)

### Overview
- Goal: Make runtime version discoverable, clarify Makefile test targets (mock vs. live), and explicitly document/acknowledge the zsync-first auth flow with AutoDiscover and IMAP fallback.

### Versioning
- Bumped extension version to 1.0.1 in Ant `build.xml` (manifest `Implementation-Version`).
- Ping now reports the JAR manifest version at runtime (reads `Implementation-Version`); dev server reports `dev`.

### Make/Test UX
- Grouped Makefile help by environment (Mock vs Live) and added clearer echo messages for shim tests.
- Added `test-rest-shim-mock` alias and more explicit guidance for `test-rest-shim-env` vs `test-rest-shim-live`.

### Auth Flow (zsync / AutoDiscover / IMAP)
- Reaffirmed the intended order for 2FA app passwords: prefer `Protocol.zsync`, then AutoDiscover probe, then IMAP validation as last resort.
- Documented toggles: `ZPUSH_SHIM_AUTODISCOVER_FALLBACK`, `ZPUSH_SHIM_AUTODISCOVER_URLS`, `ZPUSH_SHIM_BASIC_FALLBACK`, `ZPUSH_SHIM_IMAP_HOST`, `ZPUSH_SHIM_IMAP_PORTS`.
- Cross-referenced docs: `README-SHIM.md` (App Password Authentication), `docs/PROTOCOL_AUTH_BEHAVIOR.md`, and `docs/ZPUSH-AUTODISCOVER-PREAUTH.md`.

### Why
- Version visibility helps confirm what’s deployed and aids support.
- Clearer Make targets reduce confusion when SHIM_TEST_* env variables are present.
- The zsync-first approach ensures app passcodes work reliably with 2FA accounts.

## 2025-08-26 (Zimbra 10 hardening, docs + tools)

### Overview
- Goal: Make the Java shim work end-to-end on Zimbra 10 with reliable authentication, folder/message retrieval, and clear operational visibility. Align docs and tooling (Ant, paths, scripts) with reality. Reduce deploy hazards.
- Outcome: End-to-end tests pass (5/5). Robust auth on Zimbra 10, production handler with compatibility fallbacks, improved logs, safer undeploy, updated docs, and convenient Make targets + helper scripts.

### Shim Implementation (Server-side)
- Added production handler `com/zimbra/zpush/shim/ZPushShimHandler` and wired it via `ZPushShimExtension` (path: `/service/extension/zpush-shim`).
- Authentication hardening:
  - Accept header `X-Zimbra-Auth-Token` and param `zmAuthToken` (bypass cookie quirks).
  - Resolve tokens via multiple APIs (AuthProvider/ZAuthToken) and, if needed, decode the hex tail to extract `accountId`; fetch Account via Provisioning.
  - Added `AuthProvider.authenticate(Account, String, Map)` fallback with proper `AuthContext` (protocol=eas, user-agent, remote IP) for Zimbra 10.
- Visibility:
  - Logs each request: `zpush-shim action=<action> from=<ip>`.
  - Logs token source/length and decoded token tail; logs success resolving accountId.
- Data endpoints:
  - getfolders: Lists folders via `Mailbox.getFolderList` with view/unread counts.
  - getmessages: Compatible across variants. Uses SearchParams where available; falls back to `Mailbox.getItemList(...)` with multiple signatures; flexible result iteration; safe message extraction.
  - getmessage: Fetch by id with common fields (subject/from/date/size/fragment).

### Testing
- `make test-shim` now passes (ping, authenticate, getfolders, getmessages, getmessage).
- Added Make targets for quick auth flows:
  - `make auth-token` (header token, one-shot SOAP + shim auth kept inline)
  - `make auth-cookie` (cookie + optional CSRF)
  - `make auth-password` (URL-encoded credentials)
  - `make verify-ping` (simple ping verifier)
- Moved helper scripts under `test/`: `shim-auth-token.sh`, `shim-auth-cookie.sh`, `shim-auth-password.sh`.

### Deployment
- Fixed `deploy-shim.sh --undeploy` to move the extension to `/opt/zimbra/lib/ext-disabled/<name>.bak.<ts>` so Zimbra does not accidentally auto-load backups from `lib/ext`.

### Documentation
- Standardized shim endpoint to `/service/extension/zpush-shim` across README.md, README-SHIM.md, INTERNALS-SHIM.md, docs/Zimbra-Calls.md, and docs/Shim-development.txt.
- Replaced Maven instructions with Ant:
  - Build: `ant clean jar` (outputs `dist/zpush-shim.jar`).
  - Deploy: `./deploy-shim.sh --deploy` and restart mailboxd.
- README.md troubleshooting: Added “Authentication to Shim” (cookies+CSRF vs header token; pointers to helper scripts).
- README-SHIM.md file structure updated to match repo (com/zimbra/..., build.xml, dist/, test/).

### Why These Changes
- Zimbra 10 token and API variations were causing 401 and 500s. The new token resolution, Account fallback, and getmessages compatibility remove version brittleness and make failures observable.
- Docs had drift (Maven/pom.xml, old shim path). Aligning to Ant + extension path avoids confusion and speeds setup.
- Safer undeploy prevents accidental extension loading from `.bak` under `lib/ext`.

### Impacts & Notes
- End-to-end shim tests pass against Zimbra 10 (5/5).
- Header-token auth can be used to bypass CSRF when needed; the harness still supports cookie+CSRF automatically.
- Logging now makes diagnose→fix loops far faster (action, token source, decoded tail, and fallback traces).

### Suggested Next Steps
- Sweep docs/README.md to add the short “Auth Troubleshooting” block for consistency with README.md.
- Consider exposing a `getuserinfo` action and add a matching test.
- Optionally add rate-limited, optional debug logs for getmessages fallback paths in high‑load environments.

## Overview
- Goal: Make the shim testable end-to-end both on Zimbra servers and on development machines without Zimbra installed.
- Outcome: Minimal shim implementation (mock mode), standalone dev server, conditional build targets, dedicated tests, and documentation.

## Shim Implementation
- Added `com/zimbra/zpush/shim/ZPushShimExtension.java`
  - Registers the shim as a Zimbra extension at `/service/extension/zpush-shim`.
  - Reason: Ensure deploy and verify steps expose a working endpoint.
- Added `com/zimbra/zpush/shim/ZPushShimCompat.java`
  - Servlet implementing actions: `ping`, `authenticate`, `getfolders`, `getmessages`, `getmessage`.
  - Reason: Provide a minimal, testable endpoint (mock responses for now).
- Added `com/zimbra/zpush/shim/CompatCore.java`
  - Centralized mock logic used by both servlet and dev server.
  - Reason: Single source of truth for action behavior in mock mode.
- Added `com/zimbra/zpush/shim/DevServer.java`
  - Standalone HTTP server exposing `/service/extension/zpush-shim` on `http://127.0.0.1:8081`.
  - Reason: Run and test without Zimbra installed.

## Build System (Ant)
- Updated `build.xml` with two modes:
  - `compile-compat`: Builds `CompatCore` + `DevServer` (no Zimbra required).
  - `compile-full`: Builds `ZPushShimExtension` + `ZPushShimCompat` + `CompatCore` (Zimbra present).
- `jar` now depends on `compile-full` to package the extension only when Zimbra is available.
- Added `run-dev` target to launch the standalone dev server.
- Reason: Support “build anywhere” and test paths independent of Zimbra.

## Deployment
- No code changes to `deploy-shim.sh`, but ensured `ping` returns `{ "status": "ok" }` to satisfy `--verify`.
- Reason: Keep deployment/verification behavior consistent with script expectations.

## Testing
- Added `test/test_shim_endpoints.py`
  - Verifies `ping`, `authenticate`, `getfolders`, `getmessages`, `getmessage` (happy-path) with clear PASS/FAIL output.
  - Improved with docstrings and comments for maintainability.
- Added `test/shim-tests.yml` and `test/shim-tests-dev.yml`
  - Mailboxd-target and dev-server-target configurations.
- Added `test/run_shim_tests.sh`
  - Convenience runner.
- Updated `test/README.md`
  - Admin-focused usage; includes dev-server workflow (run-dev/test-dev).
- Added `test/Internals.md`
  - Deep-dive for junior devs to extend/fix tests safely.
- Reason: Provide reliable, documented tests for both environments.

## Tooling
- Added `Makefile`
  - `deps`, `test-shim`, `test-rest`, `run-dev`, `test-dev` targets.
  - Reason: Streamline common dev and validation tasks.

## Repository Guide
- Added `AGENTS.md`
  - Contributor guide: structure, build/test commands, style, PR expectations, security tips.
  - Reason: Onboard contributors quickly and consistently.

## Documentation
- Updated `INTERNALS-SHIM.md`
  - Documented standalone dev server (127.0.0.1:8081), run commands, and build modes.
  - Reason: Make the compile-anywhere + test-without-Zimbra workflow explicit.

## Why These Changes
- The repo lacked Java sources to serve `/service/extension/zpush-shim`; tests and `deploy-shim.sh --verify` would otherwise fail.
- The standalone dev server realizes the original intent to run and test on non-Zimbra machines.
- Dedicated, documented tests make it easier for junior contributors to extend and maintain.

## Impacts & Notes
- Current shim behavior is mock-only; real Zimbra API calls can be added later behind runtime detection.
- Packaging occurs only when Zimbra is present; use `ant run-dev`/`make run-dev` for local testing.
- Dev server default endpoint: `http://127.0.0.1:8081/service/extension/zpush-shim`.

## Suggested Next Steps
- Add runtime Zimbra integration in `ZPushShimCompat` (detect classes and call Provisioning/Mailbox/Search APIs).
- Extend actions as needed (e.g., `getUserInfo`) and update tests.
- Optionally adjust deploy verification to allow HTTP 200 during early development phases.
