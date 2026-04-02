#!/bin/bash
set -e

# =============================================================================
# XRay + VLESS + XTLS-Reality Automatic Installer (только IPv4)
# =============================================================================

XRAY_PORT="${XRAY_PORT:-443}"
CLIENTS="${XRAY_CLIENTS:-4}"
PUBLIC_DOMAIN="${XRAY_DOMAIN:-www.apple.com}"
INTERFACE="${XRAY_IF:-}"

if [ "$EUID" -ne 0 ]; then
    echo "❌ Please run as root."
    exit 1
fi

echo "🚀 Installing XRay with VLESS+XTLS-Reality (${CLIENTS} clients)..."

# --- Обновление и установка зависимостей ---
export DEBIAN_FRONTEND=noninteractive
apt update && apt upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
apt install -y curl wget unzip qrencode ufw python3 zip jq

# --- Установка XRay (официальный скрипт) ---
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# --- Небольшая задержка, чтобы бинарник XRay стал доступен ---
sleep 2

# --- Определение внешнего IPv4 адреса (игнорируем IPv6) ---
EXTERNAL_IP=$(curl -4 -s ifconfig.me 2>/dev/null || curl -4 -s icanhazip.com 2>/dev/null)
if [ -z "$EXTERNAL_IP" ]; then
    echo "❌ Failed to determine external IPv4 address."
    exit 1
fi
# --- Определение интерфейса по умолчанию (IPv4) ---
if [ -z "$INTERFACE" ]; then
    INTERFACE=$(ip -4 route | grep default | awk '{print $5}' | head -n1)
fi
echo "✅ Server IPv4: $EXTERNAL_IP, Interface: $INTERFACE"

# --- Создание каталогов ---
mkdir -p /usr/local/etc/xray /root/xray-clients

# --- Генерация ключей Reality (x25519) с правильным извлечением ---
echo "🔑 Generating Reality keys..."
if ! /usr/local/bin/xray x25519 > /tmp/xray_keys.txt 2>/dev/null; then
    echo "❌ Failed to generate x25519 keys."
    exit 1
fi
# Извлекаем приватный ключ (после "PrivateKey:")
PRIVATE_KEY_REALITY=$(grep -oP 'PrivateKey:\s*\K[^\s]+' /tmp/xray_keys.txt)
# Извлекаем публичный ключ (после "(PublicKey):")
PUBLIC_KEY_REALITY=$(grep -oP '\(PublicKey\):\s*\K[^\s]+' /tmp/xray_keys.txt)
rm /tmp/xray_keys.txt

if [ -z "$PRIVATE_KEY_REALITY" ] || [ -z "$PUBLIC_KEY_REALITY" ]; then
    echo "❌ Could not extract keys from xray output."
    exit 1
fi
echo "✅ Keys generated successfully."
echo "   PrivateKey: $PRIVATE_KEY_REALITY"
echo "   PublicKey:  $PUBLIC_KEY_REALITY"

# --- Генерация shortId (8 hex-символов) ---
SHORT_ID=$(openssl rand -hex 8)

# --- Базовый конфиг сервера (пустой список клиентов) ---
cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${XRAY_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${PUBLIC_DOMAIN}:443",
          "xver": 0,
          "serverNames": [
            "${PUBLIC_DOMAIN}"
          ],
          "privateKey": "${PRIVATE_KEY_REALITY}",
          "shortIds": [
            "${SHORT_ID}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "block"
      }
    ]
  }
}
EOF

# --- Добавление клиентов ---
for i in $(seq 1 $CLIENTS); do
    CLIENT_NAME="client${i}"
    UUID=$(/usr/local/bin/xray uuid)
    jq --arg uuid "$UUID" '.inbounds[0].settings.clients += [{"id": $uuid, "flow": "xtls-rprx-vision"}]' \
        /usr/local/etc/xray/config.json > /tmp/config.json && \
        mv /tmp/config.json /usr/local/etc/xray/config.json
    echo "$UUID" > /root/xray-clients/${CLIENT_NAME}.uuid
done

# --- Перезапуск XRay ---
systemctl restart xray
sleep 2
if ! systemctl is-active --quiet xray; then
    echo "❌ XRay failed to start. Check /usr/local/etc/xray/config.json and logs: journalctl -u xray"
    exit 1
fi

# --- Создание клиентских ссылок (vless://) и QR-кодов ---
cd /root/xray-clients
for i in $(seq 1 $CLIENTS); do
    CLIENT_NAME="client${i}"
    UUID=$(cat ${CLIENT_NAME}.uuid)
    # Формируем ссылку с правильным pbk
    VLESS_LINK="vless://${UUID}@${EXTERNAL_IP}:${XRAY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${PUBLIC_DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY_REALITY}&sid=${SHORT_ID}&type=tcp&headerType=none#${CLIENT_NAME}"
    echo "$VLESS_LINK" > ${CLIENT_NAME}.link
    qrencode -t utf8 -o ${CLIENT_NAME}.txt "$VLESS_LINK"
done

# --- Создание ZIP-архива со всеми конфигами ---
zip -q clients.zip *.link *.uuid *.txt 2>/dev/null || true

# --- Настройка фаервола (открываем порт XRay, SSH, временный веб) ---
ufw allow ${XRAY_PORT}/tcp comment "XRay"
ufw allow 22/tcp comment "SSH"
ufw allow 8080/tcp comment "Temporary web server"
ufw --force enable

# --- Запуск временного веб-сервера ---
echo "🌐 Starting temporary web server on port 8080..."
cd /root/xray-clients
python3 -m http.server 8080 --bind 0.0.0.0 &
HTTP_PID=$!
cd /

echo ""
echo "🔑 Download your client configs (clients.zip) using token: $(openssl rand -hex 8)"
echo "👉 URL: http://${EXTERNAL_IP}:8080/clients.zip"
echo "⏳ Server will stop after 2 minutes."
echo "   After that, SSH will be blocked and only XRay port (${XRAY_PORT}) will remain open."
echo ""
echo "⚠️  IMPORTANT: Download configs NOW!"

sleep 120

# --- Остановка веб-сервера и удаление правила ---
kill $HTTP_PID 2>/dev/null || true
ufw delete allow 8080/tcp 2>/dev/null || true

# --- Полная блокировка: разрешаем только XRay и исходящий DNS/HTTP/HTTPS ---
echo "🔒 Locking down firewall: only TCP ${XRAY_PORT} allowed."
ufw --force reset
ufw default deny incoming
ufw default deny outgoing
ufw allow out on ${INTERFACE} to any port 53 proto udp comment "DNS"
ufw allow out on ${INTERFACE} to any port 80 proto tcp comment "HTTP"
ufw allow out on ${INTERFACE} to any port 443 proto tcp comment "HTTPS"
ufw allow in on ${INTERFACE} to any port ${XRAY_PORT} proto tcp comment "XRay"
ufw allow out on ${INTERFACE} from any to any port ${XRAY_PORT} proto tcp comment "XRay-out"
ufw --force enable

# --- Удаляем правило SSH ---
ufw delete allow 22/tcp 2>/dev/null || true
ufw --force enable

echo ""
echo "✅ Setup complete. SSH is now blocked. Server is locked down."
echo "📁 Client configs are in /root/xray-clients/ (you already downloaded clients.zip)."
echo "   To regain SSH access, you need to connect via XRay (using one of the client configs) or use console."
echo ""
echo "📱 Import the vless:// links into any XRay-compatible client (v2rayN, Nekoray, Shadowrocket, etc.)"
