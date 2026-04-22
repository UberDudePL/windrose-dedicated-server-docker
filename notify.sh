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
NOTIFY_TAIL_LINES="${NOTIFY_TAIL_LINES:-0}"
NOTIFY_DEBUG="${NOTIFY_DEBUG:-false}"
IDENTITY_MAP_FILE="${IDENTITY_MAP_FILE:-$SCRIPT_DIR/state/player-identities.tsv}"

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
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"

    # Support inline dotenv comments for unquoted values, e.g.:
    # SERVER_NAME=Windrose with Cheese # Optional server name
    if [[ "$value" != \"* && "$value" != \'* ]]; then
      value="$(printf '%s' "$value" | sed -E 's/[[:space:]]+#.*$//')"
      value="${value%"${value##*[![:space:]]}"}"
    fi

    # Strip one pair of matching surrounding quotes.
    if [[ "$value" == \"*\" && "${#value}" -ge 2 ]]; then
      value="${value:1:${#value}-2}"
    elif [[ "$value" == \'*\' && "${#value}" -ge 2 ]]; then
      value="${value:1:${#value}-2}"
    fi

    [[ -z "$key" ]] && continue

    printf -v "$key" '%s' "$value"
    export "${key?}"
  done < "$ENV_FILE"
}

load_env_file

load_identity_map() {
  [[ -f "$IDENTITY_MAP_FILE" ]] || return 0

  while IFS=$'\t' read -r key value || [[ -n "${key:-}" ]]; do
    key="$(trim "${key:-}")"
    value="$(trim "${value:-}")"
    [[ -z "$key" || -z "$value" ]] && continue
    PLAYER_NAMES["$key"]="$value"
  done < "$IDENTITY_MAP_FILE"
}

persist_identity_map() {
  local key
  local dir

  dir="$(dirname "$IDENTITY_MAP_FILE")"
  mkdir -p "$dir"

  : > "$IDENTITY_MAP_FILE.tmp"
  for key in "${!PLAYER_NAMES[@]}"; do
    [[ -z "$key" ]] && continue
    [[ -z "${PLAYER_NAMES[$key]}" ]] && continue
    printf '%s\t%s\n' "$key" "${PLAYER_NAMES[$key]}" >> "$IDENTITY_MAP_FILE.tmp"
  done

  sort -t $'\t' -k1,1 "$IDENTITY_MAP_FILE.tmp" > "$IDENTITY_MAP_FILE"
  rm -f "$IDENTITY_MAP_FILE.tmp"
}

usage() {
  cat <<EOF
Windrose activity notifier

Usage:
  $(basename "$0")
  $(basename "$0") test [optional message]

Environment:
  NOTIFY_PROVIDER=auto|discord|gotify|both
  DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/...
  GOTIFY_URL=https://gotify.example.com
  GOTIFY_TOKEN=your_app_token
  GOTIFY_PRIORITY=5
  NOTIFY_DEDUPE_WINDOW=90
  NOTIFY_TAIL_LINES=0
  NOTIFY_DEBUG=false
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
    return 1
  fi

  local payload
  payload=$(printf '{"content":"%s"}' "$(printf '%s' "$content" | sed 's/\\/\\\\/g; s/"/\\"/g')")
  curl -fsS -X POST "$DISCORD_WEBHOOK_URL" \
    -H 'Content-Type: application/json' \
    -d "$payload" >/dev/null
}

send_gotify() {
  local content="$1"

  if [[ -z "$GOTIFY_URL" || -z "$GOTIFY_TOKEN" ]]; then
    echo "[notify] GOTIFY_URL or GOTIFY_TOKEN is not set; event: $content"
    return 1
  fi

  curl -fsS -X POST "$GOTIFY_URL/message?token=$GOTIFY_TOKEN" \
    -F "title=Windrose activity" \
    -F "message=$content" \
    -F "priority=$GOTIFY_PRIORITY" >/dev/null
}

send_notification() {
  local content="$1"
  local provider
  local sent=false
  provider="$(resolve_provider)"

  case "$provider" in
    discord)
      send_discord "$content" || echo "[notify] Failed to send Discord notification" >&2
      ;;
    gotify)
      send_gotify "$content" || echo "[notify] Failed to send Gotify notification" >&2
      ;;
    both)
      if send_discord "$content"; then
        sent=true
      else
        echo "[notify] Failed to send Discord notification" >&2
      fi

      if send_gotify "$content"; then
        sent=true
      else
        echo "[notify] Failed to send Gotify notification" >&2
      fi

      if [[ "$sent" != "true" ]]; then
        echo "[notify] Failed to send notification via both backends" >&2
      fi
      ;;
    *)
      echo "[notify] No notification backend configured; event: $content"
      ;;
  esac
}

test_notification() {
  local message="${1:-⚓ Test notification from Windrose server}"
  local provider
  local sent=false

  provider="$(resolve_provider)"
  echo "[notify] Sending test notification via $provider..."

  case "$provider" in
    discord)
      send_discord "$message"
      ;;
    gotify)
      send_gotify "$message"
      ;;
    both)
      if send_discord "$message"; then
        sent=true
      else
        echo "[notify] Failed to send Discord notification" >&2
      fi

      if send_gotify "$message"; then
        sent=true
      else
        echo "[notify] Failed to send Gotify notification" >&2
      fi

      if [[ "$sent" != "true" ]]; then
        return 1
      fi
      ;;
    *)
      echo "[notify] No notification backend configured."
      return 1
      ;;
  esac

  echo "[notify] Test notification sent successfully."
}

