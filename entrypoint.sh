#!/usr/bin/env bash
set -euo pipefail

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

SERVER_PID=""
SERVER_DESC="$SERVERDIR/R5/ServerDescription.json"

log() {
  echo "[windrose] $*"
}

quote() {
  printf '%q' "$1"
}

run_as_steam() {
  HOME="$STEAM_HOME" DISPLAY="${DISPLAY:-:99}" WINEPREFIX="$WINEPREFIX" WINEARCH="$WINEARCH" WINEDLLOVERRIDES="$WINEDLLOVERRIDES" \
    su -m -s /bin/bash steam -c "$*"
}

run_wine_as_steam() {
  run_as_steam "xvfb-run --auto-servernum --server-args='-screen 0 1024x768x16 -nolisten tcp' bash -lc $(quote "$*")"
}

wine_prefix_ready() {
  [[ -f "$WINEPREFIX/system.reg" && -f "$WINEPREFIX/drive_c/windows/system32/kernel32.dll" ]] || return 1
  grep -q '^#arch=win64' "$WINEPREFIX/system.reg" || return 1
}

print_log_file() {
  local label="$1"
  local file="$2"

  if [[ -f "$file" ]]; then
    log "$label"
    tail -n 120 "$file" || true
  fi
}

check_free_space() {
  local path="$1"
  local min_mb="$2"
  local avail_kb avail_mb

  avail_kb="$(df -Pk "$path" | awk 'NR==2 {print $4}')"
  avail_mb=$((avail_kb / 1024))

  if (( avail_mb < min_mb )); then
    log "ERROR: low disk space at $path (${avail_mb} MB free). Free at least ${min_mb} MB and start the container again."
    exit 70
  fi
}

ensure_user_mapping() {
  groupmod -o -g "$PGID" steam 2>/dev/null || true
  usermod -o -u "$PUID" steam 2>/dev/null || true

  mkdir -p "$SERVERDIR" "$STEAM_HOME"
  chown -R steam:steam /opt/steamcmd "$STEAM_HOME" "$SERVERDIR" 2>/dev/null || true
}

shutdown_server() {
  log "Stopping Windrose dedicated server"
  pkill -TERM -u steam -f 'WindroseServer-Win64-Shipping.exe' 2>/dev/null || true
  pkill -TERM -u steam -f 'wineserver' 2>/dev/null || true

  for _ in $(seq 1 30); do
    if ! pgrep -u steam -f 'WindroseServer-Win64-Shipping.exe|wineserver' >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  pkill -KILL -u steam -f 'WindroseServer-Win64-Shipping.exe|wineserver' 2>/dev/null || true
}

trap 'shutdown_server; exit 0' TERM INT

init_wine() {
  mkdir -p "$WINEPREFIX"
  chown -R steam:steam "$STEAM_HOME" 2>/dev/null || true

  if wine_prefix_ready; then
    log "Wine prefix already initialized and ready"
    return
  fi

  for attempt in 1 2; do
    if [[ "$attempt" -eq 1 ]]; then
      log "Initializing Wine prefix (attempt $attempt/2)"
    else
      log "Wine prefix incomplete, rebuilding it (attempt $attempt/2)"
      log "Removing old prefix: $WINEPREFIX"
      rm -rf "$WINEPREFIX"
      mkdir -p "$WINEPREFIX"
      chown -R steam:steam "$STEAM_HOME" 2>/dev/null || true
    fi

    log "Starting wineboot init (will timeout after 120s)..."
    local start_time=$SECONDS
    run_wine_as_steam "timeout 120 bash -c 'winecfg -v win10 >/tmp/windrose-wineboot.log 2>&1 || true; wineboot --init >>/tmp/windrose-wineboot.log 2>&1 || true; wineserver -w >/dev/null 2>&1 || true'" || true
    local elapsed=$((SECONDS - start_time))
    log "wineboot completed in ${elapsed}s"

    log "Checking if Wine prefix is ready..."
    if wine_prefix_ready; then
      log "Wine prefix ready and functional"
      return
    fi
    log "Wine prefix check failed, continuing to next attempt..."
  done

  log "ERROR: Wine prefix initialization failed after 2 attempts"
  log "Prefix state: $(ls -la "$WINEPREFIX" 2>&1 | head -5)"
  print_log_file "Recent Wine boot log:" "/tmp/windrose-wineboot.log"
  exit 1
}

update_server() {
  if [ "$UPDATE_ON_START" != "true" ]; then
    log "UPDATE_ON_START=false, skipping SteamCMD update"
    return
  fi

  local login_cmd
  if [ "$STEAM_LOGIN" = "anonymous" ]; then
    login_cmd='+login anonymous'
  elif [ -n "$STEAM_PASS" ]; then
    login_cmd="+login $(quote "$STEAM_LOGIN") $(quote "$STEAM_PASS")"
  else
    login_cmd="+login $(quote "$STEAM_LOGIN")"
  fi

  log "Updating or validating server files"
  run_as_steam "mkdir -p $(quote "$SERVERDIR") && /opt/steamcmd/steamcmd.sh +force_install_dir $(quote "$SERVERDIR") $login_cmd +app_update $(quote "$APPID") validate +quit"
}

