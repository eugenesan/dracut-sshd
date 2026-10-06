#!/bin/bash

# 2026, Eugene San (eugenesan) <eugenesan@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later

# check() controls if the module is included. 0 means always include.
check() {
    return 0
}

# depends() defines other module prerequisites.
depends() {
    return 0
}

# install() instructs dracut where to put your payload script.
install() {
    # find token file
    if [ -e /root/.telegram_bot ]; then
        telegram_bot_token=/root/.telegram_bot
    elif [ -e ${SUDO_HOME}/.telegram_bot ]; then
        telegram_bot_token=${SUDO_HOME}/.telegram_bot
    fi

    # make sure token file is valid
    if [ ! -r "$telegram_bot_token" ]; then
        dfatal "No telegram bot token file found!"
        return 1
    fi
    . "$telegram_bot_token"
    if [ ! -n "${TOKEN}" ] || [ ! -n "${CHAT_ID}" ]; then
        dfatal "No valid telegram bot token!"
        return 1
    fi

    # install script
    inst_binary /usr/bin/telegram-send

    # install token config file
    /usr/bin/install -m 600 "$telegram_bot_token" \
            "$initdir/root/.telegram_bot"

    # install service for telegram send script
    inst_simple "${moddir}/telegram-send.service" "$systemdsystemunitdir/telegram-send.service"
    systemctl -q --root "$initdir" enable telegram-send
}
