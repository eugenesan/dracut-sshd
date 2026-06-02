#!/bin/bash

# 2026, Eugene San (eugenesan) <eugenesan@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later

# called by dracut
install() {
    # Make sure root user is not locked

    # check if other dracut modules already created an entry for root in /etc/shadow
    if grep -qs '^root:' "$initdir/etc/shadow"; then
        grep -v '^root:' "$initdir/etc/shadow" > "$initdir/etc/shadow-"
        mv "$initdir/etc/shadow-" "$initdir/etc/shadow"
    fi

    grep '^root:' "${dracutsysrootdir-}/etc/shadow" | sed 's/^root:\!/root:/' >> "$initdir/etc/shadow"

    return 0
}

