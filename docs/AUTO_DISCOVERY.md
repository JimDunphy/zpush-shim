Here’s a nuts-and-bolts walkthrough of Z-Push Autodiscover, from the mobile client tap to the response that points the device at your ActiveSync endpoint—plus where in the tree things live and the usual snags.

# Client → server: what hits your box

1. The device tries the standard Autodiscover URL(s) for the user’s email domain, typically (in order) something like:

* `https://autodiscover.<domain>/Autodiscover/Autodiscover.xml`
* `https://<domain>/Autodiscover/Autodiscover.xml`
  Some clients also probe SRV/CNAME and alternate paths, but the XML POST to `/Autodiscover/Autodiscover.xml` is the common denominator for ActiveSync. The payload is an Autodiscover XML request with the email address and a requested schema. ([Microsoft Learn][1])

2. Your web server (Apache/Nginx) routes that path to Z-Push’s Autodiscover PHP handler. Packaged installs place a vhost/location mapping so that `/Autodiscover/Autodiscover.xml` executes the Z-Push Autodiscover script. Example configs ship with Z-Push (e.g., `config/nginx/z-push.conf`), and most distro packages install an Apache or Nginx stub you can copy. ([Fossies][2])

# The Autodiscover component in Z-Push

Z-Push has a dedicated Autodiscover submodule under `src/autodiscover/` (it’s versioned separately in recent releases). On packaged systems, its runtime config is usually installed as `/etc/z-push/autodiscover.conf.php`. You’ll see typical knobs like:

* `TIMEZONE` – PHP timezone for the process
* `BACKEND_PROVIDER` – which backend class name to advertise/expect (e.g., `BackendIMAP`, `BackendCombined`, etc.)
* `USE_FULLEMAIL_FOR_LOGIN` – whether the login should be the complete email address (common when you front another groupware like Zimbra)
* `ZPUSH_HOST` – explicit hostname to put in the returned endpoint URL if you’re not using the request’s `Host:` header as-is

These settings are documented in guides that reference the current package paths and options (the config names above), and you’ll find Autodiscover installation notes in the project’s `src/autodiscover/INSTALL`. ([LinuxBabe][3])

> Where it lives in the tree
> Source: `Z-Hub/Z-Push` → `src/autodiscover/…` (the maintainers recently “updated version for autodiscover subdirectory,” which is how you know you’re looking at the right spot). ([GitHub][4])

# What the PHP actually does (high level)

When `/Autodiscover/Autodiscover.xml` is hit:

1. **Parse request**
   The handler reads the incoming XML (email address + acceptable schema).

2. **Decide login “shape”**
   Based on `USE_FULLEMAIL_FOR_LOGIN` (and similar options), it determines what the client should use as a username (full email vs. local part). This matters for backends that expect `user@domain` (e.g., Zimbra) instead of just `user`. ([LinuxBabe][3])

3. **Build the MobileSync settings**
   Autodiscover responds with an XML “Settings” block for protocol type `MobileSync`. The crucial piece is the EAS endpoint URL, typically `https://<host>/Microsoft-Server-ActiveSync`. Z-Push’s Autodiscover uses `ZPUSH_HOST` or the request host to compose that URL. It does **not** need to hit your actual mail store to fabricate this—it’s purely a hint telling the client, “talk ActiveSync to this URL next.” (Backend access happens during the *next* step of the client’s life, not here.) ([Microsoft Learn][1])

4. **Return XML to the client**
   The client caches the EAS endpoint and proceeds to authenticate and provision against `/Microsoft-Server-ActiveSync` (Z-Push’s main `index.php`). Provisioning and the subsequent Sync/FolderSync/ItemOps are all standard EAS over HTTP(S). ([Microsoft Learn][5])

> Backend interaction during Autodiscover
> By default, the Z-Push Autodiscover responder doesn’t have to validate the mailbox or query the backend—it only needs enough config to return a correct EAS URL and a username hint. Backend specifics kick in when the phone then calls the ActiveSync endpoint and the configured backend (IMAP/Kopano/Combined/etc.) is engaged. The Autodiscover docs in the tree even note it can “auto detect which backend to use” *for advertising purposes* if left empty, underscoring that autodiscover is largely declarative. ([Fossies][6])

# Server → backend → back to the client (the rest of the dance)

Once the device gets the Autodiscover answer and calls the EAS endpoint:

1. **ActiveSync endpoint**: `/Microsoft-Server-ActiveSync` (Z-Push `index.php`) receives the request.
2. **Auth**: Your web server’s auth (HTTP Basic/Negotiate/TLS client cert), PHP FPM, and Z-Push’s auth helpers pass credentials to the configured backend.
3. **Backend**: The selected provider (`BackendIMAP`, `BackendZarafa/Kopano`, `BackendCombined`, `BackendCalDAV/CardDAV`, or Zimbra backend if you’re using the contrib module) implements the EAS storage interfaces Z-Push calls during `Provision`, `FolderSync`, `Sync`, etc.
4. **EAS flows**: The phone provisions, negotiates policies (if any), and starts syncing collections. ([Microsoft Learn][5])

