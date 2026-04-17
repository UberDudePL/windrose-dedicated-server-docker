#!/usr/bin/env bash
set -euo pipefail

SERVERDIR=${SERVERDIR:-/data}
PORT=${PORT:-7777}
QUERYPORT=${QUERYPORT:-7778}
HEALTHCHECK_REQUIRE_UDP=${HEALTHCHECK_REQUIRE_UDP:-false}
SERVER_DESC="$SERVERDIR/R5/ServerDescription.json"

log() {
  echo "[healthcheck] $*"
}

check_udp_port() {
  local port_hex
  port_hex="$(printf '%04X' "$1")"

  awk -v target=":$port_hex" '
    NR > 1 {
      local_addr = toupper($2)
      if (substr(local_addr, length(local_addr) - 4) == target) {
        found = 1
      }
    }
    END {
      exit(found ? 0 : 1)
    }
  ' /proc/net/udp /proc/net/udp6
}

if ! pgrep -f 'WindroseServer-Win64-Shipping.exe' >/dev/null 2>&1; then
  log "server process not found"
  exit 1
fi

if [[ ! -d "$SERVERDIR/R5" ]]; then
  log "server data directory missing at $SERVERDIR/R5"
  exit 1
fi

if [[ "$HEALTHCHECK_REQUIRE_UDP" == "true" ]]; then
  if ! check_udp_port "$PORT" && ! check_udp_port "$QUERYPORT"; then
    log "neither UDP port $PORT nor $QUERYPORT is listening yet"
    exit 1
  fi
fi

if [[ -f "$SERVER_DESC" ]]; then
  if ! jq -e '.ServerDescription_Persistent' "$SERVER_DESC" >/dev/null 2>&1; then
    log "ServerDescription.json exists but is not valid JSON"
    exit 1
  fi
else
  log "ServerDescription.json not generated yet"
fi

log "ok"
