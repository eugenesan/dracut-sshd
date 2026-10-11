#!/bin/bash

# 2026, Eugene San (eugenesan) <eugenesan@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later

# Dracut module: install telegram-send, its token file and its systemd unit,
# so that a boot notification is sent as soon as the initramfs has internet.
#
# Add to /etc/dracut.conf.d (or pass --add-dracutmodules):
#     add_dracutmodules+=" telegram-send "
#
# Token file lookup order (first readable wins):
#     1. $TELEGRAM_BOT_TOKEN         e.g. dracut -f --kver ... (env var)
#     2. /etc/telegram-send/token   packaged or copied by the admin
#     3. $HOME/.telegram_bot        root's or the invoking user's home
#     4. /root/.telegram_bot
#     5. $SUDO_USER's home from passwd(5)
#
# The token ends up inside the initramfs image: treat the image as a secret
# (chmod 600 /boot/initramfs-*.img, prefer a LUKS-encrypted root).

# Print the first readable token file, or fail.
_telegram_token_file() {
	local c entry home

	for c in "${TELEGRAM_BOT_TOKEN}" \
		/etc/telegram-send/token \
		"${HOME}/.telegram_bot" \
		/root/.telegram_bot; do
		if [ -n "${c}" ] && [ -r "${c}" ]; then
			printf '%s\n' "${c}"
			return 0
		fi
	done

	# sudo -H exports SUDO_HOME, plain sudo does not: ask passwd(5) instead.
	if [ -z "${SUDO_HOME}" ] && [ -n "${SUDO_USER}" ]; then
		entry=$(getent passwd "${SUDO_USER}" 2>/dev/null)
		home=${entry#*:}
		home=${home%%:*}
		if [ -n "${home}" ] && [ -r "${home}/.telegram_bot" ]; then
			printf '%s\n' "${home}/.telegram_bot"
			return 0
		fi
	fi

	return 1
}

# check() controls if the module is included. 0 means include, 255 means skip.
# Skipping (instead of failing install()) keeps a missing token from breaking
# the whole dracut run.
check() {
	local token

	if ! token=$(_telegram_token_file); then
		dfatal "telegram-send: no bot token file found (looked at \$TELEGRAM_BOT_TOKEN, /etc/telegram-send/token, \$HOME/.telegram_bot, /root/.telegram_bot, \$SUDO_USER's home). Module skipped."
		return 255
	fi

	# Validate in a subshell: sourcing must not leak TOKEN/CHAT_ID here.
	if ! ( . "${token}" >/dev/null 2>&1
		[ -n "${TOKEN}" ] && [ -n "${CHAT_ID}" ] ); then
		dfatal "telegram-send: ${token} has no TOKEN and/or CHAT_ID. Module skipped."
		return 255
	fi

	return 0
}

# depends() defines other module prerequisites.
#
# Everything telegram-send needs at runtime is already pulled in by the
# dracut.conf.d snippet shipped with this package, so this module installs no
# dependencies of its own:
#   url-lib           curl(1), sed and an SSL CA bundle - dracut's own url=
#                     fetcher needs the exact same stack. It also depends on
#                     "network" itself.
#   network/netplan/  ip(8), /etc/resolv.conf, DHCP
#   network-manager   libnss_dns.so.2 (glibc resolver used by curl)
depends() {
	echo url-lib network
	return 0
}

# install() instructs dracut where to put the payload.
install() {
	local token script unit timer

	unit=telegram-send.service
	timer=telegram-send.timer
	token=$(_telegram_token_file) || {
		dfatal "telegram-send: token file disappeared since check()."
		return 1
	}

	# The script. Prefer the copy that sits next to this module-setup.sh, so
	# the module directory is self-contained; fall back to the installed one.
	# Note: inst_script installs to <source> unless a destination is given
	# explicitly, and the unit's ExecStart is /usr/bin/telegram-send.
	script="${moddir}/telegram-send"
	[ -f "${script}" ] || script=/usr/bin/telegram-send

	# inst_script (not inst_binary) also pulls in the #!/bin/bash interpreter
	# and any shared libraries the script needs.
	inst_script "${script}" /usr/bin/telegram-send || return 1
	chmod 0755 "${initdir}/usr/bin/telegram-send"

	# Token: root only, mode 0600.
	inst_simple "${token}" "/root/.telegram_bot" || return 1
	chmod 0600 "${initdir}/root/.telegram_bot"

	# Unit and its timer. Both carry [Install] WantedBy=sysinit.target, so
	# enable them by hand instead of via `systemctl --root`, which needs a
	# working systemd environment on the build host and is not guaranteed to be
	# there. sysinit.target rather than timers.target: it is the one target that
	# is definitely reached inside the initramfs.
	inst_simple "${moddir}/${unit}" "${systemdsystemunitdir}/${unit}" || return 1
	inst_simple "${moddir}/${timer}" "${systemdsystemunitdir}/${timer}" || return 1
	mkdir -p "${initdir}/etc/systemd/system/sysinit.target.wants"
	ln -sf "${systemdsystemunitdir}/${unit}" \
		"${initdir}/etc/systemd/system/sysinit.target.wants/${unit}"
	ln -sf "${systemdsystemunitdir}/${timer}" \
		"${initdir}/etc/systemd/system/sysinit.target.wants/${timer}"
}