#!/bin/bash

# --- [ НАСТРОЙКИ ПО УМОЛЧАНИЮ ] ---
DEFAULT_SSH_PORT="2244"
DEFAULT_TELEMT_PORT="4433"
DEFAULT_TELEMT_DOMAIN="duckduckgo.com"
TELEMT_IMAGE="whn0thacked/telemt-docker:latest"

# --- [ ФУНКЦИИ ] ---

info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
success() { echo -e "\033[0;32m[SUCCESS]\033[0m $1"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }
error() { echo -e "\033[0;31m[ERROR]\033[0m $1"; }
ask() { read -p "$1 [y/N]: " -n 1 -r; echo; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "Этот скрипт должен быть запущен с правами root (sudo)."
        exit 1
    fi
}

is_port_free() {
    local port=$1
    if ss -lntu "sport = :$port" >/dev/null 2>&1 || lsof -i :$port >/dev/null 2>&1; then
        return 1 # Занят
    else
        return 0 # Свободен
    fi
}

# --- [ БЛОК 1: ОБНОВЛЕНИЕ СИСТЕМЫ ] ---
update_system() {
    info "Обновление списка пакетов..."
    apt-get update

    if ask "Найдены обновления. Установить их сейчас?"; then
        apt-get upgrade -y
        success "Система обновлена."
    else
        warn "Обновление системы пропущено по вашему выбору."
    fi
}

# --- [ БЛОК 2: БАЗОВАЯ БЕЗОПАСНОСТЬ ] ---
security_hardening() {
    # 2.1 Смена порта SSH
    if ask "Изменить порт SSH с 22 на $DEFAULT_SSH_PORT?"; then
        if is_port_free "$DEFAULT_SSH_PORT"; then
            sed -i 's/^#?Port 22/Port '"$DEFAULT_SSH_PORT"'/' /etc/ssh/sshd_config || { error "Ошибка правки SSH конфига"; exit 1; }
            systemctl restart ssh || { error "Ошибка перезапуска SSH"; exit 1; }
            success "Порт SSH изменен на $DEFAULT_SSH_PORT."
        else
            error "Порт $DEFAULT_SSH_PORT занят. Выберите другой или остановите службу."
        fi
    fi

    # 2.2 Пользователь и Root (пропускаем, если уже есть)
    if ! id -u virtusadm >/dev/null 2>&1; then
        read -p "Введите пароль для нового пользователя virtusadm: " -s PASS_VIRTUSADM && echo ""
        useradd -m virtusadm -p "$(openssl passwd -1 "$PASS_VIRTUSADM")"
        usermod -aG sudo virtusadm
        success "Пользователь virtusadm создан и добавлен в sudo."
    else
        warn "Пользователь virtusadm уже существует. Пропускаем создание."
    fi

    # Запрет Root (если еще не запрещен)
    if grep -q "PermitRootLogin yes" /etc/ssh/sshd_config; then
        sed -i 's/^#?PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config
        systemctl restart ssh
        success "Вход под root запрещен."
    fi

    # 2.3 UFW (Рекомендации)
    if ask "Установить и настроить UFW (рекомендуется)?"; then
        apt-get install -y ufw

        # Настройка UFW (Строгий режим)
        ufw default deny incoming
        ufw default deny outgoing

        # Разрешаем базовые вещи для работы сервера и обновлений
        ufw allow out http/tcp || true
        ufw allow out https/tcp

        # Разрешаем наш SSH порт (временно, до установки)
        ufw allow "$DEFAULT_SSH_PORT"/tcp comment 'SSH'
        
        ufw --force enable

        success "UFW установлен и включен. Политика: DENY IN/OUT."
    fi

    # 2.4 Тюнинг ядра (Рекомендации)
    if ask "Применить настройки ядра для оптимизации и безопасности (vm.swappiness, лимиты файлов)?"; then
        echo "vm.swappiness=10" >> /etc/sysctl.conf
        echo "fs.file-max = 1000000" >> /etc/sysctl.conf
        sysctl -p
        success "Настройки ядра применены."
    fi

    # 2.5 Отключение IPv6 (Рекомендации)
    if ask "Отключить IPv6?"; then
        cat >> /etc/sysctl.conf <<EOL
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOL
        sysctl -p
        success "IPv6 отключен."
    fi

}

