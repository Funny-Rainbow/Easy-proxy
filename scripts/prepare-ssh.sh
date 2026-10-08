#!/usr/bin/env bash
# Run from an already trusted server session. Only a public key is accepted.
set -Eeuo pipefail
umask 077
[[ $EUID == 0 ]] || { echo 'Run as root: sudo bash prepare-ssh.sh --public-key "ssh-ed25519 ..."' >&2;exit 1; }
[[ $# == 2 && $1 == --public-key ]] || { echo 'Usage: sudo bash prepare-ssh.sh --public-key "ssh-ed25519 BASE64 COMMENT"' >&2;exit 1; }
public_key=$2
[[ $public_key =~ ^ssh-ed25519\ [A-Za-z0-9+/=]+(\ [A-Za-z0-9._-]+)?$ ]] || { echo 'Expected one plain Ed25519 public key.' >&2;exit 1; }
keyfile=$(mktemp)
trap 'rm -f -- "$keyfile"' EXIT
printf '%s\n' "$public_key" > "$keyfile"
ssh-keygen -lf "$keyfile" -E sha256 >/dev/null
root_home=$(getent passwd root | cut -d: -f6)
[[ -n $root_home && -d $root_home ]] || { echo 'Cannot find root home.' >&2;exit 1; }
install -d -m 0700 -o root -g root "$root_home/.ssh"
authorized=$root_home/.ssh/authorized_keys
touch "$authorized"
chown root:root "$authorized"
chmod 0600 "$authorized"
blob=${public_key#* };blob=${blob%% *}
if ! awk -v k="$blob" '$1=="ssh-ed25519" && $2==k{found=1} END{exit !found}' "$authorized";then
  printf '\n%s\n' "$public_key" >> "$authorized"
fi
echo 'Deployment public key installed; existing authorized keys preserved.'
# Generate missing host keys only. Never rotate keys used by existing clients.
ssh-keygen -A
echo '=== SERVER HOST KEY FINGERPRINTS (copy these back from this trusted session) ==='
for key in /etc/ssh/ssh_host_*_key.pub;do
  [[ ! -f $key ]] || ssh-keygen -lf "$key" -E sha256
done
echo '=== SYSTEM ==='
cat /etc/os-release
echo '=== SSH AND PROXY LISTENERS ==='
if command -v ss >/dev/null;then ss -ltnp '( sport = :22 or sport = :443 or sport = :8443 )';fi
if command -v sshd >/dev/null;then
  echo '=== EFFECTIVE SSH AUTHENTICATION SETTINGS ==='
  sshd -T | awk '$1=="port" || $1=="permitrootlogin" || $1=="pubkeyauthentication" || $1=="authorizedkeysfile"'
fi
echo 'SSH configuration was not changed or restarted. If root/public-key login is disabled, report the output before changing it.'
echo 'Proxy TLS certificates will be generated separately by easy-proxy install.'
