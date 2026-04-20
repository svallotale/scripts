#!/usr/bin/env bash
# =============================================================================
# common.sh — shared helpers for scripts/ repo
#
# Source this from bootstrap scripts. Provides:
#   - Coloured logging: log, ok, warn, fail, info
#   - Sanity checks: require_root, require_cmd, detect_os, detect_user
#   - Apt helpers: apt_ensure, install_pkgs
#   - Idempotency: has_pkg, has_cmd, file_contains
#
# Usage:
#   source <(curl -fsSL https://raw.githubusercontent.com/svallotale/scripts/main/lib/common.sh)
#   # OR when run locally:
#   source "$(dirname "$0")/../lib/common.sh"
# =============================================================================

# shellcheck disable=SC2034
# (colour vars may be used by sourcing scripts)

# --- Colours ---
if [[ -t 1 ]]; then
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[1;33m'
  BLUE=$'\033[0;34m'
  CYAN=$'\033[0;36m'
  BOLD=$'\033[1m'
  DIM=$'\033[2m'
  NC=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; BOLD=""; DIM=""; NC=""
fi

# --- Step counter ---
_STEP=0

# --- Logging primitives ---
log()  { _STEP=$((_STEP+1)); printf "\n${BLUE}========== [%d] %s ==========${NC}\n" "${_STEP}" "$*"; }
ok()   { printf "${GREEN}✅ %s${NC}\n" "$*"; }
warn() { printf "${YELLOW}⚠️  %s${NC}\n" "$*"; }
fail() { printf "${RED}❌ %s${NC}\n" "$*" >&2; exit 1; }
info() { printf "${CYAN}ℹ️  %s${NC}\n" "$*"; }
dim()  { printf "${DIM}%s${NC}\n" "$*"; }

# --- Sanity checks ---
require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    fail "Запусти от root: sudo $0 $*"
  fi
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || fail "Команда '$cmd' не найдена. Установи её и повтори."
}

# --- Detection ---
detect_user() {
  TARGET_USER="${SUDO_USER:-$USER}"
  TARGET_HOME="$(getent passwd "${TARGET_USER}" | cut -d: -f6)"
  [[ -n "${TARGET_HOME:-}" ]] || fail "Не удалось определить домашний каталог ${TARGET_USER}"
  export TARGET_USER TARGET_HOME
}

detect_os() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_CODENAME="${VERSION_CODENAME:-unknown}"
    OS_VERSION="${VERSION_ID:-unknown}"
    export OS_ID OS_CODENAME OS_VERSION
  else
    fail "Не найден /etc/os-release (требуется systemd-совместимый дистрибутив)"
  fi
}

# --- Idempotency helpers ---
has_cmd() { command -v "$1" >/dev/null 2>&1; }

has_pkg() {
  dpkg -s "$1" >/dev/null 2>&1
}

file_contains() {
  local file="$1" pattern="$2"
  [[ -f "$file" ]] && grep -qF "$pattern" "$file"
}

# --- Apt helpers ---
apt_ensure() {
  export DEBIAN_FRONTEND=noninteractive
  if [[ ! -f /var/lib/apt/periodic/update-success-stamp ]] \
     || [[ $(($(date +%s) - $(stat -c %Y /var/lib/apt/periodic/update-success-stamp 2>/dev/null || echo 0))) -gt 3600 ]]; then
    log "apt-get update"
    apt-get update -y
  fi
}

install_pkgs() {
  local pkgs=("$@")
  local missing=()
  for p in "${pkgs[@]}"; do
    has_pkg "$p" || missing+=("$p")
  done
  if [[ ${#missing[@]} -eq 0 ]]; then
    ok "Все пакеты установлены: ${pkgs[*]}"
    return 0
  fi
  apt_ensure
  log "Установка: ${missing[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
  ok "Установлены: ${missing[*]}"
}

# --- Summary box ---
print_summary_line() {
  local label="$1" value="$2"
  printf "  ${BOLD}%-25s${NC} %s\n" "$label" "$value"
}

# Signal that lib is loaded (scripts check this)
COMMON_SH_LOADED=1
export COMMON_SH_LOADED
