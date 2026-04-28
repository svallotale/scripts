#!/bin/bash
set -euo pipefail

cleanup() {
    tput cnorm 2>/dev/null || true
    rm -f "${TEMP_FILES[@]}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

TEMP_FILES=()

# ============================================================================
# SECURE SSH — Автонастройка защиты сервера
# Интерактивный скрипт для Debian/Ubuntu
# ============================================================================

# --- Цвета и символы ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

CHECKMARK="${GREEN}✓${NC}"
CROSSMARK="${RED}✗${NC}"
WARNING="${YELLOW}⚠${NC}"
ARROW="${CYAN}►${NC}"

BACKUP_SUFFIX="$(date +%Y%m%d-%H%M%S)"
BACKUPS_MADE=()

# Общеизвестные порты, которые нельзя использовать
COMMON_PORTS=(22 80 443 3306 5432 6379 8080 8443 25 53 110 143 993 995 587 465 3389 5900 27017 6443)

# Переменные для сгенерированных параметров
SSH_PORT=""
KNOCK_PORT1=""
KNOCK_PORT2=""
KNOCK_PORT3=""
SERVER_IP=""
DETECTED_IFACE=""

# ============================================================================
# Task 1: TUI-утилиты
# ============================================================================

print_header() {
    local msg="$1"
    local len=${#msg}
    local border=""
    for ((i = 0; i < len + 4; i++)); do border+="═"; done
    echo ""
    echo -e "${BLUE}╔${border}╗${NC}"
    echo -e "${BLUE}║${NC}  ${BOLD}${msg}${NC}  ${BLUE}║${NC}"
    echo -e "${BLUE}╚${border}╝${NC}"
    echo ""
}

print_section() {
    echo ""
    echo -e "  [${ARROW}] ${BOLD}$1${NC}"
    echo ""
}

print_ok() {
    echo -e "  ${CHECKMARK} $1"
}

print_fail() {
    echo -e "  ${CROSSMARK} $1"
}

print_warn() {
    echo -e "  ${WARNING} $1"
}

print_info() {
    echo -e "  ${DIM}$1${NC}"
}

spinner() {
    local pid="$1"
    local msg="$2"
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local i=0

    tput civis 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r  ${CYAN}%s${NC} %s" "${frames[$i]}" "$msg"
        i=$(( (i + 1) % ${#frames[@]} ))
        sleep 0.1
    done
    printf "\r"
    tput cnorm 2>/dev/null || true
}

run_silent() {
    local msg="$1"
    shift
    local logfile
    logfile=$(mktemp /tmp/secure_ssh_log.XXXXXX)
    TEMP_FILES+=("$logfile")

    "$@" > "$logfile" 2>&1 &
    local pid=$!
    spinner "$pid" "$msg"
    if wait "$pid"; then
        print_ok "$msg"
        rm -f "$logfile"
        return 0
    else
        print_fail "$msg"
        echo -e "  ${DIM}--- Журнал ошибок ---${NC}"
        sed 's/^/    /' "$logfile"
        echo -e "  ${DIM}--- Конец журнала ---${NC}"
        rm -f "$logfile"
        return 1
    fi
}

# Read a line of user input, working both for `bash script.sh` (stdin = tty)
# and for `curl ... | bash` (stdin = pipe).  In the latter case we read from
# /dev/tty directly so the user can still answer prompts.
_read_input() {
    local __varname="$1"
    if [[ -t 0 ]]; then
        read -r "${__varname?}"
    elif [[ -r /dev/tty ]]; then
        read -r "${__varname?}" < /dev/tty
    else
        # No TTY available at all (CI / headless) — empty answer = default
        printf -v "$__varname" '%s' ''
        return 1
    fi
}

confirm() {
    local msg="$1"
    echo ""
    echo -ne "  ${YELLOW}?${NC} ${msg} ${DIM}[y/N]${NC}: "
    local answer=""
    _read_input answer || true
    [[ "$answer" =~ ^[Yy]$ ]]
}

confirm_or_regenerate() {
    local msg="$1"
    echo ""
    echo -ne "  ${YELLOW}?${NC} ${msg} ${DIM}[y/N/r — перегенерировать]${NC}: "
    local answer=""
    _read_input answer || true
    case "$answer" in
        [Yy]) return 0 ;;
        [Rr]) return 2 ;;
        *)    return 1 ;;
    esac
}

make_backup() {
    local file="$1"
    if [[ -f "$file" ]]; then
        local backup="${file}.bak.${BACKUP_SUFFIX}"
        cp -a "$file" "$backup"
        BACKUPS_MADE+=("$backup")
        print_info "Резервная копия: ${backup}"
    fi
}

# ============================================================================
# Task 2: Предварительные проверки
# ============================================================================

preflight_checks() {
    print_section "Предварительные проверки"

    # Проверка root
    if [[ $EUID -ne 0 ]]; then
        print_fail "Скрипт должен быть запущен от root"
        print_info "Используйте: sudo $0"
        exit 1
    fi
    print_ok "Запуск от root"

    # Установка базовых зависимостей
    local base_deps=(openssh-server iputils-ping iproute2 kmod)
    local missing_deps=()
    for dep in "${base_deps[@]}"; do
        if ! dpkg -l "$dep" 2>/dev/null | grep -qE '^ii'; then
            missing_deps+=("$dep")
        fi
    done
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        run_silent "Обновление списка пакетов" apt-get update -qq
        run_silent "Установка базовых зависимостей (${missing_deps[*]})" \
            apt-get install -y -qq "${missing_deps[@]}"
    fi
    print_ok "Базовые зависимости установлены"

    # Проверка ОС
    if [[ -f /etc/os-release ]]; then
        local os_id
        os_id=$(. /etc/os-release && echo "${ID:-unknown}")
        if [[ "$os_id" =~ ^(debian|ubuntu)$ ]]; then
            local os_pretty
            os_pretty=$(. /etc/os-release && echo "${PRETTY_NAME:-$os_id}")
            print_ok "ОС: ${os_pretty}"
        else
            print_fail "Неподдерживаемая ОС: ${os_id}"
            print_info "Скрипт поддерживает только Debian и Ubuntu"
            exit 1
        fi
    else
        print_fail "Файл /etc/os-release не найден"
        exit 1
    fi

    # Проверка authorized_keys
    local real_user="${SUDO_USER:-root}"
    local real_home
    real_home=$(getent passwd "$real_user" | cut -d: -f6)
    local auth_keys="${real_home}/.ssh/authorized_keys"

    if [[ ! -f "$auth_keys" ]] || [[ ! -s "$auth_keys" ]]; then
        print_fail "Файл ${auth_keys} не найден или пуст!"
        print_info "Добавьте SSH-ключ перед запуском скрипта:"
        print_info "  ssh-copy-id ${real_user}@сервер"
        exit 1
    fi

    local key_count
    key_count=$(grep -cE '^(ssh-|ecdsa-)' "$auth_keys" 2>/dev/null || echo "0")
    print_ok "SSH-ключи найдены: ${key_count} шт. (${auth_keys})"

    # Проверка интернета
    if ping -c1 -W3 deb.debian.org > /dev/null 2>&1; then
        print_ok "Доступ в интернет: есть"
    else
        print_fail "Нет доступа к deb.debian.org"
        exit 1
    fi
}

# ============================================================================
# Task 3: Генерация случайных параметров
# ============================================================================

is_port_available() {
    local port="$1"
    # Не должен быть в списке общеизвестных
    for cp in "${COMMON_PORTS[@]}"; do
        [[ "$port" -eq "$cp" ]] && return 1
    done
    # Не должен прослушиваться
    if ss -tlnp 2>/dev/null | grep -qE ":${port}\b"; then
        return 1
    fi
    return 0
}

generate_random_port() {
    local min="$1"
    local max="$2"
    local port
    local attempts=0
    while (( attempts++ < 1000 )); do
        port=$(shuf -i "${min}-${max}" -n 1)
        if is_port_available "$port"; then
            echo "$port"
            return 0
        fi
    done
    print_fail "Не удалось подобрать свободный порт за 1000 попыток"
    exit 1
}

generate_parameters() {
    print_section "Генерация параметров безопасности"

    while true; do
        SSH_PORT=$(generate_random_port 10000 65000)

        # Генерация 3 уникальных knock-портов
        local used_ports=("$SSH_PORT")
        KNOCK_PORT1=""
        KNOCK_PORT2=""
        KNOCK_PORT3=""

        while true; do
            local candidate
            candidate=$(generate_random_port 1024 65000)
            local is_dup=false
            for u in "${used_ports[@]}"; do
                [[ "$candidate" -eq "$u" ]] && is_dup=true && break
            done
            if ! $is_dup; then
                if [[ -z "$KNOCK_PORT1" ]]; then
                    KNOCK_PORT1="$candidate"
                    used_ports+=("$candidate")
                elif [[ -z "$KNOCK_PORT2" ]]; then
                    KNOCK_PORT2="$candidate"
                    used_ports+=("$candidate")
                elif [[ -z "$KNOCK_PORT3" ]]; then
                    KNOCK_PORT3="$candidate"
                    break
                fi
            fi
        done

        echo ""
        echo -e "  ${BOLD}Сгенерированные параметры:${NC}"
        echo -e "    SSH-порт:        ${GREEN}${SSH_PORT}${NC}"
        echo -e "    Knock-порты:     ${GREEN}${KNOCK_PORT1}${NC} → ${GREEN}${KNOCK_PORT2}${NC} → ${GREEN}${KNOCK_PORT3}${NC}"
        echo ""

        local rc=0
        confirm_or_regenerate "Принять эти параметры?" || rc=$?
        case $rc in
            0) break ;;
            2) print_info "Перегенерация..."; continue ;;
            *)
                print_fail "Отменено пользователем"
                exit 1
                ;;
        esac
    done

    print_ok "Параметры приняты"
}

