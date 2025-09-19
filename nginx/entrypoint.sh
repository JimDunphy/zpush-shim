#!/bin/bash
set -e

# Define paths
DATA_DIR="/data"
CONFIG_DIR="$DATA_DIR/config"
STATE_DIR="$DATA_DIR/state"
LOG_DIR="$DATA_DIR/log"

ZPUSH_SRC="/var/www/zpush"
MAIN_CONFIG_FILE="$CONFIG_DIR/config.php"
AUTODISCOVER_CONFIG_FILE="$CONFIG_DIR/autodiscover-config.php"

# --- Fix Volume Permissions & Ensure ALL Log Files Exist ---
# We now touch the main logs AND the autodiscover logs.
echo "Ensuring correct ownership and existence of data files..."
touch "$LOG_DIR/z-push.log" "$LOG_DIR/z-push-error.log"
touch "$LOG_DIR/autodiscover.log" "$LOG_DIR/autodiscover-error.log"
chown -R www-data:www-data "$CONFIG_DIR" "$STATE_DIR" "$LOG_DIR"

# --- Main Configuration Setup ---
if [ ! -f "$MAIN_CONFIG_FILE" ]; then
    echo "No main config.php found. Copying default..."
    cp "$ZPUSH_SRC/config.php" "$MAIN_CONFIG_FILE"
    chown www-data:www-data "$MAIN_CONFIG_FILE"
fi
# Also link it to where Z-Push expects to find it
ln -sf "$MAIN_CONFIG_FILE" "$ZPUSH_SRC/config.php"

# --- Autodiscover Configuration Setup ---
if [ ! -f "$AUTODISCOVER_CONFIG_FILE" ]; then
    echo "No autodiscover-config.php found. Copying default..."
    cp "$ZPUSH_SRC/autodiscover/config.php" "$AUTODISCOVER_CONFIG_FILE"
    chown www-data:www-data "$AUTODISCOVER_CONFIG_FILE"
    # Also link it to where Z-Push expects to find it
    ln -sf "$AUTODISCOVER_CONFIG_FILE" "$ZPUSH_SRC/autodiscover/config.php"
fi

# --- Enforce Correct Paths in BOTH Config Files ---
echo "Verifying and setting persistent data paths..."
# Main config
sed -i -E "s#^(\s*define\('STATE_DIR',).*#\1 '$STATE_DIR/');#" "$MAIN_CONFIG_FILE"
sed -i -E "s#^(\s*define\('LOGFILEDIR',).*#\1 '$LOG_DIR/');#" "$MAIN_CONFIG_FILE"
# Force BackendZimbra
sed -i -E "s#^(\s*define\('BACKEND_PROVIDER',\s*)'[^']*'#\1'BackendZimbra'#" "$MAIN_CONFIG_FILE"
# Autodiscover config
sed -i -E "s#^(\s*define\('LOGFILEDIR',).*#\1 '$LOG_DIR/');#" "$AUTODISCOVER_CONFIG_FILE"

# --- Configure Zimbra Backend from Environment Variables ---
ZIMBRA_CONFIG="/var/www/zpush/backend/zimbra/config.php"
if [ -f "$ZIMBRA_CONFIG" ]; then
    echo "Configuring Zimbra backend from environment variables..."
    
    # Fix line endings first
    dos2unix "$ZIMBRA_CONFIG" 2>/dev/null || true
    
    # Remove any existing ZIMBRA_URL definitions to avoid duplicates
    sed -i '/define.*ZIMBRA_URL/d' "$ZIMBRA_CONFIG"
    sed -i '/define.*ZIMBRA_SSL_VERIFYPEER/d' "$ZIMBRA_CONFIG"
    sed -i '/define.*ZIMBRA_SSL_VERIFYHOST/d' "$ZIMBRA_CONFIG"
    
    # Add our configuration at the end of the file
    if [ -n "$ZIMBRA_URL" ]; then
        echo "Setting ZIMBRA_URL to: $ZIMBRA_URL"
        echo "    define('ZIMBRA_URL', '$ZIMBRA_URL');" >> "$ZIMBRA_CONFIG"
    fi
    
    if [ -n "$ZIMBRA_SSL_VERIFYPEER" ]; then
        echo "Setting ZIMBRA_SSL_VERIFYPEER to: $ZIMBRA_SSL_VERIFYPEER"
        echo "    define('ZIMBRA_SSL_VERIFYPEER', $ZIMBRA_SSL_VERIFYPEER);" >> "$ZIMBRA_CONFIG"
    fi
    
    if [ -n "$ZIMBRA_SSL_VERIFYHOST" ]; then
        echo "Setting ZIMBRA_SSL_VERIFYHOST to: $ZIMBRA_SSL_VERIFYHOST"
        echo "    define('ZIMBRA_SSL_VERIFYHOST', $ZIMBRA_SSL_VERIFYHOST);" >> "$ZIMBRA_CONFIG"
    fi
    
    # Add Java Shim configuration
    if [ -n "$ZIMBRA_USE_JAVA_SHIM" ]; then
        echo "Setting ZIMBRA_USE_JAVA_SHIM to: $ZIMBRA_USE_JAVA_SHIM"
        echo "    define('ZIMBRA_USE_JAVA_SHIM', $ZIMBRA_USE_JAVA_SHIM);" >> "$ZIMBRA_CONFIG"
    fi
    
    if [ -n "$ZIMBRA_SHIM_URL" ]; then
        echo "Setting ZIMBRA_SHIM_URL to: $ZIMBRA_SHIM_URL"
        echo "    define('ZIMBRA_SHIM_URL', '$ZIMBRA_SHIM_URL');" >> "$ZIMBRA_CONFIG"
    fi
else
    echo "Warning: Zimbra backend config not found at $ZIMBRA_CONFIG"
fi


# --- Set PHP and NGINX configuration from environment variables ---
echo "Applying runtime PHP & NGINX settings..."
sed -i 's|unix:/run/php/php-fpm.sock|unix:/run/php/php8.2-fpm.sock|' /etc/nginx/conf.d/zpush.conf
sed -i "s/\${ZPUSH_HTTP_PORT}/${ZPUSH_HTTP_PORT:-9073}/g" /etc/nginx/conf.d/zpush.conf
sed -i "s/^;?memory_limit = .*/memory_limit = ${PHP_MEMORY_LIMIT:-256M}/" /etc/php/8.2/fpm/php.ini
sed -i "s/^;?upload_max_filesize = .*/upload_max_filesize = ${PHP_UPLOAD_MAX_FILESIZE:-50M}/" /etc/php/8.2/fpm/php.ini
sed -i "s/^;?post_max_size = .*/post_max_size = ${PHP_POST_MAX_SIZE:-50M}/" /etc/php/8.2/fpm/php.ini
sed -i "s/^;?max_execution_time = .*/max_execution_time = ${PHP_MAX_EXECUTION_TIME:-3600}/" /etc/php/8.2/fpm/php.ini
sed -i "s/^;?max_input_time = .*/max_input_time = ${PHP_MAX_INPUT_TIME:-3600}/" /etc/php/8.2/fpm/php.ini
sed -i "s/client_max_body_size .*;$/client_max_body_size ${NGINX_CLIENT_MAX_BODY_SIZE:-50m};/" /etc/nginx/conf.d/zpush.conf
chown www-data:www-data /run/php

echo "Starting PHP-FPM and NGINX..."
php-fpm8.2 -D
exec nginx -g 'daemon off;'


