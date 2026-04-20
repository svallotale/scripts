#!/usr/bin/env bash
# =============================================================================
# vps_bootstrap.sh — interactive orchestrator
# Runs multiple bootstrap scripts on a fresh VPS with one command.
#
# Modules: docker, zsh, nginx, ssh
#
# Usage:
#   sudo ./vps_bootstrap.sh                          # interactive menu
#   sudo ./vps_bootstrap.sh --docker --zsh           # non-interactive
#   sudo ./vps_bootstrap.sh --all --domain=... ...   # full setup
#
# Via curl:
#   curl -fsSL https://raw.githubusercontent.com/svallotale/scripts/main/bootstrap/vps_bootstrap.sh | \
#     sudo bash -s -- --docker --zsh
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

# --- Module flags ---
DO_DOCKER=0
DO_ZSH=0
DO_NGINX=0
DO_SSH=0
DO_FIREWALL=0

# --- Firewall args ---
FIREWALL_EXTRA_PORTS=()

# --- Nginx args ---
DOMAIN=""
PROXY_PORT=""
EMAIL=""

# --- Parse args ---
INTERACTIVE=1
for arg in "$@"; do
  case "$arg" in
    --all)          DO_DOCKER=1; DO_ZSH=1; DO_NGINX=1; DO_SSH=1; DO_FIREWALL=1; INTERACTIVE=0 ;;
    --docker)       DO_DOCKER=1; INTERACTIVE=0 ;;
    --zsh)          DO_ZSH=1; INTERACTIVE=0 ;;
    --nginx)        DO_NGINX=1; INTERACTIVE=0 ;;
    --ssh)          DO_SSH=1; INTERACTIVE=0 ;;
    --firewall)     DO_FIREWALL=1; INTERACTIVE=0 ;;
    --domain=*)     DOMAIN="${arg#*=}" ;;
    --port=*)       PROXY_PORT="${arg#*=}" ;;
    --email=*)      EMAIL="${arg#*=}" ;;
    --allow=*)      FIREWALL_EXTRA_PORTS+=("${arg#*=}") ;;
    -h|--help)
      cat <<EOF
Usage: $0 [MODULES] [OPTIONS]
   or: $0                    (интерактивное меню)

Modules:
  --all              docker + zsh + firewall + nginx + ssh
  --docker           Docker Engine + Compose
  --zsh              Zsh + oh-my-zsh
  --firewall         UFW baseline (22/80/443 + rate limit)
  --nginx            Nginx reverse proxy + SSL
  --ssh              SSH hardening (interactive TUI)

Опции (для --nginx):
  --domain=DOMAIN    Домен (api.example.com)
  --port=PORT        Backend порт
  --email=EMAIL      Email для Let's Encrypt

Опции (для --firewall):
  --allow=PORT       Доп. порт для файрвола (повторяй: --allow=8080 --allow=5432)

Примеры:
  sudo $0                                               # интерактив
  sudo $0 --docker --zsh                                # dev-сервер
  sudo $0 --all --domain=api.foo --port=3000 --email=a@b.c  # прод
EOF
      exit 0
      ;;
    *) fail "Неизвестный аргумент: $arg. См. $0 --help" ;;
  esac
done

# =============================================================================
# Welcome banner
# =============================================================================

clear 2>/dev/null || true
banner "VPS Bootstrap" "Modular server setup · github.com/svallotale/scripts"

require_root "$@"
detect_user
detect_os

info "Пользователь: ${BOLD}${TARGET_USER}${NC}"
info "OS: ${BOLD}${OS_ID} ${OS_VERSION}${NC} (${OS_CODENAME})"
info "Хост: ${BOLD}$(hostname)${NC}"

# =============================================================================
# Interactive mode (no flags → menu)
# =============================================================================

if [[ "$INTERACTIVE" -eq 1 ]] && [[ -t 0 ]]; then
  section "Выбор модулей"
  echo "${DIM}Можно выбрать несколько — будут запущены по очереди.${NC}"
  echo ""

  if confirm "Установить Docker (Engine + Compose)?" "y"; then
    DO_DOCKER=1
  fi

  if confirm "Установить Zsh + oh-my-zsh?" "y"; then
    DO_ZSH=1
  fi

  if confirm "Настроить UFW файрвол (baseline)?" "y"; then
    DO_FIREWALL=1
    printf "${CYAN}❯ Доп. порты через запятую (например 8080,5432) или пусто: ${NC}"
    read -r EXTRA_PORTS_INPUT
    if [[ -n "${EXTRA_PORTS_INPUT:-}" ]]; then
      IFS=',' read -ra PORT_ARR <<< "$EXTRA_PORTS_INPUT"
      for p in "${PORT_ARR[@]}"; do
        p="${p// /}"  # strip whitespace
        [[ -n "$p" ]] && FIREWALL_EXTRA_PORTS+=("$p")
      done
    fi
  fi

  if confirm "Настроить Nginx reverse proxy + SSL?" "n"; then
    DO_NGINX=1
    printf "${CYAN}❯ Домен (например api.example.com): ${NC}"
    read -r DOMAIN
    printf "${CYAN}❯ Backend порт (например 3000): ${NC}"
    read -r PROXY_PORT
    printf "${CYAN}❯ Email для Let's Encrypt: ${NC}"
    read -r EMAIL
  fi

  if confirm "Запустить SSH hardening (интерактивный TUI)?" "n"; then
    DO_SSH=1
  fi
fi

