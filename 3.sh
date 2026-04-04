#!/bin/bash
set -e

echo "🤖 Начинаем установку Telegram-бота для мониторинга XRay..."

# --- 1. Запрашиваем токен и chat_id ---
read -p "Введите TELEGRAM_TOKEN (получите у @BotFather): " TELEGRAM_TOKEN
if [ -z "$TELEGRAM_TOKEN" ]; then
    echo "❌ Токен не может быть пустым."
    exit 1
fi

read -p "Введите ваш CHAT_ID (узнайте у @userinfobot): " CHAT_ID
if [ -z "$CHAT_ID" ]; then
    echo "❌ Chat ID не может быть пустым."
    exit 1
fi

# --- 2. Обновляем систему и устанавливаем зависимости ---
export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y python3 python3-venv python3-pip git curl

# --- 3. Создаём папку для бота и переходим в неё ---
mkdir -p /opt/xray-bot && cd /opt/xray-bot

# --- 4. Создаём виртуальное окружение и устанавливаем библиотеку ---
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install python-telegram-bot==20.7
deactivate

# --- 5. Создаём основной скрипт бота с полным функционалом ---
cat > /opt/xray-bot/bot.py <<'EOF'
import asyncio
import subprocess
import re
import os
from datetime import datetime
from collections import defaultdict

from telegram import Update, BotCommand
from telegram.ext import Application, CommandHandler, ContextTypes

# ========== НАСТРОЙКИ ==========
TOKEN = "TELEGRAM_TOKEN_PLACEHOLDER"
CHAT_ID = "CHAT_ID_PLACEHOLDER"
ACCESS_LOG = "/var/log/xray/access.log"
# ===============================

# Словарь для хранения статистики
traffic_stats = defaultdict(lambda: {'upload': 0, 'download': 0})

def parse_traffic_from_log():
    """Парсит лог и возвращает статистику по клиентам."""
    stats = defaultdict(lambda: {'upload': 0, 'download': 0})
    try:
        with open(ACCESS_LOG, 'r') as f:
            for line in f:
                # Формат: 2026/04/04 16:45:01 [Info] [client1] accepted tcp:www.google.com:443 [1000 2000]
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
        await update.message.reply_text("📭 За сегодня нет данных. Убедитесь, что XRay логирует трафик.")
        return
    msg = f"📊 *Статистика за {datetime.now().strftime('%Y-%m-%d')}*\n\n"
    for email, data in stats.items():
        total = data['upload'] + data['download']
        msg += f"👤 {email}\n"
        msg += f"   ↑ Отправлено: {format_bytes(data['upload'])}\n"
        msg += f"   ↓ Получено:  {format_bytes(data['download'])}\n"
        msg += f"   💰 Всего:     {format_bytes(total)}\n\n"
    await update.message.reply_text(msg, parse_mode="Markdown")

async def live(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if str(update.effective_chat.id) != CHAT_ID:
        return
    chat_id = update.effective_chat.id
    # Запускаем фоновую задачу мониторинга, если ещё не запущена
    if 'monitor_task' not in context.bot_data:
        context.bot_data['monitor_task'] = asyncio.create_task(monitor_logs(context.bot, chat_id))
        await update.message.reply_text("✅ Отслеживание подключений запущено. Используйте /stop для остановки.")
    else:
        await update.message.reply_text("⚠️ Отслеживание уже запущено.")

async def stop(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if str(update.effective_chat.id) != CHAT_ID:
        return
    if 'monitor_task' in context.bot_data:
        context.bot_data['monitor_task'].cancel()
        del context.bot_data['monitor_task']
        await update.message.reply_text("⏹ Отслеживание подключений остановлено.")
    else:
        await update.message.reply_text("ℹ️ Отслеживание не было запущено.")

async def monitor_logs(bot, chat_id):
    """Фоновая задача: читает лог и отправляет уведомления о новых подключениях."""
    try:
        proc = await asyncio.create_subprocess_exec(
            'tail', '-F', ACCESS_LOG,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE
        )
        while True:
            line = await proc.stdout.readline()
            if not line:
                break
            line = line.decode('utf-8').strip()
            # Ищем строки с подключениями
            match = re.search(r'\[Info\] \[([^\]]+)\] accepted tcp:', line)
            if match:
                email = match.group(1)
                timestamp = datetime.now().strftime("%H:%M:%S")
                await bot.send_message(
                    chat_id=chat_id,
                    text=f"🔔 *Новое подключение*\n"
                         f"👤 Клиент: `{email}`\n"
                         f"🕒 Время: {timestamp}",
                    parse_mode="Markdown"
                )
    except asyncio.CancelledError:
        pass
    except Exception as e:
        await bot.send_message(chat_id=chat_id, text=f"❌ Ошибка мониторинга: {e}")

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

# Подставляем реальные значения
sed -i "s/TELEGRAM_TOKEN_PLACEHOLDER/$TELEGRAM_TOKEN/g" /opt/xray-bot/bot.py
sed -i "s/CHAT_ID_PLACEHOLDER/$CHAT_ID/g" /opt/xray-bot/bot.py

# --- 6. Создаём systemd сервис для автозапуска ---
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

# --- 7. Запускаем бота ---
systemctl daemon-reload
systemctl enable xray-bot.service
systemctl start xray-bot.service

# --- 8. Финальные сообщения ---
echo ""
echo "✅ Установка Telegram-бота завершена!"
echo "📋 Команды бота:"
echo "   /stats  - Статистика трафика за сегодня"
echo "   /live   - Включить уведомления о новых подключениях"
echo "   /stop   - Выключить уведомления"
echo ""
echo "🔄 Бот автоматически запущен и добавлен в автозагрузку."
echo "📱 Откройте Telegram и отправьте боту команду /start"
