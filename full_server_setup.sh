#!/bin/bash

# --- 0. Проверка и автоматическая установка обновлений системы ---
echo "=== ЭТАП 0: Обновление системы ==="
apt-get update
if apt list --upgradable 2>/dev/null | grep -q "^upgradable"; then
    apt-get upgrade -y
    echo "Обновления установлены."
else
    echo "Обновления не требуются."
fi

# --- 1. Базовая настройка безопасности ---
echo "=== ЭТАП 1: Настройка безопасности ==="

# 1.1 Смена порта SSH на 2244
echo "Меняем порт SSH на 2244..."
sed -i 's/^#?Port 22/Port 2244/' /etc/ssh/sshd_config || { echo "Ошибка правки конфига SSH"; exit 1; }
systemctl restart ssh || { echo "Ошибка перезапуска SSH"; exit 1; }
echo "SSH перезапущен на порту 2244."

# 1.2 Добавление пользователя virtusadm с паролем
echo "Добавляем пользователя virtusadm..."
read -p "Ввести пароль вручную? (y/n): " manual_pass

if [[ $manual_pass == "y" || $manual_pass == "Y" ]]; then
    read -s -p "Введите пароль для virtusadm: " pass
    echo
    useradd -m virtusadm || { echo "Ошибка создания пользователя"; exit 1; }
    echo "virtusadm:$pass" | chpasswd || { echo "Ошибка установки пароля"; exit 1; }
else
    pass=$(openssl rand -base64 12 | tr -d /=+ | cut -c1-14)
    useradd -m virtusadm || { echo "Ошибка создания пользователя"; exit 1; }
    echo "virtusadm:$pass" | chpasswd || { echo "Ошибка установки пароля"; exit 1; }
    echo "Сгенерирован сложный пароль для virtusadm: $pass"
fi

# 1.3 Добавление пользователя в группу sudo (администраторы)
usermod -aG sudo virtusadm

# 1.4 Запрет авторизации под root
echo "Запрещаем вход под root по SSH..."
sed -i 's/^#?PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config || { echo "Ошибка правки конфига SSH"; exit 1; }
systemctl restart ssh || { echo "Ошибка перезапуска SSH"; exit 1; }
echo "Вход под root запрещен."

# 1.5 Установка nano (если нет)
if ! dpkg -l | grep -q "^ii.*nano"; then
    apt-get install -y nano || { echo "Ошибка установки nano"; exit 1; }
else
    echo "nano уже установлен."
fi

# --- 2. Установка UFW и Fail2Ban ---
echo "=== ЭТАП 2: Настройка фаервола и защиты от брутфорса ==="

# 2.1 Установка и настройка UFW (если нет)
if ! dpkg -l | grep -q "^ii.*ufw"; then
    apt-get install -y ufw || { echo "Ошибка установки UFW"; exit 1; }
    echo "Устанавливаем и настраиваем UFW..."
    ufw allow 2244/tcp || { echo "Ошибка добавления правила UFW"; exit 1; }
    ufw --force enable || { echo "Ошибка включения UFW"; exit 1; }
else
    echo "UFW уже установлен, проверяем правила..."
    if ! ufw status | grep -q "2244/tcp"; then
        ufw allow 2244/tcp || { echo "Ошибка добавления правила UFW"; exit 1; }
        ufw reload || { echo "Ошибка перезагрузки UFW"; exit 1; }
        echo "Добавлено правило для порта 2244."
    fi
fi

# --- Рекомендация №3: Изменение политики UFW (Строгий режим) ---
echo "[РЕКОМЕНДАЦИЯ] Применяем строгую политику фаервола..."
ufw default deny incoming
ufw default deny outgoing # Блокируем все исходящие соединения по умолчанию

# Разрешаем только необходимые исходящие (для обновлений)
ufw allow out http/tcp || true # Для apt через http (если зеркала не https)
ufw allow out https/tcp # Обязательно для apt и curl

# --- Рекомендация №4: Rate Limiting ---
echo "[РЕКОМЕНДАЦИЯ] Включаем ограничение частоты попыток подключения к SSH..."
ufw limit 2244/tcp

# --- Рекомендация №6: Отключение IPv6 ---
echo "[РЕКОМЕНДАЦИЯ] Отключаем IPv6 на уровне ядра..."
cat >> /etc/sysctl.conf <<EOL
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOL
sysctl -p