# What you typically tweak for Autodiscover

* **Nginx/Apache mapping**: ensure `/Autodiscover/Autodiscover.xml` → Z-Push Autodiscover PHP. The project ships example configs you can adapt. ([Fossies][2])
* **Config file**: `/etc/z-push/autodiscover.conf.php` (or equivalent in your setup). Set `TIMEZONE`, `USE_FULLEMAIL_FOR_LOGIN`, and `ZPUSH_HOST`. If you front multiple domains on one host, explicitly setting `ZPUSH_HOST` prevents odd Host-header issues. ([LinuxBabe][3])
* **Backend naming**: `BACKEND_PROVIDER` should reflect the backend you’ll use later at the EAS endpoint so the login hint matches reality. ([Fossies][6])

# Common pitfalls (and quick fixes)

* **PHP function restrictions**: Packagers or hardened PHP configs sometimes disable `parse_ini_file()`; Z-Push needs it. Remove it from `disable_functions` in `php.ini` and reload PHP-FPM. Symptom is a fatal like “Call to undefined function parse\_ini\_file()”. ([forum.iredmail.org][7])
* **Wrong FastCGI/vhost plumbing**: It’s easy to mix Z-Push and another PHP app under one server block and route `/Autodiscover/...` into the wrong pool. Check your FPM `fastcgi_param SCRIPT_FILENAME` and location blocks. ([Kopano Community Forum][8])
* **Multiple domains**: Decide whether clients should always log in as full email (`user@domain`) and set `USE_FULLEMAIL_FOR_LOGIN = true`. Helps Zimbra and multi-tenant scenarios. ([LinuxBabe][3])
* **TLS & hostnames**: Your cert must cover `autodiscover.<domain>` (and/or whatever host you publish). Some clients are picky even if you think they shouldn’t be when “ignoring trust” during tests. ([forums.zimbra.org][9])

# File/area map when you need to patch bugs

* **Autodiscover handler & helpers**: `src/autodiscover/…` (look for the request parser and response builder). Recent releases explicitly mention updates to this subdirectory. ([GitHub][4])
* **Runtime config**: `/etc/z-push/autodiscover.conf.php` (Debian/Ubuntu packaging paths) or under your install prefix (some guides show `/opt/z-push/src/autodiscover/config.php`). ([LinuxBabe][3])
* **Web server snippet**: shipped example `z-push.conf` for Nginx (or an Apache conf fragment) that wires `/Autodiscover/Autodiscover.xml` to PHP. ([Fossies][2])
* **ActiveSync core**: `index.php` and `lib/core/…` (Autodiscover points the client here; your bug may be in the follow-on EAS flows rather than Autodiscover proper). ([GitHub][10])

---

If you can share which bugs you’re seeing (e.g., wrong URL in the response, username hint off, 401s on the JSON/Outlook path, PHP fatals), I can point you straight at the relevant function(s) in `src/autodiscover/*` and sketch the fix.

[1]: https://learn.microsoft.com/en-us/exchange/architecture/client-access/autodiscover?utm_source=chatgpt.com "Autodiscover service in Exchange Server"
[2]: https://fossies.org/linux/Z-Push/config/nginx/z-push.conf?utm_source=chatgpt.com "config/nginx/z-push.conf"
[3]: https://www.linuxbabe.com/mail-server/set-up-z-push-activesync-ubuntu?utm_source=chatgpt.com "How to Set Up Z-Push ActiveSync For Ubuntu Mail Server"
[4]: https://github.com/Z-Hub/Z-Push/releases "Releases · Z-Hub/Z-Push · GitHub"
[5]: https://learn.microsoft.com/en-us/exchange/clients/exchange-activesync/exchange-activesync?utm_source=chatgpt.com "Exchange ActiveSync"
[6]: https://fossies.org/linux/Z-Push/src/autodiscover/INSTALL?utm_source=chatgpt.com "Z-Push: src/autodiscover/INSTALL"
[7]: https://forum.iredmail.org/topic20684-zpush-install.html?utm_source=chatgpt.com "z-push install (Page 1) — iRedMail Support"
[8]: https://forum.kopano.io/topic/3101/autodiscover-seems-to-be-broken?utm_source=chatgpt.com "Autodiscover seems to be broken"
[9]: https://forums.zimbra.org/viewtopic.php?t=60269&utm_source=chatgpt.com "Zimbra 8.7 autodiscover"
[10]: https://github.com/sekozzi/zimbra_z-push?utm_source=chatgpt.com "Integrating Zimbra and Z-push on Centos 7"

