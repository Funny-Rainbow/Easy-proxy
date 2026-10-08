#!/usr/bin/env bash
# Run only inside a disposable Linux machine/container with systemd as PID 1.
set -Eeuo pipefail
[[ ${EASY_PROXY_DISPOSABLE_TEST:-} == 1 && $EUID == 0 ]] || { echo 'Requires root and EASY_PROXY_DISPOSABLE_TEST=1 in a disposable environment';exit 1; }
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
tar -xzf dist/easy-proxy_v0.1.0_linux_amd64.tar.gz -C "$work"
install -d -m 0755 /usr/local/lib/easy-proxy-test
install -m 0755 "$work/easy-proxy" /usr/local/lib/easy-proxy-test/easy-proxy
bin=/usr/local/lib/easy-proxy-test/easy-proxy
"$bin" install --host 203.0.113.1 --port 18443
"$bin" doctor
before=$(sha256sum /etc/easy-proxy/server.json /etc/easy-proxy/ca.pem)
"$bin" install --host 203.0.113.2 --port 443
[[ $before == "$(sha256sum /etc/easy-proxy/server.json /etc/easy-proxy/ca.pem)" ]]
"$bin" export-client --out "$work/client.json"
"$bin" check --kind client --config "$work/client.json"
"$bin" renew-cert
"$bin" rotate-password
[[ $before != "$(sha256sum /etc/easy-proxy/server.json /etc/easy-proxy/ca.pem)" ]]
ca_hash=$(sha256sum /etc/easy-proxy/ca.pem)

# Create an authentic archive whose binary passes config validation but cannot
# run its server: this exercises recovery after the live version switches.
cat > "$work/failing" <<EOF
#!/usr/bin/env bash
case \$1 in
version) echo v0.1.1;;
check) exec "$bin" "\$@";;
server) exit 42;;
*) exit 1;;
esac
EOF
mkdir "$work/package"
cp "$work/failing" "$work/package/easy-proxy"
chmod 0755 "$work/package/easy-proxy"
tar -czf "$work/easy-proxy_v0.1.1_linux_amd64.tar.gz" -C "$work/package" easy-proxy
(cd "$work"; sha256sum easy-proxy_v0.1.1_linux_amd64.tar.gz > SHA256SUMS)
old=$(readlink -f /opt/easy-proxy/current)
if "$bin" upgrade --version v0.1.1 --from "$work";then echo 'Expected upgrade failure';exit 1;fi
[[ $(readlink -f /opt/easy-proxy/current) == "$old" ]]
"$bin" doctor

# The same server binary with a distinct version wrapper exercises successful
# upgrade and rollback without relying on GitHub or mutating release tags.
cat > "$work/package/easy-proxy" <<EOF
#!/usr/bin/env bash
if [[ \$1 == version ]];then echo v0.1.2;else exec "$bin" "\$@";fi
EOF
chmod 0755 "$work/package/easy-proxy"
tar -czf "$work/easy-proxy_v0.1.2_linux_amd64.tar.gz" -C "$work/package" easy-proxy
(cd "$work"; sha256sum easy-proxy_v0.1.2_linux_amd64.tar.gz > SHA256SUMS)
"$bin" upgrade --version v0.1.2 --from "$work"
[[ $(/opt/easy-proxy/current/easy-proxy version) == v0.1.2 ]]
"$bin" rollback
[[ $(readlink -f /opt/easy-proxy/current) == "$old" ]]
"$bin" doctor
"$bin" uninstall
[[ -f /etc/easy-proxy/server.json && ! -e /opt/easy-proxy && ! -e /etc/systemd/system/easy-proxy.service ]]
"$bin" install
[[ $ca_hash == "$(sha256sum /etc/easy-proxy/ca.pem)" ]]
"$bin" uninstall --purge
[[ ! -e /etc/easy-proxy && ! -e /opt/easy-proxy && ! -e /var/lib/easy-proxy ]]
echo 'Systemd install/upgrade/failure recovery/rollback/uninstall lifecycle passed.'
