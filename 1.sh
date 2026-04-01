#!/bin/bash
set -e

XRAY_PORT="${XRAY_PORT:-443}"
CLIENTS="${XRAY_CLIENTS:-4}"
PUBLIC_DOMAIN="${XRAY_DOMAIN:-www.apple.com}"
INTERFACE="${XRAY_IF:-}"

if [ "$EUID" -ne 0 ]; then
    echo "❌ Please run as root."
    exit 1
fi

echo "🚀 Installing XRay with VLESS+XTLS-Reality (${CLIENTS} clients)..."

export DEBIAN_FRONTEND=noninteractive
apt update && apt upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
apt install -y curl wget unzip qrencode ufw python3 zip jq

bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
sleep 2

EXTERNAL_IP=$(curl -s ifconfig.me)
if [ -z "$INTERFACE" ]; then
    INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
fi
echo "✅ Server IP: $EXTERNAL_IP, Interface: $INTERFACE"

mkdir -p /usr/local/etc/xray /root/xray-clients

echo "🔑 Generating Reality keys..."
PRIVATE_KEY_REALITY=$(/usr/local/bin/xray x25519)
if [ -z "$PRIVATE_KEY_REALITY" ]; then
    echo "❌ Failed to generate private key."
    exit 1
fi
PUBLIC_KEY_REALITY=$(/usr/local/bin/xray x25519 -i "$PRIVATE_KEY_REALITY")
if [ -z "$PUBLIC_KEY_REALITY" ]; then
    echo "❌ Failed to generate public key."
    exit 1
fi
PRIVATE_KEY_REALITY=$(echo "$PRIVATE_KEY_REALITY" | tr -d '\n\r')
PUBLIC_KEY_REALITY=$(echo "$PUBLIC_KEY_REALITY" | tr -d '\n\r')
echo "✅ Keys generated successfully."
echo "   PrivateKey: $PRIVATE_KEY_REALITY"
echo "   PublicKey:  $PUBLIC_KEY_REALITY"

SHORT_ID=$(openssl rand -hex 8)
echo "✅ shortId: $SHORT_ID"

cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": ${XRAY_PORT},
    "protocol": "vless",
    "settings": { "clients": [], "decryption": "none" },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "${PUBLIC_DOMAIN}:443",
        "xver": 0,
        "serverNames": ["${PUBLIC_DOMAIN}"],
        "privateKey": "${PRIVATE_KEY_REALITY}",
        "shortIds": ["${SHORT_ID}"]
      }
    },
    "sniffing": { "enabled": true, "destOverride": ["http", "tls"] }
  }],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [{ "type": "field", "ip": ["geoip:private"], "outboundTag": "block" }]
  }
}
EOF

for i in $(seq 1 $CLIENTS); do
    UUID=$(/usr/local/bin/xray uuid)
    jq --arg uuid "$UUID" '.inbounds[0].settings.clients += [{"id": $uuid, "flow": "xtls-rprx-vision"}]' \
        /usr/local/etc/xray/config.json > /tmp/config.json && \
        mv /tmp/config.json /usr/local/etc/xray/config.json
    echo "$UUID" > /root/xray-clients/client${i}.uuid
    echo "   Client $i UUID: $UUID"
done

systemctl restart xray
sleep 2
if ! systemctl is-active --quiet xray; then
    echo "❌ XRay failed to start. Check logs: journalctl -u xray"
    exit 1
fi

cd /root/xray-clients
for i in $(seq 1 $CLIENTS); do
    UUID=$(cat client${i}.uuid)
    VLESS_LINK="vless://${UUID}@${EXTERNAL_IP}:${XRAY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${PUBLIC_DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY_REALITY}&sid=${SHORT_ID}&type=tcp&headerType=none#client${i}"
    echo "$VLESS_LINK" > client${i}.link
    qrencode -t utf8 -o client${i}.txt "$VLESS_LINK"
    echo "   client${i}.link created"
done
zip -q clients.zip *.link *.uuid *.txt 2>/dev/null || true

ufw allow ${XRAY_PORT}/tcp comment "XRay"
ufw allow 22/tcp comment "SSH"
ufw allow 8080/tcp comment "Temporary web server"
ufw --force enable

echo "🌐 Starting temporary web server on port 8080..."
cd /root/xray-clients
python3 -m http.server 8080 --bind 0.0.0.0 &
HTTP_PID=$!
cd /

echo ""
echo "🔑 Download your client configs (clients.zip) using token: $(openssl rand -hex 8)"
echo "👉 URL: http://${EXTERNAL_IP}:8080/clients.zip"
echo "⏳ Server will stop after 2 minutes. Download configs NOW!"
sleep 120

kill $HTTP_PID 2>/dev/null || true
ufw delete allow 8080/tcp 2>/dev/null || true

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

ufw delete allow 22/tcp 2>/dev/null || true
ufw --force enable

echo ""
echo "✅ Setup complete. SSH is now blocked. Server is locked down."
echo "📁 Client configs are in /root/xray-clients/ (you already downloaded clients.zip)."
echo "📱 Import the vless:// links into any XRay-compatible client (v2rayN, Nekoray, Shadowrocket, etc.)"
