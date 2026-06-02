#!/bin/bash

# Send Telegram notification using bot
# Version 0.3

# Make sure we run only once
[ ! -e /tmp/telegram-send.log ] || exit 0

exec >> /tmp/telegram-send.log 2>&1
echo "[telegram-send] args:[${@}], started at [$(date)]"

# Make sure token file is valid
telegram_bot_token=~/.telegram_bot
if [ ! -r "$telegram_bot_token" ]; then
    echo "[telegram-send] No .telegram_bot config found! Aborting"
    exit 1
fi
. "$telegram_bot_token"
if [ ! -n "${TOKEN}" ] || [ ! -n "${CHAT_ID}" ]; then
    echo "[telegram-send] No valid telegram_bot token or chat_id! Aborting"
    exit 1
fi

# Wait for network
if [ -x /usr/bin/nm-online ]; then
    /usr/bin/nm-online --timeout 300 > /dev/null
elif [ -x /usr/lib/systemd/systemd-networkd-wait-online ]; then
    /usr/lib/systemd/systemd-networkd-wait-online --timeout=300
fi

# Configuration
name="$(uname -nr)"
src="$(ip route get 1.1.1.1 | awk '{print $7; exit}')"
dev="$(ip route get 1.1.1.1 | awk '{print $5; exit}')"
drv="$(basename "$(readlink -f "/sys/class/net/${dev}/device/driver")")"

ext="$(curl -s ifconfig.me)"

# Read default message from token file if no argument is given
message=$1
[ -n "${message}" ] || message=$MESSAGE

echo "[telegram-send] host:[${name}] dev:[${dev}] drv:[${drv}] src:[${src}] ext:[${ext}] ready at [$(date)]."

# Send message using curl
curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
    -d "chat_id=$CHAT_ID" \
    -d "text= $message @ \`host:[${name}] dev:[${dev}] drv:[${drv}] src:[${src}] ext:[${ext}]\`" \
    -d "parse_mode=Markdown" > /dev/null

echo "[telegram-send] message:[${message}] sent at [$(date)]."
