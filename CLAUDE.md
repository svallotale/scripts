# CLAUDE.md

Инструкции для Claude Code при работе с этим репозиторием.

## Project

Коллекция bash/python скриптов для bootstrap VPS и ops-задач. Всё публичное — запускается через `curl | bash` на свежем Ubuntu/Debian. Модульная архитектура: общая библиотека в `lib/`, исполняемые скрипты в `bootstrap/`, оркестратор `vps_bootstrap.sh` собирает модули.

**Репо:** github.com/svallotale/scripts

## Структура

```
scripts/
├── lib/
│   └── common.sh          # Shared helpers: logging, TUI, apt, idempotency
├── bootstrap/             # VPS initialization scripts
│   ├── docker_install.sh
│   ├── zsh_install.sh
│   ├── nginx_install.sh
│   ├── secure_ssh.sh
│   └── vps_bootstrap.sh   # Orchestrator
├── .github/workflows/     # CI (shellcheck)
├── CLAUDE.md              # Этот файл
└── README.md
```

Новые категории создавай как sibling-папки: `backup/`, `monitoring/`, `crypto/` и т.п.

## Code style — non-negotiable

### Bash

| Правило | Обязательно |
|---|---|
| Shebang `#!/usr/bin/env bash` | ✅ |
| `set -euo pipefail` сразу после shebang | ✅ |
| LF line endings (см. `.gitattributes`) | ✅ |
| 2 spaces indent | ✅ |
| Shellcheck чистый (CI enforce) | ✅ |
| `[[ ]]` вместо `[ ]` | ✅ |
| Кавычки у переменных: `"$var"` | ✅ |
| `local` в функциях | ✅ |
| Нет `cd foo` без `|| exit` или early check | ✅ |
| Snake_case имена функций и файлов | ✅ |
| UPPER_CASE для env vars | ✅ |

### Именование

- **Файлы скриптов:** `snake_case.sh` (`docker_install.sh`, `backup_all.sh`)
- **Функции в lib:** `snake_case` (`install_pkgs`, `has_cmd`, `confirm`)
- **User-facing env vars:** `UPPER_SNAKE` (`TARGET_USER`, `OS_ID`, `DOMAIN`)
- **Локальные:** `lower_snake` (`file`, `pkg`, `line`)
- **Константы в скрипте:** `UPPER_SNAKE` в начале файла

### Язык комментариев и сообщений

- **Комментарии в коде** — английский (для совместимости shellcheck и портативности)
- **Сообщения пользователю** (log/ok/warn/fail) — **русский** (целевая аудитория)
- **README/CLAUDE.md** — русский и английский смешанно допустимо, но структурные заголовки на английском

## Структура нового скрипта — обязательный шаблон

Каждый скрипт в `bootstrap/`:

```bash
#!/usr/bin/env bash
# =============================================================================
# <script_name>.sh
# <one-line purpose in English>
#
# Idempotent — safe to re-run.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/svallotale/scripts/main/bootstrap/<name>.sh | sudo bash
#   OR
#   sudo ./<name>.sh [args]
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
# ... use named args: --foo=bar ...

# --- Banner + prechecks ---
banner "Script Title" "Short subtitle"

require_root "$@"
detect_user
detect_os

# --- Main logic ---
# ... use log / ok / warn / fail / info ...

# --- Summary ---
success_box "Готово" "result line 1" "result line 2"
```

## Обязательные требования к поведению

### 1. Идемпотентность

Скрипт ДОЛЖЕН быть безопасным при повторном запуске. Проверяй состояние ДО действия:

```bash
# ✅ Правильно
if has_cmd docker && has_pkg docker-ce; then
  ok "Docker уже установлен: $(docker --version)"
  exit 0
fi

# ✅ Правильно
if file_contains /etc/foo.conf "magic_line"; then
  ok "Конфиг уже настроен"
else
  echo "magic_line" >> /etc/foo.conf
fi

# ❌ Неправильно — при повторе упадёт
ln -s "$CONF" "$LINK"

# ✅ Правильно
[[ -L "$LINK" ]] || ln -s "$CONF" "$LINK"
```

