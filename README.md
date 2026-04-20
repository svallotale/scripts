# scripts

Personal collection of VPS bootstrap and ops scripts. Quick deploy via `curl | bash` on fresh Ubuntu/Debian servers.

## 🚀 Quick usage

All scripts are publicly available via raw GitHub URLs. Copy-paste on your VPS:

### Docker + Compose + zsh + oh-my-zsh

```sh
curl -fsSL https://raw.githubusercontent.com/svallotale/scripts/main/bootstrap/docker_install.sh | sudo bash
```

### Nginx reverse proxy + Let's Encrypt SSL

```sh
curl -fsSL https://raw.githubusercontent.com/svallotale/scripts/main/bootstrap/nginx_install.sh | \
  bash -s -- <domain> <port> <email>
```

Example:
```sh
curl -fsSL https://raw.githubusercontent.com/svallotale/scripts/main/bootstrap/nginx_install.sh | \
  bash -s -- api.example.com 3000 admin@example.com
```

### Secure SSH hardening (interactive)

⚠️ **Read the warnings below before running** — this script modifies SSH config and firewall. Keep a second SSH session open as a safety net.

```sh
curl -fsSL https://raw.githubusercontent.com/svallotale/scripts/main/bootstrap/secure_ssh.sh | sudo bash
```

**Safer:** download first, inspect, then run locally:
```sh
wget https://raw.githubusercontent.com/svallotale/scripts/main/bootstrap/secure_ssh.sh
chmod +x secure_ssh.sh
sudo ./secure_ssh.sh
```

## 📂 Structure

```
scripts/
├── bootstrap/                # VPS initialization
│   ├── docker_install.sh     # Docker + Compose + zsh
│   ├── nginx_install.sh      # Nginx reverse proxy + SSL
│   └── secure_ssh.sh         # SSH hardening + fail2ban + port knocking
└── .github/
    └── workflows/
        └── shellcheck.yml    # CI linting
```

## 📜 Scripts

### `bootstrap/docker_install.sh`

Installs Docker Engine, CLI, Buildx, Compose plugin, zsh, and oh-my-zsh on Ubuntu/Debian. Adds the current non-root user to the `docker` group (requires re-login).

**Requirements:** `sudo`, Ubuntu 20.04+ / Debian 11+

**What it does:**
- Adds official Docker APT repository with GPG key
- Installs `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin`
- Enables Docker service via systemd
- Installs zsh, changes default shell, configures oh-my-zsh with `git docker` plugins
- Runs `hello-world` verification

### `bootstrap/nginx_install.sh`

Configures an Nginx reverse proxy with Let's Encrypt SSL for a single domain.

**Usage:** `nginx_install.sh <domain> <proxy_port> <email>`

**Requirements:** `sudo`, A-record pointing to server, ports 80 and 443 open.

### `bootstrap/secure_ssh.sh`

Interactive TUI script for SSH hardening. Features:

- Random SSH port (avoids common ports like 22, 80, 443, 3306, etc.)
- Port knocking with 3-port sequence
- Fail2ban installation and configuration
- Automatic backups of all modified configs (`*.bak.YYYYMMDD-HHMMSS`)

**⚠️ Warnings:**
- You can **lose SSH access** if misconfigured — always keep a second SSH session open
- Port knocking breaks automation (CI/CD deploys need to implement knocking)
- Remember the new SSH port after running — no default recovery path

## 🔐 Safety tips

**Always inspect scripts before piping to bash:**
```sh
curl -fsSL https://raw.githubusercontent.com/svallotale/scripts/main/bootstrap/docker_install.sh | less
```

**Pin to a specific commit for reproducibility:**
```sh
# Replace `main` with commit SHA
curl -fsSL https://raw.githubusercontent.com/svallotale/scripts/abc1234/bootstrap/docker_install.sh | sudo bash
```

**Use jsDelivr CDN for faster downloads:**
```sh
curl -fsSL https://cdn.jsdelivr.net/gh/svallotale/scripts@main/bootstrap/docker_install.sh | sudo bash
```

## 🧪 Local development

Test scripts with [shellcheck](https://github.com/koalaman/shellcheck) before committing:

```sh
shellcheck bootstrap/*.sh
```

CI validates all `.sh` files via GitHub Actions on every push.

## 📝 License

MIT — use as you wish, no warranty.
