# Z-Push Zimbra Backend: App Passwords via AutoDiscover + Preauth (No Shim)

This document explains why ActiveSync authentication with app passwords failed previously in `zimbra.php`, the minimal change that fixes it, what we tested, and how to configure and verify it. It is written for the Z-Push Zimbra backend maintainer.

- Under 2FA, Zimbra accepts app passwords only for non‑interactive protocols (imap/pop3/dav/zsync), not SOAP.
- AutoDiscover authenticates with Basic over `zsync` and therefore accepts app passwords.
- After validating credentials with AutoDiscover, obtain a mailbox token using a SOAP AuthRequest with `<preauth>` (no user password).
- This approach requires no shim and keeps the rest of `zimbra.php` unchanged. It is opt‑in via config flags and falls back to the original SOAP path.

## Why app passwords failed before

- Z-Push traditionally authenticates by posting a SOAP AuthRequest (password) to `/service/soap`.
- With 2FA enabled, the server logic only checks app passwords for non‑interactive protocols. SOAP is interactive (Protocol.soap) and rejects app passwords by design.
- Result: SOAP AuthRequest fails with app passwords when 2FA is ON.

## The solution (minimal and server‑supported)

1) Validate the secret via AutoDiscover using Basic auth
- AutoDiscover runs with `Protocol.zsync`, which accepts app passwords when 2FA is ON and primary passwords when 2FA is OFF.
- Any non‑401 HTTP status means “credentials accepted.” Values like 200/403/503 are common; schema/body processing occurs after authentication.

2) Obtain a mailbox token via SOAP AuthRequest with `<preauth>`
- `<preauth>` uses an HMAC with the per‑domain preauth key (no user secret). The server validates the HMAC and returns a standard `authToken`.
- The response token (`ZM_AUTH_TOKEN`) works with SOAP/REST. Include `X-Zimbra-Csrf-Token` for mutating requests when provided.

### Why a Preauth Key is required (and why this approach)

- Problem: Under 2FA, SOAP rejects app passwords; AutoDiscover accepts app passwords but doesn’t mint a token. Z-Push still needs a token for SOAP/REST.
- Preauth is Zimbra’s documented mechanism to obtain a token without the user’s password or an interactive second factor. A per‑domain key (`zimbraPreAuthKey`) lets a trusted client compute a time‑bound HMAC in `<preauth>`; if valid, the server issues a mailbox token.
- Alternatives (and why not):
  - SOAP + app password: fails by design under 2FA.
  - Interactive 2FA: not feasible for ActiveSync clients.
  - Admin/delegated auth or OAuth/JWT: larger scope, different risk posture; unnecessary for this minimal change.
- Security posture:
  - HMAC + timestamp prevents replay; the key is domain‑scoped.
  - Treat `ZIMBRA_PREAUTH_KEY` as a credential (restrict access, keep out of VCS, rotate periodically).

### Scope of the Preauth Key (Domain‑Level) and Implications

- The preauth key is stored on the domain object (`zimbraPreAuthKey`). It is not per‑user; all accounts in the domain use the same key for `<preauth>` HMAC computation.
- Even though the key is shared at the domain level, the HMAC input includes the target account identifier (`account|by|expires|timestamp`). Tokens minted are per‑account and the server enforces the account in the request.
- Operationally, holding the domain key allows minting tokens for any account in that domain. This is why you must treat the key as a sensitive secret and scope its exposure appropriately (see guidance below).

Mitigations and guidance:
- Store the key only on the Z‑Push host(s) that need it; restrict filesystem permissions to the Z‑Push process user.
- Rotate the key periodically using `zmprov gdpak <domain>`; plan a brief maintenance window to update Z‑Push config and restart.
- Consider using a dedicated domain (or sub‑domain) for mobile/ActiveSync users if you want to reduce blast radius.
- Keep the `<preauth>` timestamp window short (the server already enforces a narrow skew); do not reuse HMACs.
- Monitor mailbox logs for `<preauth>` activity and unusual patterns.

