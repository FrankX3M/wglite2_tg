#!/bin/bash

# Скрипт для настройки WireGuard в Docker Compose и Telegram-бота для управления пирами
# Author: Claude
# Date: April 8, 2025

# Цвета для вывода
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Загрузка переменных из файла .env
load_env_file() {
    local env_file="./.env"
    
    # Проверка существования файла .env
    if [ -f "$env_file" ]; then
        echo -e "${GREEN}[INFO]${NC} Загрузка переменных из файла $env_file"
        
        # Чтение файла .env построчно
        while IFS='=' read -r key value || [ -n "$key" ]; do
            # Пропуск пустых строк и комментариев
            if [[ -z "$key" || "$key" == \#* ]]; then
                continue
            fi
            
            # Удаление пробелов в начале и конце
            key=$(echo "$key" | xargs)
            value=$(echo "$value" | xargs)
            
            # Удаление кавычек если они есть
            value="${value%\"}"
            value="${value#\"}"
            value="${value%\'}"
            value="${value#\'}"
            
            # Присваивание значения соответствующей локальной переменной
            case "$key" in
                BASE_DIR) BASE_DIR="$value" ;;
                WG_CONFIG_DIR) WG_CONFIG_DIR="$value" ;;
                WG_COMPOSE_DIR) WG_COMPOSE_DIR="$value" ;;
                WG_CONTAINER_NAME) WG_CONTAINER_NAME="$value" ;;
                WG_PORT) WG_PORT="$value" ;;
                WG_INTERNAL_SUBNET) WG_INTERNAL_SUBNET="$value" ;;
                WG_SERVER_URL) WG_SERVER_URL="$value" ;;
                TELEGRAM_BOT_TOKEN) TELEGRAM_BOT_TOKEN="$value" ;;
                TELEGRAM_ADMIN_IDS) TELEGRAM_ADMIN_IDS="$value" ;;
                TELEGRAM_SCRIPT_DIR) TELEGRAM_SCRIPT_DIR="$value" ;;
                TELEGRAM_LOG_FILE) TELEGRAM_LOG_FILE="$value" ;;
            esac
        done < "$env_file"
        
        echo -e "${GREEN}[INFO]${NC} Переменные из .env файла загружены"
    else
        echo -e "${YELLOW}[WARNING]${NC} Файл .env не найден: $env_file"
        echo -e "${GREEN}[INFO]${NC} Используются значения по умолчанию"
        
        # Устанавливаем значения по умолчанию
        BASE_DIR="/opt/wireguard"
        WG_CONFIG_DIR="$BASE_DIR/config"
        WG_COMPOSE_DIR="$BASE_DIR/compose"
        WG_CONTAINER_NAME="wireguard"
        WG_PORT=51820
        WG_INTERNAL_SUBNET="10.13.13.0"
        WG_SERVER_URL=""
        TELEGRAM_SCRIPT_DIR="$BASE_DIR/telegram-bot"
        TELEGRAM_LOG_FILE="/var/log/wg-telegram-bot.log"
        TELEGRAM_BOT_TOKEN=""
        TELEGRAM_ADMIN_IDS=""
    fi
}

# Функции логирования
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1" >> $TELEGRAM_LOG_FILE
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARNING] $1" >> $TELEGRAM_LOG_FILE
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1" >> $TELEGRAM_LOG_FILE
}

# Установка зависимостей для Debian 12
install_dependencies_debian() {
    log_info "Установка зависимостей для Debian 12..."
    
    # Обновление пакетов
    apt-get update
    
    # Установка необходимых пакетов
    apt-get install -y \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
        jq \
        git \
        wget \
        nano \
        sudo
    
    # Установка Docker и Docker Compose
    log_info "Установка Docker и Docker Compose..."
    
    # Удаление старых версий Docker (если есть)
    apt-get remove -y docker docker-engine docker.io containerd runc || true
    
    # Добавление официального GPG-ключа Docker
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    
    # Добавление репозитория Docker
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
      $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    # Обновление пакетов и установка Docker
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    
    # Запуск и включение автозапуска Docker
    systemctl enable docker
    systemctl start docker
    
    log_info "Docker и Docker Compose успешно установлены"
}

