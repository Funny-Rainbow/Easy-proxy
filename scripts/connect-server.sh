#!/usr/bin/env bash
# Run on your LOCAL Linux/WSL computer. Completes first-login SSH authorization.
# Usage: bash connect-server.sh SERVER_IP [SSH_PORT]
set -Eeuo pipefail
umask 077
server_host=${1:-${EASY_PROXY_SERVER_HOST:-}}
server_port=${2:-22}
[[ -n $server_host ]] || { echo 'Usage: bash connect-server.sh SERVER_IP [SSH_PORT]' >&2; exit 1; }
[[ $server_host =~ ^[A-Za-z0-9._:-]+$ ]] || { echo 'Invalid server address.' >&2; exit 1; }
[[ $server_port =~ ^[0-9]{1,5}$ ]] && ((10#$server_port > 0 && 10#$server_port <= 65535)) || { echo 'Invalid SSH port.' >&2; exit 1; }
server_port=$((10#$server_port))
for command in ssh ssh-keygen; do command -v "$command" >/dev/null || { echo "Missing command: $command" >&2; exit 1; }; done
if [[ $EUID == 0 ]]; then
  echo 'Run this locally as your normal user, without sudo, so the agent can use the generated key.' >&2
  exit 1
fi
ssh_dir="$HOME/.ssh"
key_path="$ssh_dir/easy-proxy-deploy"
known_hosts="$ssh_dir/easy-proxy-known-hosts"
connection_config="$ssh_dir/easy-proxy-server.conf"
install -d -m 0700 "$ssh_dir"
if [[ ! -f $key_path ]]; then
  ssh-keygen -q -t ed25519 -f "$key_path" -N '' -C easy-proxy-deploy
fi
chmod 0600 "$key_path"
# Some OpenSSH versions include the saved comment in -y output. Extract only
# the key type and blob before adding our stable deployment comment.
derived_key=$(ssh-keygen -y -f "$key_path")
read -r key_type key_blob key_comment <<< "$derived_key"
public_key="$key_type $key_blob easy-proxy-deploy"
[[ $public_key =~ ^ssh-ed25519\ [A-Za-z0-9+/=]+\ easy-proxy-deploy$ ]] || { echo 'Invalid deployment public key.' >&2; exit 1; }

echo "Local computer: $(hostname)"
echo "Connecting to server: root@$server_host:$server_port"
echo 'Confirm the server fingerprint when SSH asks, then enter the SERVER login password if needed.'
echo 'SSH uses a separate host-key file for this project; existing SSH records remain available.'

# Use an interactive first-use trust prompt, never silently accept a changed key.
# SSH reads password/fingerprint prompts from the terminal, while stdin carries
# the bootstrap script to the REMOTE machine.
ssh_options=(-p "$server_port" -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o UserKnownHostsFile="$known_hosts" -o StrictHostKeyChecking=ask)
ssh "${ssh_options[@]}" -i "$key_path" "root@$server_host" "bash -s -- '$public_key'" <<'REMOTE'
set -Eeuo pipefail
umask 077
[[ $EUID == 0 ]] || { echo 'Remote root login is required for deployment preparation.' >&2; exit 1; }
if [[ $(uname -r | tr '[:upper:]' '[:lower:]') == *microsoft* ]]; then
  echo 'The destination is a WSL machine; refusing to configure it as the public server.' >&2
  exit 1
fi
public_key=$1
root_home=$(getent passwd root | cut -d: -f6)
[[ -n $root_home && -d $root_home ]] || { echo 'Cannot find remote root home.' >&2; exit 1; }
install -d -m 0700 -o root -g root "$root_home/.ssh"
authorized="$root_home/.ssh/authorized_keys"
touch "$authorized"
chown root:root "$authorized"
chmod 0600 "$authorized"
blob=${public_key#* }; blob=${blob%% *}
if ! awk -v k="$blob" '$1=="ssh-ed25519" && $2==k{found=1} END{exit !found}' "$authorized"; then
  printf '\n%s\n' "$public_key" >> "$authorized"
fi
echo "=== Connected to remote server: $(hostname) ==="
echo 'Dedicated deployment public key installed.'
cat /etc/os-release
if command -v ss >/dev/null; then ss -ltnp '( sport = :22 or sport = :443 or sport = :8443 )'; fi
REMOTE

echo 'Verifying automatic login with only the dedicated deployment key...'
ssh "${ssh_options[@]}" -o StrictHostKeyChecking=yes -o BatchMode=yes -o IdentitiesOnly=yes -i "$key_path" "root@$server_host" 'printf "Automatic SSH login OK: "; hostname'

temporary_config=$(mktemp "$ssh_dir/.easy-proxy-config.XXXXXX")
trap 'rm -f -- "$temporary_config"' EXIT
cat > "$temporary_config" <<EOF
Host easy-proxy-server
    HostName $server_host
    User root
    Port $server_port
    IdentityFile "$key_path"
    IdentitiesOnly yes
    UserKnownHostsFile "$known_hosts"
    StrictHostKeyChecking yes
    BatchMode yes
    ServerAliveInterval 15
    ServerAliveCountMax 3
EOF
chmod 0600 "$temporary_config"
mv -f "$temporary_config" "$connection_config"
chmod 0600 "$known_hosts"
echo
echo 'READY: SSH access has been prepared. Tell the agent to continue deployment.'
printf 'Saved connection: ssh -F "%s" easy-proxy-server\n' "$connection_config"
