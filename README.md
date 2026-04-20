# scripts

Personal collection of VPS bootstrap and ops scripts. Modular design with a shared library and an orchestrator for composable setup.

## 🚀 Quick usage

### One-shot full setup (orchestrator)

```sh
# Docker + zsh + Nginx + SSL in one command
curl -fsSL https://raw.githubusercontent.com/svallotale/scripts/main/bootstrap/vps_bootstrap.sh | \
  sudo bash -s -- --docker --zsh --nginx \
    --domain=api.example.com --port=3000 --email=admin@example.com
```

### Individual modules

#### UFW firewall baseline
```sh
# Baseline: deny in / allow out / SSH (auto-detect port) + HTTP + HTTPS
curl -fsSL https://raw.githubusercontent.com/svallotale/scripts/main/bootstrap/firewall_baseline.sh | sudo bash

# С дополнительными портами
curl -fsSL https://raw.githubusercontent.com/svallotale/scripts/main/bootstrap/firewall_baseline.sh | \
  sudo bash -s -- --allow=8080 --allow=5432
```

Автодетектит текущий SSH-порт из `sshd_config` или активной сессии — не залочит.

#### Docker (Engine + Compose)
```sh
curl -fsSL https://raw.githubusercontent.com/svallotale/scripts/main/bootstrap/docker_install.sh | sudo bash
```

#### Zsh + oh-my-zsh
```sh
curl -fsSL https://raw.githubusercontent.com/svallotale/scripts/main/bootstrap/zsh_install.sh | sudo bash
```

#### Nginx reverse proxy + SSL
```sh
# Positional args (backward compat)
curl -fsSL https://raw.githubusercontent.com/svallotale/scripts/main/bootstrap/nginx_install.sh | \
  sudo bash -s -- api.example.com 3000 admin@example.com

# Named args (recommended)
curl -fsSL https://raw.githubusercontent.com/svallotale/scripts/main/bootstrap/nginx_install.sh | \
  sudo bash -s -- --domain=api.example.com --port=3000 --email=admin@example.com
```

Options:
- `--force` — overwrite existing vhost
- `--no-ssl` — HTTP only (skip certbot)

#### Secure SSH hardening (⚠️ interactive)
```sh
curl -fsSL https://raw.githubusercontent.com/svallotale/scripts/main/bootstrap/secure_ssh.sh | sudo bash
```

**⚠️ Keep a second SSH session open!** Port knocking breaks automation.

### Monitoring

#### Healthcheck (HTTP / SSL / Docker / disk / RAM / load + Telegram)

```sh
# Ad-hoc: проверка одного URL и домена
./monitoring/healthcheck.sh --url=https://api.foo --domain=api.foo

# Через config файл
sudo cp monitoring/healthcheck.conf.example /etc/healthcheck.conf
# edit /etc/healthcheck.conf — URLs, DOMAINS, Telegram token
./monitoring/healthcheck.sh

# Cron каждые 5 минут (только при ошибках)
*/5 * * * * /opt/scripts/monitoring/healthcheck.sh --quiet 2>&1 | logger -t healthcheck
```

**Что проверяется:**
- HTTP 200 на URL (`--url=...`, можно повторять)
- SSL expiration (`--domain=...`): warn < 14 дней, critical < 3 дней
- Docker containers: unhealthy и stopped
- Disk usage, RAM usage, Load average (пороги конфигурируемы)
- Postgres `pg_isready` (опционально)

**Telegram alerts:** задать `TELEGRAM_BOT_TOKEN` и `TELEGRAM_CHAT_ID` в env или `/etc/healthcheck.conf`.

Exit codes: `0` OK, `1` warnings, `2` errors.

## 📂 Structure

```
scripts/
├── lib/
│   └── common.sh                 # Shared helpers: logging, TUI, apt, idempotency
├── bootstrap/
│   ├── docker_install.sh         # Docker Engine + Compose
│   ├── zsh_install.sh            # Zsh + oh-my-zsh
│   ├── firewall_baseline.sh      # UFW + rate-limited SSH + autodetect
│   ├── nginx_install.sh          # Nginx + SSL + security headers
│   ├── secure_ssh.sh             # SSH hardening TUI
│   └── vps_bootstrap.sh          # Orchestrator — runs modules with flags
├── monitoring/
│   ├── healthcheck.sh            # HTTP/SSL/Docker/disk/RAM/load + Telegram
│   └── healthcheck.conf.example  # Config template
├── CLAUDE.md                     # Style guide for AI agents + humans
└── .github/workflows/
    └── shellcheck.yml            # CI linting
```

### Design principles

