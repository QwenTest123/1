#!/bin/bash
set -e

# =============================================================================
# AmneziaWG Automatic Installer – устойчивая версия
# =============================================================================

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

TOKEN=$(openssl rand -hex 12)

if [ "$EUID" -ne 0 ]; then
    echo "❌ Please run as root."
    exit 1
fi

echo "🚀 Installing AmneziaWG with $CLIENTS clients..."

# --- Неинтерактивное обновление и установка зависимостей ---
export DEBIAN_FRONTEND=noninteractive
apt update && apt upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
apt install -y curl wget software-properties-common qrencode ufw python3 zip wireguard-tools

# --- Добавление репозитория Amnezia и установка ---
add-apt-repository ppa:amnezia/ppa -y
apt update
apt install -y amneziawg

# --- Проверка наличия утилит wg и awg ---
if ! command -v wg &> /dev/null; then
    echo "❌ wg command not found. Installation of wireguard-tools might have failed."
    exit 1
fi

# --- Определение внешнего IP и сетевого интерфейса ---
EXTERNAL_IP=$(curl -s ifconfig.me)
if [ -z "$INTERFACE" ]; then
    INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
fi
echo "✅ Server IP: $EXTERNAL_IP, Interface: $INTERFACE"

# --- Создание каталогов и генерация ключей сервера ---
mkdir -p /etc/wireguard/keys
cd /etc/wireguard/keys
wg genkey | tee server_private.key | wg pubkey > server_public.key
chmod 600 server_private.key server_public.key
SERVER_PRIV=$(cat server_private.key)
SERVER_PUB=$(cat server_public.key)

# --- Подготовка подсети (только для /24) ---
SUBNET_BASE=$(echo $SUBNET | cut -d '/' -f1 | cut -d '.' -f1-3)
SUBNET_MASK=$(echo $SUBNET | cut -d '/' -f2)
SERVER_ADDR="${SUBNET_BASE}.1/${SUBNET_MASK}"

# --- Создание конфигурации сервера в /etc/wireguard/awg0.conf ---
cat > /etc/wireguard/awg0.conf <<EOF
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

# --- Настройка базового фаервола (разрешаем VPN, SSH и временный веб-сервер) ---
ufw allow ${PORT}/udp comment "AmneziaWG"
ufw allow 22/tcp comment "SSH"
ufw allow 8080/tcp comment "Temporary web server"
ufw --force enable

# --- Запуск сервиса ---
systemctl enable wg-quick@awg0
systemctl start wg-quick@awg0
sleep 2
if ! systemctl is-active --quiet wg-quick@awg0; then
    echo "❌ AmneziaWG failed to start. Check /etc/wireguard/awg0.conf and logs: journalctl -xeu wg-quick@awg0"
    exit 1
fi

# --- Создание клиентов ---
mkdir -p /root/awg-clients
cd /etc/wireguard/keys

CLIENT_IP_START=2   # первый клиент получает .2
for i in $(seq 1 $CLIENTS); do
    CLIENT_NAME="client${i}"
    CLIENT_IP="${SUBNET_BASE}.$((CLIENT_IP_START + i - 1))/32"

    wg genkey | tee ${CLIENT_NAME}_private.key | wg pubkey > ${CLIENT_NAME}_public.key
    CLIENT_PRIV=$(cat ${CLIENT_NAME}_private.key)
    CLIENT_PUB=$(cat ${CLIENT_NAME}_public.key)

    cat >> /etc/wireguard/awg0.conf <<EOF

[Peer]
PublicKey = ${CLIENT_PUB}
AllowedIPs = ${CLIENT_IP}
EOF

    cat > /root/awg-clients/${CLIENT_NAME}.conf <<EOF
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

    chmod 600 /root/awg-clients/${CLIENT_NAME}.conf
    chmod 600 ${CLIENT_NAME}_*.key
done

systemctl restart wg-quick@awg0

# --- Создание ZIP-архива с конфигами клиентов ---
cd /root/awg-clients
zip -q clients.zip *.conf
cd /

# --- Запуск временного веб-сервера ---
echo "🌐 Starting temporary web server on port 8080..."
cd /root/awg-clients
python3 -m http.server 8080 --bind 0.0.0.0 &
HTTP_PID=$!
cd /

echo ""
echo "🔑 Download your configs using token: ${TOKEN}"
echo "👉 URL: http://${EXTERNAL_IP}:8080/clients.zip?token=${TOKEN}"
echo "⏳ Server will stop after 2 minutes."
echo "   After that, SSH will be blocked and only AmneziaWG port will remain open."
echo ""
echo "⚠️  IMPORTANT: Download configs NOW!"

sleep 120

# --- Остановка веб-сервера и удаление правила ---
kill $HTTP_PID 2>/dev/null || true
ufw delete allow 8080/tcp 2>/dev/null || true

# --- Полная блокировка: разрешаем только AmneziaWG и исходящий DNS/HTTP/HTTPS ---
echo "🔒 Locking down firewall: only UDP ${PORT} allowed."
ufw --force reset
ufw default deny incoming
ufw default deny outgoing
ufw allow out on ${INTERFACE} to any port 53 proto udp comment "DNS"
ufw allow out on ${INTERFACE} to any port 80 proto tcp comment "HTTP"
ufw allow out on ${INTERFACE} to any port 443 proto tcp comment "HTTPS"
ufw allow in on ${INTERFACE} to any port ${PORT} proto udp comment "AmneziaWG"
ufw allow out on ${INTERFACE} from any to any port ${PORT} proto udp comment "AmneziaWG-out"
ufw --force enable

# --- Удаляем правило SSH, если оно ещё есть ---
ufw delete allow 22/tcp 2>/dev/null || true
ufw --force enable

echo ""
echo "✅ Setup complete. SSH is now blocked. Server is locked down."
echo "📁 Client configs are in /root/awg-clients/ (but you already downloaded them)."
echo "   To regain SSH access, you need to connect via VPN or use console."