### Preauth Rotation and User Impact (Operations FAQ)

Does rotating the preauth key force 1000 users to reconfigure their phones?
- No. End users don’t see or store the preauth key. Devices continue to use the same username + password/app‑password.
- The preauth key is only used server‑side by Z‑Push to mint tokens after AutoDiscover validates credentials.

What happens to existing sessions/tokens?
- Already‑issued `authToken`s are independent of the preauth key and remain valid until their normal expiration or logout.
- Only new authentications that rely on `<preauth>` will fail until Z‑Push is updated with the new key.

Recommended rotation runbook (single host):
1) Schedule a short maintenance window (few seconds to a minute).
2) On Zimbra: `su - zimbra -c 'zmprov gdpak your-domain.com'` (generates and sets a new domain preauth key).
3) Immediately update Z‑Push config (`ZIMBRA_PREAUTH_KEY`) with the new hex key and restart the Z‑Push/php process.
4) Verify with the AutoDiscover and `<preauth>` curl checks.

Recommended rotation runbook (HA multi‑node):
1) Drain traffic from node A; keep node B serving.
2) `gdpak` to set the new key on the domain.
3) Update node A’s `ZIMBRA_PREAUTH_KEY`, restart node A, return it to service.
4) Drain node B, update key, restart node B, return it to service.

Notes:
- Expect a brief window where `<preauth>` calls from nodes still using the old key will fail (AutoDiscover will still accept credentials). Rotate Z‑Push nodes quickly to minimize impact.
- No device reconfiguration is required; app passwords remain unchanged in Zimbra and are unrelated to the preauth key.

## Configuration (Z-Push zimbra backend `config.php`)

Add these constants to enable the optional path:

- `define('ZIMBRA_AUTODISCOVER_AUTH', true);`
  - Enables the AutoDiscover+Preauth flow.
- `define('ZIMBRA_PREAUTH_KEY', '<hex-from-zmprov-gdpak your-domain.com>');`
  - Domain preauth key (hex) obtained from the server: `su - zimbra -c 'zmprov gdpak your-domain.com'`.
  - Keep secret and rotate periodically.

Notes:
- The raw user password is used only for AutoDiscover Basic. The sanitized password remains for the existing SOAP path if fallback occurs.
- We request the Outlook response schema (2006a). Authentication happens before schema handling; non‑401 is sufficient to confirm acceptance.

## AutoDiscover Availability (FOSS vs Network Edition)

- The AutoDiscover servlet is present in both Zimbra FOSS and Network Edition; it is not the “ActiveSync feature” itself.
- AutoDiscover’s authentication step (HTTP Basic with `Protocol.zsync`) runs before any feature gating. This means:
  - On FOSS, AutoDiscover still authenticates credentials and you will see non‑401 when the secret is valid.
  - If the requested response schema implies EWS/MobileSync, the servlet may return 403 (feature not enabled) or 503 (schema not available) after authentication — and that is fine for our purposes.
- Our flow only relies on the authentication outcome (non‑401). We do not depend on the provisioning payload. After the auth check we immediately mint a mailbox token via SOAP `<preauth>`.

Admin tip (FOSS): You can use AutoDiscover for the auth step even without Network Edition/MobileSync. If you prefer to limit exposure, restrict `/Autodiscover/Autodiscover.xml` to your Z‑Push hosts at the proxy/LB, or route it internally.

## What changed in `zimbra.php` (optional and backward‑compatible)

- A small, optional block in `Logon()`:
  - POST Basic to `/Autodiscover/Autodiscover.xml` with a minimal XML body (email + acceptable schema).
  - Treat non‑401 as “accepted on zsync.”
  - Compute `<preauth>` HMAC (`HMAC-SHA1(account|by|expires|timestamp, preauthKey)`) and POST a SOAP AuthRequest to `/service/soap`.
  - On success, skip the password‑based SOAP login; otherwise fall back to the original SOAP path unchanged.