debug_log() {
  if [[ "$NOTIFY_DEBUG" == "true" ]]; then
    echo "[notify][debug] $*" >&2
  fi
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
  [[ "$uid" == "INVALID" ]] && uid=""
  [[ -z "$uid" ]] && uid=$(printf '%s' "$line" | sed -nE 's/.*AccountId[^A-Za-z0-9]*([A-Za-z0-9_-]{6,}).*/\1/p' | head -n 1)
  printf '%s' "$uid"
}

extract_name() {
  local line="$1"
  local name=""

  name=$(printf '%s' "$line" | sed -nE 's/.*(DisplayName|PlayerName|Nickname|UserName)[:=][[:space:]]*"?([^",]+)"?.*/\2/p' | head -n 1)
  [[ -z "$name" ]] && name=$(printf '%s' "$line" | sed -nE 's/.*(DisplayName|PlayerName|Nickname|UserName)[[:space:]]+([^", ]+).*/\2/p' | head -n 1)
  [[ -z "$name" ]] && name=$(printf '%s' "$line" | sed -nE 's/.*Join succeeded:[[:space:]]*(.*)$/\1/p' | head -n 1)
  [[ -z "$name" ]] && name=$(printf '%s' "$line" | sed -nE "s/.*Name '([^']+)'.*AccountId.*/\1/p" | head -n 1)
  [[ -z "$name" ]] && name=$(printf '%s' "$line" | sed -nE 's/.*Login request[^\"]*"([^\"]+)".*/\1/p' | head -n 1)
  [[ -z "$name" ]] && name=$(printf '%s' "$line" | sed -nE "s/.*Login request[^']*'([^']+)'.*/\1/p" | head -n 1)
  [[ -z "$name" ]] && name=$(printf '%s' "$line" | sed -nE 's/.*[?&](DisplayName|PlayerName|Nickname|UserName|Name)=([^ ?&,]+).*/\2/p' | head -n 1)
  [[ -z "$name" ]] && name=$(printf '%s' "$line" | sed -nE 's/.*[?&]Name=([^ ?&,]+).*/\1/p' | head -n 1)
  [[ -z "$name" ]] && name=$(printf '%s' "$line" | sed -nE 's/.*player[[:space:]]+([^ ]+)[[:space:]]+(joined|connected|disconnected).*/\1/pI' | head -n 1)
  name="${name//+/ }"
  name=$(printf '%s' "$name" | sed -E 's/[[:space:]]+(UniqueId:.*|AccountId.*|joined.*|connected.*|disconnected.*)$//I')
  printf '%s' "$(trim "$name")"
}

is_raw_identifier() {
  local value="$1"

  [[ -z "$value" ]] && return 0
  [[ "$value" =~ ^[A-F0-9]{16,}$ ]] && return 0
  [[ "$value" =~ ^DESKTOP-[A-Z0-9-]+$ ]] && return 0
  [[ "$value" =~ ^[A-Z0-9._-]+-[A-F0-9]{12,}$ ]] && return 0
  return 1
}

remember_player_name() {
  local uid="$1"
  local name="$2"
  local null_uid=""

  if [[ -n "$uid" && -n "$name" && "$name" != "Unknown player" ]] && ! is_raw_identifier "$name"; then
    null_uid="NULL:$uid"

    if [[ "${PLAYER_NAMES[$uid]:-}" == "$name" && "${PLAYER_NAMES[$null_uid]:-}" == "$name" ]]; then
      return
    fi

    PLAYER_NAMES["$uid"]="$name"
    PLAYER_NAMES["$null_uid"]="$name"
    persist_identity_map
  fi
}

