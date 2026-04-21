#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC2034 # Used by sourced script: /opt/windrose/scripts/server.sh
APPID=${WINDROSE_APP_ID:-4129620}

SERVERDIR=${SERVERDIR:-/data}
STEAM_HOME=${STEAM_HOME:-/home/steam}
WINEPREFIX=${WINEPREFIX:-$STEAM_HOME/.wine}
WINEARCH=${WINEARCH:-win64}
WINEDLLOVERRIDES=${WINEDLLOVERRIDES:-mscoree,mshtml=}
STEAM_LOGIN=${STEAM_LOGIN:-anonymous}
STEAM_PASS=${STEAM_PASS:-}
UPDATE_ON_START=${UPDATE_ON_START:-true}
GENERATE_SETTINGS=${GENERATE_SETTINGS:-true}
PUID=${PUID:-1000}
PGID=${PGID:-1000}

PORT=${PORT:-7777}
QUERYPORT=${QUERYPORT:-7778}
MULTIHOME=${MULTIHOME:-0.0.0.0}
INVITE_CODE=${INVITE_CODE:-}
SERVER_NAME=${SERVER_NAME:-}
SERVER_NOTE=${SERVER_NOTE:-}
SERVER_PASSWORD=${SERVER_PASSWORD:-}
MAX_PLAYERS=${MAX_PLAYERS:-4}
P2P_PROXY_ADDRESS=${P2P_PROXY_ADDRESS:-127.0.0.1}
FIRST_RUN_TIMEOUT=${FIRST_RUN_TIMEOUT:-300}

# shellcheck disable=SC2034 # Used by sourced script: /opt/windrose/scripts/server.sh
SERVER_PID=""
# shellcheck disable=SC2034 # Used by sourced script: /opt/windrose/scripts/server.sh
SERVER_DESC="$SERVERDIR/R5/ServerDescription.json"

SCRIPT_ROOT=${WINDROSE_SCRIPT_DIR:-/opt/windrose/scripts}

if [[ ! -d "$SCRIPT_ROOT" ]]; then
  SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts"
fi

# shellcheck source=/dev/null
source "$SCRIPT_ROOT/common.sh"
# shellcheck source=/dev/null
source "$SCRIPT_ROOT/wine.sh"
# shellcheck source=/dev/null
source "$SCRIPT_ROOT/server.sh"

trap 'shutdown_server; exit 0' TERM INT

ensure_user_mapping
check_free_space "$SERVERDIR" 512
check_free_space "$STEAM_HOME" 512
init_wine
update_server

SERVER_EXE=$(find_server_exe)
if [ -z "$SERVER_EXE" ]; then
  log_error "Windrose server executable not found"
  find "$SERVERDIR" -maxdepth 4 || true
  exit 1
fi

first_run_generate_config "$SERVER_EXE"
patch_server_config
start_server_with_kernel_retry "$SERVER_EXE"
