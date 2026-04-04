#!/bin/bash
# Финальная установка бота XRay с управлением клиентами

set -e

if [ "$EUID" -ne 0 ]; then
    echo "❌ Запустите от root"
    exit 1
fi

if [ -z "$TELEGRAM_TOKEN" ] || [ -z "$CHAT_ID" ]; then
    echo "❌ Использование: TELEGRAM_TOKEN=... CHAT_ID=... bash $0"
    exit 1
fi

echo "🤖 Установка бота для управления XRay..."
echo "   Токен: ${TELEGRAM_TOKEN:0:10}..."
echo "   Chat ID: $CHAT_ID"

# Установка пакетов
apt update && apt upgrade -y
apt install -y curl wget unzip ufw python3 python3-venv python3-pip git jq

# Установка xray-auc
echo "📥 Установка xray-auc..."
wget -q --show-progress -O /usr/local/bin/xray-auc https://github.com/archer-v/xray-auc/releases/download/v0.6.5/xray-auc-linux-amd64
chmod +x /usr/local/bin/xray-auc

# Определение inbound tag
INBOUND_TAG=$(jq -r '.inbounds[0].tag' /usr/local/etc/xray/config.json 2>/dev/null || echo "vless-inbound")
[ "$INBOUND_TAG" = "null" ] && INBOUND_TAG="vless-inbound"
echo "   Inbound tag: $INBOUND_TAG"

# Клонирование бота
rm -rf /opt/xray-traffic-bot
git clone https://github.com/maxgalzer/xray-traffic-bot.git /opt/xray-traffic-bot
cd /opt/xray-traffic-bot

# Виртуальное окружение
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt
deactivate

# Конфиг бота
cat > /opt/xray-traffic-bot/config.py <<EOF
TOKEN = "$TELEGRAM_TOKEN"
CHAT_ID = "$CHAT_ID"
ACCESS_LOG = "/var/log/xray/access.log"
SUMMARY_INTERVAL = 6
EOF

# Создаём модуль admin_commands.py
cat > /opt/xray-traffic-bot/admin_commands.py <<ADMINEOF
import subprocess
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import ContextTypes, CommandHandler, CallbackQueryHandler

INBOUND_TAG = "$INBOUND_TAG"
CHAT_ID = "$CHAT_ID"

def get_users():
    try:
        r = subprocess.run(['/usr/local/bin/xray-auc', 'listUsers', '-t', INBOUND_TAG],
                           capture_output=True, text=True, timeout=10)
        if r.returncode == 0:
            return [l.strip() for l in r.stdout.split('\n') if l.strip()]
        return []
    except:
        return []

def add_user(email, uuid=None):
    cmd = ['/usr/local/bin/xray-auc', 'addUser', '-p', 'vless', '-e', email, '--flow', 'xtls-rprx-vision', '-t', INBOUND_TAG]
    if uuid:
        cmd.extend(['-s', uuid])
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        return r.returncode == 0, r.stderr
    except Exception as e:
        return False, str(e)

def remove_user(email):
    try:
        r = subprocess.run(['/usr/local/bin/xray-auc', 'rmUser', '-e', email, '-t', INBOUND_TAG],
                           capture_output=True, text=True, timeout=10)
        return r.returncode == 0, r.stderr
    except Exception as e:
        return False, str(e)

def show_user(email):
    try:
        r = subprocess.run(['/usr/local/bin/xray-auc', 'showUser', '-e', email, '-t', INBOUND_TAG],
                           capture_output=True, text=True, timeout=10)
        if r.returncode == 0:
            return r.stdout
        return None
    except:
        return None

async def list_users(update, context):
    if str(update.effective_chat.id) != CHAT_ID: return
    users = get_users()
    if not users:
        await update.message.reply_text("📭 Нет активных клиентов.")
    else:
        msg = "📋 *Список клиентов:*\n" + "\n".join(f"• `{u}`" for u in users)
        await update.message.reply_text(msg, parse_mode="Markdown")

