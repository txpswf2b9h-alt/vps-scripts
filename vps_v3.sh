#!/bin/bash

# Скрипт начальной настройки сервера Ubuntu
# Запускать с правами sudo: sudo ./setup_server.sh

set -e  # Остановить скрипт при ошибке

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Функция вывода статуса
print_status() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

print_info() {
    echo -e "${BLUE}[i]${NC} $1"
}

print_header() {
    echo
    echo -e "${YELLOW}>>> $1${NC}"
}

# Проверка прав суперпользователя
if [[ $EUID -ne 0 ]]; then
    print_error "Этот скрипт должен запускаться с sudo!"
    echo "Используйте: sudo $0"
    exit 1
fi

print_header "НАЧАЛО НАСТРОЙКИ СЕРВЕРА"
echo

# 1. Установка пакета nano
print_header "1. Установка текстового редактора nano"
apt update
apt install -y nano
print_status "nano установлен"

# 2. Смена порта SSH с 22 на 2244
print_header "2. Изменение порта SSH с 22 на 2244"
SSH_CONFIG="/etc/ssh/sshd_config"

# Резервное копирование конфига SSH
cp $SSH_CONFIG ${SSH_CONFIG}.backup.$(date +%Y%m%d_%H%M%S)
print_status "Создана резервная копия конфигурации SSH"

# Меняем порт (раскомментируем или добавляем строку)
sed -i 's/^#Port 22/Port 2244/' $SSH_CONFIG
sed -i 's/^Port 22/Port 2244/' $SSH_CONFIG

# Если строка Port отсутствует, добавляем её
if ! grep -q "^Port" $SSH_CONFIG; then
    echo "Port 2244" >> $SSH_CONFIG
fi

print_status "Порт SSH изменён на 2244"

# 3. Перезапуск службы SSH
print_header "3. Перезапуск службы SSH"
systemctl restart ssh
print_status "Служба SSH перезапущена"

# 4. Создание нового пользователя virtusradm и запрос пароля
print_header "4. Создание пользователя virtusradm"

# Проверяем, существует ли уже пользователь
if id "virtusradm" &>/dev/null; then
    print_info "Пользователь virtusradm уже существует"
else
    # Создаём пользователя с домашней директорией
    useradd -m -s /bin/bash virtusradm
    
    # Запрашиваем пароль
    echo -e "${YELLOW}Введите пароль для пользователя virtusradm:${NC}"
    passwd virtusradm
    
    print_status "Пользователь virtusradm создан"
fi

# 5. Добавление пользователя в группу администраторов (sudo)
print_header "5. Добавление virtusradm в группу sudo"
usermod -aG sudo virtusradm
print_status "Пользователь virtusradm добавлен в группу sudo"

# 6. Запрет входа под root по SSH
print_header "6. Запрет входа под пользователем root по SSH"

# Отключаем PermitRootLogin
sed -i 's/^PermitRootLogin yes/PermitRootLogin no/' $SSH_CONFIG
sed -i 's/^PermitRootLogin prohibit-password/PermitRootLogin no/' $SSH_CONFIG

# Если параметра нет, добавляем
if ! grep -q "^PermitRootLogin" $SSH_CONFIG; then
    echo "PermitRootLogin no" >> $SSH_CONFIG
fi

print_status "Вход под root по SSH запрещён"

# 7. Перезапуск SSHD
print_header "7. Финальный перезапуск SSH сервера"
systemctl restart sshd
print_status "SSH сервер перезапущен"

# Итоговая информация
print_header "НАСТРОЙКА ЗАВЕРШЕНА"
echo
echo -e "${GREEN}✅ Скрипт успешно выполнил все задачи:${NC}"
echo "   1. Установлен nano"
echo "   2. Порт SSH изменён с 22 на 2244"
echo "   3. Создан пользователь virtusradm"
echo "   4. Пользователь добавлен в группу sudo"
echo "   5. Root доступ по SSH запрещён"
echo
echo -e "${YELLOW}⚠️  ВАЖНО:${NC}"
echo "   - Теперь SSH доступен на порту ${GREEN}2244${NC}"
echo "   - Входиться под root больше нельзя"
echo "   - Используйте: ssh virtusradm@<IP-адрес> -p 2244"
echo
echo -e "${BLUE}Резервная копия SSH конфига:${NC}"
ls -la ${SSH_CONFIG}.backup.* 2>/dev/null || echo "   (не создана)"
echo

# Проверка открытых портов
print_info "Проверка: слушает ли SSH новый порт"
if ss -tlnp | grep -q ":2244"; then
    print_status "Порт 2244 успешно слушается"
else
    print_error "Порт 2244 не обнаружен! Проверьте конфигурацию"
fi