## Validation (manual, simple)

### AutoDiscover (zsync) acceptance
```bash
BASE_URL="https://mail.example.com"
USER="user@example.com"
PASS="secret-or-app-password"
BASIC=$(printf '%s:%s' "$USER" "$PASS" | base64)

curl -k -sS -m 12 --connect-timeout 5 \
  -H "Authorization: Basic $BASIC" \
  -H 'Content-Type: text/xml; charset=UTF-8' \
  -o /dev/null -w '%{http_code}\n' \
  -X POST --data-binary @- \
  "$BASE_URL/Autodiscover/Autodiscover.xml" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<Autodiscover xmlns="http://schemas.microsoft.com/exchange/autodiscover/mobilesync/requestschema/2006">
  <Request>
    <EMailAddress>user@example.com</EMailAddress>
    <AcceptableResponseSchema>http://schemas.microsoft.com/exchange/autodiscover/outlook/responseschema/2006a</AcceptableResponseSchema>
  </Request>
</Autodiscover>
EOF
```
- Expect non‑401 for valid credentials under zsync.

### SOAP `<preauth>` token issuance
```bash
BASE_URL="https://mail.example.com"
SOAP_URL="$BASE_URL/service/soap"
PREAUTH_KEY="<hex preauth key>"
USER="user@example.com"
TS_MS="$(($(date +%s)*1000))"
DATA="$USER|name|0|$TS_MS"
PREAUTH_HEX=$(printf '%s' "$DATA" | openssl dgst -sha1 -hmac "$PREAUTH_KEY" | awk '{print $2}')

JSON=$(cat <<EOF
{
  "Header": {},
  "Body": {
    "AuthRequest": {
      "_jsns": "urn:zimbraAccount",
      "account": {"by": "name", "_content": "$USER"},
      "preauth": {"timestamp": "$TS_MS", "expires": "0", "_content": "$PREAUTH_HEX"}
    }
  }
}
EOF
)

curl -k -sS -m 12 --connect-timeout 5 -H 'Content-Type: application/json' \
  -X POST --data "$JSON" "$SOAP_URL"
```
- Expect HTTP 200 and `AuthResponse.authToken._content` (token). Use as `ZM_AUTH_TOKEN`; include `X-Zimbra-Csrf-Token` for mutating requests when present.

## What we tested and observed
- AutoDiscover: non‑401 for valid creds (app password with 2FA ON or primary with 2FA OFF). Mailbox logs show “Handling autodiscover request…” → “sending autodiscover response…”.
- SOAP `<preauth>`: HTTP 200 with a standard mailbox token; mailbox logs show “Authentication successful for user: …”.
- Combined: One‑step check proves zsync acceptance; preauth token issuance proves the session path.

## Sharing and applying the code change as a patch

Create a patch of your edited `zimbra.php` so maintainers can audit and apply easily.

Using git:
```bash
git diff -- zimbra74/zimbra.php > zimbra.patch
```

Using plain `diff`:
```bash
cp zimbra74/zimbra.php zimbra74/zimbra.php.bak
# (edit zimbra74/zimbra.php to include the AutoDiscover+Preauth block)
diff -u zimbra74/zimbra.php.bak zimbra74/zimbra.php > zimbra.patch
```

Apply / rollback on target:
```bash
patch -p0 < zimbra.patch
# rollback
patch -R -p0 < zimbra.patch
```

This optional, config‑gated change gives Z-Push a minimal, server‑supported way to accept app passwords under 2FA without relying on a shim or changing device behavior.

## Security Considerations (Attack Surface, Hardening, and Prior Incidents)

AutoDiscover endpoint exposure
- AutoDiscover is an HTTP endpoint (`/Autodiscover/Autodiscover.xml`) that accepts Basic credentials. Attackers don’t need a mobile client to hit it; they can script requests directly. This is not new — the endpoint exists whether or not Z-Push uses it — but our flow relies on it for validation.
- Treat AutoDiscover as an auth surface similar to IMAP/POP basic auth:
  - Enforce TLS; disallow plaintext.
  - Apply rate limiting / WAF rules (e.g., per-IP fail thresholds, burst limiting, geo/IP allow lists where practical).
  - Monitor logs for repeated 401s and anomalous patterns.