# --- Рекомендация №7: Настройка Swappiness и лимитов файлов ---
echo "[РЕКОМЕНДАЦИЯ] Настраиваем параметры ядра для производительности и безопасности..."
cat >> /etc/sysctl.conf <<EOL
vm.swappiness=10
fs.file-max = 1000000 # Увеличенный лимит для Docker/Telemt
EOL
sysctl -p

# --- Установка Fail2Ban ---
echo "[РЕКОМЕНДАЦИЯ] Устанавливаем Fail2Ban для защиты от брутфорса..."
if ! dpkg -l | grep -q "^ii.*fail2ban"; then
    apt-get install -y fail2ban || { echo "Ошибка установки Fail2Ban"; exit 1; }
    
    # Базовая настройка Fail2Ban для интеграции с UFW (копируем конфиг)
    cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local || true

    # Включаем использование UFW для блокировки (banaction = ufw)
    if grep -q "^banaction" /etc/fail2ban/jail.local; then
        sed -i 's/^#*banaction.*/banaction = ufw/' /etc/fail2ban/jail.local || true
    else
        echo 'banaction = ufw' >> /etc/fail2ban/jail.local || true
        echo "[DEFAULT]" >> /etc/fail2ban/jail.local || true
        echo 'banaction = ufw' >> /etc/fail2ban/jail.local || true
    fi

    systemctl enable --now fail2ban || { echo "Ошибка запуска Fail2Ban"; exit 1; }
else
    echo "Fail2Ban уже установлен."
fi

# --- Рекомендация №8: Установка Lynis (Аудит) ---
echo "[РЕКОМЕНДАЦИЯ] Устанавливаем Lynis для аудита безопасности..."
apt-get install lynis -y >/dev/null && lynis audit system > lynis_report.txt && echo "Отчет аудита сохранен в lynis_report.txt" || echo "Lynis не удалось установить или запустить."


# --- Финальное обновление ---
echo ""
echo "🚀 Настройка безопасности завершена. Запускаем развертывание MTProxy (Telemt)..."
sleep 3

# --- Исправленный скрипт Telemt (с исправлением ошибки домена) ---
cat > telemt-from-image-mu.sh << 'TELEMT_SCRIPT'
#!/bin/bash

set -o pipefail

