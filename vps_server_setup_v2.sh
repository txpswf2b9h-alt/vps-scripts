#!/bin/bash

# --- [ НАСТРОЙКИ ПО УМОЛЧАНИЮ ] ---
DEFAULT_SSH_PORT="2244"
DEFAULT_TELEMT_PORT="4433"
DEFAULT_TELEMT_DOMAIN="duckduckgo.com" # Исправлено: используем выбранный домен, а не перезаписываем его
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

    # 2.3 UFW и Fail2Ban (Рекомендации)
    if ask "Установить и настроить UFW и Fail2Ban (рекомендуется)?