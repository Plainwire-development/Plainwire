#!/usr/bin/env bash
set -euo pipefail

users="${1:-${USERS:-1000}}"
[[ "$users" =~ ^[0-9]+$ ]] && (( users >= 1 )) || { echo "USERS must be an integer >= 1" >&2; exit 2; }

fail=0
warn() { printf 'WARN: %s\n' "$*"; }
pass() { printf 'OK:   %s\n' "$*"; }

printf 'Plainwire load host preflight (target clients: %s)\n' "$users"

soft_fd="$(ulimit -Sn 2>/dev/null || echo 0)"
hard_fd="$(ulimit -Hn 2>/dev/null || echo 0)"
# One live client costs at least one accepted socket on the target. The load
# generator itself also needs one socket per client when run on the same host;
# leave room for DB/Redis/files/logs and reconnect overlap.
needed_fd=$((users + 4096))
if [[ "$soft_fd" =~ ^[0-9]+$ ]] && (( soft_fd >= needed_fd )); then
  pass "soft fd limit $soft_fd >= suggested $needed_fd"
else
  warn "soft fd limit $soft_fd is below suggested $needed_fd; raise it before a ${users}-client test"
fi
[[ "$hard_fd" =~ ^[0-9]+$ ]] && pass "hard fd limit: $hard_fd" || true

if command -v getconf >/dev/null 2>&1; then
  cpus="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo '?')"
  pass "online CPUs: $cpus"
fi

if [[ -r /proc/meminfo ]]; then
  mem_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
  if [[ "$mem_kb" =~ ^[0-9]+$ ]]; then
    printf 'OK:   RAM: %.1f GiB\n' "$(awk -v kb="$mem_kb" 'BEGIN {print kb/1024/1024}')"
  fi
fi

if [[ -r /proc/sys/net/core/somaxconn ]]; then
  backlog="$(cat /proc/sys/net/core/somaxconn)"
  if (( backlog >= 4096 )); then pass "kernel listen backlog ceiling: $backlog"; else warn "net.core.somaxconn=$backlog; reconnect storms may overflow the accept queue"; fi
fi

if [[ -r /proc/sys/net/ipv4/ip_local_port_range ]]; then
  read -r low high < /proc/sys/net/ipv4/ip_local_port_range
  range=$((high-low+1))
  if (( range >= users )); then pass "local ephemeral port range: $low-$high ($range ports)"; else warn "local ephemeral port range has only $range ports; one-machine load generation may exhaust it"; fi
fi

if command -v erl >/dev/null 2>&1; then
  proc_limit="$(erl -noshell -eval 'io:format("~p",[erlang:system_info(process_limit)]),halt().' 2>/dev/null || echo 0)"
  if [[ "$proc_limit" =~ ^[0-9]+$ ]] && (( proc_limit >= users * 4 + 10000 )); then
    pass "BEAM process limit: $proc_limit"
  else
    warn "BEAM process limit $proc_limit may be tight; Plainwire recommends +P 2000000 for large tests"
  fi
else
  warn "erl not found; synthetic BEAM load test cannot run on this host"
fi

printf '\nNotes:\n'
printf '  - Run the load generator on a separate machine for large network tests when possible.\n'
printf '  - Cloudflare TURN removes TURN host capacity from this machine, but full-mesh media still consumes client CPU/uplink.\n'
printf '  - This preflight reports host ceilings; it does not change sysctls or limits.\n'

exit "$fail"
