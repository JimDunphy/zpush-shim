# Zimbra 10 NGINX Templates + Z-Push (Zimbra Backend) with REST Shim

This document provides a definitive guide to integrating Z-Push with Zimbra 10. This setup is enhanced with a custom **Z-Push REST Shim** to dramatically improve performance by replacing the standard, slow SOAP API with a high-performance, internal REST API for all core operations.

## 1. Core Concepts & Architecture

### 1.1. High-Level Architecture

The integration uses Zimbra's own NGINX as a reverse proxy to a dedicated, containerized Z-Push application. This isolates the Z-Push environment from the main Zimbra services.

The four primary components are:

1.  **Zimbra NGINX Proxy:** The standard, front-line web server in a Zimbra installation. It handles all incoming client connections.
2.  **Z-Push Docker Container:** A self-contained environment running its own NGINX server and a PHP-FPM process to execute the Z-Push application.
3.  **Patched Z-Push Application:** The PHP-based Z-Push code, specifically a modified `BackendZimbra` (`zimbra.php`) that has been patched to make REST calls to the Z-Push Shim instead of SOAP calls.
4.  **Z-Push Shim (Java Extension):** A custom Java extension (`.jar`) deployed on the Zimbra Mailboxd (Jetty) server. It exposes an internal REST API for high-performance operations.

### 1.2. The Z-Push Shim: A Full REST-Based Backend

The key innovation in this setup is the **Z-Push Shim**, which completely replaces the slow, public SOAP API for all major ActiveSync operations.

-   **How it Works:** The shim is a Zimbra extension that exposes a simple REST endpoint (`/service/extension/zpush-shim`). The Z-Push PHP backend is patched to be a **full REST client** to this endpoint. Because the shim runs directly within the mailboxd JVM, it can access internal Zimbra Java APIs for near-instant data retrieval and updates, providing a significant performance boost over the standard `BackendZimbra`.
-   **Full REST API:** Unlike the standard backend, this integration is not a hybrid. It is designed to use REST for all core functions. The shim provides the following actions:
    -   `action=authenticate`: Validates credentials and returns auth tokens.
    -   `action=getfolders`: Retrieves the complete folder hierarchy.
    -   `action=getmessages`: Gets message lists from a folder.
    -   `action=getmessage`: Retrieves the content of an individual message.
    -   `action=ping`: A simple health check endpoint.
-   **SOAP as a Fallback:** The legacy SOAP communication method is only used if the shim is disabled in the Z-Push configuration or if a call to the shim fails, ensuring graceful degradation.

### 1.3. Protocol Flow: From Client to Zimbra and Back

`Client ---[HTTPS]--> Zimbra NGINX Proxy ---[HTTP]--> Z-Push Container ---[FastCGI]--> Patched PHP Backend ---[HTTP/REST]--> Zimbra Mailboxd (Jetty)`

-   **Hops 1-3 (Client to Container):** The request flows from the client via HTTPS to the Zimbra proxy, which forwards it via plain HTTP over the loopback interface to the container's NGINX. The container's NGINX then uses FastCGI to pass the request to the PHP process.
-   **Hop 4 (Backend to Mailboxd):** The patched PHP backend acts as a REST client. It makes a series of direct, internal **HTTP/REST** calls from the container to the Z-Push Shim endpoint on the Zimbra Mailboxd server (e.g., `http://localhost:8080/service/extension/zpush-shim`), using `action` parameters to specify the desired operation. This connection does **not** go back through the main Zimbra NGINX proxy.

## 2. The Z-Push Docker Container

The container is the heart of this solution. It is defined by three key files: `Dockerfile`, `docker-compose.yml`, and `entrypoint.sh`.

### 2.1. `Dockerfile`: Building the Image

The `Dockerfile` is a blueprint for creating the container image. It performs the following steps:

1.  **`FROM debian:bookworm-slim`**: Starts with a minimal Debian "Bookworm" base image.
2.  **`RUN apt-get install ...`**: Installs all necessary software: `nginx`, `php-fpm`, and the required PHP extensions (`php-xml`, `php-curl`, `php-soap`, etc.).
3.  **`COPY build/z-push/ ...`**: Copies the Z-Push application source code (fetched by `manage.sh`) into the image at `/var/www/zpush`.
4.  **`COPY build/zimbra-backend/ ...`**: Copies the Zimbra Backend module (also fetched by `manage.sh`) into the correct directory within the Z-Push source tree.
5.  **`COPY nginx-zpush.conf ...`**: Copies the container-specific NGINX configuration into the image.
6.  **`COPY entrypoint.sh ...`**: Copies the startup script into the image and makes it executable.
7.  **`EXPOSE 8080`**: Declares that the container listens on port 8080 internally.
8.  **`ENTRYPOINT [...]`**: Sets the `entrypoint.sh` script to be the main process that runs when the container starts.

### 2.2. `docker-compose.yml`: Defining the Service

This file tells Docker Compose how to run the container as a service:

-   **`build: context: .`**: Specifies that the image should be built from the `Dockerfile` in the current directory.
-   **`image: ${ZPUSH_IMAGE...}`**: Assigns a name and tag to the built image, taken from the `.env` file.
-   **`ports: - "127.0.0.1:${ZPUSH_HTTP_PORT...}:8080"`**: This is a critical instruction. It maps port 8080 *inside* the container to a port on the host machine (defaulting to 9073). Crucially, it binds **only to `127.0.0.1`**, the loopback interface. This ensures the container is **not** accessible from any external network, and only the local Zimbra proxy can communicate with it.
-   **`volumes: ...`**: This instruction mounts host directories into the container, ensuring data persistence:
    -   `./zpush/config:/data/config`: Persists the Z-Push configuration (`config.php`).
    -   `./zpush/state:/data/state`: Persists Z-Push state information (like sync states).
    -   `./zpush/log:/data/log`: Persists Z-Push and NGINX logs.
-   **`environment: ...`**: Passes environment variables from the `.env` file into the container, allowing you to tune PHP settings like memory limits and upload sizes without rebuilding the image.

### 2.3. `entrypoint.sh`: Container Startup Logic

This script runs every time the container starts. It handles the final setup:

1.  **Applies Tunings:** It reads the environment variables (e.g., `PHP_MEMORY_LIMIT`) and writes them into the correct PHP and NGINX configuration files inside the container.
2.  **Ensures `config.php` Exists:** It checks if a `config.php` exists in the persistent `/data/config` volume. If not, it copies the default sample file into place. This means your configuration is preserved even if the container is recreated.
3.  **Symlinks `config.php`:** It creates a symbolic link from the application directory (`/var/www/zpush/config.php`) to the persistent file (`/data/config/config.php`).
4.  **Starts Services:** It starts the `php-fpm` service in the background and then starts `nginx` in the foreground, which keeps the container running.

## 3. End-to-End Request Flow (Detailed)

Here is a detailed walkthrough of a request, with logging and debugging points.

1.  **Client Request**: A mobile device sends a request, e.g., `POST /Microsoft-Server-ActiveSync` to `https://mail.example.com`.

2.  **Zimbra NGINX Proxy**: 
    -   **Action**: Receives the request, terminates TLS. It matches the `location = /Microsoft-Server-ActiveSync` block defined in the HTTPS web template.
    -   **Code**: The `proxy_pass http://zpush;` directive forwards the request.
    -   **Debug**: Check `/opt/zimbra/log/nginx.access.log` on the Zimbra server. You should see the `POST` request with a `200` or other status code. If you see a `404` here, the `location` block is missing or incorrect in your Zimbra templates.

3.  **Into the Container (HTTP)**:
    -   **Action**: The request travels over the loopback interface (`127.0.0.1`) via plain HTTP to the port the container is listening on (e.g., 9073).
    -   **Debug**: If Zimbra's NGINX logs show a `502 Bad Gateway`, it means it could not connect to the container. Check if the container is running (`docker ps`) and if the port in the `upstream zpush` block matches the port in your `docker-compose.yml`.