Brute-force / lockout
- Ensure account lockout policies are effective across protocols. Zimbra provides per‑protocol lockout controls (see `zimbraPasswordLockout*` and related COS/account attributes); configure them to cover HTTP/basic/zsync appropriately.
- Consider stronger app‑password policies (length/entropy) and revoke on compromise.

Endpoint scoping
- If Z-Push and mailboxd run in the same environment, prefer routing AutoDiscover to an internal address/port where possible (e.g., proxy/internal VIP or loopback on the mailbox host), and restrict external exposure of AutoDiscover if not otherwise required.
- If Z-Push runs remotely and AutoDiscover must be public, consider allow‑listing the Z-Push egress IP on your edge proxy for the AutoDiscover path.

Preauth trust model
- `<preauth>` is a trusted SSO‑style mechanism protected by the domain preauth key. Our implementation calls `<preauth>` only after AutoDiscover has accepted the user’s secret — that’s our client‑side policy to reduce accidental misuse.
- Server‑side, `<preauth>` does not require the preceding AutoDiscover step; the protection is the HMAC+timestamp derived from the (secret) domain key. Protecting `ZIMBRA_PREAUTH_KEY` remains the critical control.

Patching and advisories
- Zimbra has published advisories over time involving various web endpoints (including AutoDiscover). Keep mailboxd fully patched and track vendor CVEs and release notes. If your security team flags AutoDiscover issues in an advisory, patch promptly and consider temporarily restricting external access to that path until remediated.

Summary
- Using AutoDiscover for validation does not create a new class of authentication surface; it leverages an existing one (HTTP Basic on AutoDiscover). Apply the same controls you use for other auth surfaces (TLS, lockout, rate limiting, monitoring).
- Protect the domain preauth key, rotate it, and scope access. Rotation does not require user device changes; only Z-Push configuration needs to be updated.

## Threat Model Q&A (Explicit Clarifications)

Q: If an attacker knows a user ID and password (or app password), can they derive or abuse `<preauth>`?
- A: No. `<preauth>` HMAC is keyed with the domain preauth key, not any user secret. Knowing a user’s password does not enable computing `<preauth>` values.

Q: If an attacker captures one valid `<preauth>` value, can they mint tokens for other users or at later times?
- A: No. The HMAC input includes the specific account and a timestamp. A single observed value does not reveal the domain key and is only valid for that account and short time window.

Q: Who can mint tokens for any account?
- A: Only a holder of the domain preauth key. This is by design (SSO/portal use case). Protect `ZIMBRA_PREAUTH_KEY` accordingly (restricted storage, rotation, host hardening).

Q: Does our implementation make `<preauth>` easier to abuse?
- A: No. We call `<preauth>` only after AutoDiscover has accepted the user’s credentials (client-side policy). Server-side protection for `<preauth>` is the HMAC+timestamp with the domain key; without that key, `<preauth>` is not usable.

Q: Why not use “email + password/app password” as the `<preauth>` key?
- A: Zimbra’s `<preauth>` design is key-based (domain-level) specifically for trusted third-party integrations. The server does not support using user secrets as the HMAC key.

Q: Does rotating the preauth key force users to reconfigure devices?
- A: No. Devices keep using the same username/password or app password. Existing `authToken`s continue until expiration. Only Z-Push needs the updated key, and only new `<preauth>` operations depend on it.

Q: Does exposing AutoDiscover increase risk to users?
- A: AutoDiscover is already an auth surface in Zimbra. Keep it patched, require TLS, apply lockout/rate limiting, and monitor logs. Our flow does not introduce a new class of exposure; it uses the endpoint as intended (Basic auth).
