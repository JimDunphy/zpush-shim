#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$ROOT_DIR/.env"
ENV_EXAMPLE="$ROOT_DIR/env.example"
DATA_DIR="$ROOT_DIR/zpush" # Main directory for persistent volumes

die() { echo "error: $*" >&2; exit 1; }
info() { echo "[+] $*"; }

ensure_env() {
  if [[ ! -f "$ENV_FILE" ]]; then
    cp "$ENV_EXAMPLE" "$ENV_FILE"
    info "Wrote $ENV_FILE (copied from env.example). Adjust as needed."
  fi
  # shellcheck disable=SC1090
  set -a; source "$ENV_FILE"; set +a
}

cmd_init() {
  mkdir -p "$DATA_DIR/config" "$DATA_DIR/state" "$DATA_DIR/log"
  [[ -f "$ENV_FILE" ]] || cp "$ENV_EXAMPLE" "$ENV_FILE"
  info "Initialized directories in ./zpush/ and created .env file."
}

cmd_build() {
  ensure_env
  info "Building image ${ZPUSH_IMAGE:-local/zpush:latest}"
  docker build -t "${ZPUSH_IMAGE:-local/zpush:latest}" "$ROOT_DIR"
}

cmd_console() {
  ensure_env
  local service_name="zpush"
  info "Opening a shell in the '${service_name}' service container..."
  docker compose --env-file "$ENV_FILE" -f "$ROOT_DIR/docker-compose.yml" exec "$service_name" /bin/bash
}

cmd_up() {
  ensure_env
  docker compose --env-file "$ENV_FILE" -f "$ROOT_DIR/docker-compose.yml" up -d --build
}

cmd_down() {
  ensure_env
  docker compose --env-file "$ENV_FILE" -f "$ROOT_DIR/docker-compose.yml" down
}

cmd_logs() {
  docker compose -f "$ROOT_DIR/docker-compose.yml" logs -f --tail=200
}

cmd_health() {
  curl -fsS "http://127.0.0.1:${ZPUSH_HTTP_PORT:-9073}/healthz" && echo OK || (echo FAIL; exit 1)
}

cmd_backup() {
    info "Backing up persistent data from ./zpush/ directory..."
    TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
    BACKUP_FILE="zpush-backup-${TIMESTAMP}.tar.gz"
    tar -czvf "$BACKUP_FILE" -C "$DATA_DIR" .
    info "Backup created: $BACKUP_FILE"
}

cmd_upgrade() {
    ensure_env
    info "Pulling latest image to check for new config files..."
    docker compose pull

    info "Exporting new default config files for comparison..."
    IMAGE_NAME=$(docker compose config | grep 'image:' | awk '{print $2}')
    TEMP_CONTAINER_ID=$(docker create "$IMAGE_NAME")

    # Copy out the main config and the zimbra backend config
    docker cp "${TEMP_CONTAINER_ID}:/var/www/zpush/config.php" "${DATA_DIR}/config/config.php.latest"
    docker cp "${TEMP_CONTAINER_ID}:/var/www/zpush/backend/zimbra/config.php" "${DATA_DIR}/config/zimbra-config.php.latest"

    docker rm -f "$TEMP_CONTAINER_ID" > /dev/null

    echo
    info "New default configurations have been saved:"
    echo "  - ${DATA_DIR}/config/config.php.latest"
    echo "  - ${DATA_DIR}/config/zimbra-config.php.latest"
    echo
    info "Please use 'diff' to compare these with your current config files and merge any new settings."
    info "Once you are ready, run './manage.sh up' to start the new version."
}


cmd_set_port() {
  local port="${1:-}"
  [[ -n "$port" ]] || die "Usage: $0 --set-port <port>"
  ensure_env
  sed -ri "s/^ZPUSH_HTTP_PORT=.*/ZPUSH_HTTP_PORT=${port}/" "$ENV_FILE"
  info "Set ZPUSH_HTTP_PORT=$port in $ENV_FILE"
}

cmd_print_nginx() {
  cat <<'NGX'
# 1) Add an upstream (e.g., in a common http{} block once):
upstream zpush {
    server 127.0.0.1:9073 max_fails=3 fail_timeout=30s;
    keepalive 10;
}

# 2) In HTTPS server{} (mail/autodiscover/tmail vhosts) add:
location = /Microsoft-Server-ActiveSync {
    proxy_pass http://zpush;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_read_timeout 3600s;
    client_max_body_size 50m;  # >= PHP post_max_size
}

location ~* ^/autodiscover/Autodiscover\.xml$ {
    proxy_pass http://zpush;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_read_timeout 60s;
    client_max_body_size 10m;
}

# 3) Keep HTTP 80 -> 443 redirect as-is on Zimbra.
NGX
}

