dracut-sshd: additional dracut modules
======================================

Beyond the sshd module itself (46sshd, upstream), this package ships four
more dracut modules.  They live in this source tree under

    debian/dracut/<module>/module-setup.sh

and are installed by debian/dracut-sshd.install into

    /usr/lib/dracut/modules.d/<NN><module>/

with the numbering below.  Together they make a machine that boots without
usable networking remotely reachable (sshd + a network stack) and, once the
network is up, able to announce itself over the Telegram Bot API.

Module numbering and load order
-------------------------------

    30network-manager-wireless   wifi + wpa_supplicant (upstream, patched)
    45netplan                    Ubuntu netplan configuration
    47telegram-send              Telegram boot notification
    82unlock-root                keep the root account usable inside initrd

dracut orders modules by number.  The two networking modules are numbered
before telegram-send so that whatever brings the interface up exists first;
unlock-root runs late because it only rewrites /etc/shadow.

All four are enabled from a single drop-in, installed as
/etc/dracut.conf.d/sshd.conf (source: debian/config/sshd.conf):

    kernel_cmdline="rd.neednet=1"
    add_dracutmodules+=" bash systemd-cryptsetup url-lib network netplan \
                         network-manager network-manager-wireless sshd \
                         telegram-send "
    install_items+=" nano ping ping6 top "

Note what is *not* installed by telegram-send itself: curl(1) and the SSL CA
bundle come from dracut's own url-lib module, ip(8)/awk/grep from net-lib
(which every network module pulls in).  telegram-send declares that dependency
with depends(), it does not install binaries.


If the boot hangs before the root filesystem
--------------------------------------------
`rd.neednet=1` is what makes this image refuse to continue without a network,
and it is deliberate: sshd is the reason this initramfs exists, and a rescue
shell you cannot reach is no rescue shell.  The consequence is that a machine
whose network configuration does not match the hardware it booted on - a
renamed interface, a different NIC, a VLAN that is not there any more - will
not reach the root filesystem at all, and the console shows the initqueue
retrying a hook while a job sits with no limit:

    dracut-initqueue: timeout, still waiting for following initqueue hooks:
      /var/lib/dracut/hooks/initqueue/finished/90-crypt.sh ...
    Job dev-mapper-luks\x2d....target running (5min 23s / no limit)

That is root unlock waiting, not the notification.  telegram-send does not
appear in such a log at all; it is a separate job that gives up on its own
(TELEGRAM_MAX_WAIT=60) and is killed by systemd if it somehow wedges
(TimeoutStartSec=180).

What to do about it, in order of preference:

  * Make the configuration match the hardware.  A netplan profile with
    `match: name: "en*"` (or a `set-name`) survives a NIC swap; a profile
    naming one exact interface does not.

  * Add a fallback so that *some* interface gets an address regardless of the
    installed profiles: `ip=dhcp` on the kernel command line makes dracut try
    DHCP on any interface it finds.  This is the option that makes the image
    boot on hardware it has never seen.  Be aware it competes with netplan and
    NetworkManager for the interface, so it is a deliberate trade rather than
    something to add casually.

  * Drop `rd.neednet=1`.  The boot then proceeds without a network - but so
    does sshd, since nothing retries it later, so remote access is lost until
    the next boot.  Only sensible on a machine that also boots locally.

### Bisecting: rd.telegram-send=0
If a boot misbehaves and you need to know whether this module has anything to do
with it, add `rd.telegram-send=0` to the kernel command line.  The script then
reads /proc/cmdline, logs "doing nothing" and exits 0 before touching the
network, the cache or the timer.  It can be typed at the boot prompt, which
matters because a boot that hangs is exactly the case where there is no shell to
stop the unit from.  The unit files stay in the image; only the work is skipped.


45netplan - netplan network configuration
-----------------------------------------

Purpose
    Make the initramfs use the host's /etc/netplan/*.yaml, so a stock Ubuntu
    install needs no extra network configuration to get online early.