# --- [ БЛОК 3: TELEMT (MTProxy) ] ---
install_telemt() {
    local PORT=$DEFAULT_TELEMT_PORT

    # Проверка занятости порта Telemt
    while true; do
        read -p "Введите порт для Telemt (по умолчанию $DEFAULT_TELEMT_PORT): " input_port
        PORT=${input_port:-$DEFAULT_TELEMT_PORT}
        
        if is_port_free "$PORT"; then
            break
        else
            error "Порт $PORT занят. Пожалуйста, выберите другой."
        fi
    done

    info "Установка зависимостей для Telemt..."
    apt-get install -y docker.io docker-compose-plugin openssl lsof curl nano

    info "Генерация конфигурационных файлов Telemt..."
    mkdir -p telemt-data telemt-logs

    MAIN_SECRET=$(openssl rand -hex 16)
    
    cat > telemt.toml <<EOF
show_link = ["docker"]
[general]
fast_mode = true
use_middle_proxy = false

[general.modes]
classic = false
secure = false
tls = true

[server]
port = $PORT
listen_addr_ipv4 = "0.0.0.0"
metrics_port = 9091

[[server.listeners]]
ip = "0.0.0.0"
[censorship]
tls_domain = "$DEFAULT_TELEMT_DOMAIN"
EOF

    cat > docker-compose.yml <<EOF
services:
  telemt:
    image: $TELEMT_IMAGE
    container_name: telemt-proxy
    restart: unless-stopped
    volumes:
      - ./telemt.toml:/etc/telemt.toml:ro
      - ./telemt-data:/data   # Сохраняем данные пользователей здесь!
      - ./telemt-logs:/logs   # Сохраняем логи здесь!
    ports:
      - "${PORT}:${PORT}/tcp"
      - "127.0.0.1:9091:9091/tcp" # Метрики доступны только локально для безопасности!
    network_mode: host 
    cap_drop:
      - ALL 
    cap_add:
      - NET_BIND_SERVICE 
    read_only: true 
    security_opt:
      - no-new-privileges:true 
    ulimits:
       nofile:
         soft: 65536 
         hard: 65536 
logging:
       driver: json-file 
       options:
         max-size: '5m'
         max-file: '5'
EOF

    success "Конфигурация Telemt создана в папке $(pwd)."
    info "Секрет доступа к прокси (Secret): $MAIN_SECRET"
    
    # Открываем порт в UFW, если он установлен и включен.
    if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
       ufw allow "$PORT"/tcp comment 'Telemt Proxy'
       success "Порт $PORT открыт в фаерволе UFW."
    fi

    info "Запуск контейнера Telemt..."
    docker compose up -d --build --remove-orphans

    success "🎉 Telemt установлен и запущен!"
}


# --- [ ГЛАВНОЕ МЕНЮ ] ---
main_menu() {
    clear
    echo "+-------------------------------------------+"
    echo "|     🐧 Автоматизация настройки VPS         |"
    echo "+-------------------------------------------+"
    
    check_root

    while true; do

        echo ""
        echo "[БЛОК 1] СИСТЕМА (Обновление)"
        echo "[БЛОК 2] БЕЗОПАСНОСТЬ (UFW, SSH, Ядро)"
        echo "[БЛОК 3] TELEMT (Прокси)"
        echo ""
        
        read -p "Выберите блок для настройки (1-3) или Q для выхода: " choice

        case $choice in

            1) update_system ;;
            2) security_hardening ;;
            3) install_telemt ;;
            q|Q) exit 0 ;;
            *) error "Неверный выбор. Введите цифру от 1 до 3 или Q." ;;
         esac

         read -n1 -r -p "Нажмите любую клавишу для возврата в меню..." key
         clear

     done

}
main_menu "$@"