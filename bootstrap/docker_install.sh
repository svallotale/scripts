#!/usr/bin/env bash
# =============================================================================
# docker_install.sh
# Install Docker Engine + CLI + Buildx + Compose plugin on Ubuntu/Debian.
# Adds the target (sudo) user to the `docker` group.
#
# Idempotent — safe to re-run.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/svallotale/scripts/main/bootstrap/docker_install.sh | sudo bash
#   OR
#   sudo ./docker_install.sh
# =============================================================================
set -euo pipefail

# --- Source common lib (local or via curl) ---
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

require_root "$@"
detect_user
detect_os

if [[ "${OS_ID}" != "ubuntu" && "${OS_ID}" != "debian" ]]; then
  warn "Скрипт тестирован на Ubuntu/Debian, у тебя: ${OS_ID} ${OS_VERSION}"
  if [[ -t 0 ]]; then
    read -rp "Продолжить? [y/N] " ans
    [[ "${ans:-n}" =~ ^[yY] ]] || fail "Отменено"
  fi
fi

# --- Step 1: Check if already installed ---
if has_cmd docker && has_pkg docker-ce; then
  ok "Docker уже установлен: $(docker --version)"
  if docker compose version >/dev/null 2>&1; then
    ok "Compose уже установлен: $(docker compose version)"
  fi
  if id -nG "${TARGET_USER}" | grep -qw docker; then
    ok "Пользователь ${TARGET_USER} уже в группе docker"
    exit 0
  fi
  log "Добавляю ${TARGET_USER} в группу docker"
  usermod -aG docker "${TARGET_USER}"
  ok "Готово. Перелогинься чтобы применить группу."
  exit 0
fi

# --- Step 2: Base dependencies ---
install_pkgs ca-certificates curl gnupg lsb-release

# --- Step 3: Docker APT repository ---
log "Настройка Docker APT репозитория"
KEYRING="/etc/apt/keyrings/docker.gpg"
LIST="/etc/apt/sources.list.d/docker.list"

install -m 0755 -d /etc/apt/keyrings
if [[ ! -f "${KEYRING}" ]]; then
  curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" | gpg --dearmor -o "${KEYRING}"
  chmod a+r "${KEYRING}"
  ok "GPG ключ установлен"
else
  ok "GPG ключ уже есть"
fi

ARCH="$(dpkg --print-architecture)"
REPO_LINE="deb [arch=${ARCH} signed-by=${KEYRING}] https://download.docker.com/linux/${OS_ID} ${OS_CODENAME} stable"

if ! file_contains "${LIST}" "${REPO_LINE}"; then
  echo "${REPO_LINE}" > "${LIST}"
  apt-get update -y
  ok "Репозиторий добавлен"
else
  ok "Репозиторий уже настроен"
fi

# --- Step 4: Install Docker ---
install_pkgs docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

log "Проверка systemd unit'а"
systemctl enable --now docker
ok "docker.service активен"

# --- Step 5: User to docker group ---
log "Настройка группы docker"
getent group docker >/dev/null || groupadd docker
if id -nG "${TARGET_USER}" | grep -qw docker; then
  ok "${TARGET_USER} уже в группе"
else
  usermod -aG docker "${TARGET_USER}"
  warn "${TARGET_USER} добавлен в группу docker — перелогинься для применения"
fi

# --- Step 6: Verify ---
log "Smoke test hello-world (timeout 60s)"
if timeout 60s docker run --rm hello-world >/dev/null 2>&1; then
  ok "Тестовый контейнер прошёл"
else
  warn "hello-world не запустился (возможно — сетевые ограничения)"
fi

# --- Summary ---
echo ""
echo "${BOLD}=== Итог ===${NC}"
print_summary_line "Docker:"        "$(docker --version 2>/dev/null || echo 'не найден')"
print_summary_line "Compose:"       "$(docker compose version 2>/dev/null | head -1 || echo 'не найден')"
print_summary_line "Пользователь:"  "${TARGET_USER} (группа docker — требуется relogin)"
echo ""

ok "Готово."