is_summary_line() {
  local line="$1"
  local lower_line="${line,,}"

  [[ "$lower_line" == *"connected accounts"* || "$lower_line" == *"disconnected accounts"* || "$lower_line" == *"reserved accounts"* ]]
}

resolve_player_label() {
  local uid="$1"
  local who="$2"
  local uid_null=""

  if [[ -n "$who" ]] && ! is_raw_identifier "$who"; then
    printf '%s' "$who"
    return
  fi

  if [[ -n "$uid" ]]; then
    uid_null="NULL:$uid"
  fi

  if [[ -n "$uid" && -n "${PLAYER_NAMES[$uid]:-}" ]] && ! is_raw_identifier "${PLAYER_NAMES[$uid]}"; then
    printf '%s' "${PLAYER_NAMES[$uid]}"
    return
  fi

  if [[ -n "$uid_null" && -n "${PLAYER_NAMES[$uid_null]:-}" ]] && ! is_raw_identifier "${PLAYER_NAMES[$uid_null]}"; then
    printf '%s' "${PLAYER_NAMES[$uid_null]}"
    return
  fi

  printf '%s' "Player"
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

is_disconnect_candidate() {
  local line="$1"
  local lower_line="${line,,}"

  [[ "$lower_line" == *"disconnectaccount"* || "$lower_line" == *"graceful close timed out"* || "$lower_line" == *" disconnected"* || "$lower_line" == *"connection lost"* || "$lower_line" == *"closing connection"* ]]
}

is_join_candidate() {
  local line="$1"
  local lower_line="${line,,}"

  # Ignore account/state snapshots that can mention connected players long after join.
  if [[ "$lower_line" == *"state connected"* || "$lower_line" == *"connected accounts"* || "$lower_line" == *"reserved accounts"* || "$lower_line" == *"disconnected accounts"* ]]; then
    return 1
  fi

  # Use only strong join signals to avoid stale false positives.
  [[ "$lower_line" == *"join succeeded"* || "$lower_line" == *"login request"* || "$lower_line" == *"join request"* || "$lower_line" == *"notifyacceptingconnection accepted"* ]]
}

parse_line() {
  local raw_line="$1"
  local line uid who label event_key
  local server_name="${SERVER_NAME:-Windrose Server}"

  line="$(normalize_line "$raw_line")"
  [[ -z "$line" ]] && return
  is_summary_line "$line" && return

  uid="$(extract_uid "$line")"
  who="$(extract_name "$line")"
  remember_player_name "$uid" "$who"
  label="$(resolve_player_label "$uid" "$who")"

  if is_disconnect_candidate "$line"; then
    debug_log "disconnect candidate: $line"

    # Skip generic disconnect lines without a resolved player name.
    # They often appear before richer lines and can cause duplicate alerts.
    if [[ "$label" == "Player" ]]; then
      return
    fi

    event_key="disconnect:${uid:-$label}"

    if should_send_event "$event_key"; then
      send_notification "⚓ $label disconnected from $server_name"
    fi
    return
  fi

  if is_join_candidate "$line"; then
    debug_log "join candidate: $line"

    if [[ "$label" == "Player" && -z "$uid" && -z "$who" ]]; then
      return
    fi

    # Avoid sending generic join notifications without a readable player name.
    # A later line often contains DisplayName/UserName for the same account.
    if [[ "$label" == "Player" ]]; then
      return
    fi

    event_key="join:${uid:-$label}"

    if should_send_event "$event_key"; then
      send_notification "⚓ $label joined $server_name"
    fi
  fi
}

main() {
  local watch_since

  if [[ "${1:-}" == "help" || "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
  fi

  if [[ "${1:-}" == "test" ]]; then
    shift || true
    test_notification "${*:-}"
    exit $?
  fi

  init_docker_cmd
  load_identity_map

  # Start watching from "now" to avoid replaying historical joins/leaves.
  watch_since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "[notify] Watching $SERVICE_NAME logs since $watch_since for player activity via $(resolve_provider)..."
  "${DOCKER_CMD[@]}" compose -f "$SCRIPT_DIR/docker-compose.yml" logs --since="$watch_since" --tail="$NOTIFY_TAIL_LINES" -f "$SERVICE_NAME" | while IFS= read -r line; do
    parse_line "$line"
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