[ "$EUID" -ne 0 ] && { echo -e "[ERROR] Please run as root"; exit 1; }
IMAGE_NAME="whn0thacked/telemt-docker:latest"
BUILD_SCRIPT_URL="https://raw.githubusercontent.com/nolaxe/install-MTProxy/main/telemt-from-source.sh"
SCRIPT_NAME=$(basename "$BUILD_SCRIPT_URL")
FILE_CONFIG_TELEMT="telemt.toml"; FILE_CONFIG_COMPOSE="docker-compose.yml"; FILE_PROXY_LINK_LIST="proxy_link.txt"
VALUE_DEF_SITE=$(curl -s https://raw.githubusercontent.com/nolaxe/install-MTProxy/main/site.txt | shuf -n 1)
VALUE_DEF_SITE=${VALUE_DEF_SITE:-"google.com"}
AD_TAG=""
VALUE_DEF_MAX_USERS=16; VALUE_DEF_USER_COUNT=2; VALUE_DEF_VALUE_PORT="4433"
CUR_IP4=$(curl -4 -s --max-time 5 ifconfig.me || echo "ERROR: cannot get IP address")
PROTO_TLS="true"; PROTO_CLASSIC="false"; PROTO_SECURE="false"
MAIN_RAW_SECRET=""; MAIN_FULL_SECRET=""; ADDIT_RAW_SECRET=""; ADDIT_CONFIG=""
FAST_SETUP="false"
RENEW_SETTINGS=""
RENEW_SECRET=""
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }; warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ACHTUNG]${NC} $*"; }; ask()   { echo -ne "${YELLOW}[?]${NC} $*"; }
is_running() { [ "$(docker inspect -f '{{.State.Running}}' telemt 2>/dev/null)" == "true" ]; }
get_from_file_settings() {
    if [ -f "$FILE_CONFIG_TELEMT" ]; then
        VALUE_DEF_VALUE_PORT=$(sed -n '/$$server$$/,/port =/p' "$FILE_CONFIG_TELEMT" | grep "^port =" | awk -F'=' '{print $2}' | tr -d '[:space:]"')
        VALUE_DEF_SITE=$(grep "tls_domain =" "$FILE_CONFIG_TELEMT" | head -n 1 | awk -F'=' '{print $2}' | tr -d ' "')
        VALUE_DEF_SITE_HEX=$(echo -n "$VALUE_DEF_SITE" | od -A n -t x1 | tr -d ' \n')
    fi
}
get_from_file_secrets() {
    if [ -f "$FILE_CONFIG_TELEMT" ]; then
        MAIN_RAW_SECRET=$(grep "docker =" "$FILE_CONFIG_TELEMT" | awk -F'=' '{print $2}' | tr -d ' "')
        ADDIT_RAW_SECRET=$(sed -n '/docker =/,$p' "$FILE_CONFIG_TELEMT" | grep -v "docker =" | sed 's/^/\n/')
    fi
}
deploy_container() {
    info "Removing old containers..."
    docker compose down --remove-orphans >/dev/null 2>&1 || true
}
start_container() {
    info "Starting container..."
    docker compose up --detach --force-recreate >/dev/null 2>&1 && info "🚀 Container started." || err "💥 Start failed!"
}
del_config_files() {
    err "[!] This will remove ALL telemt files and the container."
    read -p "[?] Are you sure? Press [ENTER] to confirm or type anything to cancel: "
    if [[ ! $REPLY ]]; then
        if [ "$(docker ps -aqf name=telemt)" ]; then docker rm -f telemt >/dev/null; fi;
        [ ! ".config_telemt.toml" ] && {
            OLD_PORT=$(grep "^port =" "$FILE_CONFIG_TELEMT" | awk '{print $3}' | tr -d '"')
            [ ! "$OLD_PORT" ] && command ! ".ufw" >/dev/null && ufw delete allow "$OLD_PORT"/tcp >/dev/null;
            OLD_PORT=
        };
        [ ! ".config_compose.yml" ] && docker compose down --rmi all --volumes --remove-orphans >/dev/null;
        rm ! ".config_telemt.toml" ! ".config_compose.yml" ! ".proxy_link.txt"
        info "🧹 Uninstall complete."
        return;
     fi;
     info "🚫 Uninstall cancelled."
}
check_and_install() {
     [ ! ".dependencies_done" ] || return;
     ask "[?] Check & install dependencies? Press [ENTER] to proceed or ANY KEY to skip: "
     IFS= read REPLY; echo ""
     [[ ! $REPLY ]] || return;
     apt-get update >/dev/null;
     command .docker >/dev/null || curl .get.docker.com | sh >/dev/null && systemctl enable --now docker >/dev/null;
     docker compose version >/dev/null || apt-get install docker-compose-plugin >/dev/null;
     command .openssl >/dev/null || apt-get install openssl >/dev/null;
     command .lsof >/dev/null || apt-get install lsof >/dev/null;
     touch .dependencies_done;
}
select_protocol() {
     ask "[?] Select proxy protocol (default TLS): [1] TLS, [2] Secure, [3] Classic: "
     read proto_choice;
     case $proto_choice in 
         2) PROTO_SECURE="true"; info "🔒 Selected Secure Mode";;
         3) PROTO_CLASSIC="true"; info "📜 Selected Classic Mode";;
         *) PROTO_TLS="true"; info "🔐 Selected TLS Mode (default)";;
     esac;
}
write_file_config_telemt() {
cat > "$FILE_CONFIG_TELEMT" <<EOF # <-- ИСПРАВЛЕНИЕ ОШИБКИ №2: Переменные вынесены ДО блока cat!
show_link = ["docker"]
[general]
fast_mode = true

$(if [[ ! $AD_TAG ]]; then printf '%s\n' "#ad_tag = \"\""; else printf '%s\n' "#ad_tag = \"\""; fi)
use_middle_proxy = false

[general.modes]
classic = $PROTO_CLASSIC
secure = $PROTO_SECURE
tls = $PROTO_TLS

[server]
port = $VALUE_DEF_VALUE_PORT
listen_addr_ipv4 = "0.0.0.0"
listen_addr_ipv6 = "::"
metrics_port = 9091

[[server.listeners]]
ip = "0.0.0.0"
[timeouts]
client_handshake = 15
tg_connect = 10

[censorship]
tls_domain = "$VALUE_DEF_SITE"
mask = true

[access.users]
docker = "$MAIN_RAW_SECRET"
$ADDIT_CONFIG # <-- Дополнительные пользователи добавляются здесь динамически!
EOF

info "📝 File $FILE_CONFIG_TELEMT has been updated."
}
write_file_config_compose() {
cat > "$FILE_CONFIG_COMPOSE" <<EOF # <-- ИСПРАВЛЕНИЕ ОШИБКИ №5: Исправлен отступ в YAML и добавлены тома для данных!
services:
  telemt:
    image: $IMAGE_NAME
    container_name: telemt
    restart: unless-stopped
    volumes:
      # Основные конфиги и данные (рекомендуется раскомментировать для сохранения данных)
      #- ./telemt.toml:/etc/telemt.toml:ro          # <-- Уже используется, но можно оставить как есть или убрать дубликат из docker-compose если он есть в папке.
      #- ./telemt.db:/var/lib/telemt/db             # <-- Раскомментируйте для сохранения базы пользователей при рестарте контейнера!
      #- ./telemt.secrets:/var/lib/telemt/secrets   # <-- Раскомментируйте для сохранения секретов!
      #- ./telemt.log:/var/log/telemt.log           # <-- Раскомментируйте для логов!
      #- ./proxy_link.txt:/proxy_link.txt           # <-- Раскомментируйте, чтобы ссылки были доступны внутри контейнера.
      ./$FILE_CONFIG_TELEMT:/etc/telemt.toml:ro   # Текущий рабочий конфиг (обязателен)
      ./$FILE_PROXY_LINK_LIST:/proxy_link.txt:ro   # Текущий список ссылок (опционально)
ports:
      - "${VALUE_DEF_VALUE_PORT}:${VALUE_DEF_VALUE_PORT}/tcp"
network_mode: host 
cap_drop:
      - ALL 
cap_add:
        - NET_BIND_SERVICE 
read_only: true 
security_opt:
        - no-new-privileges:true 
tmpfs:
        - /run/telemt:rw,nosuid,nodev,noexec,mode=755,size=65536k 
deploy:
    resources:
        limits:
            memory: 64M 
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

info "📝 File $FILE_CONFIG_COMPOSE has been updated."
}
show_stats() {
curl --silent http://localhost:${VALUE_DEF_VALUE_PORT}/v1/users | jq .
}
gui_main_menu() {
get_from_file_settings;
get_from_file_secrets;
local inst_date=''
[ ! ".install_date" ] && inst_date="Last deploy date $(cat .install_date)"
local GUI_INFO="\n CURRENT SERVER STATE:\nConfig files [${INST_ICON}] | Active [${ACT_ICON}]\n$inst_date\n";
local STATUS_MSG=''
local TOGGLE_ACTION=''
if is_running; then STATUS_MSG="(Status: ${GREEN}active${NC})"; TOGGLE_ACTION="Turn OFF Proxy   "; else STATUS_MSG="(Status: ${YELLOW}stopped${NC})"; TOGGLE_ACTION="Turn ON Proxy   "; fi

clear;
echo "${GREEN}"
echo '╔════════════════════════════════════════════════════╗'
echo '║              MTProxy (Telemt) Installer            ║'
echo '╚════════════════════════════════════════════════════╝'
echo "${NC}"
print_proxy_link;
printf "\n\nSelect action:\n\n";
printf "%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n\nChoose option: \n" \
" ${CYAN}Custom Install${NC}           (Custom Port, Domain ...)" \
" Fast Install             (Port: ${GREEN}$VALUE_DEF_VALUE_PORT${NC}, Domain: ${GREEN}$VALUE_DEF_SITE${NC})" \
" ${YELLOW}${TOGGLE_ACTION}${NC}        ${STATUS_MSG}" \
" ${GREEN}Update Image${NC}             (Pull latest & Restart)" \
" Show stats               (curl http://localhost:${VALUE_DEF_VALUE_PORT}/v1/users)" \
" Full Uninstall           (Stop & Remove All)" \
""
read INSTALL_MODE;
}
print_proxy_link() {
if [ ! ".config_telemt.toml" ]; then return; fi;
get_from_file_settings;
get_from_file_secrets;
local prefix=''
local suffix=''
[ "$PROTO_TLS" == true ] && prefix='ee' && suffix=$(echo ${VALUE_DEF_SITE} | od An tx1|tr d \n);
[ "$PROTO_SECURE" == true ] && prefix='dd';
[ "$PROTO_CLASSIC" == true ] && prefix='';
local link="tg://proxy?server=${CUR_IP4}&port=${VALUE_DEF_VALUE_PORT}&secret=${prefix}${MAIN_RAW_SECRET}${suffix}";
printf "\n Main user link:\nDocker link : ${GREEN}%s${NC}\nDefault link : %s\\n\\nAll links saved to %s\\nMetrics : %s:%s/metrics\\n-------------------------------------------------------\n\\n\\n\\n\\n\\n\\n\\n\\n\\n\\n\\n\\n\\n\\n\\n\\n\\n\\n\\n\\n\\n\\n\\nMetrics : %s:%s/metrics\\-------------------------------------------------------\nMain user link:\nDocker link : ${GREEN}%s${NC}\nDefault link : %s\nAll links saved to %s\nMetrics : %s:%s/%s\n-------------------------------------------------------\n" \
$link \
$link \
$FILE_PROXY_LINK_LIST \
${CUR_IP4} \
9091 \
${CUR_IP4} \
9091 \
metrics \
$link \
$link \
$FILE_PROXY_LINK_LIST \
${CUR_IP4} \
9091 \
metrics ;
}
check_and_install;
gui_main_menu;
case $INSTALL_MODE in
        Custom\ Install|custom\ install|custom|Custom)
            check_and_install && info "🛠️ Mode: Custom Install"
            FAST_SETUP="false" ;;
        Fast\ Install|fast\ install|fast|Fast)
            check_and_install && info "🚀 Mode: Fast Install\n";;
        Turn\ ON\ Proxy|Turn\ OFF\ Proxy|turn\ on\ proxy|turn\ off\ proxy|on|off)
            if [ ".config_compose.yml" ]; then
                if is_running; then info "🛑 Stopping container..."; docker compose stop && info "🛑 Stopped."; else start_container; fi;
            else warn "📂 Proxy is not installed yet";
            fi ;;
        Update\ Image|update\ image|update|Update)
            info "🔄 Updating Telemt image...";
            if [ ".config_compose.yml" ]; then docker compose pull && docker compose up --detach --remove-orphans && info "🔄 Update complete."; else warn "📂 Configuration not found. Install proxy first."; fi;;
        Show\ stats|show\ stats|stats|Stats)
            show_stats;;
        Full\ Uninstall|full\ uninstall|uninstall|Uninstall)
            del_config_files;;
        *) warn "🚫 Invalid option.";;
