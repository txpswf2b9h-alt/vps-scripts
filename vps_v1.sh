#!/bin/bash

# --- [ ФУНКЦИИ ] ---
info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
success() { echo -e "\033[0;32m[SUCCESS]\033[0m $1"; }
error() { echo -e "\033[0;31m[ERROR]\033[0m $1"; exit 1; }
ask() { read -p "$1 [y/N]: " -n 1 -r; echo; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "Этот скрипт должен быть запущен с правами root (sudo)."
    fi
}

# --- [ БЛОК 1: СИСТЕМА И ОБНОВЛЕНИЯ ] ---
system_update() {
    info "=== БЛОК 1: СИСТЕМА И ОБНОВЛЕНИЯ ==="
    info "Запуск проверки списка доступных обновлений..."
    apt-get update

    if ask "Найдены обновления. Установить их сейчас?"; then
        info "Установка обновлений..."
        apt-get upgrade -y
        success "Система успешно обновлена."
    else
        warn "Обновление системы пропущено по вашему выбору."
    fi
}

# --- [ БЛОК 2: БАЗОВАЯ БЕЗОПАСНОСТЬ ] ---
security_hardening() {
    info ""
    info "=== БЛОК 2: БАЗОВАЯ БЕЗОПАСНОСТЬ ==="

    # 2.1 Меняем порт SSH с 22 на 2244
    if ask "Изменить порт SSH с 22 на 2244?"; then
        # Проверяем, свободен ли порт, ДО внесения изменений
        if ss -lntu "sport = :2244" >/dev/null 2>&1 || lsof -i :2244 >/dev/null 2>&1; then
            error "Порт 2244 занят другой программой. Изменение порта SSH отменено."
        else
            info "Порт 2244 свободен. Вносим изменения в конфигурацию SSH..."
            sed -i 's/^#?Port 22/Port 2244/' /etc/ssh/sshd_config || error "Ошибка правки конфига SSH."
            systemctl restart ssh || error "Ошибка перезапуска службы SSH."
            success "Порт SSH успешно изменен на 2244."
        fi
    fi

    # 2.2 Устанавливаем nano (если нет)
    if ! command -v nano > /dev/null 2>&1; then
        info "Установка текстового редактора nano..."
        apt-get install -y nano
        success "nano установлен."
    else
        info "nano уже установлен."
    fi

    # 2.3 Устанавливаем и настраиваем UFW (если нет)
    if ! command -v ufw > /dev/null 2>&1; then
        info "Установка фаервола UFW..."
        apt-get install -y ufw

        info "Настройка правил UFW (строгий режим)..."
        ufw default deny incoming
        ufw default deny outgoing

        info "Разрешаем соединения для SSH и обновлений..."
        ufw allow 2244/tcp comment 'SSH'
        ufw allow out http/tcp comment 'HTTP'
        ufw allow out https/tcp comment 'HTTPS'

        ufw --force enable
        success "UFW установлен и включен."
    else
        info "UFW уже установлен. Проверяем статус..."
        if ! ufw status | grep -q "Status: active"; then
            info "Включаем UFW..."
            ufw --force enable
            success "UFW включен."
        else
            info "UFW уже активен."
            # Проверяем, есть ли правило для нашего SSH порта
            if ! ufw status | grep -q "2244/tcp"; then
                info "Добавляем правило для порта SSH (2244)..."
                ufw allow 2244/tcp comment 'SSH'
                success "Правило для SSH добавлено."
            fi
        fi
    fi

    # 2.4 Снова проверяем актуальность пакетов после установки нового ПО (nano, ufw)
    info ""
    info "[ПОВТОРНАЯ ПРОВЕРКА] Проверка актуальности пакетов после установки нового ПО..."
    apt-get update && apt-get upgrade -y
    success "[ПОВТОРНАЯ ПРОВЕРКА] Финальное обновление системы завершено."
}


# --- [ ГЛАВНОЕ МЕНЮ ] ---
main_menu() {
    clear
    echo "+-------------------------------------------+"
    echo "|     🛡️ НАЧАЛЬНАЯ НАСТРОЙКА VPS             |"
    echo "+-------------------------------------------+"
    
    check_root

    while true; do

        echo ""
        echo "[БЛОК 1] СИСТЕМА И ОБНОВЛЕНИЯ"
        echo "[БЛОК 2] БАЗОВАЯ БЕЗОПАСНОСТЬ"
        echo ""
        
        read -p "Выберите блок для настройки (1-2) или Q для выхода: " choice

        case $choice in
            1) system_update ;;
            2) security_hardening ;;
            q|Q) exit 0 ;;
            *) error "🚫 Неверный выбор. Введите цифру от 1 до 2 или Q." ;;
         esac

         read -n1 -r -p "👉 Нажмите любую клавишу для возврата в меню..." key
         clear

     done

}
main_menu "$@"
