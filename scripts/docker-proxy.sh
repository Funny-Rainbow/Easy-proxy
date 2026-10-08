#!/usr/bin/env bash
set -Eeuo pipefail
[[ $EUID == 0 ]] || { echo 'Run with sudo/root.' >&2; exit 1; }
action=${1:-help}
dropin=/etc/systemd/system/docker.service.d/easy-proxy.conf
case $action in
enable)
  proxy=${2:-http://127.0.0.1:17890}
  [[ $proxy =~ ^http://127\.0\.0\.1:([0-9]{1,5})$ ]] || { echo 'Expected http://127.0.0.1:PORT' >&2; exit 1; }
  ((10#${BASH_REMATCH[1]} > 0 && 10#${BASH_REMATCH[1]} <= 65535)) || exit 1
  if [[ -f $dropin ]] && ! grep -Fxq '# Managed by Easy-proxy' "$dropin"; then echo 'Refusing to overwrite an unrecognized file.' >&2; exit 1; fi
  install -d -m 0755 "$(dirname "$dropin")"
  cat > "$dropin" <<EOF
# Managed by Easy-proxy
[Service]
Environment="HTTPS_PROXY=$proxy"
EOF
  chmod 0644 "$dropin"
  ;;
disable)
  if [[ -f $dropin ]];then
    grep -Fxq '# Managed by Easy-proxy' "$dropin" || { echo 'Refusing to remove an unrecognized file.' >&2; exit 1; }
    rm -f "$dropin"
  fi
  ;;
*) echo 'Usage: sudo bash scripts/docker-proxy.sh enable [http://127.0.0.1:17890] | disable';exit 1;;
esac
systemctl daemon-reload
echo 'Docker proxy configuration updated. Apply with: sudo systemctl restart docker'
echo 'Restarting Docker may interrupt running containers. Keep the local Easy-proxy client running when proxy is enabled.'
