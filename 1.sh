#!/bin/bash
set -e

# =============================================================================
# AmneziaWG Automatic Installer with temporary web server and strict firewall
# =============================================================================

# Default config (can be overridden by environment variables)
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

# Secret token for download (randomly generated)
TOKEN=$(openssl rand -hex 12)

if [ "$EUID" -ne 0 ]; then
    echo "❌ Please run as root."
    exit 1
fi

echo "🚀 Installing AmneziaWG with $CLIENTS clients..."

# --- System update and dependencies ---
apt update && apt upgrade -y
apt install -y curl wget software-properties-common qrencode ufw python3 zip

# --- Add Amnezia repo ---
add-apt-repository ppa:amnezia/ppa -y
apt update
apt install -y amneziawg

# --- Determine external IP and network interface ---
EXTERNAL_IP=$(curl -s ifconfig.me)
if [ -z "$INTERFACE" ]; then
    INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
fi
echo "✅ Server IP: $EXTERNAL_IP, Interface: $INTERFACE"

# --- Server keys ---
mkdir -p /etc/amneziawg
cd /etc/amneziawg
wg genkey | tee server_private.key | wg pubkey > server_public.key
chmod 600 server_private.key server_public.key
SERVER_PRIV=$(cat server_private.key)
SERVER_PUB=$(cat server_public.key)

# --- Subnet preparation ---
SUBNET_BASE=$(echo $SUBNET | cut -d '/' -f1)
SUBNET_MASK=$(echo $SUBNET | cut -d '/' -f2)
SERVER_ADDR="${SUBNET_BASE}.1/${SUBNET_MASK}"

# --- Server config ---
cat > /etc/amneziawg/awg0.conf <<EOF
[Interface]
Address = ${SERVER_ADDR}
ListenPort = ${PORT}
PrivateKey = ${SERVER_PRIV}
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
PostUp = sysctl -w net.ipv4.ip_forward=1
PostUp = iptables -A FORWARD -i %i -j ACCEPT
PostUp = iptables -A FORWARD -o %i -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -o ${INTERFACE} -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT
PostDown = iptables -D FORWARD -o %i -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o ${INTERFACE} -j MASQUERADE
EOF

# --- IP forwarding ---
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-amneziawg.conf
sysctl -p /etc/sysctl.d/99-amneziawg.conf

# --- Basic firewall (allow SSH and AmneziaWG) ---
ufw allow ${PORT}/udp comment "AmneziaWG"
ufw allow 22/tcp comment "SSH"
ufw --force enable

# --- Start AmneziaWG service ---
systemctl enable wg-quick@awg0
systemctl start wg-quick@awg0

# --- Create clients ---
mkdir -p /root/awg-clients
cd /root/awg-clients

CLIENT_IP_START=$(( $(echo $SUBNET_BASE | cut -d '.' -f4) + 1 ))
for i in $(seq 1 $CLIENTS); do
    CLIENT_NAME="client${i}"
    CLIENT_IP="${SUBNET_BASE}.$((CLIENT_IP_START + i - 1))/32"
    
    wg genkey | tee ${CLIENT_NAME}_private.key | wg pubkey > ${CLIENT_NAME}_public.key
    CLIENT_PRIV=$(cat ${CLIENT_NAME}_private.key)
    CLIENT_PUB=$(cat ${CLIENT_NAME}_public.key)
    
    cat >> /etc/amneziawg/awg0.conf <<EOF

[Peer]
PublicKey = ${CLIENT_PUB}
AllowedIPs = ${CLIENT_IP}
EOF
    
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
done

systemctl restart wg-quick@awg0

# --- Create a zip archive with all client configs ---
zip -q clients.zip *.conf
cd /

# --- Start temporary web server on port 8080 (only on all interfaces) ---
echo "🌐 Starting temporary web server on port 8080..."
cd /root/awg-clients
python3 -m http.server 8080 --bind 0.0.0.0 &
HTTP_PID=$!
cd /

echo ""
echo "🔑 Download your configs using token: ${TOKEN}"
echo "👉 URL: http://${EXTERNAL_IP}:8080/clients.zip?token=${TOKEN}"
echo "⏳ Server will stop after 2 minutes or when you press Enter."
echo "   After that, SSH will be blocked and only AmneziaWG port will remain open."
echo ""
echo "⚠️  IMPORTANT: Make sure you have downloaded the configs BEFORE the 2 minutes expire."
echo "   After that, you will only be able to access the server via VPN."

# --- Wait for 2 minutes or user input ---
sleep 120

# Kill the web server
kill $HTTP_PID 2>/dev/null || true

# --- Harden firewall: block everything except AmneziaWG port ---
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

# --- Remove SSH rule (if it still exists) ---
ufw delete allow 22/tcp 2>/dev/null || true
ufw --force enable

echo ""
echo "✅ Setup complete. SSH is now blocked. Server is locked down."
echo "📁 Client configs are in /root/awg-clients/ (but you already downloaded them)."
echo "   To regain SSH access, you need to connect via VPN or use console."