async def add_client(update, context):
    if str(update.effective_chat.id) != CHAT_ID: return
    args = context.args
    if len(args) < 1:
        await update.message.reply_text("❌ Использование: /add_client <email> [uuid]")
        return
    email = args[0]
    uuid = args[1] if len(args) > 1 else None
    ok, err = add_user(email, uuid)
    if ok:
        await update.message.reply_text(f"✅ Клиент `{email}` добавлен.", parse_mode="Markdown")
    else:
        await update.message.reply_text(f"❌ Ошибка: {err}")

async def del_client(update, context):
    if str(update.effective_chat.id) != CHAT_ID: return
    args = context.args
    if len(args) < 1:
        await update.message.reply_text("❌ Использование: /del_client <email>")
        return
    email = args[0]
    ok, err = remove_user(email)
    if ok:
        await update.message.reply_text(f"✅ Клиент `{email}` удалён.", parse_mode="Markdown")
    else:
        await update.message.reply_text(f"❌ Ошибка: {err}")

async def show_user_cmd(update, context):
    if str(update.effective_chat.id) != CHAT_ID: return
    args = context.args
    if len(args) < 1:
        await update.message.reply_text("❌ Использование: /show_user <email>")
        return
    email = args[0]
    cfg = show_user(email)
    if cfg:
        await update.message.reply_text(f"🔧 Конфигурация для `{email}`:\n```\n{cfg}\n```", parse_mode="Markdown")
    else:
        await update.message.reply_text(f"❌ Клиент `{email}` не найден.", parse_mode="Markdown")

async def menu(update, context):
    if str(update.effective_chat.id) != CHAT_ID: return
    keyboard = [
        [InlineKeyboardButton("📊 Статус", callback_data="status")],
        [InlineKeyboardButton("📋 Список клиентов", callback_data="list")],
        [InlineKeyboardButton("➕ Добавить клиента", callback_data="add_prompt")],
        [InlineKeyboardButton("❌ Удалить клиента", callback_data="del_prompt")],
        [InlineKeyboardButton("🔍 Показать конфиг", callback_data="show_prompt")],
    ]
    await update.message.reply_text("🤖 *Панель управления XRay*", parse_mode="Markdown",
                                    reply_markup=InlineKeyboardMarkup(keyboard))

async def button_handler(update, context):
    query = update.callback_query
    await query.answer()
    data = query.data
    if data == "status":
        await query.message.reply_text("Статус сервера: работает (заглушка)")
    elif data == "list":
        await list_users(update, context)
    elif data == "add_prompt":
        await query.edit_message_text("Введите команду: `/add_client <email> [uuid]`", parse_mode="Markdown")
    elif data == "del_prompt":
        await query.edit_message_text("Введите команду: `/del_client <email>`", parse_mode="Markdown")
    elif data == "show_prompt":
        await query.edit_message_text("Введите команду: `/show_user <email>`", parse_mode="Markdown")

def register_handlers(app):
    app.add_handler(CommandHandler("start", menu))
    app.add_handler(CommandHandler("list", list_users))
    app.add_handler(CommandHandler("add_client", add_client))
    app.add_handler(CommandHandler("del_client", del_client))
    app.add_handler(CommandHandler("show_user", show_user_cmd))
    app.add_handler(CallbackQueryHandler(button_handler))
ADMINEOF

# Интеграция в bot.py
if ! grep -q "from admin_commands import register_handlers" /opt/xray-traffic-bot/bot.py; then
    echo -e "\n# Добавлено для управления клиентами\nfrom admin_commands import register_handlers\nregister_handlers(app)" >> /opt/xray-traffic-bot/bot.py
fi

# Сервис systemd
cat > /etc/systemd/system/xray-traffic-bot.service <<EOF
[Unit]
Description=XRay Bot
After=network.target xray.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/xray-traffic-bot
ExecStart=/opt/xray-traffic-bot/venv/bin/python /opt/xray-traffic-bot/bot.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable xray-traffic-bot.service
systemctl restart xray-traffic-bot.service

echo "✅ Установка завершена!"
echo "📱 Отправьте боту /start в Telegram"
