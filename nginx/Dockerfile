# Use a slim Debian image as the base
FROM debian:bookworm-slim

# Set environment variables
ENV DEBIAN_FRONTEND=noninteractive
ENV NGINX_WORKER_PROCESSES=auto

# Install necessary packages:
# nginx, php, and their dependencies for the web server
# curl, wget, ca-certificates, tar for downloading and extracting files
# tini as a lightweight init system
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
    nginx vim \
    php-fpm php-cli php-xml php-curl php-mbstring php-soap php-zip \
    ca-certificates curl wget tar tini gettext-base \
 && rm -rf /var/lib/apt/lists/*

# Install Composer (PHP dependency manager)
RUN curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

# --- Automated Download and Installation ---
# This single RUN command performs all the steps from your script to keep the number of image layers small.
RUN set -e && \
    # 1. Fetch latest Z-Push version tag from GitHub API
    echo "Fetching latest Z-Push release information..." && \
    LATEST_TAG=$(curl -s https://api.github.com/repos/Z-Hub/Z-Push/releases/latest | grep '"tag_name"' | cut -d '"' -f 4) && \
    if [ -z "$LATEST_TAG" ]; then echo "Error: Could not find latest Z-Push tag." >&2; exit 1; fi && \
    echo "Latest Z-Push version found: $LATEST_TAG" && \
    \
    # 2. Download the frontend and backend archives
    DOWNLOAD_URL="https://github.com/Z-Hub/Z-Push/archive/refs/tags/${LATEST_TAG}.tar.gz" && \
    echo "Downloading Z-Push frontend..." && \
    wget -q -O z-push.tar.gz "$DOWNLOAD_URL" && \
    echo "Downloading latest Z-Push Zimbra backend..." && \
    wget -q -O zpushzimbra.tar.gz https://sourceforge.net/projects/zimbrabackend/files/latest/download && \
    \
    # 3. Create directories and extract Z-Push source directly
    echo "Setting up Z-Push directories..." && \
    mkdir -p /var/www/zpush && \
    echo "Extracting Z-Push 'src' directory..." && \
    tar xf ./z-push.tar.gz -C /var/www/zpush --strip-components=2 "Z-Push-${LATEST_TAG}/src" && \
    \
    # 4. Extract Zimbra backend into the correct location
    echo "Extracting Zimbra backend..." && \
    mkdir -p /var/www/zpush/backend/zimbra && \
    tar zxf zpushzimbra.tar.gz -C /var/www/zpush/backend/zimbra --strip-components=1 && \
    \
    # 5. Run composer for the main application and the backend
    echo "Installing main Z-Push composer dependencies..." && \
    composer install --working-dir=/var/www/zpush --no-dev --no-interaction && \
    echo "Installing composer dependencies for Zimbra backend..." && \
    composer require --working-dir=/var/www/zpush/backend/zimbra halaxa/json-machine --update-no-dev --no-interaction && \
    \
    # 6. Clean up downloaded archives to keep the final image small
    echo "Cleaning up..." && \
    rm -f z-push.tar.gz zpushzimbra.tar.gz

# Prepare additional filesystem directories needed at runtime
RUN mkdir -p /run/php /data/config /data/state /data/log

# Set correct ownership for the web server user (www-data on Debian)
# This is critical to prevent permission errors
RUN chown -R www-data:www-data /var/www/zpush /data

# Copy container-specific config files and the entrypoint script
COPY nginx-zpush.conf /etc/nginx/conf.d/zpush.conf
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh \
 && rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-available/default || true

# Expose the port the container will listen on
EXPOSE 8080

# Add a healthcheck to ensure the service is running correctly
HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
  CMD curl -fsS http://127.0.0.1:8080/healthz || exit 1

# Set the entrypoint for the container
ENTRYPOINT ["/usr/bin/tini","--","/entrypoint.sh"]

