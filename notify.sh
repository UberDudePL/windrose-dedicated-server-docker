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

parse_line() {
  local line="$1"
  local server_name="${SERVER_NAME:-Windrose Server}"

  if [[ "$line" == *"DisconnectAccount"* || "$line" == *"graceful close timed out"* ]]; then
    local who
    who=$(printf '%s' "$line" | sed -n 's/.*UniqueId: NULL:\([^ ]*\).*/\1/p')
    [[ -z "$who" ]] && who="Unknown player"
    send_notification "⚓ $who disconnected from $server_name"
    return
  fi

  if [[ "$line" == *"Join"* || "$line" == *"joined"* || "$line" == *"connected"* ]]; then
    send_notification "⚓ Player activity detected on $server_name: $line"
  fi
}

main() {
  if [[ "${1:-}" == "help" || "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
  fi

  init_docker_cmd
  echo "[notify] Watching $SERVICE_NAME logs for player activity via $(resolve_provider)..."
  "${DOCKER_CMD[@]}" compose -f "$SCRIPT_DIR/docker-compose.yml" logs -f "$SERVICE_NAME" | while IFS= read -r line; do
    parse_line "$line"
  done
}

main "$@"