How it works
    check()   only in hostonly mode, only when netplan(8) exists and
              /etc/netplan/*.yaml is non-empty (otherwise it is skipped
              silently).
    depends() reads `netplan get renderer` and pulls in either
              network-manager or systemd-networkd, so both worlds work.
    install() copies the yaml into a temporary root and runs
              `netplan generate` there, then installs the generated
              systemd-networkd .network/.netdev files (or the NetworkManager
              keyfiles) into the image, rewriting /run/... paths to /etc/....

    netplan-ovs-cleanup.service is deliberately skipped: it is only relevant
    for Open vSwitch, and shipping it would fail the boot when ovs is absent.

Caveats
    Hostonly mode only.  On a --no-hostonly build this module does nothing and
    you need plain networkd (see example/20-wired.network and
    example/90-networkd.conf) or NetworkManager instead.

    Generated files are marked -H (hostonly), so an image built on one machine
    carries that machine's configuration.


30network-manager-wireless - wifi in the initramfs
---------------------------------------------------

Upstream module by Georg Sauthoff (dracut-network-manager-wireless), shipped
here with an extended driver list.

Purpose
    Bring up wifi from the initramfs through NetworkManager + wpa_supplicant,
    for machines whose only network is wireless.

    check()   requires wpa_supplicant and rfkill on the build host.
    install() adds wpa_supplicant with its D-Bus policy, enables
              wpa_supplicant.service, and loads these modules:
              cfg80211 mac80211 rfkill ath9k ath9k_htc brcmfmac brcmfmac_wcc
              iwlmvm iwlwifi rt2x00lib rt2x00usb rt2800lib rt2800usb
              rtw88_8723du
              Firmware is installed best-effort (/lib/firmware/{brcm,iwlmvm,
              iwlwifi*,rt28*,rtw88*}); a missing blob means no wifi, not a
              failed build.
              It also installs a netdev group entry if the host has none.

    wpa_supplicant.service is patched to run with DefaultDependencies=no and
    Conflicts=shutdown.target so it cannot delay the boot.

    For a wired-only machine this module is dead weight - drop it from
    add_dracutmodules.

    Wifi credentials: provide a NetworkManager system connection or
    wpa_supplicant.conf (both are installed if present on the build host).


47telegram-send - boot notification over the Bot API
----------------------------------------------------

Purpose
    Tell yourself, over Telegram, that the machine came up: host name,
    interface, driver, source address and external address.  Also the thing
    that tells you the SSH session you are about to make is worth making.

Files
    /usr/bin/telegram-send                 the script
    /usr/lib/systemd/system/telegram-send.service
    /usr/lib/systemd/system/telegram-send.timer
    /etc/systemd/system/sysinit.target.wants/{telegram-send.service,
                                               telegram-send.timer}
    /root/.telegram_bot                    token, mode 0600

Token
    The token file must exist on the *build* host or the module is skipped.
    Lookup order (first readable wins):

        $TELEGRAM_BOT_TOKEN           e.g. exported when running dracut
        /etc/telegram-send/token
        $HOME/.telegram_bot           (root's or the invoking user's home)
        /root/.telegram_bot
        $SUDO_USER's home from passwd(5)

    It must define TOKEN and CHAT_ID; MESSAGE is the default text.  The file is
    a shell fragment and is sourced.  Only an example is shipped, at
    /usr/share/doc/dracut-sshd/examples/.telegram_bot - copy it yourself, or
    drop a real one at /root/.telegram_bot before building.

    The token ends up inside the initramfs image: treat /boot/initramfs-*.img
    as a secret (chmod 600, LUKS-encrypted root).

    check() validates the token and returns 255 to skip the module cleanly, so
    a missing token never breaks the dracut run.

Behaviour
    Started early (DefaultDependencies=no, WantedBy=sysinit.target), so it can
    report even while the root filesystem is still locked.  It deliberately
    does NOT order itself before cryptsetup.target: a notification must not
    delay root unlock.

    telegram-send.timer checks every 5 minutes (OnBootSec, OnUnitActiveSec).
    The service waits up to TELEGRAM_MAX_WAIT=300s for the internet, probes a
    rotating list of public connectivity endpoints, and sends only when
    something actually changed.  The cache in the runtime directory holds the
    last attempt's outcome plus the network identity, so you get one message per
    real change rather than one per tick.  It lives on tmpfs, so the first run
    after every reboot always notifies.

    A change means: interface, driver, source address or message text differ
    from the last successful send, or the last attempt failed.

    The external address is the one field that comes from a third party
    (api.ipify.org, ifconfig.me/ip, checkip.amazonaws.com, icanhazip.com,
    ident.me, wtfismyip.com/text, ipinfo.io/ip - a different operator each run,
    so no single service sees every request), and a lookup that fails must not
    look like a change, or a flaky service would notify you in a loop.
    Endpoints are asked for the address family of the local source address, so
    the field cannot flip between IPv4 and IPv6 just because a different
    operator answered.

    With TELEGRAM_EXT_CHECK=on-change (the default) it is looked up only when
    something *local* suggests it may have changed, so a quiet machine asks no
    IP-echo service at all.  "Something local" is the identity above plus two
    free signals read from sysfs:

      /sys/class/net/<dev>/carrier_down_count   the kernel's tally of link
                                                losses (carrier_changes on an
                                                older kernel).  A router
                                                reboot drops carrier for a
                                                moment even when the cable
                                                never moves.
      /sys/class/net/<dev>/statistics/rx_packets only ever grows while an
                                                interface exists, so a decrease
                                                means it was destroyed and
                                                recreated - a driver reload,
                                                or dhcpcd/NetworkManager
                                                re-plugging the device.

    Why that matters: the usual way an unattended machine ends up with a new
    external address is a router reboot, and that leaves interface, driver and
    source address untouched - routers hand the same address to the same MAC -
    so without these signals the new public address would go unnoticed until
    something else changed too.  Both signals are one-sided on purpose: only a
    regression or a loss counts, never growth, because counters increase all
    day on a busy link and treating that as a change would ask a third party on
    every tick.

    A detected cycle is reported in its own right, whether or not anything else
    moved, and the reason goes into the message as
    "link:[carrier losses 0 -> 1]".  Waiting for an address to differ would
    mean never reporting it, because the same router usually hands out the
    same address again.  Being detected from the kernel alone, it also works
    with TELEGRAM_SEND_IP=0 - which makes cycling the link an out-of-band
    trigger: unplug the cable, or reboot the router, and a fresh status
    message goes out regardless of the state telegram-send is in.

    To keep a flapping cable from becoming a message per tick, at most
    TELEGRAM_CYCLE_MAX cycle-triggered messages (3) go out per
    TELEGRAM_CYCLE_WINDOW seconds (3600), counted over a rolling window.  One
    cycle means one message: the new counters are recorded with the attempt, so
    the following ticks stay quiet until the link is cycled again.  The limit
    only ever suppresses a cycle that is the *sole* reason to report - the
    initial status and any real change of identity always get through, and
    TELEGRAM_CYCLE_MAX=0 keeps the detection while never notifying on it.
    Both signals may be absent on an older kernel, and then simply do not
    contribute.

    Set TELEGRAM_EXT_CHECK=always to also notice a change of the external
    address with no local sign at all (an upstream NAT rebinding, say), at the
    cost of one request per tick.

    The log names the operator behind every third-party answer: the line
    "internet reachable (confirmed by <url>)" says which reachability endpoint
    spoke, and "external address <addr> from <url>" says which service was
    asked.  Both lists start at a random entry on every run, so over a few
    cycles you see the rotation working and, when one service is having a bad
    day, exactly which one.

    Exit codes: 0 delivered, 1 permanent failure (bad token), 75 no internet
    yet.  The unit only cares about 0 vs non-zero; the code exists to make the
    journal and the log readable.

Files and permissions
    The script puts its log and its state cache in one runtime directory,
    picked so the same script works for root in an initramfs and for a regular
    user:

        $TELEGRAM_RUN_DIR                if set
        $XDG_RUNTIME_DIR                 /run/user/<uid> - set by systemd for
                                         user units and by pam_systemd at login
        /run                             writable by root; tmpfs in an initrd
        /tmp                             last resort, filename suffixed with
                                         the uid so two users cannot collide

    As shipped (root, initramfs): /run/telegram-send.{log,state}.  For an
    unprivileged user: /run/user/<uid>/telegram-send.{log,state}.  Both are
    overridable with TELEGRAM_LOG and TELEGRAM_STATE.

    The token is read from $TELEGRAM_CONF, defaulting to $HOME/.telegram_bot
    (/root/.telegram_bot when $HOME is unset, which is what a system unit gets).
    A *system* unit running as User=somebody therefore needs a drop-in with
    Environment=TELEGRAM_CONF=/home/somebody/.telegram_bot
    or an EnvironmentFile=-/etc/telegram-send.env.  As a user unit systemd sets
    $HOME for you and no override is needed.

Debugging
    Log: telegram-send.log in the runtime directory (TELEGRAM_LOG).  In an
    initramfs that is tmpfs and is gone after switch-root, so read it from the
    initrd (rd.break, init=/bin/bash - tail(1) is installed for exactly that)
    or set TELEGRAM_LOG=/dev/kmsg for one boot.
    State: telegram-send.state next to it; delete it to force a notification.

    condition: the unit carries ConditionPathExists=/root/.telegram_bot so a
    missing token skips it silently; comment that line out to get an explicit
    "no readable config" in the log instead.

    Override behaviour from the token file or the unit's Environment=, e.g.
    TELEGRAM_MAX_WAIT=60, TELEGRAM_RETRIES=5, TELEGRAM_SEND_IP=0 (drop the
    external address), TELEGRAM_EXT_CHECK=always, and netchecks=(...) /
    apiaddrs=(...) / exturls=(...) if your provider blocks these endpoints.

    When DNS is up but api.telegram.org is unreachable, the script logs curl's
    own error (rc and message) on every attempt - including rc=60, which means
    no CA bundle in the image, and rc=6, which it works around by retrying
    through the pinned addresses in apiaddrs.

    A machine that never sends anything: check that dev and src are non-empty
    in the log.  With no default route (or no ip(8) in the image) the script
    refuses to report an incomplete identity, and says so.


82unlock-root - keep root usable inside initrd
-----------------------------------------------

Purpose
    dracut's systemd units lock the root account (root:! in /etc/shadow), which
    would make an emergency shell or an unlock prompt behave differently than
    on the installed system.

How it works
    install() rewrites the root entry in $initdir/etc/shadow, replacing
    root:! with root: (empty password field) using the host's own
    /etc/shadow entry.  If another module already wrote a root entry, that one
    is removed first so there is exactly one.

    Only affects the initramfs.  Pair it with a real root password and an
    encrypted root; it does not weaken the running system.


Module dependencies at a glance
-------------------------------

    45netplan        -> network-manager | systemd-networkd (netplan get renderer)
    30network-m-wl   -> wpa_supplicant, rfkill (build host), dbus
    47telegram-send  -> url-lib (curl + CA bundle), network (ip, resolv.conf)
    82unlock-root    -> nothing

If you change one of these modules, rebuild with

    dracut -f --kver <version>        (or: update-initramfs -u)

and inspect the result with

    lsinitramfs /boot/initramfs-<version>.img | less

Troubleshooting
---------------

    No telegram message, no error in the journal
        The token was missing at build time: the module was skipped. Look for
        "no bot token file found" in the dracut output.
    telegram-send.service not in `systemctl list-unit-files` inside initrd
        telegram-send was not in add_dracutmodules when the image was built.
    Everything works but the boot is slow
        Check for a notification ordering itself before the root is unlocked;
        the shipped unit deliberately does not, so this is a local change.
    Wifi does not come up
        Firmware blobs are installed best-effort: check
        /lib/firmware in the image and the wpa_supplicant unit's status.