4.  **Container's NGINX**:
    -   **Action**: The NGINX process inside the container receives the request on port 8080. Its configuration (`nginx-zpush.conf`) is intentionally restrictive for security. It only accepts the exact URIs required for ActiveSync and passes them to PHP-FPM. All other URIs are rejected with a `404`.
    -   **Debug**: Check the container logs with `./manage.sh --logs`. You should see an access log entry from the container's NGINX. If not, the request never made it into the container.
    -   **Why Not Expose the Document Root?** The configuration does not set a public document root (e.g., `location / { ... }`). This is a security measure to prevent accidental exposure of other PHP files, source code, or directories within the Z-Push application.
    -   **Debugging Tip**: For temporary debugging, you *could* modify `nginx-zpush.conf` to add a `location /` block to browse the file structure, but **this is highly discouraged in production**.

5.  **Container's PHP-FPM**:
    -   **Action**: The PHP-FPM process executes `/var/www/zpush/index.php`.
    -   **Debug**: PHP errors (e.g., syntax errors, fatal errors) will be logged here. Check `./manage.sh --logs`.

6.  **Patched Z-Push Application (`BackendZimbra`)**:
    -   **Action**: The patched Z-Push code, specifically the `BackendZimbra` module, acts as a **full REST client**. It checks if `ZIMBRA_USE_JAVA_SHIM` is enabled in `config.php`.
    -   **Debug**: Z-Push has its own application-level logging. You can increase the `LOGLEVEL` in `zpush/config/config.php` and check the log files in `zpush/log/` for detailed information about which backend (REST shim or SOAP fallback) is being used.

7.  **Direct Connection to Zimbra Mailboxd (Jetty)**:
    -   **Action**: If the shim is enabled, the `BackendZimbra` module makes a **direct HTTP/REST network connection from the container to the Z-Push Shim endpoint** on the Zimbra mailboxd server (e.g., `http://localhost:8080/service/extension/zpush-shim`). It sends requests like `action=authenticate` or `action=getfolders` and receives a JSON response. This connection does **not** go back through the main Zimbra NGINX proxy.
    -   **Debug**: To troubleshoot this specific hop, you must verify that the container can resolve and connect to the Zimbra REST shim URL. Use `docker exec -it <container_name> curl -d "action=ping" http://<zimbra_host>:8080/service/extension/zpush-shim` to test connectivity directly from inside the container. A `Connection refused` or `Host not found` error indicates a network problem between the container and the mailboxd server.

8.  **The Return Journey**: The JSON response from the shim is processed by the PHP backend and transformed into an ActiveSync response, which then flows back through the exact same chain to the client.

## 4. Deployment & Configuration (Revised)

Deployment requires actions on both the Zimbra server and within this project's directory.

### 4.1. Step 1: Deploy the Z-Push Shim to Zimbra

Before configuring the container, you must install the shim on your Zimbra Mailboxd server(s).

1.  Obtain the `zpush-shim.jar` file.
2.  Copy it to `/opt/zimbra/lib/ext/zpush-shim/` on each mailboxd server.
3.  Restart the mailboxd service: `zmmailboxdctl restart`.

### 4.2. Step 2: Prepare and Configure the Z-Push Container

In this project directory:

1.  **`./manage.sh --init`**: Creates the `.env` file and persistent data directories.
2.  **`./manage.sh --fetch`**: Clones the Z-Push source code into `build/z-push`.
3.  **`./manage.sh --fetch-backend`**: Downloads the standard Zimbra Backend module.
4.  **Apply the Shim Patch**: This is a **critical manual step**. The `zimbra.patch` file, which contains the REST client logic, must be applied to the backend code.
    ```bash
    # Note: Ensure your patch file is complete and contains the logic for all REST actions.
    patch build/z-push/backend/zimbra/zimbra.php < /path/to/your/zimbra.patch
    ```
5.  **`./manage.sh --vendor-backend`**: Copies the *patched* backend into the final application source tree.
6.  **Configure `config.php`**: Edit `zpush/config/config.php` and add the following line to enable the shim functionality:
    ```php
    define('ZIMBRA_USE_JAVA_SHIM', true);
    ```
7.  **`./manage.sh --up`**: Builds the container with the patched code and starts the service.

### 4.3. Step 3: Configure Zimbra NGINX Proxy

