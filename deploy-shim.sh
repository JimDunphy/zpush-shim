#!/bin/bash

# Z-Push Java Shim Deployment Script
# 
# This script automates the deployment of the Java Shim to Zimbra

set -e  # Exit on any error

# Script configuration
SCRIPT_VERSION="1.0"
SCRIPT_NAME="Z-Push Java Shim Deployment"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Help function
show_help() {
    cat << EOF
$SCRIPT_NAME v$SCRIPT_VERSION

USAGE:
    $0 [OPTIONS]

OPTIONS:
    --help              Show this help message
    --build             Build the Java shim JAR
    --deploy            Deploy to Zimbra
    --undeploy          Remove the extension from Zimbra (backup then remove)
    --restart           Restart Zimbra services
    --verify            Verify deployment
    --plan              Dry-run: show exactly what --deploy would do
    --status            Show install status (paths, file, logs, endpoint ping)
    --all               Build, deploy, restart, and verify
    
EXAMPLES:
    $0 --build          # Build JAR only
    $0 --deploy         # Deploy existing JAR
    $0 --all            # Complete deployment process

REQUIREMENTS:
    - Apache Ant for building (Zimbra's official build system)
    - Java:
        * On Zimbra servers: bundled JDK at /opt/zimbra/common/lib/jvm/java (sourced automatically)
        * Elsewhere: a modern JDK (8+/11/17); e.g., on RHEL: sudo dnf install -y java-11-openjdk-devel
    - Zimbra user access for deployment
    - Root/sudo privileges for service restart

CROSS-MACHINE DEVELOPMENT:
    - Build on any machine with 'ant jar'
    - Copy JAR to Zimbra server for deployment
    - Supports development without Zimbra installation

EOF
}

# Check if running as zimbra user for deployment
check_zimbra_user() {
    if [ "$EUID" -ne 0 ] && [ "$(whoami)" != "zimbra" ]; then
        log_error "Operation must be run as root or zimbra user"
        exit 1
    fi
}

# Require root for filesystem operations under /opt/zimbra/lib/ext
require_root_fs() {
    if [ "$EUID" -ne 0 ]; then
        log_error "This action requires root (filesystem changes under /opt/zimbra/lib/ext)"
        exit 1
    fi
}

# Build the Java shim using Ant (Zimbra's build system)
advise_pkg_install() {
    if command -v dnf >/dev/null 2>&1; then
        echo "sudo dnf install -y ant java-11-openjdk-devel"
    elif command -v yum >/dev/null 2>&1; then
        echo "sudo yum install -y ant java-11-openjdk-devel"
    else
        echo "Install Apache Ant and a JDK (11+ recommended) via your OS package manager."
    fi
}

# Build the Java shim using Ant (Zimbra's build system)
build_shim() {
    log_info "Building Java Shim using Ant..."

    # Prefer Zimbra's Java when available to avoid classpath/version drift
    if [ -f "/opt/zimbra/bin/zmshutil" ]; then
        log_info "Sourcing Zimbra environment (/opt/zimbra/bin/zmshutil)"
        # shellcheck disable=SC1091
        source /opt/zimbra/bin/zmshutil || true
        if command -v zmsetvars >/dev/null 2>&1; then
            zmsetvars -f || true
        fi
        if [ -n "${zimbra_java_home:-}" ] && [ -x "${zimbra_java_home}/bin/java" ]; then
            export JAVA_HOME="${zimbra_java_home}"
            export PATH="${JAVA_HOME}/bin:${PATH}"
            # Optional: set JRE_EXT_DIR similar to zmjava behavior (not required for Ant)
            if [ -d "${zimbra_java_home}/jre" ]; then
                export JRE_EXT_DIR="${zimbra_java_home}/jre/lib/ext"
            else
                export JRE_EXT_DIR="${zimbra_java_home}/lib/ext"
            fi
            log_info "Using Zimbra Java: $(${JAVA_HOME}/bin/java -version 2>&1 | head -1)"
        else
            log_warning "Could not determine zimbra_java_home; falling back to system Java"
        fi
    fi

    if [ ! -f "build.xml" ]; then
        log_error "build.xml not found. Are you in the correct directory?"
        exit 1
    fi

    # Verify Java presence
    if ! command -v java >/dev/null 2>&1; then
        log_error "Java not found on PATH"
        log_info "Install guidance (RHEL): $(advise_pkg_install)"
        exit 1
    else
        log_info "Java detected: $(java -version 2>&1 | head -1)"
    fi

    if ! command -v ant >/dev/null 2>&1; then
        log_error "Ant not found on PATH"
        log_info "Install guidance (RHEL): $(advise_pkg_install)"
        exit 1
    fi

    # Build using Ant
    ant clean jar
    
    if [ $? -eq 0 ]; then
        log_success "Java Shim built successfully"
        if [ -f "dist/zpush-shim.jar" ]; then
            log_info "JAR file: dist/zpush-shim.jar"
        fi
    else
        log_error "Build failed"
        exit 1
    fi
}

# Deploy to Zimbra using extension model
deploy_shim() {
    log_info "Deploying Java Shim to Zimbra as extension..."

    require_root_fs

    # Find Zimbra home
    if [ -d "/opt/zimbra" ]; then
        ZIMBRA_HOME="/opt/zimbra"
    elif [ -d "/usr/local/zimbra" ]; then
        ZIMBRA_HOME="/usr/local/zimbra"
    else
        log_error "Zimbra installation not found"
        exit 1
    fi
    
    log_info "Found Zimbra at: $ZIMBRA_HOME"
    
    # Check for JAR file
    JAR_FILE="dist/zpush-shim.jar"
    if [ ! -f "$JAR_FILE" ]; then
        log_error "JAR file not found: $JAR_FILE"
        log_info "Run --build first to create the JAR file"
        exit 1
    fi
    
    # Deploy to Zimbra extension directory
    EXTENSION_NAME="zpush-shim"
    DEPLOY_DIR="$ZIMBRA_HOME/lib/ext/$EXTENSION_NAME"
    
    log_info "Creating extension directory: $DEPLOY_DIR (root:root 755)"
    mkdir -p "$DEPLOY_DIR"
    chown root:root "$DEPLOY_DIR" || true
    chmod 755 "$DEPLOY_DIR" || true
    
    # Copy JAR file, set permissions similar to other extensions (root:root 444)
    cp "$JAR_FILE" "$DEPLOY_DIR/zpush-shim.jar"
    chown root:root "$DEPLOY_DIR/zpush-shim.jar"
    chmod 444 "$DEPLOY_DIR/zpush-shim.jar"
    
    log_success "Java Shim deployed successfully to Zimbra extension directory"
    log_info "Extension directory: $DEPLOY_DIR"
    log_info "JAR file: $DEPLOY_DIR/zpush-shim.jar"
    
    echo
    log_info "IMPORTANT: Restart Zimbra mailbox service to load the extension:"
    log_info "su - zimbra -c 'zmmailboxdctl restart'"
}

# Remove the deployed extension (safe undeploy)
undeploy_shim() {
    log_info "Undeploying Java Shim from Zimbra..."

    require_root_fs

    # Locate Zimbra
    if [ -d "/opt/zimbra" ]; then
        ZIMBRA_HOME="/opt/zimbra"
    elif [ -d "/usr/local/zimbra" ]; then
        ZIMBRA_HOME="/usr/local/zimbra"
    else
        log_error "Zimbra installation not found"
        exit 1
    fi

    EXTENSION_NAME="zpush-shim"
    EXT_DIR="$ZIMBRA_HOME/lib/ext/$EXTENSION_NAME"

    if [ ! -d "$EXT_DIR" ]; then
        log_warning "Extension directory not found: $EXT_DIR"
        log_info "Nothing to remove."
        return 0
    fi

    # Important: Do NOT leave backups under lib/ext (Zimbra loads any subdir here)
    TS=$(date +%Y%m%d%H%M%S)
    DISABLED_ROOT="$ZIMBRA_HOME/lib/ext-disabled"
    BAK_DIR="$DISABLED_ROOT/${EXTENSION_NAME}.bak.$TS"
    mkdir -p "$DISABLED_ROOT"
    log_info "Moving extension out of lib/ext to: $BAK_DIR"
    mv "$EXT_DIR" "$BAK_DIR"

    if [ $? -eq 0 ]; then
        log_success "Extension moved to: $BAK_DIR"
        log_info "Restart mailboxd to fully unload the extension:"
        log_info "su - zimbra -c 'zmmailboxdctl restart'"
    else
        log_error "Failed to move extension directory"
        exit 1
    fi
}

# Restart Zimbra mailbox service (required for extensions)
restart_zimbra() {
    log_info "Restarting Zimbra mailbox service (required for extension loading)..."
    
    if [ "$(whoami)" != "zimbra" ]; then
        log_info "Switching to zimbra user for service restart"
        su - zimbra -c "zmmailboxdctl restart"
    else
        zmmailboxdctl restart
    fi
    
    if [ $? -eq 0 ]; then
        log_success "Zimbra mailbox service restarted successfully"
        log_info "Extension should now be loaded"
    else
        log_error "Failed to restart Zimbra mailbox service"
        exit 1
    fi
}

# Verify deployment
verify_deployment() {
    log_info "Verifying Java Shim extension deployment..."
    
    # Check if JAR is deployed in extension directory
    if [ -d "/opt/zimbra" ]; then
        ZIMBRA_HOME="/opt/zimbra"
    elif [ -d "/usr/local/zimbra" ]; then
        ZIMBRA_HOME="/usr/local/zimbra"
    else
        log_error "Zimbra installation not found"
        return 1
    fi
    EXTENSION_DIR="$ZIMBRA_HOME/lib/ext/zpush-shim"
    JAR_PATH="$EXTENSION_DIR/zpush-shim.jar"
    
    if [ -f "$JAR_PATH" ]; then
        log_success "Extension JAR deployed: $JAR_PATH"
    else
        log_error "Extension JAR not found: $JAR_PATH"
        return 1
    fi
    
    # Test extension endpoint (mailboxd Jetty on loopback)
    log_info "Testing extension endpoint..."
    SHIM_URL="http://127.0.0.1:8080/service/extension/zpush-shim"

    # Ensure curl is available
    if ! command -v curl >/dev/null 2>&1; then
        log_warning "curl not found; skipping HTTP verification"
    else
        # Wait for mailboxd to come up and the extension to load (retry up to ~60s)
        attempts=0
        RESPONSE=""
        until [ $attempts -ge 12 ]; do
            RESPONSE=$(curl -sS --max-time 5 -X POST -d "action=ping" "$SHIM_URL" 2>/dev/null || true)
            if [[ "$RESPONSE" == *"\"status\":\"ok\""* ]]; then
                log_success "Extension endpoint responding correctly"
                log_info "Response: $RESPONSE"
                break
            fi
            attempts=$((attempts+1))
            sleep 5
        done
        if [ $attempts -ge 12 ]; then
            log_warning "Extension endpoint did not respond with status=ok. Last response: ${RESPONSE:-<none>}"
            log_info "You can test manually with: curl -X POST -d 'action=ping' $SHIM_URL"
        fi
    fi
    
    # Check Zimbra logs for extension loading
    LOG_FILE="$ZIMBRA_HOME/log/mailbox.log"
    if [ -f "$LOG_FILE" ]; then
        RECENT_LOGS=$(tail -n 50 "$LOG_FILE" | grep -i "zpush\|shim\|extension" || echo "No extension-related log entries found")
        if [ "$RECENT_LOGS" != "No extension-related log entries found" ]; then
            log_info "Recent extension-related log entries:"
            echo "$RECENT_LOGS"
        fi
    fi
    
    log_success "Extension deployment verification completed"
    
    echo
    log_info "Next steps:"
    log_info "1. Configure Z-Push to use the shim in config.php:"
    log_info "   define('ZIMBRA_USE_JAVA_SHIM', true);"
    log_info "   define('ZIMBRA_SHIM_URL', 'http://localhost:8080/service/extension/zpush-shim');"
    log_info "2. Test with a mobile device"
    log_info "3. Monitor Z-Push logs for 'Java Shim' messages"
}

# Dry-run: Show what --deploy would do
plan_actions() {
    echo
    log_info "Dry-run: showing deploy actions (no changes made)"
    if [ -d "/opt/zimbra" ]; then
        ZIMBRA_HOME="/opt/zimbra"
    elif [ -d "/usr/local/zimbra" ]; then
        ZIMBRA_HOME="/usr/local/zimbra"
    else
        log_error "Zimbra installation not found"
        return 1
    fi
    EXTENSION_NAME="zpush-shim"
    DEPLOY_DIR="$ZIMBRA_HOME/lib/ext/$EXTENSION_NAME"
    JAR_FILE="dist/zpush-shim.jar"

    echo "- Will create extension dir: $DEPLOY_DIR (root:root 755)"
    echo "- Will copy JAR: $JAR_FILE -> $DEPLOY_DIR/zpush-shim.jar (root:root 444)"
    echo "- Requires: su - zimbra -c 'zmmailboxdctl restart' to load the extension"
    echo
    if [ -f "$JAR_FILE" ]; then
        log_info "JAR present: $JAR_FILE ($(stat -c '%s bytes, mtime=%y' "$JAR_FILE" 2>/dev/null || stat -f '%z bytes' "$JAR_FILE" 2>/dev/null))"
    else
        log_warning "JAR not found at $JAR_FILE. Run: ant clean jar"
    fi
}

# Status: Show whether the extension is installed and responsive
status_shim() {
    if [ -d "/opt/zimbra" ]; then
        ZIMBRA_HOME="/opt/zimbra"
    elif [ -d "/usr/local/zimbra" ]; then
        ZIMBRA_HOME="/usr/local/zimbra"
    else
        log_error "Zimbra installation not found"
        return 1
    fi
    EXT_DIR="$ZIMBRA_HOME/lib/ext/zpush-shim"
    JAR_PATH="$EXT_DIR/zpush-shim.jar"
    echo
    log_info "Extension directory: $EXT_DIR"
    if [ -d "$EXT_DIR" ]; then
        log_success "Present"
    else
        log_warning "Not present"
    fi
    log_info "JAR path: $JAR_PATH"
    if [ -f "$JAR_PATH" ]; then
        log_success "Present ($(stat -c '%s bytes, mtime=%y' "$JAR_PATH" 2>/dev/null || stat -f '%z bytes' "$JAR_PATH" 2>/dev/null))"
    else
        log_warning "Not present"
    fi
    # Quick endpoint check (best-effort)
    if command -v curl >/dev/null 2>&1; then
        SHIM_URL="http://127.0.0.1:8080/service/extension/zpush-shim"
        RESP=$(curl -sS --max-time 5 -X POST -d 'action=ping' "$SHIM_URL" 2>/dev/null || true)
        if [[ "$RESP" == *"\"status\":\"ok\""* ]]; then
            log_success "Endpoint responds at $SHIM_URL"
        else
            log_warning "Endpoint did not return status=ok (mailboxd may need restart)"
        fi
    fi
    # Recent log lines
    LOG_FILE="$ZIMBRA_HOME/log/mailbox.log"
    if [ -f "$LOG_FILE" ]; then
        echo
        log_info "Recent extension-related log lines (mailbox.log):"
        tail -n 100 "$LOG_FILE" | egrep -i 'zpush|shim|extension|registered handler' | tail -n 20 || true
    fi
}

# Main execution
main() {
    echo -e "${BLUE}$SCRIPT_NAME v$SCRIPT_VERSION${NC}"
    echo "=============================================="
    echo
    
    case "${1:-}" in
        --help|-h)
            show_help
            exit 0
            ;;
        --build)
            build_shim
            ;;
        --deploy)
            require_root_fs
            deploy_shim
            ;;
        --undeploy)
            require_root_fs
            undeploy_shim
            ;;
        --restart)
            check_zimbra_user
            restart_zimbra
            ;;
        --verify)
            verify_deployment
            ;;
        --plan)
            plan_actions
            ;;
        --status)
            status_shim
            ;;
        --all)
            build_shim
            check_zimbra_user
            deploy_shim
            restart_zimbra
            verify_deployment
            ;;
        *)
            show_help
            log_error "Invalid or missing option"
            exit 1
            ;;
    esac
}

# Run main function with all arguments
main "$@"
