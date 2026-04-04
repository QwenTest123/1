#!/bin/bash
set -e

if [ -z "$TELEGRAM_TOKEN" ] || [ -z "$CHAT_ID" ]; then
    echo "❌ Ошибка: не заданы TELEGRAM_TOKEN и CHAT_ID"
    echo "📌 Использование: TELEGRAM_TOKEN=... CHAT_ID=... bash <(curl -s URL)"
    exit 1
fi

echo "🤖 Установка Telegram-бота для мониторинга XRay..."

export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y python3 python3-venv python3-pip git curl

mkdir -p /opt/xray-bot && cd /opt/xray-bot
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install python-telegram-bot==20.7
deactivate

cat > /opt/xray-bot/bot.py <<EOF
import asyncio
import subprocess
import re
import os
from datetime import datetime
from collections import defaultdict

from telegram import Update, BotCommand
from telegram.ext import Application, CommandHandler, ContextTypes

TOKEN = "$TELEGRAM_TOKEN"
CHAT_ID = "$CHAT_ID"
ACCESS_LOG = "/var/log/xray/access.log"

traffic_stats = defaultdict(lambda: {'upload': 0, 'download': 0})

def parse_traffic_from_log():
    stats = defaultdict(lambda: {'upload': 0, 'download': 0})
    try:
        with open(ACCESS_LOG, 'r') as f:
            for line in f:
                match = re.search(r'\[Info\] \[([^\]]+)\].*?\[(\d+) (\d+)\]', line)
                if match:
                    email, up, down = match.groups()
                    stats[email]['upload'] += int(up)
                    stats[email]['download'] += int(down)
    except FileNotFoundError:
        pass
    return stats

def format_bytes(bytes):
    for unit in ['B', 'KB', 'MB', 'GB']:
        if bytes < 1024:
            return f"{bytes:.1f} {unit}"
        bytes /= 1024
    return f"{bytes:.1f} TB"

async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if str(update.effective_chat.id) != CHAT_ID:
        return
    await update.message.reply_text(
        "🤖 *Бот для мониторинга XRay*\n\n"
        "📊 Команды:\n"
        "/stats - Статистика трафика за сегодня\n"
        "/live - Подключения в реальном времени (присылает уведомления)\n"
        "/stop - Остановить уведомления",
        parse_mode="Markdown"
    )

async def stats(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if str(update.effective_chat.id) != CHAT_ID:
        return
    stats = parse_traffic_from_log()
    if not stats:
        await update.message.reply_text("📭 За сегодня нет данных.")
        return
    msg = f"📊 *Статистика за {datetime.now().strftime('%Y-%m-%d')}*\n\n"
    for email, data in stats.items():
        total = data['upload'] + data['download']
        msg += f"👤 {email}\n   ↑ {format_bytes(data['upload'])} ↓ {format_bytes(data['download'])} (всего {format_bytes(total)})\n"
    await update.message.reply_text(msg, parse_mode="Markdown")

async def live(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if str(update.effective_chat.id) != CHAT_ID:
        return
    if 'monitor_task' not in context.bot_data:
        context.bot_data['monitor_task'] = asyncio.create_task(monitor_logs(context.bot, update.effective_chat.id))
        await update.message.reply_text("✅ Отслеживание подключений запущено. /stop для остановки.")
    else:
        await update.message.reply_text("⚠️ Уже запущено.")

async def stop(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if str(update.effective_chat.id) != CHAT_ID:
        return
    if 'monitor_task' in context.bot_data:
        context.bot_data['monitor_task'].cancel()
        del context.bot_data['monitor_task']
        await update.message.reply_text("⏹ Отслеживание остановлено.")
    else:
        await update.message.reply_text("ℹ️ Не было запущено.")

async def monitor_logs(bot, chat_id):
    try:
        proc = await asyncio.create_subprocess_exec('tail', '-F', ACCESS_LOG, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        while True:
            line = await proc.stdout.readline()
            if not line:
                break
            line = line.decode('utf-8').strip()
            match = re.search(r'\[Info\] \[([^\]]+)\] accepted tcp:', line)
            if match:
                email = match.group(1)
                timestamp = datetime.now().strftime("%H:%M:%S")
                await bot.send_message(chat_id=chat_id, text=f"🔔 *Новое подключение*\n👤 Клиент: `{email}`\n🕒 {timestamp}", parse_mode="Markdown")
    except asyncio.CancelledError:
        pass
    except Exception as e:
        await bot.send_message(chat_id=chat_id, text=f"❌ Ошибка: {e}")

def main():
    app = Application.builder().token(TOKEN).build()
    app.add_handler(CommandHandler("start", start))
    app.add_handler(CommandHandler("stats", stats))
    app.add_handler(CommandHandler("live", live))
    app.add_handler(CommandHandler("stop", stop))
    app.run_polling()

if __name__ == "__main__":
    main()
EOF

cat > /etc/systemd/system/xray-bot.service <<EOF
[Unit]
Description=XRay Telegram Bot
After=network.target xray.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/xray-bot
ExecStart=/opt/xray-bot/venv/bin/python /opt/xray-bot/bot.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable xray-bot.service
systemctl start xray-bot.service

echo ""
echo "✅ Установка завершена! Бот запущен."
echo "📱 Отправьте боту /start в Telegram."