# --- All other commands for template management are unchanged ---
# (cmd_verify_templates, cmd_patch_templates, etc. would go here)
# ... [previous template management functions from your script] ...
cmd_verify_templates() {
  local dir="${1:-/opt/zimbra/conf/nginx/templates}"
  info "Dry-run verify in: $dir"
  if [[ ! -d "$dir" ]]; then
    info "Directory not found. Pass target path explicitly if running on Zimbra host."
    exit 0
  fi
  grep -RInE "Microsoft-Server-ActiveSync|Autodiscover\.xml|zpush" "$dir" || true
  info "If nothing found, templates likely need patching. Use: $0 --print-nginx to get snippets."
}

cmd_patch_templates() {
  local dir="${1:-/opt/zimbra/conf/nginx/templates}"
  info "Non-destructive helper. Back up templates and print instructions."
  [[ -d "$dir" ]] || die "Templates dir not found: $dir"
  cmd_backup_templates "$dir"
  info "Backed up templates. Please edit the HTTPS templates to add location stanzas and upstream as printed by: $0 --print-nginx"
  echo "After editing run on Zimbra: zmproxyctl restart"
}

cmd_patch_templates_auto() {
  local base="${1:-/opt/zimbra/conf/nginx/templates}"
  [[ -d "$base" ]] || die "Templates dir not found: $base"
  info "Auto-injecting snippets into: $base"
  # Create a full snapshot tarball in current working directory for easy revert
  cmd_backup_templates "$base"

  # 1) Inject upstream into the main web template http{} once
  local main_tmpl
  main_tmpl=$(find "$base" -type f -name 'nginx.conf.web.template*' -print -quit || true)
  if [[ -n "$main_tmpl" ]]; then
    if ! grep -q "upstream zpush" "$main_tmpl"; then
      cp "$main_tmpl" "$main_tmpl.bak"
      info "Adding upstream zpush to: $main_tmpl"
      awk '
        BEGIN{added=0}
        /http[[:space:]]*\{/ && !added {print; print "    upstream zpush {"; print "        server 127.0.0.1:9073 max_fails=3 fail_timeout=30s;"; print "        keepalive 10;"; print "    } # injected-by-manage.sh"; added=1; next}
        {print}
      ' "$main_tmpl" > "$main_tmpl.tmp" && mv "$main_tmpl.tmp" "$main_tmpl"
    else
      info "Upstream already present in: $main_tmpl (skipping)"
    fi
  else
    info "Could not find nginx.conf.web.template under $base (skipping upstream injection)"
  fi

  # 2) Inject EAS + Autodiscover locations into HTTPS templates
  mapfile -t https_tmps < <(find "$base" -type f \( -iname '*web.https*template*' -o -iname 'nginx.conf.web.https.template' -o -iname 'nginx.conf.web.https.default.template' \) || true)
  if [[ ${#https_tmps[@]} -eq 0 ]]; then
    info "No HTTPS templates found under $base"
    return 0
  fi

  for f in "${https_tmps[@]}"; do
    [[ -f "$f" ]] || continue
    if grep -q "BEGIN zpush-eas" "$f"; then
      info "Markers already present in $f (skipping)"
      continue
    fi
    cp "$f" "$f.bak"
    info "Injecting locations into: $f"
    awk '
      BEGIN{block=0}
      /server[[:space:]]*\{/ {
        print; print "        # BEGIN zpush-eas (injected by manage.sh)";
        print "        location = /Microsoft-Server-ActiveSync {";
        print "            proxy_pass http://zpush;";
        print "            proxy_set_header Host $host;";
        print "            proxy_set_header X-Real-IP $remote_addr;";
        print "            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;";
        print "            proxy_set_header X-Forwarded-Proto https;";
        print "            proxy_read_timeout 3600s;";
        print "            client_max_body_size 50m;";
        print "        }";
        print "        location ~* ^/autodiscover/Autodiscover\\.xml$ {";
        print "            proxy_pass http://zpush;";
        print "            proxy_set_header Host $host;";
        print "            proxy_set_header X-Real-IP $remote_addr;";
        print "            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;";
        print "            proxy_set_header X-Forwarded-Proto https;";
        print "            proxy_read_timeout 60s;";
        print "            client_max_body_size 10m;";
        print "        }";
        print "        # END zpush-eas";
        next
      }
      {print}
    ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  done

  info "Done. Review backups (*.bak.<ts>) and diffs if needed."
  echo "To revert, restore the .bak files or remove the marked block."
}

cmd_backup_templates() {
  local dir="${1:-/opt/zimbra/conf/nginx/templates}"
  [[ -d "$dir" ]] || die "Templates dir not found: $dir"
  local parent base out
  parent="$(cd "$dir/.." && pwd)"
  base="$(basename "$dir")"
  out="$parent/${base}-backup.tgz"
  if [[ -f "$out" ]]; then
    info "Backup already exists: $out"
    info "Will not overwrite. Move or remove it, then retry."
    exit 1
  fi
  tar -C "$dir" -czf "$out" .
  info "Backup written: $out"
}

cmd_restore_templates() {
  local dir="${1:-}"
  local tarball="${2:-}"
  [[ -n "$dir" ]] || die "Usage: $0 --restore-templates <dir> [backup.tar.gz]"
  [[ -d "$dir" ]] || die "Templates dir not found: $dir"
  if [[ -z "$tarball" ]]; then
    local parent base
    parent="$(cd "$dir/.." && pwd)"
    base="$(basename "$dir")"
    tarball="$parent/${base}-backup.tgz"
  fi
  [[ -f "$tarball" ]] || die "Backup tarball not found: $tarball"
  info "Restoring $dir from $tarball"
  # Backup current before overwrite
  cmd_backup_templates "$dir"
  # Extract to a temp and then replace
  local tmp
  tmp="$(mktemp -d)"
  tar -xzf "$tarball" -C "$tmp"
  rm -rf "$dir"/*
  shopt -s dotglob
  cp -a "$tmp"/* "$dir"/
  shopt -u dotglob
  rm -rf "$tmp"
  info "Restore complete. Review changes and reload proxy if applicable."
}

cmd_revert_templates_auto() {
  local base="${1:-/opt/zimbra/conf/nginx/templates}"
  [[ -d "$base" ]] || die "Templates dir not found: $base"
  info "Reverting injected snippets in: $base"

  # Revert HTTPS template injections
  mapfile -t https_tmps < <(grep -RIl "BEGIN zpush-eas" "$base" || true)
  for f in "${https_tmps[@]}"; do
    [[ -f "$f" ]] || continue
    cp "$f" "$f.bak"
    awk '
      BEGIN{skip=0}
      /# BEGIN zpush-eas/ {skip=1; next}
      /# END zpush-eas/ {skip=0; next}
      skip==0 {print}
    ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    info "Removed EAS/autodiscover block from: $f"
  done

  # Revert upstream injection in main template
  mapfile -t main_tmps < <(grep -RIl "upstream zpush" "$base" || true)
  for f in "${main_tmps[@]}"; do
    [[ -f "$f" ]] || continue
    if grep -q "# injected-by-manage.sh" "$f"; then
      cp "$f" "$f.bak"
      awk '
        BEGIN{rm=0}
        /upstream[[:space:]]+zpush[[:space:]]*\{/ {rm=1; next}
        /\}[[:space:]]*# injected-by-manage.sh/ {rm=0; next}
        rm==0 {print}
      ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
      info "Removed upstream block from: $f"
    fi
  done

  info "Revert complete. You can now rebuild/regenerate configs."
}


usage() {
  cat <<USAGE
Usage: $(basename "$0") <command> [args]

Container Lifecycle & Data
  --init      Create .env and data dirs (config/state/log)
  --build     Build container image using the Dockerfile
  --up        docker compose up -d (builds if needed)
  --down      docker compose down
  --logs      Tail container logs
  --health    Check container /healthz
  --backup    Create a timestamped backup of the ./zpush data directory
  --upgrade   Pull latest image and export new configs for manual review

Configuration
  --set-port <port>  Update .env ZPUSH_HTTP_PORT
  --print-nginx      Show NGINX upstream + location snippets for Zimbra proxy

Zimbra Host Template Management
  --verify-templates [dir]      Grep templates for EAS/autodiscover refs
  --patch-templates [dir]       Create backup and print manual patching guidance
  --patch-templates-auto [dir]  Auto-inject upstream+locations into templates
  --backup-templates [dir]      Create a .tgz backup of the templates directory
  --restore-templates <dir> [f] Restore templates from a .tgz backup
  --revert-templates-auto [dir] Remove auto-injected snippets from templates

USAGE
}

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    help|-h|--help|'') usage; exit 0;;
    --init|init) cmd_init "$@";;
    --build|build) cmd_build "$@";;
    --console|console) cmd_console "$@";;
    --up|up) cmd_up "$@";;
    --down|down) cmd_down "$@";;
    --logs|logs) cmd_logs "$@";;
    --health|health) cmd_health "$@";;
    --backup|backup) cmd_backup "$@";;
    --upgrade|upgrade) cmd_upgrade "$@";;
    --set-port|set-port) cmd_set_port "$@";;
    --print-nginx|print-nginx) cmd_print_nginx "$@";;
    --verify-templates|verify-templates) cmd_verify_templates "$@";;
    --patch-templates|patch-templates) cmd_patch_templates "$@";;
    --patch-templates-auto|patch-templates-auto) cmd_patch_templates_auto "$@";;
    --backup-templates|backup-templates) cmd_backup_templates "$@";;
    --restore-templates|restore-templates) cmd_restore_templates "$@";;
    --revert-templates-auto|revert-templates-auto) cmd_revert_templates_auto "$@";;
    *) usage; [[ -n "$cmd" ]] && exit 1 || true ;;
  esac
}

main "$@"
