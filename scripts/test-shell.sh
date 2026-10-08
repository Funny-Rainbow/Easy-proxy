#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
for file in internal/manage/*.sh scripts/*.sh;do bash -n "$file";done
source scripts/client-env.sh
export HTTPS_PROXY=https://previous.example:443 NO_PROXY=previous.example
unset https_proxy no_proxy
easy_proxy_enable
[[ $HTTPS_PROXY == http://127.0.0.1:17890 && $NO_PROXY == previous.example,localhost,127.0.0.1,::1 ]]
easy_proxy_enable 127.0.0.1:17891
easy_proxy_disable
[[ $HTTPS_PROXY == https://previous.example:443 && $NO_PROXY == previous.example && ! -v https_proxy && ! -v no_proxy ]]
if easy_proxy_enable 0.0.0.0:1234;then exit 1;fi
if easy_proxy_enable 127.0.0.1:99999;then exit 1;fi
echo 'Bash environment restoration passed.'
