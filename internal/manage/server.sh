#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
binary=$1; action=$2; shift 2
base=/opt/easy-proxy
state=/etc/easy-proxy
data=/var/lib/easy-proxy
unit=/etc/systemd/system/easy-proxy.service
command_link=/usr/local/bin/easy-proxy
die() { echo "easy-proxy: $*" >&2; exit 1; }
if [[ $action == status ]]; then
  systemctl status easy-proxy.service --no-pager
  exit
fi
[[ $EUID == 0 ]] || die 'Run this command with sudo/root.'
command -v systemctl >/dev/null || die 'systemd is required.'
[[ -d /run/systemd/system ]] || die 'systemd must be running.'
for tool in flock sha256sum install tar ss; do command -v "$tool" >/dev/null || die "Missing dependency: $tool"; done
install -d -m 0755 /run/lock
exec 9>/run/lock/easy-proxy.lock
flock -n 9 || die 'Another Easy-proxy management command is running.'
host= port=443 listen= out=client.json release= from= purge=false
release_base=https://github.com/Funny-Rainbow/Easy-proxy/releases/download
work= recovery_version= recovery_state= installing=false
finish() {
  local code=$?
  trap - EXIT
  if ((code != 0)); then
    set +e
    if [[ -n $recovery_version ]]; then
      systemctl stop easy-proxy.service
      rm -f "$base/.current-next"
      switch_to "$recovery_version"
      if [[ -n $recovery_state ]]; then cp -a "$recovery_state/." "$state/"; fix_permissions; fi
      systemctl start easy-proxy.service
      echo 'Previous release/state restored after management failure.' >&2
    elif $installing; then
      systemctl disable --now easy-proxy.service
      rm -f "$unit"
      systemctl daemon-reload
      echo 'Failed installation stopped; state retained for inspection.' >&2
    fi
  fi
  [[ -z $work ]] || rm -rf -- "$work"
  exit "$code"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
while (($#)); do
  case $1 in
    --host|--port|--listen|--out|--version|--from|--base-url)
      (($# >= 2)) || die "Missing value for $1"
      case $1 in
        --host) host=$2;; --port) port=$2;; --listen) listen=$2;; --out) out=$2;;
        --version) release=$2;; --from) from=$2;; --base-url) release_base=$2;;
      esac; shift 2;;
    --purge) purge=true; shift;;
    *) die "Unknown option: $1";;
  esac
done
fix_permissions() {
  chown root:easy-proxy "$state"
  chmod 0750 "$state"
  chown root:easy-proxy "$state/server.json" "$state/server-key.pem"
  chmod 0640 "$state/server.json" "$state/server-key.pem"
  chown root:root "$state/ca-key.pem"
  chmod 0600 "$state/ca-key.pem"
}
installed() { [[ -x $base/current/easy-proxy && -f $state/server.json ]] || die 'Easy-proxy is not installed.'; }
healthy() {
  for ((i=0;i<20;i++)); do
    if systemctl is-active --quiet easy-proxy.service && "$base/current/easy-proxy" check --kind server --config "$state/server.json" >/dev/null 2>&1; then
      # Confirm that the running service actually owns a listening socket.
      local pid
      pid=$(systemctl show -p MainPID --value easy-proxy.service)
      if [[ $pid =~ ^[1-9][0-9]*$ ]] && ss -H -ltnp | awk -v p="pid=$pid," 'index($0,p){found=1} END{exit !found}'; then return 0; fi
    fi
    sleep 0.5
  done
  return 1
}
switch_to() {
  ln -s "$1" "$base/.current-next"
  mv -Tf "$base/.current-next" "$base/current"
}
stage_binary() {
  local src=$1 ver digest
  ver=$("$src" version)
  [[ $ver =~ ^[A-Za-z0-9._-]+$ ]] || die 'Invalid binary version.'
  digest=$(sha256sum "$src"); digest=${digest%% *}
  staged="$base/releases/$ver-${digest:0:12}"
  install -d -m 0755 "$staged"
  if [[ $(readlink -f "$src") != "$staged/easy-proxy" ]]; then install -m 0755 "$src" "$staged/easy-proxy"; fi
}
write_unit() {
  [[ ! -e $unit ]] || die "Service unit already exists: $unit; inspect it before installing."
  cat > "$unit" <<'UNIT'
[Unit]
Description=Easy-proxy encrypted CONNECT server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=easy-proxy
Group=easy-proxy
ExecStart=/opt/easy-proxy/current/easy-proxy server --config /etc/easy-proxy/server.json
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
UMask=0077
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT
  chmod 0644 "$unit"
}

