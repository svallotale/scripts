#!/usr/bin/env bash
# =============================================================================
# nginx_install.sh
# Install Nginx reverse proxy + Let's Encrypt SSL for a single domain.
# Includes security headers (HSTS, X-Frame-Options, Referrer-Policy).
# Supports WebSocket proxy.
#
# Idempotent — safe to re-run (skips if vhost already exists).
#
# Usage (positional, backward compat):
#   ./nginx_install.sh <domain> <port> <email>
#
# Usage (named args, recommended):
#   ./nginx_install.sh --domain=api.foo --port=3000 --email=admin@foo
#   Optional: --force (rewrite existing vhost), --no-ssl (http only)
#
# Via curl:
#   curl -fsSL https://raw.githubusercontent.com/svallotale/scripts/main/bootstrap/nginx_install.sh | sudo bash -s -- <domain> <port> <email>
# =============================================================================
set -euo pipefail

# --- Source common lib ---
REPO_RAW="https://raw.githubusercontent.com/svallotale/scripts/main"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "")"

if [[ -n "${SCRIPT_DIR}" && -f "${SCRIPT_DIR}/../lib/common.sh" ]]; then
  # shellcheck source=../lib/common.sh
  source "${SCRIPT_DIR}/../lib/common.sh"
else
  # shellcheck disable=SC1090
  source <(curl -fsSL "${REPO_RAW}/lib/common.sh")
fi

[[ -n "${COMMON_SH_LOADED:-}" ]] || { echo "common.sh failed to load"; exit 1; }

# =============================================================================

# --- Argument parsing ---
DOMAIN=""
PROXY_PORT=""
EMAIL=""
FORCE=0
NO_SSL=0

for arg in "$@"; do
  case "$arg" in
    --domain=*)  DOMAIN="${arg#*=}" ;;
    --port=*)    PROXY_PORT="${arg#*=}" ;;
    --email=*)   EMAIL="${arg#*=}" ;;
    --force)     FORCE=1 ;;
    --no-ssl)    NO_SSL=1 ;;
    -h|--help)
      cat <<EOF
Usage: $0 [OPTIONS]
   or: $0 <domain> <port> <email>  (positional, backward compat)

Options:
  --domain=DOMAIN    Domain name (e.g. api.example.com)
  --port=PORT        Backend port (e.g. 3000)
  --email=EMAIL      Email for Let's Encrypt
  --force            Overwrite existing vhost
  --no-ssl           Skip SSL setup (HTTP only)
  -h, --help         Show this help
EOF
      exit 0
      ;;
    --*)  fail "Неизвестный флаг: $arg" ;;
    *)
      # Positional fallback
      if [[ -z "$DOMAIN" ]]; then DOMAIN="$arg"
      elif [[ -z "$PROXY_PORT" ]]; then PROXY_PORT="$arg"
      elif [[ -z "$EMAIL" ]]; then EMAIL="$arg"
      fi
      ;;
  esac
done

# --- Validation ---
[[ -n "$DOMAIN" ]]     || fail "Не задан --domain. См. $0 --help"
[[ -n "$PROXY_PORT" ]] || fail "Не задан --port"
[[ -n "$EMAIL" || "$NO_SSL" -eq 1 ]] || fail "Не задан --email (обязателен без --no-ssl)"

# Basic domain sanity check
[[ "$DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] \
  || fail "Невалидный домен: $DOMAIN"

# Port range check
if [[ ! "$PROXY_PORT" =~ ^[0-9]+$ ]] || [[ "$PROXY_PORT" -lt 1 ]] || [[ "$PROXY_PORT" -gt 65535 ]]; then
  fail "Порт должен быть 1-65535, получено: $PROXY_PORT"
fi

banner "Nginx Install" "${DOMAIN} → :${PROXY_PORT}"

require_root "$@"
detect_os

# --- Step 1: Install Nginx + Certbot ---
PKGS=(nginx)
[[ "$NO_SSL" -eq 0 ]] && PKGS+=(certbot python3-certbot-nginx)
install_pkgs "${PKGS[@]}"

# --- Step 2: Check existing vhost ---
NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"
NGINX_LINK="/etc/nginx/sites-enabled/$DOMAIN"

if [[ -f "$NGINX_CONF" ]] && [[ "$FORCE" -eq 0 ]]; then
  warn "Vhost для $DOMAIN уже существует: $NGINX_CONF"
  warn "Используй --force чтобы перезаписать"
  info "Текущий конфиг:"
  dim "$(head -20 "$NGINX_CONF")"
  exit 0
fi

# --- Step 3: Create vhost config ---
log "Создание vhost для $DOMAIN → localhost:$PROXY_PORT"

cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    # Security headers (эффективны после certbot --redirect)
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;

    # Увеличенные таймауты для долгих WS/SSE
    proxy_read_timeout 300s;
    proxy_connect_timeout 30s;
    client_max_body_size 50M;

    location / {
        proxy_pass http://127.0.0.1:$PROXY_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOF

ok "Vhost создан: $NGINX_CONF"

# --- Step 4: Enable site ---
if [[ ! -L "$NGINX_LINK" ]]; then
  ln -s "$NGINX_CONF" "$NGINX_LINK"
  ok "Активирован в sites-enabled"
else
  ok "Уже активен в sites-enabled"
fi

# --- Step 5: Test + reload ---
log "Проверка конфигурации Nginx"
if ! nginx -t; then
  fail "nginx -t провалился, откатываю symlink"
  rm -f "$NGINX_LINK"
fi

systemctl reload nginx
ok "Nginx перезагружен"

# --- Step 6: SSL via certbot ---
if [[ "$NO_SSL" -eq 1 ]]; then
  warn "SSL пропущен (--no-ssl). Конфиг только HTTP."
else
  log "Получение SSL сертификата Let's Encrypt"
  info "Убедись что A-запись $DOMAIN указывает на IP сервера"

  if certbot --nginx -n --agree-tos --redirect --email "$EMAIL" -d "$DOMAIN"; then
    systemctl reload nginx
    ok "SSL сертификат установлен, HTTPS активен"
  else
    warn "certbot завершился с ошибкой. Возможные причины:"
    warn "  - DNS не настроен (A-запись)"
    warn "  - Порты 80/443 закрыты файрволом"
    warn "  - Превышен лимит Let's Encrypt (5 certs/неделю/домен)"
    warn "Сайт работает по HTTP. Попробуй вручную: certbot --nginx -d $DOMAIN"
  fi
fi

URL="$([[ "$NO_SSL" -eq 1 ]] && echo "http://$DOMAIN" || echo "https://$DOMAIN")"
SSL_STATUS="$([[ "$NO_SSL" -eq 1 ]] && echo 'HTTP (без SSL)' || echo "Let's Encrypt")"

success_box "Nginx настроен" \
  "URL: ${URL}" \
  "Прокси на: localhost:${PROXY_PORT}" \
  "SSL: ${SSL_STATUS}" \
  "Config: ${NGINX_CONF}"
