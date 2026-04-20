#!/usr/bin/env bash
# =============================================================================
# zsh_install.sh
# Install zsh + oh-my-zsh for the target user, set as default shell.
# Configures plugins: git, docker.
#
# Idempotent — safe to re-run.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/svallotale/scripts/main/bootstrap/zsh_install.sh | sudo bash
#   OR
#   sudo ./zsh_install.sh
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

banner "Zsh Install" "zsh + oh-my-zsh + плагины"

require_root "$@"
detect_user
detect_os

# --- Step 1: Install zsh ---
install_pkgs zsh curl git

# --- Step 2: Set default shell ---
log "Установка zsh как shell по умолчанию для ${TARGET_USER}"
ZSH_PATH="$(command -v zsh)"
CURRENT_SHELL="$(getent passwd "${TARGET_USER}" | cut -d: -f7)"

if [[ "${CURRENT_SHELL}" == "${ZSH_PATH}" ]]; then
  ok "${TARGET_USER} уже использует zsh"
else
  if chsh -s "${ZSH_PATH}" "${TARGET_USER}"; then
    ok "Shell изменён (вступит в силу при новом входе)"
  else
    warn "Не удалось сменить shell автоматически. Вручную: chsh -s ${ZSH_PATH} ${TARGET_USER}"
  fi
fi

# --- Step 3: Install oh-my-zsh ---
OHMYZSH_DIR="${TARGET_HOME}/.oh-my-zsh"

if [[ -d "${OHMYZSH_DIR}" ]]; then
  ok "oh-my-zsh уже установлен в ${OHMYZSH_DIR}"
else
  log "Установка oh-my-zsh для ${TARGET_USER}"
  su - "${TARGET_USER}" -c '
    export RUNZSH=no CHSH=no KEEP_ZSHRC=yes
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
  '
  ok "oh-my-zsh установлен"
fi

# --- Step 4: Configure plugins ---
ZSHRC="${TARGET_HOME}/.zshrc"
log "Настройка плагинов в .zshrc"

if [[ -f "${ZSHRC}" ]]; then
  if grep -qE '^plugins=\(.*docker.*\)' "${ZSHRC}"; then
    ok "Плагин docker уже в .zshrc"
  elif grep -qE '^plugins=' "${ZSHRC}"; then
    sed -i 's/^plugins=.*/plugins=(git docker)/' "${ZSHRC}"
    ok "Плагины обновлены: git docker"
  else
    echo 'plugins=(git docker)' >> "${ZSHRC}"
    ok "Плагины добавлены"
  fi
else
  warn "${ZSHRC} не найден — создаю минимальный"
  cat > "${ZSHRC}" <<'EOF'
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="robbyrussell"
plugins=(git docker)
source $ZSH/oh-my-zsh.sh
EOF
  chown "${TARGET_USER}:${TARGET_USER}" "${ZSHRC}"
  ok "Создан базовый ${ZSHRC}"
fi

chown -R "${TARGET_USER}:${TARGET_USER}" "${OHMYZSH_DIR}" "${ZSHRC}" 2>/dev/null || true

success_box "Zsh установлен" \
  "$(zsh --version 2>/dev/null | cut -d, -f1 || echo 'zsh не найден')" \
  "oh-my-zsh: $([[ -d "${OHMYZSH_DIR}" ]] && echo "✓ готов" || echo 'не установлен')" \
  "" \
  "⚠ Перелогинься для активации zsh shell"
