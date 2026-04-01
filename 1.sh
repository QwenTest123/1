#!/bin/bash
set -euo pipefail

# =============================================================================
# AmneziaWG Automated Installer – устойчивая версия
# =============================================================================

# Параметры по умолчанию (можно переопределить переменными окружения)
PORT="${AWG_PORT:-51820}"
SUBNET="${AWG_SUBNET:-10.0.0.0/24}"
CLIENTS="${AWG_CLIENTS:-4}"
DNS_SERVERS="${AWG_DNS:-1.1.1.1, 8.8.8.8}"
INTERFACE="${AWG_IF:-}"
JC="${AWG_JC:-4}"
JMIN="${AWG_JMIN:-40}"
JMAX="${AWG_JMAX:-70}"
S1="${AWG_S1:-51}"
S2="${AWG_S2:-69}"
S3="${AWG_S3:-87}"
S4="${AWG_S4:-105}"
H1="${AWG_H1:-1261922956}"
H2="${AWG_H2:-1406358319}"
H3="${AWG_H3:-1551061718}"
H4="${AWG_H4:-1703880275}"
I1="${AWG_I1:-106}"
I2="${AWG_I2:-116}"
I3="${AWG_I3:-126}"
I4="${AWG_I4:-136}"
I5="${AWG_I5:-146}"

# Дополнительные опции
KEEP_SSH="${AWG_KEEP_SSH:-false}"      # true - не блокировать SSH, false - заблокировать
WEB_PORT="${AWG_WEB_PORT:-8080}"        # порт временного веб-сервера
WAIT_SECONDS="${AWG_WAIT_SECONDS:-120}" # сколько секунд ждать перед блокировкой (0 - ждать Enter)

# --- Вспомогательные функции ---
log_info() {
    echo "ℹ️ $1"
}
log_success() {
    echo "✅ $1"
}
log_error() {
    echo "❌ $1" >&2
}
log_warn() {
    echo "⚠️ $1"
}

# --- Проверка root ---
if [ "$EUID" -ne 0 ]; then
    log_error "Пожалуйста, запустите скрипт с правами root (sudo)."
    exit 1
fi

log_info "Начинаем установку AmneziaWG с $CLIENTS клиентами..."

# --- Обновление системы и установка зависимостей (без интерактива) ---
export DEBIAN_FRONTEND=noninteractive
apt update -y
apt upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
apt install -y curl wget software-properties-common qrencode ufw python3 zip wireguard-tools ipcalc

# --- Добавление репозитория AmneziaWG и установка ---
if ! grep -q "amnezia/ppa" /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null; then
    add-apt-repository ppa:amnezia/ppa -y
    apt update -y
fi
apt install -y amneziawg

# --- Проверка, что команда wg доступна ---
if ! command -v wg &> /dev/null; then
    log_error "Команда wg не найдена после установки. Убедитесь, что wireguard-tools установлен."
    exit 1
fi

# --- Определение внешнего IP и интерфейса ---
EXTERNAL_IP=$(curl -s ifconfig.me || curl -s icanhazip.com || curl -s ipinfo.io/ip)
if [ -z "$EXTERNAL_IP" ]; then
    log_error "Не удалось определить внешний IP. Проверьте подключение к интернету."
    exit 1
fi

if [ -z "$INTERFACE" ]; then
    INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
    if [ -z "$INTERFACE" ]; then
        log_error "Не удалось определить сетевой интерфейс по умолчанию."
        exit 1
    fi
fi
log_success "Сервер: $EXTERNAL_IP, интерфейс: $INTERFACE"

# --- Генерация ключей сервера ---
mkdir -p /etc/amneziawg
cd /etc/amneziawg
wg genkey | tee server_private.key | wg pubkey > server_public.key
chmod 600 server_private.key server_public.key
SERVER_PRIV=$(cat server_private.key)
SERVER_PUB=$(cat server_public.key)
log_success "Ключи сервера созданы."

# --- Подготовка подсети ---
SUBNET_BASE=$(echo $SUBNET | cut -d '/' -f1)
SUBNET_MASK=$(echo $SUBNET | cut -d '/' -f2)
SERVER_ADDR="${SUBNET_BASE}.1/${SUBNET_MASK}"
log_info "Подсеть клиентов: $SUBNET"

# --- Создание конфигурации сервера (без параметров обфускации, они только на клиентах) ---
cat > /etc/amneziawg/awg0.conf <<EOF
[Interface]
Address = ${SERVER_ADDR}
ListenPort = ${PORT}
PrivateKey = ${SERVER_PRIV}
PostUp = sysctl -w net.ipv4.ip_forward=1
PostUp = iptables -A FORWARD -i %i -j ACCEPT
PostUp = iptables -A FORWARD -o %i -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -o ${INTERFACE} -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT
PostDown = iptables -D FORWARD -o %i -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o ${INTERFACE} -j MASQUERADE
EOF

# --- Включение IP forwarding ---
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-amneziawg.conf
sysctl -p /etc/sysctl.d/99-amneziawg.conf

# --- Настройка UFW: открываем порт AmneziaWG, SSH, временный веб-порт ---
ufw allow ${PORT}/udp comment "AmneziaWG"
ufw allow ${WEB_PORT}/tcp comment "Temporary web server"
if [ "$KEEP_SSH" = "true" ]; then
    ufw allow 22/tcp comment "SSH"
    log_warn "SSH будет оставлен открытым (KEEP_SSH=true)."
else
    ufw allow 22/tcp comment "SSH (temporary, will be removed later)"
fi
ufw --force enable

