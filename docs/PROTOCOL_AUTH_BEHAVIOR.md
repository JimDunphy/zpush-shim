# Protocol Authentication Behavior with 2FA

This document outlines how different protocols and endpoints within Zimbra handle authentication when two-factor authentication (2FA) is enabled for an account. The key differentiator is how each entry point sets the `Protocol` enum within the `AuthContext`, which then dictates whether application-specific passcodes can be used.

## The Core Logic

The central 2FA logic contains a `switch` statement that separates behavior for different protocols. The simplified logic is:

1.  **Interactive Protocols (`soap`, `http_basic`):** These are assumed to be used by a client that can handle a second-factor prompt (like a TOTP code from an authenticator app). They do **not** validate against application passcodes in the primary flow.
2.  **Non-Interactive Protocols (`default` case):** All other protocols (IMAP, POP3, DAV, zsync) are assumed to be non-interactive. If 2FA is enabled, they **must** authenticate using an application-specific passcode.

---

## Protocol-Specific Implementations

### IMAP and POP3

*   **Behavior**: Fully support application passcodes.
*   **Implementation**: The `ImapHandler` and `Pop3Handler` set the protocol in the `AuthContext` to `imap` and `pop3` respectively. These values fall into the `default` case of the 2FA logic, correctly triggering validation against the `zimbraAppSpecificPassword` attribute.

### SOAP (Web Client / ZCSDK)

*   **Behavior**: Does **not** support application passcodes. Requires the primary password and a TOTP code if 2FA is enabled.
*   **Implementation**: The `SoapServlet` handles requests to `/service/soap`. It sets the protocol to `soap`, which is handled as an interactive flow.

### ActiveSync (`/Microsoft-Server-ActiveSync`)

*   **Behavior**: Fully supports application passcodes.
*   **Implementation**: The ActiveSync endpoint is **not** part of the core `zm-mailbox` web application. It is a separate, dedicated application or gateway that listens on the `/Microsoft-Server-ActiveSync` path. This gateway is responsible for:
    1.  Accepting the connection from the mobile device.
    2.  Validating the provided application passcode against the Zimbra backend.
    3.  Using a trusted **Pre-Authentication Key** to make standard SOAP requests to `zm-mailbox` on behalf of the now-authenticated user.

### REST API (`/home/*` and `/user/*`)

*   **Behavior**: Does **not** support application passcodes.
*   **Implementation**: The `UserServlet` that handles these paths contains logic that explicitly rejects an authentication attempt if 2FA is enabled and the authentication method was HTTP Basic Auth. It is designed to work with an existing cookie-based session from an interactive login.

### CalDAV/CardDAV (`/dav/*`)

*   **Behavior**: Fully supports application passcodes.
*   **Implementation**: The `DavServlet` handles these requests. When it receives credentials via HTTP Basic Auth, the `AuthUtil.basicAuthRequest` helper correctly sets the protocol in the `AuthContext` to `dav`. This falls into the `default` case of the 2FA logic, enabling authentication via application passcodes, which is essential for mobile device calendar and contact sync.

### The `zsync` Protocol and the AutoDiscover Servlet

This provides the solution for external services like Z-Push that need to authenticate over HTTP using application passcodes.

*   **Behavior**: Fully supports application passcodes.
*   **What is `zsync`?**: It is an internal protocol identifier. It is used to tell the authentication service, "This request is coming over HTTP, but it is from a non-interactive source. Treat it like IMAP or DAV for 2FA purposes."
*   **Implementation**: The `AutoDiscoverServlet` (which listens on `/Autodiscover/Autodiscover.xml`) is designed for this purpose. When this servlet receives an authentication request, it explicitly calls the central authentication service with the protocol set to `zsync`:
    ```java
    prov.authAccount(account, pass, AuthContext.Protocol.zsync, authCtxt);
    ```
*   **Solution for Z-Push**: For a service like Z-Push to correctly authenticate a user who has 2FA enabled, it must perform its authentication against the `/Autodiscover/Autodiscover.xml` endpoint. This will set the correct protocol (`zsync`), allowing the application passcode to be validated successfully.