case $action in
install)
  for tool in ss useradd groupadd; do command -v "$tool" >/dev/null || die "Missing dependency: $tool"; done
  if [[ -e $unit ]]; then
    installed
    "$base/current/easy-proxy" check --kind server --config "$state/server.json"
    echo 'Already installed; configuration preserved. Use upgrade to change versions.'
    exit
  fi
  [[ -n $host || -f $state/server.json ]] || die 'install requires --host SERVER_IP'
  if [[ -e $command_link || -L $command_link ]]; then
    [[ $(readlink "$command_link") == "$base/current/easy-proxy" ]] || die "$command_link already exists and is not managed by Easy-proxy."
  fi
  getent group easy-proxy >/dev/null || groupadd --system easy-proxy
  if getent passwd easy-proxy >/dev/null; then
    [[ $(id -u easy-proxy) != 0 && $(id -gn easy-proxy) == easy-proxy ]] || die 'Existing easy-proxy account is unsuitable.'
  else useradd --system --gid easy-proxy --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin easy-proxy; fi
  install -d -m 0755 "$base/releases"
  install -d -m 0700 "$data"
  if [[ ! -f $state/server.json ]]; then
    args=(init --dir "$state" --host "$host" --port "$port")
    [[ -z $listen ]] || args+=(--listen "$listen")
    "$binary" "${args[@]}"
  fi
  fix_permissions
  "$binary" check --kind server --config "$state/server.json" --listen
  stage_binary "$binary"
  rm -f "$base/.current-next"
  switch_to "$staged"
  installing=true
  write_unit
  systemctl daemon-reload
  systemctl enable --now easy-proxy.service
  healthy || die 'Installation failed. See journalctl -u easy-proxy.'
  install -d -m 0755 /usr/local/bin
  ln -sfn "$base/current/easy-proxy" "$command_link"
  installing=false
  echo 'Installed. Export a client profile with export-client --out /secure/path/client.json.'
  echo 'Open your configured TCP port in the host/cloud firewall. Firewall rules were not modified.'
  ;;
