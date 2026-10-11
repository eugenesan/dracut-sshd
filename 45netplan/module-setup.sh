#!/usr/bin/bash
# shellcheck disable=SC2154

check() {
  [[ $hostonly ]] || return 1
  command -v netplan >/dev/null || return 1

  local _f
  for _f in /etc/netplan/*.yaml; do
    return 0
  done

  echo "No files in /etc/netplan" >&2
  return 1
}

depends() {
  local renderer
  renderer=$(netplan get renderer)
  case "$renderer" in
  NetworkManager)
    echo network-manager ;;
  networkd)
    echo systemd-networkd ;;
  esac
}

install() {
  inst_multiple -o -H "/etc/netplan/*.yaml"

  local tmp_root
  tmp_root=$(mktemp -d --tmpdir dracut-netplan.XXXX)
  test -d "${tmp_root}" || return 1
  mkdir -p "${tmp_root}/etc/netplan"
  cp "${initdir}/etc/netplan"/*.yaml "${tmp_root}/etc/netplan/"

  netplan generate --root-dir "${tmp_root}"

  local src dst
  while read -r src; do
    if [ "$(basename "$src")" == netplan-ovs-cleanup.service ]; then
      continue
    fi

    # shellcheck disable=SC2001
    dst=$(sed "s!^${tmp_root}/run!/etc!" <<< "$src")
    [ "$src" != "$dst" ] || continue

    inst_simple -H "$src" "$dst"
  done < <(find "${tmp_root}/run" -not -type d)

  rm --preserve-root --one-file-system -r "${tmp_root}"
}
