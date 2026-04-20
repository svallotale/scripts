#!/usr/bin/env bash
# =============================================================================
# healthcheck.sh
# VPS health monitoring with Telegram alerts.
#
# Checks:
#   - HTTP 200 on configured URLs
#   - SSL cert expiration (< 14 days warn, < 3 days critical)
#   - Docker containers (all up?)
#   - Disk usage (threshold configurable)
#   - RAM usage
#   - Load average (vs CPU cores)
#   - Optional: Postgres SELECT 1
#
# Configuration via:
#   - /etc/healthcheck.conf (sourced if exists)
#   - Environment variables
#   - CLI flags (--url, --domain, --disk=85, etc.)
#
# Usage (ad-hoc):
#   ./healthcheck.sh --url=https://api.foo --domain=api.foo --disk=85
#
# Usage (cron every 5 min):
#   */5 * * * * /opt/scripts/monitoring/healthcheck.sh --quiet 2>&1 | logger -t healthcheck
#
# Telegram alerts (optional):
#   export TELEGRAM_BOT_TOKEN=...
#   export TELEGRAM_CHAT_ID=...
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

# --- Default config (override via env or /etc/healthcheck.conf) ---
URLS=()
DOMAINS=()
DISK_THRESHOLD=${DISK_THRESHOLD:-85}
RAM_THRESHOLD=${RAM_THRESHOLD:-90}
LOAD_MULTIPLIER=${LOAD_MULTIPLIER:-2}
CHECK_DOCKER=${CHECK_DOCKER:-auto}
SSL_WARN_DAYS=${SSL_WARN_DAYS:-14}
SSL_CRITICAL_DAYS=${SSL_CRITICAL_DAYS:-3}
POSTGRES_CONTAINER=${POSTGRES_CONTAINER:-}
POSTGRES_USER=${POSTGRES_USER:-}
POSTGRES_DB=${POSTGRES_DB:-}
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

# --- Config file (optional) ---
CONFIG_FILE="${HEALTHCHECK_CONFIG:-/etc/healthcheck.conf}"
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
fi

# --- Parse args ---
QUIET=0
DRY_RUN=0

for arg in "$@"; do
  case "$arg" in
    --url=*)            URLS+=("${arg#*=}") ;;
    --domain=*)         DOMAINS+=("${arg#*=}") ;;
    --disk=*)           DISK_THRESHOLD="${arg#*=}" ;;
    --ram=*)            RAM_THRESHOLD="${arg#*=}" ;;
    --load=*)           LOAD_MULTIPLIER="${arg#*=}" ;;
    --postgres=*)       POSTGRES_CONTAINER="${arg#*=}" ;;
    --no-docker)        CHECK_DOCKER=0 ;;
    --quiet|-q)         QUIET=1 ;;
    --dry-run)          DRY_RUN=1 ;;
    -h|--help)
      cat <<EOF
Usage: $0 [OPTIONS]

VPS healthcheck с опциональным Telegram-алертом.

Checks:
  --url=URL              Проверять HTTP 200 (можно повторять)
  --domain=DOMAIN        Проверять SSL expiration (можно повторять)
  --disk=PERCENT         Порог disk usage (default: 85)
  --ram=PERCENT          Порог RAM usage (default: 90)
  --load=MULTIPLIER      Load > CPU × multiplier (default: 2)
  --postgres=CONTAINER   Проверять Postgres в Docker контейнере
  --no-docker            Не проверять Docker

Options:
  --quiet, -q            Только при ошибках (для cron)
  --dry-run              Не отправлять Telegram (только в stdout)
  -h, --help             Эта справка

Environment / config (/etc/healthcheck.conf):
  TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID
  URLS=(url1 url2), DOMAINS=(d1 d2)
  DISK_THRESHOLD, RAM_THRESHOLD, LOAD_MULTIPLIER

Cron example:
  */5 * * * * /opt/scripts/monitoring/healthcheck.sh --quiet 2>&1 | logger -t hc
EOF
      exit 0
      ;;
    *) fail "Неизвестный флаг: $arg. См. $0 --help" ;;
  esac
