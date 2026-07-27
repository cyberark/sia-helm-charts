#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# CyberArk DPA Connector — shell aliases
# Mirrors setup_connector_aliases() from the Linux installer.
# Sourced automatically via $HOME/.bashrc on kubectl exec.
# ---------------------------------------------------------------------------

_con_bin() {
  # Use the stable 'bin' symlink — always points to the current version
  # regardless of whether CONTAINER_NAME is set in this shell session.
  local pod_name
  pod_name=$(hostname)
  echo "/opt/cyberark/connector/${pod_name}/bin/linux-connector"
}

if [[ $- == *i* ]]; then
  local bin
  bin=$(_con_bin)
  printf "\n%-20s %-60s\n" "ALIAS" "COMMAND"
  printf '%*s\n' 80 "" | tr ' ' '-'
  printf "%-20s %-60s\n" "con-stop"    "kill \$(pgrep linux-connector)"
  printf "%-20s %-60s\n" "con-status"  "pgrep -a linux-connector"
  printf "%-20s %-60s\n" "con-start"   "${bin}"
  printf "%-20s %-60s\n" "con-test"    "${bin} --test"
  printf "%-20s %-60s\n" "con-version" "${bin} --version"
  printf '%*s\n' 80 "" | tr ' ' '-'
  echo ""
fi

con-stop() {
  local pid
  pid=$(pgrep linux-connector) || { echo "connector is not running"; return 0; }
  kill "${pid}" && echo "connector stopped (pid ${pid})"
}

con-status() {
  if pgrep -a linux-connector | grep --color=never 'linux-connector'; then
    echo "Active: running"
  else
    echo "Active: inactive (not running)"
  fi
}

con-start() {
  "$(_con_bin)"
}

con-test() {
  "$(_con_bin)" --test
}

con-version() {
  "$(_con_bin)" --version
}