- **Modular:** each script does one thing (Docker *or* zsh *or* Nginx), not many
- **Idempotent:** safe to re-run — checks state before acting
- **Self-describing:** `--help` flag, coloured output, progress steps
- **Orchestratable:** `vps_bootstrap.sh` composes modules with named flags
- **DRY:** shared helpers in `lib/common.sh` (sourced locally or via curl)

## 📜 Scripts reference

### `bootstrap/vps_bootstrap.sh` (orchestrator)

Runs multiple modules with one command.

```sh
# All modules
sudo ./vps_bootstrap.sh --all --domain=foo.com --port=3000 --email=a@b.c

# Just Docker + zsh
sudo ./vps_bootstrap.sh --docker --zsh

# Docker + Nginx for a web app
sudo ./vps_bootstrap.sh --docker --nginx --domain=app.foo --port=8080 --email=a@b.c
```

Flags: `--all`, `--docker`, `--zsh`, `--nginx`, `--ssh`.

### `bootstrap/docker_install.sh`

Installs Docker Engine + Compose plugin. Idempotent — exits early if already installed.

**What it does:**
- Adds Docker APT repository with GPG key
- Installs `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin`
- Adds sudo user to `docker` group (requires re-login)
- Verifies via `hello-world` container

### `bootstrap/zsh_install.sh`

Installs Zsh + oh-my-zsh. Separated from docker so you can install individually.

**What it does:**
- Installs zsh, curl, git
- Changes default shell for target user (`chsh`)
- Runs oh-my-zsh installer non-interactively
- Configures `plugins=(git docker)` in .zshrc

### `bootstrap/nginx_install.sh`

Nginx reverse proxy + Let's Encrypt SSL. **Idempotent** (won't clobber existing vhost without `--force`).

**Features:**
- Security headers: HSTS, X-Frame-Options, X-Content-Type-Options, Referrer-Policy, Permissions-Policy
- WebSocket support (`Upgrade` / `Connection`)
- Extended timeouts (300s) for long-lived connections
- `X-Real-IP` / `X-Forwarded-For` / `X-Forwarded-Proto` headers

**Requirements:** A-record pointing to server, ports 80/443 open.

### `bootstrap/secure_ssh.sh`

27KB interactive TUI for SSH hardening: random port, 3-port knocking, fail2ban, config backups.

**⚠️ Warnings:**
- Can **lose SSH access** if misconfigured — always keep a second SSH session open
- Port knocking breaks CI/CD automation (deploy scripts must implement knocking)
- Remember new SSH port after running

### `lib/common.sh`

Shared helpers sourced by all scripts:

- Logging: `log`, `ok`, `warn`, `fail`, `info`, `dim`
- Sanity: `require_root`, `require_cmd`
- Detection: `detect_user` (populates `$TARGET_USER`, `$TARGET_HOME`), `detect_os` (populates `$OS_ID`, `$OS_CODENAME`, `$OS_VERSION`)
- Idempotency: `has_cmd`, `has_pkg`, `file_contains`
- APT: `apt_ensure`, `install_pkgs` (skips if already installed)
- Summary: `print_summary_line`

**Sourcing pattern** (each script does this):
```bash
if [[ -f "${SCRIPT_DIR}/../lib/common.sh" ]]; then
  source "${SCRIPT_DIR}/../lib/common.sh"
else
  source <(curl -fsSL "$REPO_RAW/lib/common.sh")
fi
```

Works both locally (via relative path) and via `curl | bash` (fetches lib from GitHub).

## 🔐 Safety tips

**Inspect before running:**
```sh
curl -fsSL https://raw.githubusercontent.com/svallotale/scripts/main/bootstrap/docker_install.sh | less
```

**Pin to commit SHA for reproducibility:**
```sh
curl -fsSL https://raw.githubusercontent.com/svallotale/scripts/abc1234/bootstrap/docker_install.sh | sudo bash
```

**Use jsDelivr CDN:**
```sh
curl -fsSL https://cdn.jsdelivr.net/gh/svallotale/scripts@main/bootstrap/docker_install.sh | sudo bash
```

## 🧪 Development

Test locally before pushing:

```sh
# Install shellcheck
sudo apt install shellcheck  # Debian/Ubuntu
brew install shellcheck      # macOS
scoop install shellcheck     # Windows

# Lint all scripts
shellcheck lib/*.sh bootstrap/*.sh
```

CI (GitHub Actions) runs shellcheck on every push.

### Adding a new script

1. Put it in `bootstrap/` (or create a new category folder)
2. Source `lib/common.sh` using the pattern above
3. Use `log`, `ok`, `warn`, `fail` for output
4. Make it idempotent (check state before modifying)
5. Add `--help` flag
6. Update this README
7. `git commit && git push` → CI validates → raw URL ready

## 📝 License

MIT — use as you wish, no warranty.