find_server_exe() {
  find "$SERVERDIR" -iname 'WindroseServer-Win64-Shipping.exe' | head -n 1 || true
}

first_run_generate_config() {
  local exe="$1"

  if [ "$GENERATE_SETTINGS" != "true" ] || [ -f "$SERVER_DESC" ]; then
    return
  fi

  log "First run detected, generating default server config"
  run_wine_as_steam "WINEPREFIX=$(quote "$WINEPREFIX") wine $(quote "$exe") -log -MULTIHOME=$(quote "$MULTIHOME") -PORT=$(quote "$PORT") -QUERYPORT=$(quote "$QUERYPORT") >/tmp/windrose-first-run.log 2>&1" &
  local warmup_pid=$!

  local count=0
  while [ ! -f "$SERVER_DESC" ] && [ "$count" -lt "$FIRST_RUN_TIMEOUT" ]; do
    sleep 1
    count=$((count + 1))
  done

  kill "$warmup_pid" 2>/dev/null || true
  wait "$warmup_pid" 2>/dev/null || true
  pkill -TERM -u steam -f 'wineserver' 2>/dev/null || true

  if [ ! -f "$SERVER_DESC" ]; then
    log "ServerDescription.json was not generated during first run"
    print_log_file "Recent first-run log:" "/tmp/windrose-first-run.log"
  fi
}

patch_server_config() {
  if [ "$GENERATE_SETTINGS" != "true" ]; then
    log "GENERATE_SETTINGS=false, skipping JSON patching"
    return
  fi

  if [ ! -f "$SERVER_DESC" ]; then
    log "ServerDescription.json not found, skipping patch"
    return
  fi

  log "Patching ServerDescription.json from environment"
  tr -d '\r' < "$SERVER_DESC" | jq \
    --arg invite "$INVITE_CODE" \
    --arg name "$SERVER_NAME" \
    --arg note "$SERVER_NOTE" \
    --arg password "$SERVER_PASSWORD" \
    --arg proxy "$P2P_PROXY_ADDRESS" \
    --argjson maxplayers "$MAX_PLAYERS" \
    '
    .ServerDescription_Persistent.P2pProxyAddress = $proxy |
    if $invite != "" then .ServerDescription_Persistent.InviteCode = $invite else . end |
    if $name != "" then .ServerDescription_Persistent.ServerName = $name else . end |
    if $note != "" then .ServerDescription_Persistent.Note = $note else . end |
    if $password != "" then
      .ServerDescription_Persistent.IsPasswordProtected = true |
      .ServerDescription_Persistent.Password = $password
    else
      .ServerDescription_Persistent.IsPasswordProtected = false |
      .ServerDescription_Persistent.Password = ""
    end |
    .ServerDescription_Persistent.MaxPlayerCount = $maxplayers
    ' > "$SERVER_DESC.tmp"

  mv "$SERVER_DESC.tmp" "$SERVER_DESC"
  chown steam:steam "$SERVER_DESC" 2>/dev/null || true
}

start_server() {
  local exe="$1"

  log "Starting Windrose dedicated server"
  log "Executable: $exe"

  run_wine_as_steam "wine $(quote "$exe") -log -MULTIHOME=$(quote "$MULTIHOME") -PORT=$(quote "$PORT") -QUERYPORT=$(quote "$QUERYPORT")" &
  SERVER_PID=$!

  if wait "$SERVER_PID"; then
    return 0
  else
    local exit_code=$?
    log "Windrose dedicated server exited with code $exit_code"
    print_log_file "Recent Steam stderr log:" "$STEAM_HOME/Steam/logs/stderr.txt"
    return "$exit_code"
  fi
}

rebuild_wine_prefix() {
  log "Rebuilding Wine prefix at $WINEPREFIX"
  rm -rf "$WINEPREFIX"
  mkdir -p "$WINEPREFIX"
  chown -R steam:steam "$STEAM_HOME" 2>/dev/null || true
  init_wine
}

start_server_with_kernel_retry() {
  local exe="$1"
  local launch_attempt

  for launch_attempt in 1 2; do
    if start_server "$exe"; then
      return 0
    fi

    local exit_code=$?
    # Exit code 53 with kernel32.dll c0000135 usually means a broken/mismatched Wine prefix.
    if [[ "$launch_attempt" -eq 1 && "$exit_code" -eq 53 ]] && grep -q 'kernel32.dll, status c0000135' "$STEAM_HOME/Steam/logs/stderr.txt" 2>/dev/null; then
      log "Detected kernel32.dll startup failure, forcing Wine prefix rebuild and retry"
      rebuild_wine_prefix
      continue
    fi

    return "$exit_code"
  done

  return 1
}

ensure_user_mapping
check_free_space "$SERVERDIR" 512
check_free_space "$STEAM_HOME" 512
init_wine
update_server

SERVER_EXE=$(find_server_exe)
if [ -z "$SERVER_EXE" ]; then
  log "ERROR: Windrose server executable not found"
  find "$SERVERDIR" -maxdepth 4 || true
  exit 1
fi

first_run_generate_config "$SERVER_EXE"
patch_server_config
start_server_with_kernel_retry "$SERVER_EXE"