# --- Запуск AmneziaWG ---
systemctl enable wg-quick@awg0
systemctl start wg-quick@awg0
sleep 2
if ! systemctl is-active --quiet wg-quick@awg0; then
    log_error "AmneziaWG не запустился. Проверьте /etc/amneziawg/awg0.conf и логи (journalctl -u wg-quick@awg0)."
    exit 1
fi
log_success "AmneziaWG запущен."

# --- Создание клиентов ---
mkdir -p /root/awg-clients
cd /root/awg-clients

# Вычисляем начальный IP для клиентов (считаем, что подсеть /24, и первый адрес занят сервером)
# Если подсеть не /24, может потребоваться более сложный расчет, но для простоты оставим так.
CLIENT_IP_START=$(( $(echo $SUBNET_BASE | cut -d '.' -f4) + 1 ))
for i in $(seq 1 $CLIENTS); do
    CLIENT_NAME="client${i}"
    CLIENT_IP="${SUBNET_BASE}.$((CLIENT_IP_START + i - 1))/32"
    
    wg genkey | tee ${CLIENT_NAME}_private.key | wg pubkey > ${CLIENT_NAME}_public.key
    CLIENT_PRIV=$(cat ${CLIENT_NAME}_private.key)
    CLIENT_PUB=$(cat ${CLIENT_NAME}_public.key)
    
    # Добавляем peer в конфиг сервера
    cat >> /etc/amneziawg/awg0.conf <<EOF

[Peer]
PublicKey = ${CLIENT_PUB}
AllowedIPs = ${CLIENT_IP}
EOF
    
    # Создаём клиентский конфиг с параметрами обфускации
    cat > ${CLIENT_NAME}.conf <<EOF
[Interface]
PrivateKey = ${CLIENT_PRIV}
Address = ${CLIENT_IP}
DNS = ${DNS_SERVERS}

[Peer]
PublicKey = ${SERVER_PUB}
Endpoint = ${EXTERNAL_IP}:${PORT}
AllowedIPs = 0.0.0.0/0
Jc = ${JC}
Jmin = ${JMIN}
Jmax = ${JMAX}
S1 = ${S1}
S2 = ${S2}
S3 = ${S3}
S4 = ${S4}
H1 = ${H1}
H2 = ${H2}
H3 = ${H3}
H4 = ${H4}
I1 = ${I1}
I2 = ${I2}
I3 = ${I3}
I4 = ${I4}
I5 = ${I5}
EOF
    
    chmod 600 ${CLIENT_NAME}*.key ${CLIENT_NAME}.conf
    log_info "Создан клиент ${CLIENT_NAME} с IP ${CLIENT_IP}"
done

systemctl restart wg-quick@awg0
log_success "Клиенты добавлены."

# --- Упаковка конфигов в zip ---
cd /root/awg-clients
zip -q clients.zip *.conf
cd /

# --- Запуск временного веб-сервера ---
log_info "Запускаем временный веб-сервер на порту ${WEB_PORT}..."
cd /root/awg-clients
python3 -m http.server ${WEB_PORT} --bind 0.0.0.0 &
HTTP_PID=$!
cd /

# Генерируем токен (просто для красоты)
TOKEN=$(openssl rand -hex 12 2>/dev/null || echo "noopenssl")
echo ""
echo "🔑 Скачайте конфиги по ссылке:"
echo "👉 http://${EXTERNAL_IP}:${WEB_PORT}/clients.zip?token=${TOKEN}"
echo "⏳ Время ожидания: ${WAIT_SECONDS} секунд."
if [ "$WAIT_SECONDS" -eq 0 ]; then
    echo "Нажмите Enter, когда скачаете конфиги, чтобы продолжить блокировку..."
    read -r
else
    echo "Сервер остановится автоматически через ${WAIT_SECONDS} секунд."
fi
echo "⚠️  ВНИМАНИЕ: После этого SSH будет заблокирован (если не установлен KEEP_SSH=true), и доступ будет только через VPN."

# --- Ожидание ---
if [ "$WAIT_SECONDS" -gt 0 ]; then
    sleep "$WAIT_SECONDS"
else
    # Ждём нажатия Enter
    read -r
fi

# --- Остановка веб-сервера и удаление временного правила UFW ---
kill $HTTP_PID 2>/dev/null || true
ufw delete allow ${WEB_PORT}/tcp 2>/dev/null || true

# --- Жёсткая блокировка (если требуется) ---
if [ "$KEEP_SSH" != "true" ]; then
    log_info "Блокируем всё, кроме AmneziaWG и необходимых исходящих портов..."
    ufw --force reset
    ufw default deny incoming
    ufw default deny outgoing
    ufw allow out on ${INTERFACE} to any port 53 proto udp comment "DNS"
    ufw allow out on ${INTERFACE} to any port 80 proto tcp comment "HTTP"
    ufw allow out on ${INTERFACE} to any port 443 proto tcp comment "HTTPS"
    ufw allow in on ${INTERFACE} to any port ${PORT} proto udp comment "AmneziaWG"
    ufw allow out on ${INTERFACE} from any to any port ${PORT} proto udp comment "AmneziaWG-out"
    ufw --force enable
    log_success "Firewall настроен: только порт ${PORT} (UDP) доступен для входящих."
else
    log_warn "SSH оставлен открытым (KEEP_SSH=true)."
fi

echo ""
echo "✅ Установка завершена."
if [ "$KEEP_SSH" != "true" ]; then
    echo "🔒 SSH теперь заблокирован. Подключайтесь через AmneziaWG или консоль провайдера."
fi
echo "📁 Клиентские конфиги находятся в /root/awg-clients/ (уже скачаны)."