done

# --- Auto-detect Docker ---
if [[ "$CHECK_DOCKER" == "auto" ]]; then
  has_cmd docker && CHECK_DOCKER=1 || CHECK_DOCKER=0
fi

# =============================================================================
# Results storage
# =============================================================================
ERRORS=()
WARNINGS=()
OK_COUNT=0

add_error()   { ERRORS+=("$1"); }
add_warn()    { WARNINGS+=("$1"); }
add_ok()      { OK_COUNT=$((OK_COUNT+1)); [[ "$QUIET" -eq 1 ]] || ok "$1"; }

# =============================================================================
# Checks
# =============================================================================

check_http() {
  local url="$1"
  local code
  code=$(curl -fsS -o /dev/null -w "%{http_code}" --max-time 10 "$url" 2>/dev/null || echo "000")

  if [[ "$code" == "200" ]]; then
    add_ok "HTTP $url → 200"
  elif [[ "$code" == "000" ]]; then
    add_error "HTTP $url → timeout/unreachable"
  else
    add_error "HTTP $url → $code"
  fi
}

check_ssl() {
  local domain="$1"
  local expiry_date expiry_epoch now_epoch days_left

  expiry_date=$(echo | timeout 10 openssl s_client -servername "$domain" -connect "$domain:443" 2>/dev/null \
    | openssl x509 -noout -enddate 2>/dev/null \
    | cut -d= -f2 || true)

  if [[ -z "$expiry_date" ]]; then
    add_error "SSL $domain → не удалось получить сертификат"
    return
  fi

  expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null || echo 0)
  now_epoch=$(date +%s)
  days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

  if [[ "$days_left" -lt "$SSL_CRITICAL_DAYS" ]]; then
    add_error "SSL $domain expires in $days_left days (CRITICAL)"
  elif [[ "$days_left" -lt "$SSL_WARN_DAYS" ]]; then
    add_warn "SSL $domain expires in $days_left days"
  else
    add_ok "SSL $domain → $days_left days"
  fi
}

check_disk() {
  local usage
  usage=$(df / | awk 'NR==2 {print $5}' | tr -d '%')

  if [[ "$usage" -gt "$DISK_THRESHOLD" ]]; then
    add_error "Disk usage: ${usage}% (threshold ${DISK_THRESHOLD}%)"
  else
    add_ok "Disk: ${usage}%"
  fi
}

check_ram() {
  local usage
  usage=$(free | awk '/^Mem:/ {printf "%.0f", ($3/$2)*100}')

  if [[ "$usage" -gt "$RAM_THRESHOLD" ]]; then
    add_error "RAM usage: ${usage}% (threshold ${RAM_THRESHOLD}%)"
  else
    add_ok "RAM: ${usage}%"
  fi
}

check_load() {
  local cores load_1m threshold
  cores=$(nproc 2>/dev/null || echo 1)
  load_1m=$(awk '{print $1}' /proc/loadavg)
  threshold=$(awk "BEGIN {print ${cores} * ${LOAD_MULTIPLIER}}")

  # Compare floats
  if awk "BEGIN {exit !(${load_1m} > ${threshold})}"; then
    add_error "Load avg: ${load_1m} (${cores} cores × ${LOAD_MULTIPLIER} = ${threshold})"
  else
    add_ok "Load: ${load_1m} (${cores} cores)"
  fi
}

check_docker() {
  if ! has_cmd docker; then
    add_warn "Docker не установлен, пропускаю"
    return
  fi

  if ! docker info >/dev/null 2>&1; then
    add_error "Docker daemon не отвечает"
    return
  fi

  local total running unhealthy
  total=$(docker ps -a -q | wc -l | tr -d ' ')
  running=$(docker ps -q | wc -l | tr -d ' ')
  unhealthy=$(docker ps --filter "health=unhealthy" -q | wc -l | tr -d ' ')

  if [[ "$unhealthy" -gt 0 ]]; then
    local unhealthy_names
    unhealthy_names=$(docker ps --filter "health=unhealthy" --format '{{.Names}}' | tr '\n' ' ')
    add_error "Docker: $unhealthy unhealthy containers: $unhealthy_names"
  fi

  # Stopped containers (running < total means some stopped)
  local stopped=$((total - running))
  if [[ "$stopped" -gt 0 ]]; then
    local stopped_names
    stopped_names=$(docker ps -a --filter "status=exited" --format '{{.Names}}' | tr '\n' ' ')
    if [[ -n "$stopped_names" ]]; then
      add_warn "Docker: $stopped stopped: $stopped_names"
    fi
  fi

  add_ok "Docker: $running running / $total total"
}