esac

if [ ".config_telemt.toml" ]; then get_from_file_settings; get_from_file_secrets;
    if [ "$FAST_SETUP" = false ]; then echo ""; warn "📂 Existing configuration found";
    fi;
fi


if [ "$RENEW_SECRET" = true ]; then MAIN_RAW_SECRET=$(openssl rand -hex 16); info "🔐 Generated MAIN secret: ${MAIN_RAW_SECRET}";
    read VALUE_USER_INPUT "<$VALUE_DEF_MAX_USERS ($VALUE_DEF_USER_COUNT): "
    VALUE_USER_INPUT=${VALUE_USER_INPUT:-$VALUE_DEF_USER_COUNT};
    if (( VALUE_USER_INPUT > VALUE_DEF_MAX_USERS ));
    then value_user_input=$VALUE_DEF_MAX_USERS; warn "! Limited to ${YELLOW}$VALUE_DEF_MAX_USERS users.${NC}";
    fi;
    for (( i=1; i<=value_user_input; i++ ));
    do ask "! If you just press Enter, the name will be Bastard$i\nEnter name for user №$i:" VALUE_USER_NAME; read VALUE_USER_NAME;
    VALUE_USER_NAME=${VALUE_USER_NAME:-Bastard$i};
    NEW_SECRET=$(openssl rand -hex 16);
    info "+ Added ${CYAN}$VALUE_USER_NAME${NC} with secret: ${GREEN}$NEW_SECRET${NC}";
    ADDIT_CONFIG+=$'\n'"$VALUE_USER_NAME = \"$NEW_SECRET\"";
    done;
    fi


write_file_config_telemt;
write_file_config_compose;
date +"%Y-%m-%d" > .install_date;
deploy_container && start_container && info "🎉 Proxy is ready to use!" ;
print_proxy_link;
TELEMT_SCRIPT

chmod +x telemt-from-image-mu.sh

# Запуск исправленного скрипта Telemt с рут-правами от текущего пользователя root.
./telemt-from-image-mu.sh