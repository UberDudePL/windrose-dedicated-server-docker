#!/usr/bin/env bash

shutdown_server() {
  log_info "Stopping Windrose dedicated server"
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

update_server() {
  if [ "$UPDATE_ON_START" != "true" ]; then
    log_info "UPDATE_ON_START=false, skipping SteamCMD update"
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

  log_info "Initializing SteamCMD (bootstrap pass)"
  run_as_steam "mkdir -p $(quote "$SERVERDIR") && /opt/steamcmd/steamcmd.sh +quit" >/dev/null 2>&1 || true

  log_info "Updating or validating server files"
  local attempts=0
  local exit_code=0
  while [ "$attempts" -lt 3 ]; do
    attempts=$((attempts + 1))

    if run_as_steam "mkdir -p $(quote "$SERVERDIR") && /opt/steamcmd/steamcmd.sh +force_install_dir $(quote "$SERVERDIR") $login_cmd +app_update $(quote "$APPID") validate +quit"; then
      return 0
    fi

    exit_code=$?
    if [ "$exit_code" -eq 254 ]; then
      log_warn "SteamCMD self-updated (exit 254), retrying ($attempts/3)"
      sleep 2
      continue
    fi

    log_error "SteamCMD failed with exit code $exit_code"
    return "$exit_code"
  done

  log_error "SteamCMD still failed after retries (last exit code: $exit_code)"
  return "$exit_code"
}

find_server_exe() {
  find "$SERVERDIR" -iname 'WindroseServer-Win64-Shipping.exe' | head -n 1 || true
}

server_launch_args() {
  printf '%s' "-log -stdout -FullStdOutLogOutput -AllowStdOutLogVerbosity -forcelogflush -UTF8Output -MULTIHOME=$(quote "$MULTIHOME") -PORT=$(quote "$PORT") -QUERYPORT=$(quote "$QUERYPORT")"
}

first_run_generate_config() {
  local exe="$1"

  if [ "$GENERATE_SETTINGS" != "true" ] || [ -f "$SERVER_DESC" ]; then
    return
  fi

  log_info "First run detected, generating default server config"
  run_wine_as_steam "WINEPREFIX=$(quote "$WINEPREFIX") wine $(quote "$exe") $(server_launch_args) >/tmp/windrose-first-run.log 2>&1" &
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
    log_warn "ServerDescription.json was not generated during first run"
    print_log_file "Recent first-run log:" "/tmp/windrose-first-run.log"
  fi
}

patch_server_config() {
  if [ "$GENERATE_SETTINGS" != "true" ]; then
    log_info "GENERATE_SETTINGS=false, skipping JSON patching"
    return
  fi

  if [ ! -f "$SERVER_DESC" ]; then
    log_warn "ServerDescription.json not found, skipping patch"
    return
  fi

  log_info "Patching ServerDescription.json from environment"
  tr -d '\r' <"$SERVER_DESC" | jq \
    --arg invite "$INVITE_CODE" \
    --arg name "$SERVER_NAME" \
    --arg note "$SERVER_NOTE" \
    --arg password "$SERVER_PASSWORD" \
    --arg proxy "$P2P_PROXY_ADDRESS" \
    --argjson directconn "${USE_DIRECT_CONNECTION:-false}" \
    --argjson dcport "${DIRECT_CONNECTION_SERVER_PORT:-7777}" \
    --arg dcproxy "${DIRECT_CONNECTION_PROXY_ADDRESS:-0.0.0.0}" \
    --arg region "${USER_SELECTED_REGION:-}" \
    --argjson maxplayers "$MAX_PLAYERS" \
    '
    .ServerDescription_Persistent.P2pProxyAddress = $proxy |
    .ServerDescription_Persistent.UseDirectConnection = $directconn |
    .ServerDescription_Persistent.DirectConnectionServerPort = $dcport |
    .ServerDescription_Persistent.DirectConnectionProxyAddress = $dcproxy |
    if $region != "" then .ServerDescription_Persistent.UserSelectedRegion = $region else . end |
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
    ' >"$SERVER_DESC.tmp"

  mv "$SERVER_DESC.tmp" "$SERVER_DESC"
  chown steam:steam "$SERVER_DESC" 2>/dev/null || true
}

start_server() {
  local exe="$1"

  log_info "Starting Windrose dedicated server"
  log_info "Executable: $exe"

  run_wine_as_steam "wine $(quote "$exe") $(server_launch_args)" &
  SERVER_PID=$!

  if wait "$SERVER_PID"; then
    return 0
  fi

  local exit_code=$?
  log_error "Windrose dedicated server exited with code $exit_code"
  print_log_file "Recent Steam stderr log:" "$STEAM_HOME/Steam/logs/stderr.txt"
  return "$exit_code"
}

start_server_with_kernel_retry() {
  local exe="$1"
  local launch_attempt

  for launch_attempt in 1 2; do
    if start_server "$exe"; then
      return 0
    fi

    local exit_code=$?
    if [[ "$launch_attempt" -eq 1 && "$exit_code" -eq 53 ]] && grep -q 'kernel32.dll, status c0000135' "$STEAM_HOME/Steam/logs/stderr.txt" 2>/dev/null; then
      log_warn "Detected kernel32.dll startup failure, forcing Wine prefix rebuild and retry"
      dump_wine_diagnostics
      rebuild_wine_prefix
      continue
    fi

    return "$exit_code"
  done

  return 1
}