# ============================================================================
# Task 4: Установка пакетов
# ============================================================================

install_packages() {
    print_section "Установка необходимых пакетов"

    local packages=(knockd iptables iptables-persistent)
    local to_install=()

    for pkg in "${packages[@]}"; do
        if dpkg -l "$pkg" 2>/dev/null | grep -qE '^ii'; then
            print_ok "${pkg} — уже установлен"
        else
            to_install+=("$pkg")
            print_warn "${pkg} — требует установки"
        fi
    done

    if [[ ${#to_install[@]} -eq 0 ]]; then
        print_ok "Все пакеты уже установлены"
        return 0
    fi

    if ! confirm "Установить пакеты: ${to_install[*]}?"; then
        print_fail "Отменено пользователем"
        exit 1
    fi

    export DEBIAN_FRONTEND=noninteractive

    run_silent "Обновление списка пакетов" apt-get update -qq

    for pkg in "${to_install[@]}"; do
        run_silent "Установка ${pkg}" apt-get install -y -qq "$pkg"
    done

    print_ok "Все пакеты установлены"
}

# ============================================================================
# Task 5: Конфигурация SSH
# ============================================================================

set_sshd_option() {
    local key="$1"
    local value="$2"
    local file="$3"

    if grep -qE "^\s*#?\s*${key}\b" "$file"; then
        sed -i "s|^\s*#\?\s*${key}\b.*|${key} ${value}|" "$file"
    else
        echo "${key} ${value}" >> "$file"
    fi
}

configure_ssh() {
    print_section "Настройка SSH-сервера"

    local sshd_config="/etc/ssh/sshd_config"
    local tmp_config
    tmp_config=$(mktemp /tmp/sshd_config.XXXXXX)
    TEMP_FILES+=("$tmp_config")

    make_backup "$sshd_config"
    cp "$sshd_config" "$tmp_config"

    # Применение настроек
    set_sshd_option "Port"                   "$SSH_PORT"  "$tmp_config"
    set_sshd_option "PasswordAuthentication"  "no"         "$tmp_config"
    set_sshd_option "PermitRootLogin"         "yes"        "$tmp_config"
    set_sshd_option "PermitEmptyPasswords"    "no"         "$tmp_config"
    set_sshd_option "MaxAuthTries"            "3"          "$tmp_config"
    set_sshd_option "ClientAliveInterval"     "300"        "$tmp_config"
    set_sshd_option "ClientAliveCountMax"     "2"          "$tmp_config"
    set_sshd_option "Protocol"                "2"          "$tmp_config"

    echo ""
    echo -e "  ${BOLD}Изменения в sshd_config:${NC}"
    echo ""
    while IFS= read -r line; do
        if [[ "$line" =~ ^[-] ]]; then
            echo -e "    ${RED}${line}${NC}"
        elif [[ "$line" =~ ^[+] ]]; then
            echo -e "    ${GREEN}${line}${NC}"
        elif [[ "$line" =~ ^@@ ]]; then
            echo -e "    ${CYAN}${line}${NC}"
        fi
    done < <(diff -u "$sshd_config" "$tmp_config" 2>/dev/null | tail -n +3 || true)
    echo ""

    if ! confirm "Применить изменения SSH?"; then
        rm -f "$tmp_config"
        print_fail "Настройка SSH отменена"
        exit 1
    fi

    cp "$tmp_config" "$sshd_config"
    rm -f "$tmp_config"

    mkdir -p /run/sshd 2>/dev/null || true

    # Валидация конфига на месте
    local sshd_errors
    sshd_errors=$(sshd -t 2>&1) || true
    if sshd -t 2>/dev/null; then
        print_ok "Проверка синтаксиса: sshd -t — OK"
    else
        print_fail "Ошибка валидации sshd_config — откат"
        print_info "$sshd_errors"
        cp "${sshd_config}.bak.${BACKUP_SUFFIX}" "$sshd_config"
        return 1
    fi

    print_ok "Port ${SSH_PORT}"
    print_ok "PasswordAuthentication no"
    print_ok "PermitRootLogin yes"
    print_ok "PermitEmptyPasswords no"
    print_ok "MaxAuthTries 3"
    print_ok "ClientAliveInterval 300"
    print_ok "ClientAliveCountMax 2"
    print_ok "Protocol 2"

    print_info "SSH-сервер НЕ перезапущен (ожидание настройки knockd и iptables)"
}

# ============================================================================
# Task 6: Конфигурация knockd
# ============================================================================

configure_knockd() {
    print_section "Настройка port knocking (knockd)"

    local knockd_conf="/etc/knockd.conf"
    local knockd_default="/etc/default/knockd"

    make_backup "$knockd_conf"
    make_backup "$knockd_default"

    # Определение сетевого интерфейса
    DETECTED_IFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
    if [[ -z "$DETECTED_IFACE" ]]; then
        print_fail "Не удалось определить сетевой интерфейс"
        exit 1
    fi
    print_ok "Сетевой интерфейс: ${DETECTED_IFACE}"

    echo ""
    echo -e "  ${BOLD}Конфигурация knockd:${NC}"
    echo -e "    Последовательность: ${GREEN}${KNOCK_PORT1}${NC}, ${GREEN}${KNOCK_PORT2}${NC}, ${GREEN}${KNOCK_PORT3}${NC}"
    echo -e "    Таймаут:           10 сек"
    echo -e "    Интерфейс:         ${DETECTED_IFACE}"
    echo -e "    SSH-порт:          ${SSH_PORT}"
    echo ""

    if ! confirm "Применить конфигурацию knockd?"; then
        # Откат резервных копий
        if [[ -f "${knockd_conf}.bak.${BACKUP_SUFFIX}" ]]; then
            cp "${knockd_conf}.bak.${BACKUP_SUFFIX}" "$knockd_conf"
        fi
        if [[ -f "${knockd_default}.bak.${BACKUP_SUFFIX}" ]]; then
            cp "${knockd_default}.bak.${BACKUP_SUFFIX}" "$knockd_default"
        fi
        print_fail "Настройка knockd отменена"
        exit 1
    fi

    # Запись /etc/knockd.conf
    cat > "$knockd_conf" <<KNOCKEOF
[options]
    UseSyslog

[openSSH]
    sequence      = ${KNOCK_PORT1},${KNOCK_PORT2},${KNOCK_PORT3}
    seq_timeout   = 10
    tcpflags      = syn
    command       = /sbin/iptables -I INPUT -s %IP% -p tcp --dport ${SSH_PORT} -j ACCEPT
    cmd_timeout   = 10
    stop_command  = /sbin/iptables -D INPUT -s %IP% -p tcp --dport ${SSH_PORT} -j ACCEPT
KNOCKEOF

    # Настройка /etc/default/knockd
    if [[ -f "$knockd_default" ]]; then
        sed -i 's|^#\?START_KNOCKD=.*|START_KNOCKD=1|' "$knockd_default"
        if grep -q "^KNOCKD_OPTS=" "$knockd_default"; then
            sed -i "s|^KNOCKD_OPTS=.*|KNOCKD_OPTS=\"-i ${DETECTED_IFACE}\"|" "$knockd_default"
        elif grep -q "^#\?KNOCKD_OPTS=" "$knockd_default"; then
            sed -i "s|^#\?KNOCKD_OPTS=.*|KNOCKD_OPTS=\"-i ${DETECTED_IFACE}\"|" "$knockd_default"
        else
            echo "KNOCKD_OPTS=\"-i ${DETECTED_IFACE}\"" >> "$knockd_default"
        fi
    else
        cat > "$knockd_default" <<DEFEOF
START_KNOCKD=1
KNOCKD_OPTS="-i ${DETECTED_IFACE}"
DEFEOF
    fi

    print_ok "knockd.conf записан"
    print_ok "knockd включён (START_KNOCKD=1)"
    print_ok "Интерфейс: ${DETECTED_IFACE}"

    local knockd_output
    knockd_output=$(timeout 3 knockd -c "$knockd_conf" -D 2>&1 || true)
    if echo "$knockd_output" | grep -q "sequence:"; then
        print_ok "Валидация knockd.conf — OK"
    else
        print_fail "Ошибка валидации knockd.conf"
        print_info "$knockd_output"
        if [[ -f "${knockd_conf}.bak.${BACKUP_SUFFIX}" ]]; then
            cp "${knockd_conf}.bak.${BACKUP_SUFFIX}" "$knockd_conf"
        fi
        exit 1
    fi
}

# ============================================================================
# Task 7: Правила iptables
# ============================================================================

configure_iptables() {
    print_section "Настройка iptables"

    # Резервная копия текущих правил
    local iptables_backup="/root/iptables.bak.${BACKUP_SUFFIX}"
    iptables-save > "$iptables_backup" 2>/dev/null || true
    BACKUPS_MADE+=("$iptables_backup")
    print_info "Резервная копия iptables: ${iptables_backup}"

    # Генерация правил
    local rules_file
    rules_file=$(mktemp /tmp/iptables_rules.XXXXXX)
    TEMP_FILES+=("$rules_file")

    cat > "$rules_file" <<IPTEOF
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT ACCEPT [0:0]

# Loopback
-A INPUT -i lo -j ACCEPT
-A OUTPUT -o lo -j ACCEPT

# Установленные и связанные соединения
-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Невалидные пакеты
-A INPUT -m conntrack --ctstate INVALID -j DROP

# Защита от сканирования портов — NULL-пакеты
-A INPUT -p tcp --tcp-flags ALL NONE -j DROP

# Защита от сканирования — XMAS
-A INPUT -p tcp --tcp-flags ALL ALL -j DROP

# Защита от сканирования — FIN/URG/PSH
-A INPUT -p tcp --tcp-flags ALL FIN,URG,PSH -j DROP

# Защита от SYN flood (глобальный лимит новых соединений)
-A INPUT -p tcp --syn -m limit --limit 25/s --limit-burst 50 -j ACCEPT
-A INPUT -p tcp --syn -j DROP

# Блокировка ICMP echo-request (ping)
-A INPUT -p icmp --icmp-type echo-request -j DROP

# Knock-порты с ограничением частоты (anti-scanner)
-A INPUT -p tcp -m multiport --dports ${KNOCK_PORT1},${KNOCK_PORT2},${KNOCK_PORT3} -m recent --name knock --update --seconds 60 --hitcount 10 -j DROP
-A INPUT -p tcp -m multiport --dports ${KNOCK_PORT1},${KNOCK_PORT2},${KNOCK_PORT3} -m recent --name knock --set -j ACCEPT

# Логирование отброшенных пакетов
-A INPUT -m limit --limit 3/min -j LOG --log-prefix "iptables-drop: " --log-level 4

COMMIT
IPTEOF

    echo ""
    echo -e "  ${BOLD}Правила iptables:${NC}"
    echo ""
    sed 's/^/    /' "$rules_file"
    echo ""

    if ! confirm "Применить правила iptables?"; then
        rm -f "$rules_file"
        print_fail "Настройка iptables отменена"
        exit 1
    fi

    # Атомарное применение
    if ! iptables-restore < "$rules_file"; then
        print_fail "Ошибка применения iptables — откат"
        if [[ -f "$iptables_backup" ]]; then
            iptables-restore < "$iptables_backup" || true
        fi
        rm -f "$rules_file"
        return 1
    fi

    rm -f "$rules_file"
    print_ok "Правила iptables применены атомарно"

    # Сохранение для переживания перезагрузки
    if command -v netfilter-persistent &>/dev/null; then
        run_silent "Сохранение правил (netfilter-persistent)" netfilter-persistent save
    else
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || \
            iptables-save > /etc/iptables.rules 2>/dev/null || true
        print_ok "Правила сохранены"
    fi
}

# ============================================================================
# Task 8: Ужесточение sysctl
# ============================================================================

configure_sysctl() {
    print_section "Ужесточение параметров ядра (sysctl)"

    local sysctl_file="/etc/sysctl.d/99-hardening.conf"

    make_backup "$sysctl_file"

    local sysctl_content
    read -r -d '' sysctl_content <<'SYSEOF' || true
# Защита от SYN flood
net.ipv4.tcp_syncookies = 1

# Не принимать ICMP-перенаправления
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0

# Не отправлять ICMP-перенаправления
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Проверка обратного пути (anti-spoofing)
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Игнорировать широковещательные ICMP
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Логировать марсианские пакеты
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# Не принимать source route
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
SYSEOF

    echo ""
    echo -e "  ${BOLD}Параметры sysctl:${NC}"
    echo ""
    echo "$sysctl_content" | sed 's/^/    /'
    echo ""

    if ! confirm "Применить параметры sysctl?"; then
        if [[ -f "${sysctl_file}.bak.${BACKUP_SUFFIX}" ]]; then
            cp "${sysctl_file}.bak.${BACKUP_SUFFIX}" "$sysctl_file"
        fi
        print_fail "Настройка sysctl отменена"
        exit 1
    fi

    echo "$sysctl_content" > "$sysctl_file"
    print_ok "Файл ${sysctl_file} записан"

    if sysctl -p "$sysctl_file" > /dev/null 2>&1; then
        print_ok "Параметры sysctl применены"
    else
        print_fail "Ошибка применения sysctl — откат"
        if [[ -f "${sysctl_file}.bak.${BACKUP_SUFFIX}" ]]; then
            cp "${sysctl_file}.bak.${BACKUP_SUFFIX}" "$sysctl_file"
            sysctl -p "$sysctl_file" > /dev/null 2>&1 || true
        else
            rm -f "$sysctl_file"
        fi
        return 1
    fi
}

# ============================================================================
# Task 9: Перезапуск сервисов и итоговая сводка
# ============================================================================

restart_and_summary() {
    print_section "Перезапуск сервисов"

    if ! confirm "Перезапустить knockd и sshd?"; then
        print_warn "Сервисы НЕ перезапущены. Перезапустите вручную:"
        print_info "  systemctl restart knockd && systemctl restart sshd"
        return 0
    fi

    # Порядок: knockd → sshd
    run_silent "Перезапуск knockd" systemctl restart knockd
    run_silent "Включение knockd в автозагрузку" systemctl enable knockd
    run_silent "Перезапуск sshd" systemctl restart sshd

    # Проверка прослушивания SSH на новом порту
    sleep 1
    if ss -tlnp | grep -qE ":${SSH_PORT}\b"; then
        print_ok "SSH слушает на порту ${SSH_PORT}"
    else
        print_warn "SSH может не слушать на порту ${SSH_PORT} — проверьте вручную"
    fi

    # Определение IP сервера
    SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    if [[ -z "$SERVER_IP" ]]; then
        SERVER_IP="<IP_СЕРВЕРА>"
    fi

    local real_user="${SUDO_USER:-root}"

    # Итоговая сводка
    echo ""
    echo ""
    local summary_lines=(
        "  SSH-порт:          ${SSH_PORT}"
        "  Knock-порты:       ${KNOCK_PORT1} → ${KNOCK_PORT2} → ${KNOCK_PORT3}"
        "  Таймаут knock:     10 сек"
        ""
        "  Команда подключения:"
        "  knock ${SERVER_IP} ${KNOCK_PORT1} ${KNOCK_PORT2} ${KNOCK_PORT3} && ssh -p ${SSH_PORT} ${real_user}@${SERVER_IP}"
    )

    local max_len=0
    for line in "${summary_lines[@]}"; do
        local stripped
        stripped=$(echo -e "$line" | sed 's/\x1b\[[0-9;]*m//g')
        local len=${#stripped}
        (( len > max_len )) && max_len=$len
    done
    max_len=$((max_len + 4))

    local border=""
    for ((i = 0; i < max_len; i++)); do border+="═"; done

    echo -e "${GREEN}╔${border}╗${NC}"
    echo -e "${GREEN}║${NC}  ${BOLD}НАСТРОЙКА ЗАВЕРШЕНА${NC}$(printf '%*s' $((max_len - 21)) '')${GREEN}║${NC}"
    echo -e "${GREEN}╠${border}╣${NC}"

    for line in "${summary_lines[@]}"; do
        local stripped
        stripped=$(echo -e "$line" | sed 's/\x1b\[[0-9;]*m//g')
        local pad=$((max_len - ${#stripped} - 2))
        echo -e "${GREEN}║${NC} ${line}$(printf '%*s' $pad '')${GREEN}║${NC}"
    done

    echo -e "${GREEN}╠${border}╣${NC}"
    echo -e "${GREEN}║${NC}  ${BOLD}Резервные копии:${NC}$(printf '%*s' $((max_len - 18)) '')${GREEN}║${NC}"

    for bk in "${BACKUPS_MADE[@]}"; do
        local pad=$((max_len - ${#bk} - 4))
        (( pad < 0 )) && pad=0
        echo -e "${GREEN}║${NC}   ${DIM}${bk}${NC}$(printf '%*s' $pad '')${GREEN}║${NC}"
    done

    echo -e "${GREEN}╚${border}╝${NC}"

    echo ""
    echo -e "  ${RED}${BOLD}⚠  ВНИМАНИЕ: НЕ закрывайте текущую SSH-сессию!${NC}"
    echo -e "  ${RED}${BOLD}   Сначала проверьте подключение в новом окне.${NC}"
    echo ""
}

# ============================================================================
# Task 10: Точка входа
# ============================================================================

main() {
    print_header "SECURE SSH — Автонастройка защиты сервера"
    preflight_checks
    generate_parameters
    install_packages
    configure_ssh
    configure_knockd
    configure_iptables
    configure_sysctl
    restart_and_summary
}

main "$@"
