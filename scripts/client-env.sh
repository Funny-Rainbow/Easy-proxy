#!/usr/bin/env bash
# Source this file, then call easy_proxy_enable / easy_proxy_disable.
easy_proxy_enable() {
  local address=${1:-127.0.0.1:17890} name
  if [[ ! $address =~ ^127\.0\.0\.1:([0-9]{1,5})$ ]] || ((10#${BASH_REMATCH[1]} < 1 || 10#${BASH_REMATCH[1]} > 65535)); then
    echo 'Use a loopback address such as 127.0.0.1:17890' >&2; return 1
  fi
  if [[ ${_easy_proxy_enabled:-0} != 1 ]]; then
    declare -gA _easy_proxy_values=() _easy_proxy_present=()
    for name in HTTPS_PROXY https_proxy NO_PROXY no_proxy; do
      if [[ -v $name ]]; then _easy_proxy_present[$name]=1; _easy_proxy_values[$name]=${!name}; fi
    done
  fi
  export HTTPS_PROXY="http://$address" https_proxy="http://$address"
  export NO_PROXY="${_easy_proxy_values[NO_PROXY]:+${_easy_proxy_values[NO_PROXY]},}localhost,127.0.0.1,::1"
  export no_proxy="${_easy_proxy_values[no_proxy]:+${_easy_proxy_values[no_proxy]},}localhost,127.0.0.1,::1"
  _easy_proxy_enabled=1
  echo "HTTPS proxy enabled: http://$address"
}
easy_proxy_disable() {
  local name
  [[ ${_easy_proxy_enabled:-0} == 1 ]] || return 0
  for name in HTTPS_PROXY https_proxy NO_PROXY no_proxy; do
    if [[ ${_easy_proxy_present[$name]:-0} == 1 ]]; then export "$name=${_easy_proxy_values[$name]}"; else unset "$name"; fi
  done
  unset _easy_proxy_values _easy_proxy_present _easy_proxy_enabled
  echo 'Original proxy environment restored.'
}
