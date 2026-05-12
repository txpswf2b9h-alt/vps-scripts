#!/bin/bash

# --- [ ИНФОРМАЦИОННЫЕ ФУНКЦИИ ] ---
info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
success() { echo -e "\033[0;32m[SUCCESS]\033[0m $1"; }
error() { echo -e "\033[0;31m[ERROR]\033[0m $1"; exit 1; }

# --- [ ПРОВЕРКА ПРАВ ] ---
if [[ $EUID -ne 0 ]]; then
   echo "Этот скрипт должен быть запущен с правами root (sudo)."
   exit 1
fi

# --- [ НАЧАЛО СКРИПТА ] ---
info "Запуск базовой настройки сервера..."

# 1. Установка пакета nano
info "1/7. Установка текстового редактора nano..."
apt-get install -y nano
success "nano установлен."

# 2. Смена порта SSH с 22 на 2244
info "2/7. Изменение порта SSH с 22 на 2244..."
sed -i 's/^#?Port 22/Port 2244/' /etc/ssh/sshd_config

# 3. Перезапуск службы SSH
info "3/7. Перезапуск службы SSH..."
systemctl restart ssh

# 4. Создание нового пользователя и запрос пароля
info "4/7. Создание пользователя virtusadm..."
read -p "Введите пароль для нового пользователя virtusadm: " -s PASS_VIRTUSADM && echo ""
useradd -m virtusadm

# 5. Установка пароля для нового пользователя
echo "virtusadm:$PASS_VIRTUSADM" | chpasswd

# 6. Добавление пользователя в группу sudo (администраторы)
info "5/7. Добавление пользователя в группу sudo..."
usermod -aG sudo virtusadm

# 7. Запрет входа по SSH под пользователем root
info "6/7. Запрет входа под пользователем root..."
sed -i 's/^#?PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config

# Финальный перезапуск SSHD (на случай, если конфиг изменился)
info "7/7. Финальный перезапуск службы SSHD..."
systemctl restart sshd

success "✅ Базовая настройка завершена успешно!"
echo ""
echo "ВАЖНО:"
echo "- Новый пользователь: virtusadm"
echo "- Новый порт SSH: 2244"
echo "- Вход под root запрещен."