check_postgres() {
  local container="$1"

  if ! docker ps --format '{{.Names}}' | grep -qw "^${container}$"; then
    add_error "Postgres container '$container' не запущен"
    return
  fi

  if docker exec "$container" pg_isready -q 2>/dev/null; then
    add_ok "Postgres ($container): ready"
  else
    add_error "Postgres ($container): not ready"
  fi
}

# =============================================================================
# Send Telegram alert
# =============================================================================
send_telegram() {
  local message="$1"

  if [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]]; then
    return 0
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "[dry-run] Would send Telegram: $message"
    return 0
  fi

  local response
  response=$(curl -fsS --max-time 10 -X POST \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TELEGRAM_CHAT_ID}" \
    -d "text=${message}" \
    -d "parse_mode=HTML" 2>&1 || true)

  if echo "$response" | grep -q '"ok":true'; then
    [[ "$QUIET" -eq 1 ]] || ok "Telegram alert отправлен"
  else
    warn "Telegram alert failed: $response"
  fi
}

# =============================================================================
# Run checks
# =============================================================================

[[ "$QUIET" -eq 1 ]] || banner "Healthcheck" "$(hostname) · $(date -Iseconds)"

for url in "${URLS[@]}"; do
  check_http "$url"
done

for domain in "${DOMAINS[@]}"; do
  check_ssl "$domain"
done

check_disk
check_ram
check_load

[[ "$CHECK_DOCKER" -eq 1 ]] && check_docker

if [[ -n "$POSTGRES_CONTAINER" ]]; then
  check_postgres "$POSTGRES_CONTAINER"
fi

# =============================================================================
# Summary + exit code
# =============================================================================

HOSTNAME=$(hostname)
NOW=$(date '+%Y-%m-%d %H:%M:%S')
EXIT_CODE=0

if [[ ${#ERRORS[@]} -gt 0 ]]; then
  EXIT_CODE=2

  # Build alert message
  MESSAGE="🚨 <b>Healthcheck ALERT</b>
Host: <code>${HOSTNAME}</code>
Time: ${NOW}

<b>Errors (${#ERRORS[@]}):</b>"
  for err in "${ERRORS[@]}"; do
    MESSAGE+="
❌ ${err}"
  done
  if [[ ${#WARNINGS[@]} -gt 0 ]]; then
    MESSAGE+="

<b>Warnings:</b>"
    for w in "${WARNINGS[@]}"; do
      MESSAGE+="
⚠️ ${w}"
    done
  fi

  # Print errors always, even in quiet mode
  for err in "${ERRORS[@]}"; do
    printf "${RED}❌ %s${NC}\n" "$err" >&2
  done
  for w in "${WARNINGS[@]}"; do
    printf "${YELLOW}⚠️  %s${NC}\n" "$w" >&2
  done

  send_telegram "$MESSAGE"

elif [[ ${#WARNINGS[@]} -gt 0 ]]; then
  EXIT_CODE=1
  for w in "${WARNINGS[@]}"; do
    printf "${YELLOW}⚠️  %s${NC}\n" "$w" >&2
  done
  # Warnings не триггерят telegram по умолчанию (можно изменить)
fi

# Success box если всё ок и не quiet
if [[ "$EXIT_CODE" -eq 0 && "$QUIET" -eq 0 ]]; then
  success_box "Healthcheck OK" \
    "Host: ${HOSTNAME}" \
    "Passed: ${OK_COUNT} проверок" \
    "Time: ${NOW}"
fi

exit $EXIT_CODE