# =============================================================================
# Validation
# =============================================================================

if [[ "$DO_DOCKER" -eq 0 && "$DO_ZSH" -eq 0 && "$DO_NGINX" -eq 0 && "$DO_SSH" -eq 0 && "$DO_FIREWALL" -eq 0 ]]; then
  fail "Не выбран ни один модуль. См. $0 --help"
fi

if [[ "$DO_NGINX" -eq 1 ]]; then
  [[ -n "$DOMAIN" && -n "$PROXY_PORT" && -n "$EMAIL" ]] \
    || fail "Для --nginx требуются --domain, --port, --email"
fi

# =============================================================================
# Execution plan
# =============================================================================

section "План выполнения"

MODULE_COUNT=0
[[ "$DO_DOCKER" -eq 1 ]]   && { MODULE_COUNT=$((MODULE_COUNT+1)); print_summary_line "[${MODULE_COUNT}] Docker:"   "Engine + Compose plugin"; }
[[ "$DO_ZSH" -eq 1 ]]      && { MODULE_COUNT=$((MODULE_COUNT+1)); print_summary_line "[${MODULE_COUNT}] Zsh:"      "zsh + oh-my-zsh + plugins"; }
[[ "$DO_FIREWALL" -eq 1 ]] && { MODULE_COUNT=$((MODULE_COUNT+1)); print_summary_line "[${MODULE_COUNT}] Firewall:" "UFW baseline${FIREWALL_EXTRA_PORTS[*]:+ + ports: ${FIREWALL_EXTRA_PORTS[*]}}"; }
[[ "$DO_NGINX" -eq 1 ]]    && { MODULE_COUNT=$((MODULE_COUNT+1)); print_summary_line "[${MODULE_COUNT}] Nginx:"    "${DOMAIN} → :${PROXY_PORT} + SSL"; }
[[ "$DO_SSH" -eq 1 ]]      && { MODULE_COUNT=$((MODULE_COUNT+1)); print_summary_line "[${MODULE_COUNT}] SSH:"      "hardening + port knocking (INTERACTIVE)"; }
echo ""

if ! confirm "Всё верно? Запускаем?" "y"; then
  fail "Отменено пользователем"
fi

# =============================================================================
# Run modules
# =============================================================================

run_module() {
  local name="$1"
  shift
  local url="${REPO_RAW}/bootstrap/${name}"
  local local_path="${SCRIPT_DIR}/${name}"

  section "${name}${*:+ }$*"

  if [[ -f "$local_path" ]]; then
    bash "$local_path" "$@" || fail "Модуль $name упал"
  else
    curl -fsSL "$url" | bash -s -- "$@" || fail "Модуль $name упал"
  fi
}

CURRENT=0
[[ "$DO_DOCKER" -eq 1 ]] && { CURRENT=$((CURRENT+1)); progress_step "$CURRENT" "$MODULE_COUNT" "Docker install"; run_module "docker_install.sh"; }
[[ "$DO_ZSH" -eq 1 ]]    && { CURRENT=$((CURRENT+1)); progress_step "$CURRENT" "$MODULE_COUNT" "Zsh install"; run_module "zsh_install.sh"; }

if [[ "$DO_FIREWALL" -eq 1 ]]; then
  CURRENT=$((CURRENT+1))
  progress_step "$CURRENT" "$MODULE_COUNT" "Firewall baseline"
  FW_ARGS=()
  for p in "${FIREWALL_EXTRA_PORTS[@]}"; do
    FW_ARGS+=("--allow=$p")
  done
  run_module "firewall_baseline.sh" "${FW_ARGS[@]}"
fi

if [[ "$DO_NGINX" -eq 1 ]]; then
  CURRENT=$((CURRENT+1))
  progress_step "$CURRENT" "$MODULE_COUNT" "Nginx reverse proxy + SSL"
  run_module "nginx_install.sh" "--domain=$DOMAIN" "--port=$PROXY_PORT" "--email=$EMAIL"
fi

if [[ "$DO_SSH" -eq 1 ]]; then
  CURRENT=$((CURRENT+1))
  progress_step "$CURRENT" "$MODULE_COUNT" "SSH hardening"
  warn "Интерактивный модуль. Открой ВТОРУЮ SSH-сессию перед запуском!"
  if confirm "Готов к SSH hardening?" "n"; then
    run_module "secure_ssh.sh"
  else
    warn "SSH hardening пропущен"
  fi
fi

# =============================================================================
# Final summary
# =============================================================================

SUMMARY_LINES=()
[[ "$DO_DOCKER" -eq 1 ]]   && SUMMARY_LINES+=("Docker: $(docker --version 2>/dev/null || echo 'установлен')")
[[ "$DO_ZSH" -eq 1 ]]      && SUMMARY_LINES+=("Zsh: $(zsh --version 2>/dev/null | cut -d, -f1 || echo 'установлен')")
[[ "$DO_FIREWALL" -eq 1 ]] && SUMMARY_LINES+=("Firewall: UFW активен")
[[ "$DO_NGINX" -eq 1 ]]    && SUMMARY_LINES+=("Nginx: https://${DOMAIN}")
[[ "$DO_SSH" -eq 1 ]]      && SUMMARY_LINES+=("SSH: hardened (проверь новый порт!)")
SUMMARY_LINES+=("")
SUMMARY_LINES+=("⚠ Перелогинься для активации docker/zsh")

success_box "VPS Bootstrap завершён" "${SUMMARY_LINES[@]}"
