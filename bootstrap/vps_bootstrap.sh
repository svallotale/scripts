#!/usr/bin/env bash
# =============================================================================
# vps_bootstrap.sh — orchestrator
# Runs multiple bootstrap scripts on a fresh VPS with one command.
#
# Available modules: docker, zsh, nginx, ssh, firewall (future)
#
# Usage:
#   sudo ./vps_bootstrap.sh --docker --zsh
#   sudo ./vps_bootstrap.sh --all --domain=api.foo --port=3000 --email=me@foo
#   sudo ./vps_bootstrap.sh --docker --nginx --domain=api.foo --port=3000 --email=me@foo
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

# --- Nginx args ---
DOMAIN=""
PROXY_PORT=""
EMAIL=""

# --- Parse args ---
for arg in "$@"; do
  case "$arg" in
    --all)       DO_DOCKER=1; DO_ZSH=1; DO_NGINX=1; DO_SSH=1 ;;
    --docker)    DO_DOCKER=1 ;;
    --zsh)       DO_ZSH=1 ;;
    --nginx)     DO_NGINX=1 ;;
    --ssh)       DO_SSH=1 ;;
    --domain=*)  DOMAIN="${arg#*=}" ;;
    --port=*)    PROXY_PORT="${arg#*=}" ;;
    --email=*)   EMAIL="${arg#*=}" ;;
    -h|--help)
      cat <<EOF
Usage: $0 [MODULES] [OPTIONS]

Modules (выбери хотя бы один):
  --all              Все модули (docker + zsh + nginx + ssh)
  --docker           Docker Engine + Compose
  --zsh              Zsh + oh-my-zsh
  --nginx            Nginx reverse proxy + SSL
  --ssh              SSH hardening (interactive TUI)

Опции (для --nginx):
  --domain=DOMAIN    Домен (например api.example.com)
  --port=PORT        Backend порт
  --email=EMAIL      Email для Let's Encrypt

Примеры:
  # Просто Docker
  sudo $0 --docker

  # Docker + zsh (обычный старт dev-сервера)
  sudo $0 --docker --zsh

  # Полный прод-setup
  sudo $0 --all --domain=api.mysite.com --port=3000 --email=admin@mysite.com

  # Через curl
  curl -fsSL https://raw.githubusercontent.com/svallotale/scripts/main/bootstrap/vps_bootstrap.sh | \\
    sudo bash -s -- --docker --zsh
EOF
      exit 0
      ;;
    *) fail "Неизвестный аргумент: $arg. См. $0 --help" ;;
  esac
done

# --- Validation ---
if [[ "$DO_DOCKER" -eq 0 && "$DO_ZSH" -eq 0 && "$DO_NGINX" -eq 0 && "$DO_SSH" -eq 0 ]]; then
  fail "Не выбран ни один модуль. Используй --docker, --zsh, --nginx, --ssh или --all. См. $0 --help"
fi

if [[ "$DO_NGINX" -eq 1 ]]; then
  [[ -n "$DOMAIN" && -n "$PROXY_PORT" && -n "$EMAIL" ]] \
    || fail "Для --nginx требуются --domain, --port, --email"
fi

require_root "$@"
detect_user
detect_os

# --- Execution plan ---
echo ""
echo "${BOLD}=== План выполнения ===${NC}"
[[ "$DO_DOCKER" -eq 1 ]] && print_summary_line "[ ] Docker:"  "Engine + Compose plugin"
[[ "$DO_ZSH" -eq 1 ]]    && print_summary_line "[ ] Zsh:"     "zsh + oh-my-zsh + plugins"
[[ "$DO_NGINX" -eq 1 ]]  && print_summary_line "[ ] Nginx:"   "$DOMAIN → :$PROXY_PORT + SSL"
[[ "$DO_SSH" -eq 1 ]]    && print_summary_line "[ ] SSH:"     "hardening + port knocking + fail2ban (INTERACTIVE)"
print_summary_line "Пользователь:" "$TARGET_USER"
print_summary_line "OS:"           "$OS_ID $OS_VERSION ($OS_CODENAME)"
echo ""

if [[ -t 0 ]]; then
  read -rp "Продолжить? [Y/n] " ans
  [[ "${ans:-y}" =~ ^[nN] ]] && fail "Отменено"
fi

# --- Helper to run sub-script ---
run_module() {
  local name="$1"
  shift
  local url="${REPO_RAW}/bootstrap/${name}"
  local local_path="${SCRIPT_DIR}/${name}"

  echo ""
  echo "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo "${BOLD}${BLUE}  → ${name} $*${NC}"
  echo "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

  if [[ -f "$local_path" ]]; then
    bash "$local_path" "$@" || fail "Модуль $name упал"
  else
    curl -fsSL "$url" | bash -s -- "$@" || fail "Модуль $name упал"
  fi
}

# --- Execute ---
[[ "$DO_DOCKER" -eq 1 ]] && run_module "docker_install.sh"
[[ "$DO_ZSH" -eq 1 ]]    && run_module "zsh_install.sh"

if [[ "$DO_NGINX" -eq 1 ]]; then
  run_module "nginx_install.sh" "--domain=$DOMAIN" "--port=$PROXY_PORT" "--email=$EMAIL"
fi

if [[ "$DO_SSH" -eq 1 ]]; then
  warn "SSH hardening запускается интерактивно. Открой ВТОРУЮ SSH-сессию для страховки!"
  if [[ -t 0 ]]; then
    read -rp "Готов? [Y/n] " ans
    [[ "${ans:-y}" =~ ^[nN] ]] || run_module "secure_ssh.sh"
  else
    warn "Non-interactive mode — SSH hardening пропущен"
  fi
fi

# --- Final summary ---
echo ""
echo "${BOLD}${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo "${BOLD}${GREEN}║                                                      ║${NC}"
echo "${BOLD}${GREEN}║          VPS Bootstrap завершён успешно              ║${NC}"
echo "${BOLD}${GREEN}║                                                      ║${NC}"
echo "${BOLD}${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
[[ "$DO_DOCKER" -eq 1 ]] && ok "Docker: $(docker --version 2>/dev/null || echo 'установлен')"
[[ "$DO_ZSH" -eq 1 ]]    && ok "Zsh: $(zsh --version 2>/dev/null | cut -d, -f1 || echo 'установлен')"
[[ "$DO_NGINX" -eq 1 ]]  && ok "Nginx: https://$DOMAIN → :$PROXY_PORT"
[[ "$DO_SSH" -eq 1 ]]    && ok "SSH hardening выполнен (проверь новый порт!)"
echo ""
warn "НЕ ЗАБУДЬ: перелогинься для активации docker-группы и zsh shell"
echo ""
