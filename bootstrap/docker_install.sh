#!/usr/bin/env bash
set -euo pipefail

STEP=0
log() { STEP=$((STEP+1)); echo -e "\n========== [$STEP/??] $* =========="; }
ok()  { echo -e "✅ $*"; }
warn(){ echo -e "⚠️  $*"; }
fail(){ echo -e "❌ $*"; exit 1; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    fail "Запустите скрипт от root: sudo ./install.sh"
  fi
}

detect_user() {
  TARGET_USER="${SUDO_USER:-$USER}"
  TARGET_HOME="$(getent passwd "${TARGET_USER}" | cut -d: -f6)"
  [[ -n "${TARGET_HOME:-}" ]] || fail "Не удалось определить домашний каталог пользователя ${TARGET_USER}"
  ok "Целевой пользователь: ${TARGET_USER}, домашний каталог: ${TARGET_HOME}"
}

apt_update_base() {
  log "Обновление пакетов и установка зависимостей"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg lsb-release git
  ok "Базовые зависимости установлены"
}

install_docker_repo() {
  log "Добавление официального репозитория Docker"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  ARCH="$(dpkg --print-architecture)"
  echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update -y
  ok "Репозиторий Docker добавлен"
}

install_docker() {
  log "Установка Docker Engine, CLI, Buildx и Compose (plugin)"
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  ok "Docker установлен и запущен"
}

postinstall_docker() {
  log "Добавление пользователя в группу docker"
  getent group docker >/dev/null || groupadd docker
  usermod -aG docker "${TARGET_USER}" || true
  ok "Пользователь ${TARGET_USER} добавлен в группу docker (требуется перелогиниться)"
}

verify_docker() {
  log "Проверка Docker и Compose"
  docker --version || fail "Docker не отвечает"
  ok "$(docker --version)"

  if docker compose version >/dev/null 2>&1; then
    ok "$(docker compose version)"
  else
    warn "docker compose (plugin) не найден, попробуем установить отдельный бинарник"
    DOCKER_COMPOSE_BIN="/usr/local/bin/docker-compose"
    if [[ ! -x "${DOCKER_COMPOSE_BIN}" ]]; then
      curl -fsSL "https://github.com/docker/compose/releases/download/v2.29.7/docker-compose-$(uname -s)-$(uname -m)" -o "${DOCKER_COMPOSE_BIN}"
      chmod +x "${DOCKER_COMPOSE_BIN}"
    fi
    "${DOCKER_COMPOSE_BIN}" version && ok "Установлен docker-compose (standalone)"
  fi

  log "Тестовый запуск контейнера hello-world (таймаут 60с)"
  if timeout 60s docker run --rm hello-world >/dev/null 2>&1; then
    ok "Тестовый контейнер успешно запущен"
  else
    warn "Не удалось запустить hello-world. Возможные причины: сетевые ограничения или прокси."
  fi
}

install_zsh() {
  log "Установка Zsh"
  apt-get install -y zsh
  ok "Zsh установлен: $(zsh --version)"

  log "Смена шелла по умолчанию на Zsh для пользователя ${TARGET_USER}"
  ZSH_PATH="$(command -v zsh)"
  chsh -s "${ZSH_PATH}" "${TARGET_USER}" || warn "Не удалось сменить shell автоматически. Можно вручную: chsh -s $(command -v zsh) ${TARGET_USER}"
  ok "Шелл по умолчанию (вступит в силу после нового входа)"
}

install_ohmyzsh() {
  log "Установка Oh My Zsh (без автозапуска)"
  su - "${TARGET_USER}" -c 'export RUNZSH=no CHSH=no KEEP_ZSHRC=yes; sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"'
  ok "Oh My Zsh установлен"

  ZSHRC="${TARGET_HOME}/.zshrc"
  if [[ -f "${ZSHRC}" ]]; then
    log "Настройка плагинов в .zshrc"
    # Обновим plugins, добавим docker, сохраняя остальное
    if grep -qE '^plugins=' "${ZSHRC}"; then
      sed -i 's/^plugins=.*/plugins=(git docker)/' "${ZSHRC}"
    else
      echo 'plugins=(git docker)' >> "${ZSHRC}"
    fi
    ok "Плагины .zshrc обновлены (git docker)"
  else
    warn ".zshrc не найден, создаём минимальный"
    cat >> "${ZSHRC}" <<'EOF'
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="robbyrussell"
plugins=(git docker)
source $ZSH/oh-my-zsh.sh
EOF
    ok "Создан базовый ${ZSHRC}"
  fi

  chown -R "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/.oh-my-zsh" "${ZSHRC}" || true
}

verify_shells() {
  log "Проверка Zsh и Oh My Zsh"
  zsh --version || fail "Zsh не найден"
  [[ -d "${TARGET_HOME}/.oh-my-zsh" ]] && ok "Oh My Zsh найден в ${TARGET_HOME}/.oh-my-zsh" || warn "Oh My Zsh не обнаружен"

  CURRENT_SHELL="$(getent passwd "${TARGET_USER}" | cut -d: -f7)"
  ok "Текущий shell ${TARGET_USER}: ${CURRENT_SHELL}"
}

summary() {
  echo -e "\n========== Итоги =========="
  echo "• Docker: $(docker --version 2>/dev/null || echo 'не найден')"
  echo "• Docker Compose: $( (docker compose version 2>/dev/null) || (/usr/local/bin/docker-compose version 2>/dev/null) || echo 'не найден')"
  echo "• Zsh: $(zsh --version 2>/dev/null || echo 'не найден')"
  echo "• Oh My Zsh: $([[ -d "${TARGET_HOME}/.oh-my-zsh" ]] && echo 'установлен' || echo 'не установлен')"
  echo "• Пользователь для docker-группы: ${TARGET_USER} (перелогиньтесь, чтобы применить группу и shell)"
  echo "==========================="
}

main() {
  require_root
  detect_user
  apt_update_base
  install_docker_repo
  install_docker
  postinstall_docker
  verify_docker
  install_zsh
  install_ohmyzsh
  verify_shells
  summary
}

main "$@"