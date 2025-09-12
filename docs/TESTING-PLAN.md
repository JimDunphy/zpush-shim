# Z-Push Container Smoke Test Plan

## 1. Objective

The purpose of this test plan is to perform a "smoke test" on the base Z-Push container. This plan validates that the container builds correctly, that the Z-Push application is installed, and that the core application endpoints are responding.

This test is performed **without** the Z-Push Shim patch to ensure the fundamental components are working before introducing the complexity of the REST shim integration.

## 2. Test Steps

### Step 2.1: Prepare and Build the Base Container

This step prepares the necessary source code and then validates that the `Dockerfile` is syntactically correct and that all OS-level dependencies can be successfully installed.

**Command:**

```bash
# From the 'nginx' directory

# 1. Initialize the project, creating .env and required directories
./manage.sh --init

# 2. Fetch the Z-Push source code
./manage.sh --fetch

# 3. Fetch the Zimbra Backend source code
./manage.sh --fetch-backend

# 4. Copy the backend into the Z-Push source tree
./manage.sh --vendor-backend

# 5. Now, build the container image
./manage.sh --build
```

**Expected Outcome:**

- All commands complete without any errors.
- The final output of the `--build` step shows that the image (e.g., `local/zpush:latest`) has been successfully built and tagged.

### Step 2.2: Start the Container

This step validates that the container can be started successfully using Docker Compose and that the port mapping is correctly established.

**Command:**

```bash
# From the 'nginx' directory
./manage.sh --up
```

**Expected Outcome:**

- The `docker compose up` command starts the container without errors.
- Running `docker ps` in a separate terminal should show the container in an "Up" state. The "PORTS" column should show `127.0.0.1:9073->8080/tcp` (or the custom port if `ZPUSH_HTTP_PORT` was changed in `.env`).

### Step 2.3: Verify Z-Push Installation (Internal Check)

This step validates that the Z-Push application files were correctly copied into the container image during the build process.

**Command:**

```bash
# Find the container name or ID first with 'docker ps'
# Then execute this command, replacing <container_name>
docker exec -it <container_name> ls -l /var/www/zpush/index.php
```

**Expected Outcome:**

- The command executes without error.
- The output shows the file details for `index.php`, confirming its existence and permissions (e.g., `-rw-r--r-- 1 www-data www-data ... /var/www/zpush/index.php`).

### Step 2.4: Verify Z-Push Endpoints (External Check)

This is the most critical step. It validates that NGINX and PHP-FPM are running correctly inside the container and that the Z-Push application can be executed. We will test the two primary ActiveSync endpoints from the host machine.

**Commands:**

1.  **Test the ActiveSync Endpoint:**

    ```bash
    curl -v -X POST http://127.0.0.1:9073/Microsoft-Server-ActiveSync
    ```

2.  **Test the Autodiscover Endpoint:**

    ```bash
    curl -v -X POST http://127.0.0.1:9073/autodiscover/Autodiscover.xml
    ```

**Expected Outcomes:**

-   **For both commands, the most important result is the HTTP status code.** You should see `< HTTP/1.1 401 Unauthorized`.
-   A `401 Unauthorized` response is the **correct** outcome. It proves that the request successfully traversed the container's NGINX, was passed to PHP-FPM, and the Z-Push application executed and correctly determined that the request was missing credentials.
-   **An incorrect outcome** would be a connection error (e.g., `Connection refused`), a gateway error (`502 Bad Gateway`), or a server error (`500 Internal Server Error`).

## 3. Cleanup

After the tests are complete, you can stop and remove the container.

**Command:**

```bash
# From the 'nginx' directory
./manage.sh --down
```

**Expected Outcome:**

- The container is stopped and removed without errors.
- Running `docker ps` should no longer show the test container.
