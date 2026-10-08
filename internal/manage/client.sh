#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
binary=$1; action=$2; shift 2
root=${XDG_CONFIG_HOME:-$HOME/.config}/easy-proxy
binroot=${XDG_DATA_HOME:-$HOME/.local/share}/easy-proxy
unitroot=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
unit=$unitroot/easy-proxy-client.service
die(){ echo "easy-proxy: $*" >&2; exit 1; }
[[ $root != *$'\n'* && $root != *'%'* && $root != *'"'* && $binroot != *'%'* && $binroot != *'"'* && $binroot != *$'\n'* ]] || die 'Unsupported character in user configuration path.'
command -v systemctl >/dev/null && systemctl --user show-environment >/dev/null 2>&1 || die 'A running systemd user session is required. Alternatively use client run --config PATH in a terminal.'
source_config=
while (($#));do
  case $1 in --config) (($#>=2)) || die 'Missing config path';source_config=$2;shift 2;; *) die "Unknown option: $1";; esac
done
case $action in
install)
  [[ -n $source_config ]] || die 'Use client install --config PATH'
  "$binary" check --kind client --config "$source_config" --listen
  [[ ! -e $unit ]] || die 'Client already installed. Stop and uninstall before replacing it.'
  install -d -m 0700 "$root" "$binroot"
  install -d -m 0755 "$unitroot"
  install -m 0755 "$binary" "$binroot/easy-proxy"
  if [[ $(readlink -f "$source_config") != "$root/client.json" ]]; then install -m 0600 "$source_config" "$root/client.json"; else chmod 0600 "$root/client.json"; fi
  cat > "$unit" <<UNIT
[Unit]
Description=Easy-proxy local CONNECT bridge
After=network-online.target
[Service]
ExecStart="$binroot/easy-proxy" client run --config "$root/client.json"
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
UMask=0077
[Install]
WantedBy=default.target
UNIT
  systemctl --user daemon-reload
  systemctl --user enable --now easy-proxy-client.service
  sleep 0.5
  systemctl --user is-active --quiet easy-proxy-client.service || die 'Client failed to start; inspect journalctl --user -u easy-proxy-client.'
  echo 'Installed and enabled for your systemd user session. Use client run for foreground operation.'
  ;;
start) systemctl --user start easy-proxy-client.service;;
stop) systemctl --user stop easy-proxy-client.service;;
status) systemctl --user status easy-proxy-client.service --no-pager;;
uninstall)
  if [[ -e $unit ]];then
    grep -Fq 'Description=Easy-proxy local CONNECT bridge' "$unit" || die 'Unrecognized service unit.'
    systemctl --user disable --now easy-proxy-client.service
    rm -f "$unit";systemctl --user daemon-reload
  fi
  rm -f "$binroot/easy-proxy" "$root/client.json"
  rmdir "$binroot" "$root" 2>/dev/null || true
  echo 'Client removed. Disable proxy in any terminals where it was enabled.'
  ;;
*) die "Unknown client command: $action";;
esac
