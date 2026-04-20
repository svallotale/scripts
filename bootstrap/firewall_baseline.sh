#!/usr/bin/env bash
# =============================================================================
# firewall_baseline.sh
# Safe UFW baseline for a fresh VPS.
# Auto-detects current SSH port to prevent lockout.
#
# Defaults:
#   - deny incoming, allow outgoing
#   - allow current SSH port (rate-limited)
#   - allow 80/tcp (HTTP) and 443/tcp (HTTPS)
#   - allow IPv6
#   - logging: low
#
# Idempotent.
#
# Usage:
#   sudo ./firewall_baseline.sh                        # baseline
#   sudo ./firewall_baseline.sh --allow=8080           # + custom port
#   sudo ./firewall_baseline.sh --allow=5432 --allow=6379
#   sudo ./firewall_baseline.sh --ssh-port=2222        # override autodetect
#   sudo ./firewall_baseline.sh --no-http              # без 80
#   sudo ./firewall_baseline.sh --reset                # сброс всех правил
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
ALLOW_HTTP=1
ALLOW_HTTPS=1
SSH_PORT=""
EXTRA_PORTS=()
DO_RESET=0

for arg in "$@"; do
  case "$arg" in
    --allow=*)    EXTRA_PORTS+=("${arg#*=}") ;;
    --ssh-port=*) SSH_PORT="${arg#*=}" ;;
    --no-http)    ALLOW_HTTP=0 ;;
    --no-https)   ALLOW_HTTPS=0 ;;
    --reset)      DO_RESET=1 ;;
    -h|--help)
      cat <<EOF
Usage: $0 [OPTIONS]

Базовый UFW для свежего VPS. Автодетект SSH порта — не залочит.

Options:
  --allow=PORT       Доп. порт (можно повторять: --allow=8080 --allow=5432)
  --ssh-port=PORT    Перебить автодетект SSH порта
  --no-http          Не открывать 80/tcp
  --no-https         Не открывать 443/tcp
  --reset            Сбросить ВСЕ правила перед настройкой (опасно!)
  -h, --help         Эта справка

Примеры:
  sudo $0                                    # baseline (SSH + 80 + 443)
  sudo $0 --allow=8080 --allow=5432          # + приложение + Postgres
  sudo $0 --ssh-port=2222 --no-http          # кастомный SSH, только HTTPS
EOF
      exit 0
      ;;
    *) fail "Неизвестный флаг: $arg. См. $0 --help" ;;
  esac
done

# =============================================================================
banner "Firewall Baseline" "UFW setup с автодетектом SSH"

require_root "$@"
detect_os

# --- Step 1: Detect current SSH port ---
log "Определение текущего SSH порта"

if [[ -n "$SSH_PORT" ]]; then
  info "Задано вручную: $SSH_PORT"