1.  **`./manage.sh --print-nginx`**: Displays the `upstream` and `location` blocks.
2.  **`./manage.sh --patch-templates-auto [dir]`**: Automatically injects the snippets into your Zimbra NGINX templates.
3.  **`zmproxyctl restart`**: Applies the NGINX changes on the Zimbra server.

## 5. Full Commands Reference

**Setup**
- `./manage.sh --init`: Creates `.env` and data dirs (config/state/log)
- `./manage.sh --fetch`: Clone/refresh Z-Push into build/
- `./manage.sh --fetch-backend`: Download & stage Zimbra Backend (SourceForge)
- `./manage.sh --vendor-backend`: Copy staged backend into Z-Push tree

**Build & Run**
- `./manage.sh --build`: Builds the container image.
- `./manage.sh --up`: Starts the container (builds if needed) binding `127.0.0.1:${ZPUSH_HTTP_PORT}`.
- `./manage.sh --down`: Stops and removes the container.
- `./manage.sh --logs`: Tails container logs.
- `./manage.sh --health`: Checks `http://127.0.0.1:${ZPUSH_HTTP_PORT}/healthz`.
- `./manage.sh --set-port <port>`: Updates `.env` to change the loopback port.

**Proxy Snippets**
- `./manage.sh --print-nginx`: Shows NGINX upstream + location snippets for Zimbra proxy.

**Templates: Inspect & Patch**
- `./manage.sh --verify-templates [dir]`: Greps template tree for EAS/autodiscover refs.
- `./manage.sh --patch-templates [dir]`: Creates a tar.gz backup and prints manual patching guidance.
- `./manage.sh --patch-templates-auto [dir]`: Auto-injects upstream+locations into HTTPS templates.

**Templates: Backup & Revert**
- `./manage.sh --backup-templates [dir]`: Creates `<parent>/<basename>-backup.tgz`.
- `./manage.sh --restore-templates <dir> [backup.tar.gz]`: Restores from a tarball.
- `./manage.sh --revert-templates-auto [dir]`: Removes only the injected blocks using markers.

## 6. Troubleshooting Checklist

-   **502/504 Bad Gateway**: The Zimbra proxy can't talk to the container. Check that the container is running (`docker ps`) and that the ports match.
-   **Shim-specific Errors**: If Z-Push logs show "falling back to SOAP" or other shim-related errors, the issue is with the REST shim connection.
    -   **Verify the shim is deployed**: Check for `zpush-shim.jar` on the mailboxd server.
    -   **Verify `config.php`**: Ensure `ZIMBRA_USE_JAVA_SHIM` is `true`.
    -   **Test connectivity from the container**: Use `curl` to test the shim endpoint directly. A `401 Unauthorized` is an expected response for a `ping` without a valid token, but `Connection refused` indicates a network problem.
        ```bash
        # Test the ping action
        docker exec -it <container_name> curl -d "action=ping" http://<zimbra_host>:8080/service/extension/zpush-shim
        ```
-   **413 Request Entity Too Large**: The file being synced is too big. Increase `client_max_body_size` in the Zimbra proxy templates, and `PHP_UPLOAD_MAX_FILESIZE` / `PHP_POST_MAX_SIZE` in your `.env` file.

## 7. Advanced Topics

### 7.1. Zimbra NGINX Internals

-   **Generated config**: `/opt/zimbra/conf/nginx/includes/` (do not edit).
-   **Templates**: `/opt/zimbra/conf/nginx/templates/` (edit here).
-   **Regeneration**: `zmproxyctl restart` triggers `zconfigd` which runs `zmproxyconfgen` to build includes from templates.
-   **Template DSL**: The templates use a simple language with `${...}` variables, `{if...}` conditionals, and `explode` for loops.

### 7.2. Jetty CGI vs. php-fpm Container

This container-based `php-fpm` approach is favored over the older Jetty CGI method for several reasons:
-   **Pros**: Better isolation from `mailboxd`, allows for independent resource tuning (PHP memory vs. Java heap), and a smaller blast radius if Z-Push fails.
-   **Cons**: Adds Docker as a dependency and requires edits to the NGINX templates.