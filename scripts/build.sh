#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
version=${1:-dev}
[[ $version =~ ^[A-Za-z0-9._-]+$ ]] || { echo 'Invalid version' >&2; exit 1; }
mkdir -p dist
for target in linux/amd64 linux/arm64 windows/amd64; do
  os=${target%/*}; arch=${target#*/}; ext=; [[ $os != windows ]] || ext=.exe
  dir=$(mktemp -d)
  trap 'rm -rf -- "$dir"' EXIT
  CGO_ENABLED=0 GOOS=$os GOARCH=$arch go build -trimpath -ldflags "-s -w -X main.version=$version" -o "$dir/easy-proxy$ext" ./cmd/easy-proxy
  if [[ $os == windows ]]; then
    python3 - "$dir/easy-proxy.exe" "dist/easy-proxy_${version}_${os}_${arch}.zip" <<'PY'
import sys,zipfile
with zipfile.ZipFile(sys.argv[2],'w',zipfile.ZIP_DEFLATED) as z: z.write(sys.argv[1],'easy-proxy.exe')
PY
  else tar -czf "dist/easy-proxy_${version}_${os}_${arch}.tar.gz" -C "$dir" easy-proxy; fi
  rm -rf -- "$dir";trap - EXIT
done
(cd dist; sha256sum "easy-proxy_${version}_linux_amd64.tar.gz" "easy-proxy_${version}_linux_arm64.tar.gz" "easy-proxy_${version}_windows_amd64.zip" > SHA256SUMS)
echo 'Built release packages in dist/'
