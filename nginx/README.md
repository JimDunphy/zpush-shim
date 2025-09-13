# Z-Push for Zimbra

This project provides a self-contained, containerized Z-Push service for Zimbra, enabling ActiveSync and Autodiscover functionality. A `manage.sh` script is included to simplify the deployment and lifecycle management of the container.

## Prerequisites

- Docker and Docker Compose must be installed on the host machine.
- The Zimbra server's proxy must be accessible from the machine running this container.

## Quick Start Deployment

Deploying the Z-Push container is a simple two-step process:

1.  **Initialize the Environment:**

    This command creates the necessary data directories (`./zpush/config`, `./zpush/state`, `./zpush/log`) and a `.env` file from the `env.example` template.

    ```bash
    ./manage.sh --init
    ```

2.  **Build and Start the Container:**

    This command builds the Docker image and starts the container in the background. On the first run, it will automatically download the latest versions of Z-Push and the Zimbra Backend. Subsequent runs will use the `--build` flag to ensure any changes to the `Dockerfile` or `entrypoint.sh` are applied.

    ```bash
    ./manage.sh --up
    ```

3.  **Configure Zimbra's NGINX Proxy:**

    The Z-Push container is now running and listening on `127.0.0.1:9073` (by default). The final step is to configure your Zimbra server's NGINX to proxy ActiveSync requests to the container.

    The `manage.sh` script provides the necessary NGINX configuration snippets. Run this command and add the output to your Zimbra proxy configuration.

    ```bash
    ./manage.sh --print-nginx
    ```

    You will need to add the `upstream` and `location` blocks to the appropriate template files (typically under `/opt/zimbra/conf/nginx/templates/`) on your Zimbra server and then restart the proxy:

    ```bash
    zmproxyctl restart
    ```

## Container Management

-   **Stop and Remove the Container:**
    ```bash
    ./manage.sh --down
    ```

-   **View Container Logs:**
    ```bash
    ./manage.sh --logs
    ```

-   **Open a Shell Inside the Container:**
    ```bash
    ./manage.sh --console
    ```

## Upgrading

When a new version of Z-Push or the Zimbra backend is released, you can upgrade your container with the following process:

1.  **Check for New Configuration:**

    The `upgrade` command will pull the latest Docker image, export the new default configuration files, and save them with a `.latest` extension for you to compare.

    ```bash
    ./manage.sh --upgrade
    ```
    Manually `diff` your current `zpush/config/config.php` with `zpush/config/config.php.latest` and merge any new settings.

2.  **Restart the Container with the New Image:**
    ```bash
    ./manage.sh --up
    ```

## Backups

To create a backup of your persistent data (configuration, state, and logs), use the `backup` command. This will create a timestamped `zpush-backup-*.tar.gz` file in the project directory.

```bash
./manage.sh --backup