# Проверка наличия необходимых утилит
check_requirements() {
    log_info "Проверка наличия необходимых компонентов..."
    
    local required_commands=("docker" "docker" "compose" "curl" "jq")
    local missing_commands=()
    
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_commands+=("$cmd")
        fi
    done
    
    if [ ${#missing_commands[@]} -ne 0 ]; then
        log_error "Отсутствуют следующие необходимые утилиты: ${missing_commands[*]}"
        
        # Проверяем, является ли система Debian 12
        if [ -f /etc/os-release ]; then
            source /etc/os-release
            if [ "$ID" = "debian" ] && [[ "$VERSION_ID" == "12"* ]]; then
                log_info "Обнаружена Debian 12. Устанавливаем зависимости..."
                install_dependencies_debian
            else
                log_info "Установите необходимые зависимости с помощью вашего пакетного менеджера, например:"
                log_info "apt update && apt install -y docker.io docker-compose curl jq"
                exit 1
            fi
        else
            log_info "Установите необходимые зависимости с помощью вашего пакетного менеджера"
            exit 1
        fi
    fi
    
    # Проверка работы Docker
    if ! docker info &> /dev/null; then
        log_error "Docker не запущен или у пользователя нет прав для работы с ним"
        log_info "Проверьте, запущен ли сервис Docker и имеет ли текущий пользователь права:"
        log_info "systemctl start docker"
        log_info "usermod -aG docker $USER"
        exit 1
    fi
    
    log_info "Все необходимые компоненты установлены"
}

# Настройка структуры директорий
setup_directories() {
    log_info "Создание структуры директорий..."
    
    mkdir -p "$WG_CONFIG_DIR"
    mkdir -p "$WG_COMPOSE_DIR"
    mkdir -p "$TELEGRAM_SCRIPT_DIR"
    touch "$TELEGRAM_LOG_FILE"
    chmod 640 "$TELEGRAM_LOG_FILE"
    
    log_info "Структура директорий создана"
}

# Настройка и создание SWAP файла
setup_swap() {
    log_info "Проверка и настройка SWAP-файла..."
    
    # Проверка наличия SWAP
    local swap_total=$(free -m | awk '/^Swap:/ {print $2}')
    
    if [ "$swap_total" -gt 0 ]; then
        log_info "SWAP уже настроен (${swap_total}MB). Пропускаем создание."
        return 0
    fi
    
    # Определяем размер SWAP файла в зависимости от RAM
    local ram_total=$(free -m | awk '/^Mem:/ {print $2}')
    local swap_size=0
    
    if [ "$ram_total" -le 2048 ]; then
        # Для серверов с RAM до 2GB используем swap = 2 * RAM
        swap_size=$((ram_total * 2))
    elif [ "$ram_total" -le 8192 ]; then
        # Для серверов с RAM от 2GB до 8GB используем swap = 1 * RAM
        swap_size=$ram_total
    else
        # Для серверов с RAM более 8GB используем 4GB swap
        swap_size=4096
    fi
    
    log_info "Создание SWAP-файла размером ${swap_size}MB..."
    
    # Создание swap файла
    local swap_file="/swapfile"
    
    # Создаем файл заданного размера
    dd if=/dev/zero of=$swap_file bs=1M count=$swap_size status=progress
    
    # Задаем права доступа
    chmod 600 $swap_file
    
    # Настраиваем как swap
    mkswap $swap_file
    
    # Включаем swap
    swapon $swap_file
    
    # Добавляем в fstab для автоматического монтирования при загрузке
    if ! grep -q "^$swap_file " /etc/fstab; then
        echo "$swap_file none swap sw 0 0" >> /etc/fstab
    fi
    
    # Настройка параметров использования swap (значение 10 означает, что swap будет использоваться только когда RAM заполнена на 90%)
    echo "vm.swappiness=10" > /etc/sysctl.d/99-swappiness.conf
    sysctl -p /etc/sysctl.d/99-swappiness.conf
    
    log_info "SWAP-файл успешно создан и настроен (${swap_size}MB)"
}

# Создание Docker Compose файла для WireGuard
create_docker_compose_file() {
    log_info "Создание Docker Compose файла для WireGuard..."
    
    # Если SERVER_URL пуст, используем auto-определение
    if [ -z "$WG_SERVER_URL" ]; then
        WG_SERVER_URL="auto"
    fi
    
    # Создание файла docker-compose.yml
    cat > "$WG_COMPOSE_DIR/docker-compose.yml" << EOF
version: '3'

services:
  wireguard:
    image: lscr.io/linuxserver/wireguard:latest
    container_name: ${WG_CONTAINER_NAME}
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=$(cat /etc/timezone 2>/dev/null || echo 'Etc/UTC')
      - SERVERURL=${WG_SERVER_URL}
      - SERVERPORT=${WG_PORT}
      - PEERS=1
      - PEERDNS=auto
      - INTERNAL_SUBNET=${WG_INTERNAL_SUBNET}
      - ALLOWEDIPS=0.0.0.0/0
      - LOG_CONFS=true
    volumes:
      - ${WG_CONFIG_DIR}:/config
      - /lib/modules:/lib/modules
    ports:
      - ${WG_PORT}:51820/udp
    sysctls:
      - net.ipv4.conf.all.src_valid_mark=1
    restart: unless-stopped
EOF

    log_info "Docker Compose файл создан: $WG_COMPOSE_DIR/docker-compose.yml"
}

# Настройка WireGuard в Docker Compose
setup_wireguard_docker() {
    log_info "Настройка WireGuard через Docker Compose..."
    
    # Создаем Docker Compose файл
    create_docker_compose_file
    
    # Проверка наличия контейнера
    if docker ps -a --format '{{.Names}}' | grep -q "^${WG_CONTAINER_NAME}$"; then
        log_warning "Контейнер $WG_CONTAINER_NAME уже существует. Остановка и удаление..."
        docker compose -f "$WG_COMPOSE_DIR/docker-compose.yml" down
    fi
    
    # Запуск контейнеров через Docker Compose
    log_info "Запуск WireGuard через Docker Compose..."
    cd "$WG_COMPOSE_DIR" && docker compose up -d
    
    if [ $? -ne 0 ]; then
        log_error "Не удалось запустить WireGuard через Docker Compose"
        exit 1
    fi
    
    log_info "WireGuard успешно запущен через Docker Compose"
    log_info "Ожидание инициализации WireGuard..."
    sleep 10
}

# Создание Telegram-бота
create_telegram_bot_script() {
    log_info "Создание скрипта Telegram-бота..."
    
    cat > "$TELEGRAM_SCRIPT_DIR/wg-telegram-bot.sh" << 'EOF'
#!/bin/bash

# WireGuard Telegram Bot
# Этот скрипт обрабатывает команды Telegram-бота для управления WireGuard пирами

# Загрузка конфигурации
source "$(dirname "$0")/config.sh"

# Функции логирования
log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1" >> $LOG_FILE
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1" >> $LOG_FILE
}

# Функция для отправки сообщений в Telegram
send_telegram_message() {
    local chat_id="$1"
    local message="$2"
    local parse_mode="${3:-HTML}"
    
    curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
        -d "chat_id=$chat_id" \
        -d "text=$message" \
        -d "parse_mode=$parse_mode" > /dev/null
    
    if [ $? -ne 0 ]; then
        log_error "Ошибка при отправке сообщения в Telegram"
    fi
}

# Функция для отправки файлов в Telegram
send_telegram_document() {
    local chat_id="$1"
    local file_path="$2"
    local caption="${3:-}"
    
    curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendDocument" \
        -F "chat_id=$chat_id" \
        -F "document=@$file_path" \
        -F "caption=$caption" > /dev/null
}

# Функция для отправки фотографий (QR-кодов) в Telegram
send_telegram_photo() {
    local chat_id="$1"
    local file_path="$2"
    local caption="${3:-}"
    
    curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendPhoto" \
        -F "chat_id=$chat_id" \
        -F "photo=@$file_path" \
        -F "caption=$caption" > /dev/null
}

# Проверка авторизации пользователя
is_authorized() {
    local user_id="$1"
    
    IFS=',' read -ra ADMIN_ARRAY <<< "$ADMIN_IDS"
    for admin_id in "${ADMIN_ARRAY[@]}"; do
        if [ "$user_id" = "$admin_id" ]; then
            return 0
        fi
    done
    
    return 1
}

# Функция для создания нового пира
create_peer() {
    local chat_id="$1"
    local peer_name="$2"
    
    log_info "Создание пира '$peer_name' запрошено пользователем $chat_id"
    
    # Проверка на допустимые символы в имени пира
    if ! [[ $peer_name =~ ^[a-zA-Z0-9_-]+$ ]]; then
        send_telegram_message "$chat_id" "❌ Ошибка: Имя пира может содержать только буквы, цифры, дефисы и подчеркивания"
        return 1
    fi
    
    # Получаем текущее количество пиров
    local current_peers=$(docker exec "$CONTAINER_NAME" sh -c "ls -1 /config/peer_* 2>/dev/null | wc -l" 2>/dev/null || echo "0")
    
    # Добавляем новый пир
    local peers_var=$(docker inspect --format '{{range .Config.Env}}{{if eq (index (split . "=") 0) "PEERS"}}{{index (split . "=") 1}}{{end}}{{end}}' "$CONTAINER_NAME")
    
    # Если формат PEERS - число, преобразуем его в список имен
    if [[ "$peers_var" =~ ^[0-9]+$ ]]; then
        local new_peers_list=""
        for ((i=1; i<=peers_var; i++)); do
            local peer_dir="/config/peer$i"
            if docker exec "$CONTAINER_NAME" test -d "$peer_dir"; then
                local existing_name=$(echo "peer$i")
                if [ -n "$new_peers_list" ]; then
                    new_peers_list="$new_peers_list,$existing_name"
                else
                    new_peers_list="$existing_name"
                fi
            fi
        done
        
        if [ -n "$new_peers_list" ]; then
            peers_var="$new_peers_list"
        else
            peers_var=""
        fi
    fi
    
    # Добавляем новое имя в список
    if [ -n "$peers_var" ]; then
        new_peers="$peers_var,$peer_name"
    else
        new_peers="$peer_name"
    fi
    
    send_telegram_message "$chat_id" "⏳ Создание пира <b>$peer_name</b>. Пожалуйста, подождите..."
    
    # Обновляем переменные окружения и перезапускаем контейнер через docker-compose
    local compose_dir=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$CONTAINER_NAME" 2>/dev/null)
    
    if [ -n "$compose_dir" ] && [ -f "$compose_dir/docker-compose.yml" ]; then
        # Обновляем PEERS в docker-compose.yml
        sed -i "s/- PEERS=.*$/- PEERS=$new_peers/" "$compose_dir/docker-compose.yml"
        
        # Перезапускаем через docker-compose
        cd "$compose_dir" && docker compose down && docker compose up -d
    else
        # Резервный метод, если не можем определить директорию docker-compose
        docker stop "$CONTAINER_NAME" > /dev/null
        docker update --env PEERS="$new_peers" "$CONTAINER_NAME" > /dev/null
        docker start "$CONTAINER_NAME" > /dev/null
    fi
    
    # Проверяем, был ли создан пир
    sleep 5
    if docker exec "$CONTAINER_NAME" test -d "/config/peer_$peer_name"; then
        log_info "Пир '$peer_name' успешно создан"
        
        # Отправляем QR-код
        local qr_file="/config/peer_$peer_name/peer_$peer_name.png"
        docker cp "$CONTAINER_NAME:$qr_file" "/tmp/wg_qr_$peer_name.png"
        send_telegram_photo "$chat_id" "/tmp/wg_qr_$peer_name.png" "QR-код для пира $peer_name"
        rm -f "/tmp/wg_qr_$peer_name.png"
        
        # Отправляем конфигурационный файл
        local conf_file="/config/peer_$peer_name/peer_$peer_name.conf"
        docker cp "$CONTAINER_NAME:$conf_file" "/tmp/wg_conf_$peer_name.conf"
        send_telegram_document "$chat_id" "/tmp/wg_conf_$peer_name.conf" "Конфигурация для пира $peer_name"
        rm -f "/tmp/wg_conf_$peer_name.conf"
        
        send_telegram_message "$chat_id" "✅ Пир <b>$peer_name</b> успешно создан!"
    else
        log_error "Не удалось создать пир '$peer_name'"
        send_telegram_message "$chat_id" "❌ Ошибка: Не удалось создать пир <b>$peer_name</b>"
    fi
}

# Функция для удаления пира
delete_peer() {
    local chat_id="$1"
    local peer_name="$2"
    
    log_info "Удаление пира '$peer_name' запрошено пользователем $chat_id"
    
    # Проверяем существование пира
    if ! docker exec "$CONTAINER_NAME" test -d "/config/peer_$peer_name"; then
        send_telegram_message "$chat_id" "❌ Ошибка: Пир <b>$peer_name</b> не существует"
        return 1
    fi
    
    send_telegram_message "$chat_id" "⏳ Удаление пира <b>$peer_name</b>. Пожалуйста, подождите..."
    
    # Получаем текущий список пиров
    local peers_var=$(docker inspect --format '{{range .Config.Env}}{{if eq (index (split . "=") 0) "PEERS"}}{{index (split . "=") 1}}{{end}}{{end}}' "$CONTAINER_NAME")
    
    # Удаляем пир из списка
    local new_peers=""
    IFS=',' read -ra PEER_ARRAY <<< "$peers_var"
    for peer in "${PEER_ARRAY[@]}"; do
        if [ "$peer" != "$peer_name" ]; then
            if [ -n "$new_peers" ]; then
                new_peers="$new_peers,$peer"
            else
                new_peers="$peer"
            fi
        fi
    done
    
    # Если список пуст, устанавливаем значение по умолчанию
    if [ -z "$new_peers" ]; then
        new_peers="1"
    fi
    
    # Удаляем директорию пира
    docker exec "$CONTAINER_NAME" rm -rf "/config/peer_$peer_name"
    
    # Обновляем переменные окружения и перезапускаем контейнер через docker-compose
    local compose_dir=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$CONTAINER_NAME" 2>/dev/null)
    
    if [ -n "$compose_dir" ] && [ -f "$compose_dir/docker-compose.yml" ]; then
        # Обновляем PEERS в docker-compose.yml
        sed -i "s/- PEERS=.*$/- PEERS=$new_peers/" "$compose_dir/docker-compose.yml"
        
        # Перезапускаем через docker-compose
        cd "$compose_dir" && docker compose down && docker compose up -d
    else
        # Резервный метод, если не можем определить директорию docker-compose
        docker stop "$CONTAINER_NAME" > /dev/null
        docker update --env PEERS="$new_peers" "$CONTAINER_NAME" > /dev/null
        docker start "$CONTAINER_NAME" > /dev/null
    fi
    
    log_info "Пир '$peer_name' успешно удален"
    send_telegram_message "$chat_id" "✅ Пир <b>$peer_name</b> успешно удален!"
}

# Функция для отображения списка пиров
list_peers() {
    local chat_id="$1"
    
    log_info "Список пиров запрошен пользователем $chat_id"
    
    # Получаем список пиров
    local peer_dirs=$(docker exec "$CONTAINER_NAME" sh -c "ls -d /config/peer_* 2>/dev/null | xargs -n1 basename 2>/dev/null" 2>/dev/null)
    
    if [ -z "$peer_dirs" ]; then
        send_telegram_message "$chat_id" "ℹ️ Нет настроенных пиров"
        return
    fi
    
    local message="📋 <b>Список пиров:</b>\n\n"
    
    while IFS= read -r peer_dir; do
        local peer_name="${peer_dir#peer_}"
        message+="• $peer_name\n"
    done <<< "$peer_dirs"
    
    send_telegram_message "$chat_id" "$message"
}

# Функция для показа информации о пире
show_peer() {
    local chat_id="$1"
    local peer_name="$2"
    
    log_info "Информация о пире '$peer_name' запрошена пользователем $chat_id"
    
    # Проверяем существование пира
    if ! docker exec "$CONTAINER_NAME" test -d "/config/peer_$peer_name"; then
        send_telegram_message "$chat_id" "❌ Ошибка: Пир <b>$peer_name</b> не существует"
        return 1
    fi
    
    # Отправляем QR-код
    local qr_file="/config/peer_$peer_name/peer_$peer_name.png"
    docker cp "$CONTAINER_NAME:$qr_file" "/tmp/wg_qr_$peer_name.png"
    send_telegram_photo "$chat_id" "/tmp/wg_qr_$peer_name.png" "QR-код для пира $peer_name"
    rm -f "/tmp/wg_qr_$peer_name.png"
    
    # Отправляем конфигурационный файл
    local conf_file="/config/peer_$peer_name/peer_$peer_name.conf"
    docker cp "$CONTAINER_NAME:$conf_file" "/tmp/wg_conf_$peer_name.conf"
    send_telegram_document "$chat_id" "/tmp/wg_conf_$peer_name.conf" "Конфигурация для пира $peer_name"
    rm -f "/tmp/wg_conf_$peer_name.conf"
    
    send_telegram_message "$chat_id" "✅ Информация о пире <b>$peer_name</b> отправлена"
}

# Функция для отображения справки
show_help() {
    local chat_id="$1"
    
    local message="🔰 <b>WireGuard Бот - Справка</b>\n\n"
    message+="Доступные команды:\n\n"
    message+="/list - Показать список пиров\n"
    message+="/create <имя> - Создать новый пир\n"
    message+="/show <имя> - Показать информацию о пире\n"
    message+="/delete <имя> - Удалить пир\n"
    message+="/help - Показать эту справку\n\n"
    message+="Примеры:\n"
    message+="/create phone - Создать пир с именем 'phone'\n"
    message+="/show laptop - Показать информацию о пире 'laptop'\n"
    
    send_telegram_message "$chat_id" "$message"
}

# Главная функция обработки команд
process_update() {
    local update="$1"
    
    # Извлекаем информацию из обновления
    local chat_id=$(echo "$update" | jq -r '.message.chat.id')
    local user_id=$(echo "$update" | jq -r '.message.from.id')
    local message_text=$(echo "$update" | jq -r '.message.text')
    
    # Если сообщение пустое, пропускаем
    if [ "$message_text" = "null" ] || [ -z "$message_text" ]; then
        return
    fi
    
    log_info "Получено сообщение от пользователя $user_id: $message_text"
    
    # Проверяем авторизацию пользователя
    if ! is_authorized "$user_id"; then
        log_info "Неавторизованный доступ от пользователя $user_id"
        send_telegram_message "$chat_id" "⛔ У вас нет прав для использования этого бота"
        return
    fi
    
    # Обрабатываем команды
    if [[ "$message_text" == "/start" ]]; then
        send_telegram_message "$chat_id" "👋 Добро пожаловать в WireGuard Бот!\n\nИспользуйте /help для получения списка команд."
    
    elif [[ "$message_text" == "/help" ]]; then
        show_help "$chat_id"
    
    elif [[ "$message_text" == "/list" ]]; then
        list_peers "$chat_id"
    
    elif [[ "$message_text" =~ ^/create[[:space:]]+([a-zA-Z0-9_-]+)$ ]]; then
        local peer_name="${BASH_REMATCH[1]}"
        create_peer "$chat_id" "$peer_name"
    
    elif [[ "$message_text" =~ ^/show[[:space:]]+([a-zA-Z0-9_-]+)$ ]]; then
        local peer_name="${BASH_REMATCH[1]}"
        show_peer "$chat_id" "$peer_name"
    
    elif [[ "$message_text" =~ ^/delete[[:space:]]+([a-zA-Z0-9_-]+)$ ]]; then
        local peer_name="${BASH_REMATCH[1]}"
        delete_peer "$chat_id" "$peer_name"
    
    else
        send_telegram_message "$chat_id" "❓ Неизвестная команда. Используйте /help для получения списка команд."
    fi
}

# Главный цикл
main() {
    log_info "Бот запущен с токеном $BOT_TOKEN"
    
    local last_update_id=0
    
    while true; do
        # Получаем обновления
        local updates=$(curl -s "https://api.telegram.org/bot$BOT_TOKEN/getUpdates?offset=$((last_update_id + 1))&timeout=60")
        
        # Проверяем, успешен ли запрос
        if [ "$(echo "$updates" | jq -r '.ok')" != "true" ]; then
            log_error "Ошибка при получении обновлений: $(echo "$updates" | jq -r '.description')"
            sleep 10
            continue
        fi
        
        # Обрабатываем каждое обновление
        for update_id in $(echo "$updates" | jq -r '.result[].update_id'); do
            if [ "$update_id" -gt "$last_update_id" ]; then
                local update=$(echo "$updates" | jq -r ".result[] | select(.update_id == $update_id)")
                process_update "$update"
                last_update_id=$update_id
            fi
        done
        
        # Небольшая пауза
        sleep 1
    done
}

# Запуск главного цикла
main
EOF
    
    chmod +x "$TELEGRAM_SCRIPT_DIR/wg-telegram-bot.sh"
    
    # Создание файла конфигурации для бота
    cat > "$TELEGRAM_SCRIPT_DIR/config.sh" << EOF
#!/bin/bash

# Конфигурация WireGuard Telegram-бота

# Токен Telegram-бота
BOT_TOKEN="$TELEGRAM_BOT_TOKEN"

# ID администраторов (через запятую)
ADMIN_IDS="$TELEGRAM_ADMIN_IDS"

# Имя контейнера WireGuard
CONTAINER_NAME="$WG_CONTAINER_NAME"

# Путь к файлу журнала
LOG_FILE="$TELEGRAM_LOG_FILE"
EOF
    
    chmod +x "$TELEGRAM_SCRIPT_DIR/config.sh"
    
    log_info "Скрипты Telegram-бота созданы"
}

# Создание systemd-сервиса для Telegram-бота
create_telegram_bot_service() {
    log_info "Создание systemd-сервиса для Telegram-бота..."
    
    cat > /etc/systemd/system/wg-telegram-bot.service << EOF
[Unit]
Description=WireGuard Telegram Bot
After=docker.service
Requires=docker.service

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=$TELEGRAM_SCRIPT_DIR
ExecStart=$TELEGRAM_SCRIPT_DIR/wg-telegram-bot.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    # Перезагрузка systemd для обнаружения нового сервиса
    systemctl daemon-reload
    
    log_info "Systemd-сервис для Telegram-бота создан"
}

# Запуск Telegram-бота
start_telegram_bot() {
    log_info "Запуск Telegram-бота..."
    
    # Включение и запуск сервиса
    systemctl enable wg-telegram-bot.service
    systemctl start wg-telegram-bot.service
    
    if systemctl is-active --quiet wg-telegram-bot.service; then
        log_info "Telegram-бот успешно запущен"
    else
        log_error "Не удалось запустить Telegram-бота"
        log_info "Проверьте статус сервиса: systemctl status wg-telegram-bot.service"
    fi
}

# Настройка загрузочных модулей для WireGuard на Debian 12
setup_wireguard_modules() {
    log_info "Настройка загрузочных модулей для WireGuard..."
    
    # Проверка наличия модуля WireGuard
    if ! lsmod | grep -q wireguard; then
        log_info "Модуль WireGuard не загружен. Загрузка модуля..."
        
        # Установка пакета wireguard если требуется
        if ! command -v wg &> /dev/null; then
            log_info "Установка пакета wireguard..."
            apt-get update
            apt-get install -y wireguard
        fi
        
        # Загрузка модуля
        modprobe wireguard
        
        # Добавление модуля в автозагрузку
        echo "wireguard" > /etc/modules-load.d/wireguard.conf
    fi
    
    log_info "Модуль WireGuard настроен"
}

# Настройка дополнительных параметров ядра
setup_kernel_parameters() {
    log_info "Настройка параметров ядра для WireGuard..."
    
    # Включение IP-форвардинга
    echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-wireguard.conf
    echo "net.ipv6.conf.all.forwarding = 1" >> /etc/sysctl.d/99-wireguard.conf
    
    # Применение параметров
    sysctl -p /etc/sysctl.d/99-wireguard.conf
    
    log_info "Параметры ядра настроены"
}

# Функция для проверки наличия необходимых аргументов
check_telegram_config() {
    if [ -z "$TELEGRAM_BOT_TOKEN" ]; then
        log_error "Не указан токен Telegram-бота (TELEGRAM_BOT_TOKEN)"
        log_info "Получите токен у @BotFather в Telegram и укажите его в файле .env"
        exit 1
    fi
    
    if [ -z "$TELEGRAM_ADMIN_IDS" ]; then
        log_error "Не указаны ID администраторов (TELEGRAM_ADMIN_IDS)"
        log_info "Укажите ID администраторов через запятую в файле .env"
        log_info "Чтобы узнать свой ID, напишите боту @userinfobot в Telegram"
        exit 1
    fi
}

# Создание примера файла .env
create_env_file_example() {
    local env_example_file="./env.example"
    
    log_info "Создание примера файла .env: $env_example_file"
    
    cat > "$env_example_file" << EOF
# Конфигурация директорий
BASE_DIR=$BASE_DIR
WG_CONFIG_DIR=$WG_CONFIG_DIR
WG_COMPOSE_DIR=$WG_COMPOSE_DIR
TELEGRAM_SCRIPT_DIR=$TELEGRAM_SCRIPT_DIR
TELEGRAM_LOG_FILE=$TELEGRAM_LOG_FILE

# Конфигурация WireGuard
WG_CONTAINER_NAME=$WG_CONTAINER_NAME
WG_PORT=$WG_PORT
WG_INTERNAL_SUBNET=$WG_INTERNAL_SUBNET
# Оставьте пустым для автоопределения или укажите ваш домен/IP
WG_SERVER_URL=$WG_SERVER_URL

# Конфигурация Telegram-бота
# Получите токен у @BotFather
TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
# Укажите ID администраторов через запятую (узнать ID можно у @userinfobot)
TELEGRAM_ADMIN_IDS=$TELEGRAM_ADMIN_IDS
EOF
    
    log_info "Пример файла .env создан"
}

# Основная функция
main() {
    echo -e "${GREEN}=== Установка и настройка WireGuard с Telegram-ботом ===${NC}"
    
    # Проверка прав root
    if [ "$(id -u)" -ne 0 ]; then
        log_error "Этот скрипт должен быть запущен с правами root"
        exit 1
    fi
    
    # Загрузка переменных из файла .env
    load_env_file
    
    # Создание примера файла .env
    create_env_file_example
    
    # Проверка конфигурации Telegram
    check_telegram_config
    
    # Проверка необходимых компонентов
    check_requirements
    
    # Настройка SWAP
    setup_swap
    
    # Настройка директорий
    setup_directories
    
    # Настройка загрузочных модулей для WireGuard
    setup_wireguard_modules
    
    # Настройка параметров ядра
    setup_kernel_parameters
    
    # Настройка WireGuard в Docker
    setup_wireguard_docker
    
    # Создание скрипта Telegram-бота
    create_telegram_bot_script
    
    # Создание systemd-сервиса для Telegram-бота
    create_telegram_bot_service
    
    # Запуск Telegram-бота
    start_telegram_bot
    
    log_info "Установка и настройка завершены успешно!"
    log_info "WireGuard доступен на порту: $WG_PORT/UDP"
    log_info "Конфигурация WireGuard находится в: $WG_CONFIG_DIR"
    log_info "Docker Compose файл находится в: $WG_COMPOSE_DIR/docker-compose.yml"
    log_info "Telegram-бот запущен, проверьте: systemctl status wg-telegram-bot.service"
    log_info "Конфигурация загружена из файла .env"
    log_info "Для изменения настроек отредактируйте файл .env и перезапустите установку"
}

# Запуск основной функции
main "$@"