upgrade)
  installed
  [[ $release =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$ ]] || die 'Use --version vX.Y.Z'
  case $(uname -m) in x86_64) arch=amd64;; aarch64|arm64) arch=arm64;; *) die 'Unsupported server architecture.';; esac
  archive="easy-proxy_${release}_linux_${arch}.tar.gz"
  # /tmp is commonly mounted noexec. Use the installation filesystem where
  # release executables are intended to run, rather than executing in /tmp.
  work=$(mktemp -d "$base/.upgrade.XXXXXX")
  if [[ -n $from ]]; then
    cp -- "$from/$archive" "$from/SHA256SUMS" "$work/"
  else
    command -v curl >/dev/null || die 'curl is required for online upgrades.'
    [[ $release_base == https://* ]] || die 'Release base URL must use HTTPS.'
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 600 -o "$work/$archive" "$release_base/$release/$archive"
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 60 -o "$work/SHA256SUMS" "$release_base/$release/SHA256SUMS"
  fi
  sum=$(awk -v f="$archive" '$2==f {print $1}' "$work/SHA256SUMS")
  [[ $sum =~ ^[0-9a-fA-F]{64}$ ]] || die 'Missing or ambiguous archive checksum.'
  (cd "$work"; printf '%s  %s\n' "$sum" "$archive" | sha256sum --check --status) || die 'Archive checksum mismatch.'
  [[ $(tar -tzf "$work/$archive") == easy-proxy ]] || die 'Unexpected archive contents.'
  tar -xzf "$work/$archive" -C "$work" --no-same-owner --no-same-permissions
  [[ -f $work/easy-proxy && ! -L $work/easy-proxy ]] || die 'Archive must contain a regular executable.'
  chmod 0755 "$work/easy-proxy"
  [[ $("$work/easy-proxy" version) == "$release" ]] || die 'Binary version differs from requested release.'
  "$work/easy-proxy" check --kind server --config "$state/server.json"
  old=$(readlink -f "$base/current")
  stage_binary "$work/easy-proxy"
  if [[ $old == "$staged" ]]; then echo 'Already running this release.'; exit; fi
  rm -rf -- "$data/pending-state"
  cp -a "$state" "$data/pending-state"
  rm -f "$base/.current-next"
  recovery_version=$old
  recovery_state=$data/pending-state
  systemctl stop easy-proxy.service
  switch_to "$staged"
  if ! systemctl start easy-proxy.service || ! healthy; then
    die 'Upgrade failed; restoring previous version and configuration.'
  fi
  recovery_version= recovery_state=
  rm -rf -- "$data/previous-state"
  mv "$data/pending-state" "$data/previous-state"
  printf '%s\n' "$old" > "$data/previous-version"
  echo "Upgraded to $release. Previous release is available via rollback."
  ;;
rollback)
  installed
  [[ -f $data/previous-version ]] || die 'No previous release available.'
  previous=$(cat "$data/previous-version")
  [[ $previous == "$base/releases/"* && -x $previous/easy-proxy ]] || die 'Invalid previous release.'
  # Config schema v1 has no migrations. Keep current credentials/certificates so
  # clients remain usable after a password change or certificate renewal.
  "$previous/easy-proxy" check --kind server --config "$state/server.json"
  old=$(readlink -f "$base/current")
  rm -f "$base/.current-next"
  recovery_version=$old
  systemctl stop easy-proxy.service
  switch_to "$previous"
  if ! systemctl start easy-proxy.service || ! healthy; then
    die 'Rollback failed; restoring original release.'
  fi
  recovery_version=
  printf '%s\n' "$old" > "$data/previous-version"
  echo 'Rolled back; current credentials and CA preserved.'
  ;;
doctor)
  installed
  "$base/current/easy-proxy" check --kind server --config "$state/server.json"
  systemctl is-active easy-proxy.service
  healthy || die 'Service is not listening.'
  echo 'Service and listener OK. Run probe on a client to verify Internet egress.'
  ;;
restart)
  installed; systemctl restart easy-proxy.service; healthy || die 'Service did not become healthy.';;
export-client)
  installed
  args=(pki-export --dir "$state" --out "$out")
  [[ -z $listen ]] || args+=(--listen "$listen")
  "$base/current/easy-proxy" "${args[@]}"
  echo "Client profile written to $out (contains a password; transfer securely)."
  ;;
rotate-password|renew-cert)
  installed
  backup=$(mktemp -d "$data/maintenance.XXXXXX")
  cp -a "$state/." "$backup/"
  recovery_version=$(readlink -f "$base/current")
  recovery_state=$backup
  sub=pki-rotate; [[ $action != renew-cert ]] || sub=pki-renew
  if "$base/current/easy-proxy" "$sub" --dir "$state" && fix_permissions && systemctl restart easy-proxy.service && healthy; then
    recovery_version= recovery_state=
    rm -rf -- "$backup"
    if [[ $action == rotate-password ]]; then echo 'Password rotated. Export and redistribute client profiles.'; else echo 'Certificate renewed; existing client CA remains valid.'; fi
  else
    die 'Maintenance failed; restoring previous state.'
  fi
  ;;
uninstall)
  if [[ -e $unit ]]; then
    grep -Fxq 'ExecStart=/opt/easy-proxy/current/easy-proxy server --config /etc/easy-proxy/server.json' "$unit" || die 'Refusing to remove an unrecognized unit.'
    systemctl disable --now easy-proxy.service
    rm -f "$unit"
    systemctl daemon-reload
    systemctl reset-failed easy-proxy.service 2>/dev/null || true
  fi
  if [[ -L $command_link && $(readlink "$command_link") == "$base/current/easy-proxy" ]]; then rm -f "$command_link"; fi
  rm -rf -- "$base"
  if $purge; then
    rm -rf -- "$state" "$data"
    echo 'Uninstalled and deleted Easy-proxy state.'
  else echo 'Uninstalled. Credentials and CA retained in /etc/easy-proxy; reinstall reuses them.'; fi
  echo 'The dedicated service account is retained to prevent UID reuse; existing services and firewall rules were not modified.'
  ;;
*) die "Unknown management command: $action";;
esac
