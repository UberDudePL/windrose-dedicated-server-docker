#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"
SERVICE_NAME="${SERVICE_NAME:-windrose}"
DOCKER_BIN="${DOCKER_BIN:-}"
DOCKER_CMD=()

NOTIFY_PROVIDER="${NOTIFY_PROVIDER:-auto}"
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
GOTIFY_URL="${GOTIFY_URL:-}"
GOTIFY_TOKEN="${GOTIFY_TOKEN:-}"
GOTIFY_PRIORITY="${GOTIFY_PRIORITY:-5}"
NOTIFY_DEDUPE_WINDOW="${NOTIFY_DEDUPE_WINDOW:-90}"

declare -A PLAYER_NAMES=()
declare -A RECENT_EVENTS=()

load_env_file() {
  [[ -f "$ENV_FILE" ]] || return 0

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue

    local key="${line%%=*}"
    local value="${line#*=}"

    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
    value="${value%$'\r'}"

    [[ -z "$key" ]] && continue

    printf -v "$key" '%s' "$value"
    export "$key"
  done < "$ENV_FILE"
}

load_env_file

usage() {
  cat <<EOF
Windrose activity notifier

Usage:
  $(basename "$0")

Environment:
  NOTIFY_PROVIDER=auto|discord|gotify
  DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/...
  GOTIFY_URL=https://gotify.example.com
  GOTIFY_TOKEN=your_app_token
  GOTIFY_PRIORITY=5
EOF
}

init_docker_cmd() {
  if [[ -n "$DOCKER_BIN" ]]; then
    read -r -a DOCKER_CMD <<< "$DOCKER_BIN"
    return
  fi

  if docker info >/dev/null 2>&1; then
    DOCKER_CMD=(docker)
  elif command -v sudo >/dev/null 2>&1; then
    DOCKER_CMD=(sudo docker)
  else
    echo "[notify] docker is not available"
    exit 1
  fi
}

resolve_provider() {
  if [[ "$NOTIFY_PROVIDER" == "auto" ]]; then
    if [[ -n "$GOTIFY_URL" && -n "$GOTIFY_TOKEN" ]]; then
      echo "gotify"
    elif [[ -n "$DISCORD_WEBHOOK_URL" ]]; then
      echo "discord"
    else
      echo "none"
    fi
  else
    echo "$NOTIFY_PROVIDER"
  fi
}

send_discord() {
  local content="$1"

  if [[ -z "$DISCORD_WEBHOOK_URL" ]]; then
    echo "[notify] DISCORD_WEBHOOK_URL is not set; event: $content"
    return
  fi

  local payload
  payload=$(printf '{"content":"%s"}' "$(printf '%s' "$content" | sed 's/\\/\\\\/g; s/"/\\"/g')")
  curl -sS -X POST "$DISCORD_WEBHOOK_URL" \
    -H 'Content-Type: application/json' \
    -d "$payload" >/dev/null || true
}

send_gotify() {
  local content="$1"

  if [[ -z "$GOTIFY_URL" || -z "$GOTIFY_TOKEN" ]]; then
    echo "[notify] GOTIFY_URL or GOTIFY_TOKEN is not set; event: $content"
    return
  fi

  curl -sS -X POST "$GOTIFY_URL/message?token=$GOTIFY_TOKEN" \
    -F "title=Windrose activity" \
    -F "message=$content" \
    -F "priority=$GOTIFY_PRIORITY" >/dev/null || true
}

send_notification() {
  local content="$1"
  local provider
  provider="$(resolve_provider)"

  case "$provider" in
    discord)
      send_discord "$content"
      ;;
    gotify)
      send_gotify "$content"
      ;;
    *)
      echo "[notify] No notification backend configured; event: $content"
      ;;
  esac
}

trim() {
  local value="$1"
  value="${value%$'\r'}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

normalize_line() {
  local line="$1"
  line="${line#*| }"
  trim "$line"
}

extract_uid() {
  local line="$1"
  local uid=""

  uid=$(printf '%s' "$line" | sed -nE 's/.*UniqueId: NULL:([^ ,]+).*/\1/p' | head -n 1)
  [[ -z "$uid" ]] && uid=$(printf '%s' "$line" | sed -nE 's/.*AccountId[^A-Za-z0-9]*([A-Za-z0-9_-]{6,}).*/\1/p' | head -n 1)
  printf '%s' "$uid"
}

extract_name() {
  local line="$1"
  local name=""

  name=$(printf '%s' "$line" | sed -nE 's/.*(DisplayName|PlayerName|Nickname|UserName)[:=][[:space:]]*"?([^",]+)"?.*/\2/p' | head -n 1)
  [[ -z "$name" ]] && name=$(printf '%s' "$line" | sed -nE 's/.*player[[:space:]]+([^ ]+)[[:space:]]+(joined|connected|disconnected).*/\1/pI' | head -n 1)
  name=$(printf '%s' "$name" | sed -E 's/[[:space:]]+(UniqueId:.*|AccountId.*|joined.*|connected.*|disconnected.*)$//I')
  printf '%s' "$(trim "$name")"
}

remember_player_name() {
  local uid="$1"
  local name="$2"

  if [[ -n "$uid" && -n "$name" && "$name" != "Unknown player" ]]; then
    PLAYER_NAMES["$uid"]="$name"
  fi
}

should_send_event() {
  local key="$1"
  local now last

  now=$(date +%s)
  last="${RECENT_EVENTS[$key]:-0}"

  if (( now - last < NOTIFY_DEDUPE_WINDOW )); then
    return 1
  fi

  RECENT_EVENTS["$key"]="$now"
  return 0
}

parse_line() {
  local raw_line="$1"
  local line uid who event_key
  local server_name="${SERVER_NAME:-Windrose Server}"

  line="$(normalize_line "$raw_line")"
  [[ -z "$line" ]] && return

  uid="$(extract_uid "$line")"
  who="$(extract_name "$line")"
  remember_player_name "$uid" "$who"

  if [[ -z "$who" && -n "$uid" && -n "${PLAYER_NAMES[$uid]:-}" ]]; then
    who="${PLAYER_NAMES[$uid]}"
  fi

  if [[ "$line" == *"DisconnectAccount"* || "$line" == *"graceful close timed out"* || "$line" == *" disconnected"* ]]; then
    [[ -z "$who" && -n "$uid" ]] && who="$uid"
    [[ -z "$who" ]] && who="Unknown player"
    event_key="disconnect:${uid:-$who}"

    if should_send_event "$event_key"; then
      send_notification "⚓ $who disconnected from $server_name"
    fi
    return
  fi

  if [[ "$line" == *" joined"* || "$line" == *" connected"* ]]; then
    [[ -z "$who" && -n "$uid" ]] && who="$uid"
    [[ -z "$who" ]] && who="Player"
    event_key="join:${uid:-$who}"

    if should_send_event "$event_key"; then
      send_notification "⚓ $who joined $server_name"
    fi
  fi
}

main() {
  if [[ "${1:-}" == "help" || "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
  fi

  init_docker_cmd
  echo "[notify] Watching $SERVICE_NAME logs for player activity via $(resolve_provider)..."
  "${DOCKER_CMD[@]}" compose -f "$SCRIPT_DIR/docker-compose.yml" logs --tail=0 -f "$SERVICE_NAME" | while IFS= read -r line; do
    parse_line "$line"
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