else
  # Try to detect from sshd_config
  if [[ -f /etc/ssh/sshd_config ]]; then
    DETECTED_PORT=$(grep -E '^Port\s+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1)
    [[ -n "${DETECTED_PORT:-}" ]] && SSH_PORT="$DETECTED_PORT"
  fi

  # Try to detect from active connection (who am i)
  if [[ -z "$SSH_PORT" ]]; then
    LIVE_PORT=$(ss -tnp 2>/dev/null | grep "$(who am i 2>/dev/null | awk '{print $NF}' | tr -d '()')" | awk '{print $4}' | awk -F: '{print $NF}' | head -1 || true)
    [[ -n "${LIVE_PORT:-}" ]] && SSH_PORT="$LIVE_PORT"
  fi

  # Fallback to 22
  if [[ -z "$SSH_PORT" ]]; then
    SSH_PORT=22
    warn "Не удалось определить SSH порт — использую стандартный 22"
  else
    ok "Найден SSH порт: $SSH_PORT"
  fi
fi

# Validate
if [[ ! "$SSH_PORT" =~ ^[0-9]+$ ]] || [[ "$SSH_PORT" -lt 1 ]] || [[ "$SSH_PORT" -gt 65535 ]]; then
  fail "Невалидный SSH порт: $SSH_PORT"
fi

# --- Step 2: Install UFW ---
install_pkgs ufw

# --- Step 3: Plan + confirm ---
section "План настройки файрвола"

print_summary_line "Default incoming:"  "deny"
print_summary_line "Default outgoing:"  "allow"
print_summary_line "SSH порт:"          "$SSH_PORT/tcp (rate-limited)"
[[ "$ALLOW_HTTP" -eq 1 ]]  && print_summary_line "HTTP:"  "80/tcp"
[[ "$ALLOW_HTTPS" -eq 1 ]] && print_summary_line "HTTPS:" "443/tcp"
for p in "${EXTRA_PORTS[@]}"; do
  print_summary_line "Extra:" "$p/tcp"
done
[[ "$DO_RESET" -eq 1 ]] && warn "⚠ --reset: все текущие правила будут удалены"

echo ""
if ! confirm "Применить настройки файрвола?" "y"; then
  fail "Отменено"
fi

# --- Step 4: Reset (optional) ---
if [[ "$DO_RESET" -eq 1 ]]; then
  log "Сброс существующих правил UFW"
  ufw --force reset >/dev/null
  ok "Правила сброшены"
fi

# --- Step 5: Apply rules ---
log "Применение правил"

ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ok "Defaults: deny in / allow out"

# SSH с rate limiting (ufw limit = 6 attempts per 30 sec)
ufw limit "${SSH_PORT}/tcp" comment 'SSH (rate limited)' >/dev/null
ok "SSH: ${SSH_PORT}/tcp (ufw limit)"

if [[ "$ALLOW_HTTP" -eq 1 ]]; then
  ufw allow 80/tcp comment 'HTTP' >/dev/null
  ok "HTTP: 80/tcp"
fi

if [[ "$ALLOW_HTTPS" -eq 1 ]]; then
  ufw allow 443/tcp comment 'HTTPS' >/dev/null
  ok "HTTPS: 443/tcp"
fi

for p in "${EXTRA_PORTS[@]}"; do
  if [[ "$p" =~ ^[0-9]+$ ]] && [[ "$p" -ge 1 ]] && [[ "$p" -le 65535 ]]; then
    ufw allow "${p}/tcp" comment 'custom' >/dev/null
    ok "Custom: ${p}/tcp"
  else
    warn "Пропускаю невалидный порт: $p"
  fi
done

# Enable logging (low level)
ufw logging low >/dev/null 2>&1 || true

# --- Step 6: Enable ---
log "Активация UFW"

if ufw status | grep -qE '^Status: active'; then
  # Reload to apply changes
  ufw reload >/dev/null
  ok "UFW уже активен, правила перезагружены"
else
  # Non-interactive enable
  echo "y" | ufw enable >/dev/null
  ok "UFW активирован"
fi

# --- Step 7: Verify ---
log "Проверка"
FIREWALL_STATUS=$(ufw status numbered | head -3 | tail -1)

# --- Summary ---
RULES_SUMMARY=()
RULES_SUMMARY+=("SSH: ${SSH_PORT}/tcp (rate-limited)")
[[ "$ALLOW_HTTP" -eq 1 ]]  && RULES_SUMMARY+=("HTTP: 80/tcp")
[[ "$ALLOW_HTTPS" -eq 1 ]] && RULES_SUMMARY+=("HTTPS: 443/tcp")
for p in "${EXTRA_PORTS[@]}"; do
  [[ "$p" =~ ^[0-9]+$ ]] && RULES_SUMMARY+=("Custom: ${p}/tcp")
done
RULES_SUMMARY+=("")
RULES_SUMMARY+=("Проверь: ufw status numbered")

success_box "Firewall активен" "${RULES_SUMMARY[@]}"
