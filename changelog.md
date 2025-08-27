# Changelog

This document lists the changes introduced during the recent iteration, with reasons and impacts, so contributors and admins can see what was added and why.

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