Используй хелперы из lib: `has_cmd`, `has_pkg`, `file_contains`, `install_pkgs` (сам skip'ает установленные).

### 2. Error handling

```bash
# ✅ Используй fail — красный ❌ и exit 1
[[ -n "$DOMAIN" ]] || fail "Не задан --domain"

# ❌ Не надо
echo "error" && exit 1
```

**Не глушить ошибки** через `|| true` без явного комментария зачем.

### 3. Вывод

**Всегда** используй TUI-хелперы из `lib/common.sh`:

| Хелпер | Когда |
|---|---|
| `log "Step name"` | Начало шага (автонумерация `[1]`, `[2]`, ...) |
| `ok "Result"` | Успех |
| `warn "Notice"` | Некритичное предупреждение |
| `fail "Error"` | Критичная ошибка → exit 1 |
| `info "FYI"` | Информация |
| `dim "note"` | Приглушённый текст |
| `banner "Title" "Sub"` | В начале скрипта |
| `section "Name"` | Раздел в оркестраторе |
| `confirm "Yes?" "y"` | Y/N с default |
| `select_menu "Pick:" a b c` | Выбор из списка |
| `progress_step N M "desc"` | Счётчик шагов |
| `success_box "Done" "line1"` | Финальная рамка |
| `print_summary_line "Label:" "value"` | Строка с выравниванием |

**Никогда:**
```bash
# ❌ Сырой echo для статуса
echo "Installing..."

# ✅
log "Installing packages"
```

### 4. Аргументы

- Поддерживай `--help` / `-h`
- Именованные args — `--domain=foo`, `--port=3000` (preferred)
- Позиционные — только для backward compat существующих скриптов
- Валидируй **все** required args **в начале**, fail с `fail`

Пример:
```bash
for arg in "$@"; do
  case "$arg" in
    --domain=*) DOMAIN="${arg#*=}" ;;
    --port=*)   PORT="${arg#*=}" ;;
    -h|--help)  print_help; exit 0 ;;
    --*)        fail "Неизвестный флаг: $arg" ;;
  esac
done

[[ -n "$DOMAIN" ]] || fail "Не задан --domain"
```

### 5. Root и OS

Для скриптов меняющих систему:

```bash
require_root "$@"
detect_user     # $TARGET_USER, $TARGET_HOME
detect_os       # $OS_ID, $OS_CODENAME, $OS_VERSION
```

Скрипты **не меняющие систему** (отправляющие payload, генерирующие файлы в HOME) — без `require_root`.

## Python скрипты

Если скрипт на Python:

- Shebang: `#!/usr/bin/env python3`
- Docstring в начале (что делает, usage)
- Конфигурация через **env vars**, никогда не хардкод секретов
- `sys.exit(1)` с `print(..., file=sys.stderr)` при ошибке
- Поддержка `-h`/`--help` через `argparse`

```python
#!/usr/bin/env python3
"""Short purpose line.

Usage:
    export FOO_TOKEN="..."
    python3 script.py --arg value
"""
import os
import sys

TOKEN = os.environ.get("FOO_TOKEN")
if not TOKEN:
    print("ERROR: FOO_TOKEN не задан", file=sys.stderr)
    sys.exit(1)
```

**Нельзя:**
```python
API_SECRET = "hardcoded_secret"  # ❌ — попадёт в git
```

## Добавление нового скрипта — чек-лист

- [ ] Файл в подходящей папке (`bootstrap/`, `backup/`, `monitoring/`, …)
- [ ] Шебанг `#!/usr/bin/env bash` + `set -euo pipefail`
- [ ] Source `lib/common.sh` по стандартному паттерну
- [ ] `banner` в начале, `success_box` в конце
- [ ] Использует `log/ok/warn/fail/info` — никаких сырых echo
- [ ] Идемпотентен — проверки состояния перед действием
- [ ] Флаг `--help`
- [ ] `require_root` / `detect_user` / `detect_os` если нужно
- [ ] Локально пройден `shellcheck <file>.sh`
- [ ] Обновлён `README.md` (короткое описание + one-liner)
- [ ] Коммит по формату (см. ниже)

## Commit messages

Формат: `<type>: <subject>`

Типы:
- `feat:` — новый скрипт или крупная фича
- `fix:` — багфикс
- `refactor:` — реструктуризация без изменения поведения
- `docs:` — README / CLAUDE.md
- `ci:` — GitHub Actions / workflows
- `chore:` — мелочи (обновления `.gitignore` и т.п.)

Примеры:
```
✅ feat: add backup_all.sh — universal backup with encryption
✅ fix(nginx): allow domains with underscores
✅ refactor: extract TUI helpers from vps_bootstrap.sh to common.sh
✅ docs: add safety warnings to secure_ssh.sh README

❌ update
❌ fix stuff
❌ wip
```

Тело коммита (опционально, для больших изменений): bullet-points что изменилось.

## Тестирование

**Минимум:** `shellcheck <script>.sh` проходит без ошибок уровня warning.

**Локально:**
```sh
# Install shellcheck
sudo apt install shellcheck   # Debian/Ubuntu
brew install shellcheck       # macOS
scoop install shellcheck      # Windows

# Прогон
shellcheck lib/*.sh bootstrap/*.sh
```

**Для критичных скриптов** (работающих с SSH, firewall, secrets):
- Тест на свежем VPS (или Docker-контейнере):
  ```sh
  docker run --rm -it ubuntu:24.04 bash
  # внутри:
  apt-get update && apt-get install -y curl sudo
  curl -fsSL https://raw.githubusercontent.com/svallotale/scripts/main/bootstrap/<name>.sh | bash
  ```
- Проверка idempotency: запустить 2 раза подряд, второй раз должен сказать "уже установлено"

## Что НЕ делать

- ❌ Хардкод секретов, токенов, паролей в коде
- ❌ `sudo` внутри скрипта (предполагай что скрипт уже запущен через sudo; используй `require_root`)
- ❌ Молчаливое swallowing ошибок (`|| true` без комментария)
- ❌ `rm -rf /` без подтверждения (ну понятно)
- ❌ Писать в `/tmp/` без `mktemp` (security)
- ❌ `wget | sh` без проверок (всегда curl с `-fsSL`)
- ❌ Дублировать логику из `lib/common.sh` — используй хелперы

## Специфика `curl | bash`

Скрипты запускаются как:
```sh
curl -fsSL <raw_url> | sudo bash -s -- [args]
```

При этом:
- `$0` может быть `bash` или `/dev/stdin`
- `$BASH_SOURCE[0]` может быть пустым
- Нет файловой системы для `$SCRIPT_DIR`

**Поэтому:**
- Source lib через конструкцию с fallback на curl (см. шаблон)
- Не полагайся на `$SCRIPT_DIR` — fallback на `REPO_RAW`
- Скрипт должен быть **self-contained** — не требовать других файлов в dir

## Security mindset

- Скрипты публичные, их могут форкнуть и внести backdoor — используй **pinning** (commit SHA) в prod
- GitHub raw редиректит на CDN — проверяй SSL (`curl -fsSL` с `-f` падает на 4xx)
- Не логируй секреты (`echo "$TOKEN"` — никогда)
- В interactive prompts для паролей — `read -s` (silent)

## Дорожная карта (для ориентира Claude)

Планируемые скрипты (не реализованы):
- `firewall_baseline.sh` — UFW baseline (22, 80, 443)
- `fail2ban_standalone.sh` — fail2ban отдельно от secure_ssh
- `backup_all.sh` — Postgres + volumes + files → S3/Nextcloud
- `healthcheck.sh` — HTTP/SSL/DB monitoring + Telegram
- `ssl_check.sh` — мониторинг expiration всех доменов
- `docker_cleanup.sh` — prune старых images/volumes

Если пользователь просит что-то из этого списка — следуй шаблону выше, добавляй в оркестратор при необходимости.

## Вопросы к пользователю — когда спросить

Спрашивай **перед** тем как:
- Писать деструктивный скрипт (rm, overwrite configs)
- Добавлять внешние зависимости (новые packages, новые tokens)
- Менять поведение существующего скрипта на несовместимое
- Создавать новую категорию папок

Можно делать без вопроса:
- Баг-фиксы
- Улучшения логирования / сообщений
- Добавление idempotency-проверок
- Рефакторинг в пределах одного файла
- Обновление README / CLAUDE.md
