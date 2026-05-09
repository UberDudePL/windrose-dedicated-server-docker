#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
SELF_NAME="${WINDROSE_CMD_NAME:-$(basename "$0")}"

# ANSI color policy: disable colors when NO_COLOR is set or stdout is not a TTY.
if [[ -n "${NO_COLOR:-}" || ! -t 1 ]]; then
  _COLOR_RESET=''
  _COLOR_CYAN=''
  _COLOR_GREEN=''
  _COLOR_YELLOW=''
  _COLOR_RED=''
else
  _COLOR_RESET='\033[0m'
  _COLOR_CYAN='\033[0;36m'
  _COLOR_GREEN='\033[0;32m'
  _COLOR_YELLOW='\033[1;33m'
  _COLOR_RED='\033[0;31m'
fi

log_info() {
  echo -e "${_COLOR_CYAN}[windrose]${_COLOR_RESET} $*"
}

log_ok() {
  echo -e "${_COLOR_GREEN}[windrose]${_COLOR_RESET} $*"
}

log_warn() {
  echo -e "${_COLOR_YELLOW}[windrose]${_COLOR_RESET} $*"
}

log_error() {
  echo -e "${_COLOR_RED}[windrose]${_COLOR_RESET} $*"
}

log_skip() {
  echo -e "${_COLOR_YELLOW}[windrose]${_COLOR_RESET} [SKIP] $*"
}

prompt_text() {
  printf '%b' "${_COLOR_YELLOW}[windrose]${_COLOR_RESET} $1"
}

prompt_confirm_default_no() {
  local question="$1"
  local answer

  if [[ ! -t 0 || ! -t 1 ]]; then
    log_skip "Non-interactive shell detected; defaulting to No: $question"
    return 1
  fi

  read -r -p "$(prompt_text "$question ${_COLOR_YELLOW}[y/N]${_COLOR_RESET}: ")" answer
  case "${answer,,}" in
  y | yes)
    return 0
    ;;
  *)
    return 1
    ;;
  esac
}

fatal_exit() {
  local message="$1"
  local next_step="${2:-Review the error above and rerun ./$SELF_NAME after fixing the configuration.}"

  log_error "$message"
  log_info "Next step: $next_step"
  exit 1
}

log_step() {
  echo -ne "${_COLOR_CYAN}[windrose]${_COLOR_RESET} $1..."
}

screen_title() {
  printf '\n%s\n' "== $1 =="
}

screen_section() {
  printf '\n%s\n' "[$1]"
}

screen_kv() {
  printf '  %-18s %s\n' "$1" "$2"
}

dotenv_value() {
  local key="$1"

  if [[ ! -f "$ENV_FILE" ]]; then
    return 1
  fi

  awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, "", $0); print $0}' "$ENV_FILE" | tail -n 1
}

DATA_DIR="${DATA_DIR:-$SCRIPT_DIR/data}"
SAVE_PROFILES_DEFAULT_DIR="$DATA_DIR/R5/Saved/SaveProfiles/Default"
ROCKSDB_V2_DIR="$SAVE_PROFILES_DEFAULT_DIR/RocksDB_v2"
ROCKSDB_V1_DIR="$SAVE_PROFILES_DEFAULT_DIR/RocksDB"
BACKUP_DIR="${BACKUP_DIR:-$(dotenv_value BACKUP_DIR || true)}"
BACKUP_DIR="${BACKUP_DIR:-$SCRIPT_DIR/backups}"
if [[ "$BACKUP_DIR" != /* ]]; then
  BACKUP_DIR="$SCRIPT_DIR/$BACKUP_DIR"
fi
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-$(dotenv_value BACKUP_RETENTION_DAYS || true)}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"
BACKUP_FORMAT="${BACKUP_FORMAT:-$(dotenv_value BACKUP_FORMAT || true)}"
BACKUP_FORMAT="${BACKUP_FORMAT:-tar.gz}"
BACKUP_SCOPE="${BACKUP_SCOPE:-$(dotenv_value BACKUP_SCOPE || true)}"
BACKUP_SCOPE="${BACKUP_SCOPE:-full}"
BACKUP_SKIP_ONLINE_CHECK="${BACKUP_SKIP_ONLINE_CHECK:-$(dotenv_value BACKUP_SKIP_ONLINE_CHECK || true)}"
BACKUP_SKIP_ONLINE_CHECK="${BACKUP_SKIP_ONLINE_CHECK:-false}"

COMPOSE_DIR="${COMPOSE_DIR:-$SCRIPT_DIR}"
SERVICE_NAME="${SERVICE_NAME:-$(dotenv_value SERVICE_NAME || true)}"
SERVICE_NAME="${SERVICE_NAME:-windrose}"
DOCKER_BIN="${DOCKER_BIN:-}"
DOCKER_CMD=()

NOTIFY_PROVIDER="${NOTIFY_PROVIDER:-$(dotenv_value NOTIFY_PROVIDER || true)}"
NOTIFY_PROVIDER="${NOTIFY_PROVIDER:-auto}"
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-$(dotenv_value DISCORD_WEBHOOK_URL || true)}"
GOTIFY_URL="${GOTIFY_URL:-$(dotenv_value GOTIFY_URL || true)}"
GOTIFY_TOKEN="${GOTIFY_TOKEN:-$(dotenv_value GOTIFY_TOKEN || true)}"
GOTIFY_PRIORITY="${GOTIFY_PRIORITY:-$(dotenv_value GOTIFY_PRIORITY || true)}"
GOTIFY_PRIORITY="${GOTIFY_PRIORITY:-5}"
TIMESTAMP="$(date +%F-%H%M%S)"
declare -a CREATED_BACKUPS=()

case "$BACKUP_FORMAT" in
tar.gz)
  ARCHIVE_EXT="tar.gz"
  ;;
zip)
  ARCHIVE_EXT="zip"
  ;;
*)
  fatal_exit "unsupported BACKUP_FORMAT '$BACKUP_FORMAT' (supported: tar.gz, zip)" "Set BACKUP_FORMAT to tar.gz or zip in .env, then rerun ./$SELF_NAME."
  ;;
esac

case "$BACKUP_SCOPE" in
full | save | both) ;;
*)
  fatal_exit "unsupported BACKUP_SCOPE '$BACKUP_SCOPE' (supported: full, save, both)" "Set BACKUP_SCOPE to full, save, or both in .env, then rerun ./$SELF_NAME."
  ;;
esac

run_quiet() {
  "$@" >/dev/null 2>&1
}

init_docker_cmd() {
  if [[ -n "$DOCKER_BIN" ]]; then
    read -r -a DOCKER_CMD <<<"$DOCKER_BIN"
    return
  fi

  if docker info >/dev/null 2>&1; then
    DOCKER_CMD=(docker)
  elif command -v sudo >/dev/null 2>&1; then
    DOCKER_CMD=(sudo docker)
  else
    DOCKER_CMD=()
  fi
}

dc_backup() {
  if [[ ${#DOCKER_CMD[@]} -eq 0 ]]; then
    return 1
  fi
  (
    cd "$COMPOSE_DIR"
    "${DOCKER_CMD[@]}" compose "$@"
  )
}

resolve_notify_provider() {
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

send_backup_discord() {
  local content="$1"
  if [[ -z "$DISCORD_WEBHOOK_URL" ]]; then
    return 1
  fi
  local payload
  payload=$(printf '{"content":"%s"}' "$(printf '%s' "$content" | sed 's/\\/\\\\/g; s/"/\\"/g')")
  curl -fsS -X POST "$DISCORD_WEBHOOK_URL" \
    -H 'Content-Type: application/json' \
    -d "$payload" >/dev/null
}

send_backup_gotify() {
  local content="$1"
  if [[ -z "$GOTIFY_URL" || -z "$GOTIFY_TOKEN" ]]; then
    return 1
  fi
  curl -fsS -X POST "$GOTIFY_URL/message?token=$GOTIFY_TOKEN" \
    -F "title=Windrose backup" \
    -F "message=$content" \
    -F "priority=$GOTIFY_PRIORITY" >/dev/null
}

send_backup_notification() {
  local content="$1"
  local provider
  provider="$(resolve_notify_provider)"

  case "$provider" in
  discord)
    send_backup_discord "$content" || log_warn "Failed to send Discord notification"
    ;;
  gotify)
    send_backup_gotify "$content" || log_warn "Failed to send Gotify notification"
    ;;
  both)
    send_backup_discord "$content" || log_warn "Failed to send Discord notification"
    send_backup_gotify "$content" || log_warn "Failed to send Gotify notification"
    ;;
  *)
    return 0
    ;;
  esac
}

check_players_online() {
  if [[ "$BACKUP_SKIP_ONLINE_CHECK" == "true" ]]; then
    return 0
  fi

  init_docker_cmd

  if [[ ${#DOCKER_CMD[@]} -eq 0 ]]; then
    log_warn "Docker not available; skipping online player check"
    return 0
  fi

  # Skip check if container is not running
  if ! dc_backup ps --status running --services 2>/dev/null | grep -Fx "$SERVICE_NAME" >/dev/null 2>&1; then
    return 0
  fi

  screen_section "Online Player Check"

  local log_tmp parsed_tmp
  log_tmp="$(mktemp)"
  parsed_tmp="$(mktemp)"

  if ! dc_backup logs --no-color --timestamps --since 24h "$SERVICE_NAME" 2>&1 | sed 's/\.[0-9]*Z/Z/' >"$log_tmp"; then
    rm -f "$log_tmp" "$parsed_tmp"
    log_warn "Could not read container logs; skipping online player check"
    return 0
  fi

  awk '
    {
      line = $0
      low = tolower(line)
      player = ""
      type = ""

      if (low ~ /lognet: join succeeded:/) {
        sub(/.*[Jj]oin succeeded:[[:space:]]*/, "", line)
        player = line
        type = "join"
      } else if (low ~ /lognet: leave:/) {
        sub(/.*[Ll]eave:[[:space:]]*/, "", line)
        player = line
        type = "leave"
      } else if (match(line, /Name '\''([^'\'']+)'\''.*State '\''SaidFarewell'\''/, m)) {
        player = m[1]
        type = "leave"
      } else if (match(tolower(line), /disconnectaccount.*accountid[[:space:]]+([a-z0-9]+)/, m)) {
        player = toupper(m[1])
        type = "leave"
      }

      gsub(/^[[:space:]]+|[[:space:]]+$/, "", player)
      if (player != "" && player != "INVALID" && player != "NULL") {
        print type "\t" player
      }
    }
  ' "$log_tmp" >"$parsed_tmp"

  rm -f "$log_tmp"

  declare -A online_players=()
  local event_type event_player
  while IFS=$'\t' read -r event_type event_player; do
    [[ -z "$event_type" || -z "$event_player" ]] && continue
    case "$event_type" in
    join) online_players["$event_player"]="1" ;;
    leave) unset 'online_players[$event_player]' ;;
    esac
  done <"$parsed_tmp"

  rm -f "$parsed_tmp"

  local online_count=${#online_players[@]}

  if [[ "$online_count" -gt 0 ]]; then
    log_error "Backup aborted: ${online_count} player(s) currently online."
    log_info "Use BACKUP_SKIP_ONLINE_CHECK=true to override."
    send_backup_notification "Windrose backup aborted: ${online_count} player(s) currently online. Run backup manually after the session ends."
    return 1
  fi

  log_ok "No players online — safe to proceed"
  return 0
}

check_backup_disk_space() {
  local data_dir="$1"
  local backup_dir="$2"
  local estimated_backup_size_mb=0
  local free_disk_mb=0
  local disk_mount="unknown"
  local safety_margin_mb=$((1024 * 2)) # 2 GB safety margin

  # Estimate backup size (1.5x the data directory size as rough estimate)
  if [[ -d "$data_dir" ]]; then
    estimated_backup_size_mb=$(du -sm "$data_dir" 2>/dev/null | awk '{printf "%d", int($1 * 1.5)}' || echo 0)
  fi

  # Check free disk space
  read -r free_disk_mb disk_mount < <(df -Pm "$backup_dir" | awk 'NR==2 {print $4, $6}')

  screen_section "Disk Space Check"

  if [[ -n "$estimated_backup_size_mb" ]] && [[ "$estimated_backup_size_mb" -gt 0 ]]; then
    screen_kv "estimated backup size:" "$((estimated_backup_size_mb / 1024)) GB (+ ${safety_margin_mb} MB margin)"
  fi

  if [[ "$free_disk_mb" =~ ^[0-9]+$ ]] && [[ "$free_disk_mb" -gt 0 ]]; then
    screen_kv "free disk (${disk_mount}):" "$((free_disk_mb / 1024)) GB"

    local required_space_mb=$((estimated_backup_size_mb + safety_margin_mb))
    if [[ "$free_disk_mb" -lt "$required_space_mb" ]]; then
      log_error "Not enough free disk space. Need ${required_space_mb} MB but only ${free_disk_mb} MB available."
      log_info "Next step: free up disk space or change BACKUP_DIR to a mount with more capacity."
      return 1
    fi
    log_ok "Sufficient disk space available"
  else
    log_warn "Could not detect free disk space; proceeding with caution"
  fi

  return 0
}

install_zip_package() {
  if command -v apt-get >/dev/null 2>&1; then
    if [[ "$EUID" -eq 0 ]]; then
      run_quiet apt-get install -y zip
    elif command -v sudo >/dev/null 2>&1; then
      run_quiet sudo apt-get install -y zip
    else
      log_error "need root privileges to install zip (sudo not available)."
      return 1
    fi
    return 0
  fi

  if command -v dnf >/dev/null 2>&1; then
    if [[ "$EUID" -eq 0 ]]; then
      run_quiet dnf install -y zip
    elif command -v sudo >/dev/null 2>&1; then
      run_quiet sudo dnf install -y zip
    else
      log_error "need root privileges to install zip (sudo not available)."
      return 1
    fi
    return 0
  fi

  if command -v yum >/dev/null 2>&1; then
    if [[ "$EUID" -eq 0 ]]; then
      run_quiet yum install -y zip
    elif command -v sudo >/dev/null 2>&1; then
      run_quiet sudo yum install -y zip
    else
      log_error "need root privileges to install zip (sudo not available)."
      return 1
    fi
    return 0
  fi

  if command -v apk >/dev/null 2>&1; then
    if [[ "$EUID" -eq 0 ]]; then
      run_quiet apk add --no-cache zip
    elif command -v sudo >/dev/null 2>&1; then
      run_quiet sudo apk add --no-cache zip
    else
      log_error "need root privileges to install zip (sudo not available)."
      return 1
    fi
    return 0
  fi

  if command -v pacman >/dev/null 2>&1; then
    if [[ "$EUID" -eq 0 ]]; then
      run_quiet pacman -Sy --noconfirm zip
    elif command -v sudo >/dev/null 2>&1; then
      run_quiet sudo pacman -Sy --noconfirm zip
    else
      log_error "need root privileges to install zip (sudo not available)."
      return 1
    fi
    return 0
  fi

  log_error "unsupported package manager. Install zip manually."
  return 1
}

ensure_zip_available() {
  if command -v zip >/dev/null 2>&1; then
    return 0
  fi

  if [[ ! -t 0 || ! -t 1 ]]; then
    log_skip "Non-interactive shell detected; defaulting to No: zip command not found. Install it now?"
    log_info "Next step: install zip package manually, or set BACKUP_FORMAT=tar.gz and rerun ./$SELF_NAME."
    return 1
  fi

  if prompt_confirm_default_no "zip command not found. Install it now?"; then
    log_info "Installing zip package..."
    if ! install_zip_package; then
      log_error "failed to install zip package."
      log_info "Next step: install zip manually or set BACKUP_FORMAT=tar.gz, then rerun ./$SELF_NAME."
      return 1
    fi
    if ! command -v zip >/dev/null 2>&1; then
      log_error "zip command still not available after installation."
      log_info "Next step: verify zip is on PATH or set BACKUP_FORMAT=tar.gz, then rerun ./$SELF_NAME."
      return 1
    fi
    log_ok "zip package installed successfully."
  else
    log_error "zip is required for BACKUP_FORMAT=zip. Install zip or set BACKUP_FORMAT=tar.gz"
    log_info "Next step: install zip or set BACKUP_FORMAT=tar.gz in .env, then rerun ./$SELF_NAME."
    return 1
  fi
}

if [[ ! -d "$DATA_DIR/R5" ]]; then
  fatal_exit "expected data directory not found at $DATA_DIR/R5" "Verify DATA_DIR points to your Windrose data path, then rerun ./$SELF_NAME."
fi

if [[ "$BACKUP_SCOPE" == "save" || "$BACKUP_SCOPE" == "both" ]]; then
  if [[ ! -d "$DATA_DIR/R5/Saved" ]]; then
    fatal_exit "expected save directory not found at $DATA_DIR/R5/Saved" "Verify DATA_DIR and BACKUP_SCOPE, then rerun ./$SELF_NAME."
  fi
fi

mkdir -p "$BACKUP_DIR"
BACKUP_DIR="$(cd "$BACKUP_DIR" && pwd)"

screen_title "Windrose Backup"
screen_section "Configuration"
screen_kv "scope:" "$BACKUP_SCOPE"
screen_kv "format:" "$BACKUP_FORMAT"
screen_kv "source:" "$DATA_DIR"
screen_kv "output dir:" "$BACKUP_DIR"
screen_kv "retention:" "${BACKUP_RETENTION_DAYS} days"

if [[ "$BACKUP_SCOPE" == "save" || "$BACKUP_SCOPE" == "both" ]]; then
  log_info "Backup scope '$BACKUP_SCOPE' archives the full R5/Saved tree; RocksDB and RocksDB_v2 are both included when present."

  if [[ -d "$ROCKSDB_V2_DIR" && -d "$ROCKSDB_V1_DIR" ]]; then
    log_info "Detected save roots: RocksDB and RocksDB_v2. Both will be archived."
  elif [[ -d "$ROCKSDB_V2_DIR" ]]; then
    log_info "Detected save root: RocksDB_v2. It will be archived."
  elif [[ -d "$ROCKSDB_V1_DIR" ]]; then
    log_info "Detected save root: RocksDB. It will be archived."
  else
    log_warn "No RocksDB save root detected under $SAVE_PROFILES_DEFAULT_DIR. R5/Saved will still be archived as configured."
  fi
fi

if ! check_players_online; then
  exit 1
fi

if ! check_backup_disk_space "$DATA_DIR" "$BACKUP_DIR"; then
  exit 1
fi

create_archive() {
  local label="$1"
  local archive_path="$2"
  shift 2

  screen_section "Backup: $label"

  log_step "Create archive"
  if [[ "$BACKUP_FORMAT" == "zip" ]]; then
    if ! (
      cd "$DATA_DIR"
      zip -qr "$archive_path" "$@" >/dev/null 2>&1
    ); then
      echo -e " ${_COLOR_RED}FAIL${_COLOR_RESET}"
      log_error "Failed to create backup archive: $archive_path"
      return 1
    fi
  else
    if ! tar -czf "$archive_path" -C "$DATA_DIR" "$@" >/dev/null 2>&1; then
      echo -e " ${_COLOR_RED}FAIL${_COLOR_RESET}"
      log_error "Failed to create backup archive: $archive_path"
      return 1
    fi
  fi
  echo -e " ${_COLOR_GREEN}OK${_COLOR_RESET}"
  screen_kv "archive:" "$(basename "$archive_path")"

  log_step "Verify archive integrity"
  if [[ "$BACKUP_FORMAT" == "zip" ]]; then
    if ! zip -T "$archive_path" >/dev/null 2>&1; then
      echo -e " ${_COLOR_RED}FAIL${_COLOR_RESET}"
      log_error "Backup integrity verification failed: $archive_path"
      return 1
    fi
  else
    if ! tar -tzf "$archive_path" >/dev/null 2>&1; then
      echo -e " ${_COLOR_RED}FAIL${_COLOR_RESET}"
      log_error "Backup integrity verification failed: $archive_path"
      return 1
    fi
  fi
  echo -e " ${_COLOR_GREEN}OK${_COLOR_RESET}"

  CREATED_BACKUPS+=("$archive_path")
}

if [[ "$BACKUP_FORMAT" == "zip" ]]; then
  ensure_zip_available || exit 1
fi

if [[ "$BACKUP_SCOPE" == "full" || "$BACKUP_SCOPE" == "both" ]]; then
  create_archive "full" "$BACKUP_DIR/windrose-backup-full-$TIMESTAMP.$ARCHIVE_EXT" R5
fi

if [[ "$BACKUP_SCOPE" == "save" || "$BACKUP_SCOPE" == "both" ]]; then
  save_items=(R5/Saved)
  if [[ -f "$DATA_DIR/R5/ServerDescription.json" ]]; then
    save_items+=(R5/ServerDescription.json)
  fi
  create_archive "save" "$BACKUP_DIR/windrose-backup-save-$TIMESTAMP.$ARCHIVE_EXT" "${save_items[@]}"
fi

if [[ "$BACKUP_RETENTION_DAYS" =~ ^[0-9]+$ ]] && [[ "$BACKUP_RETENTION_DAYS" -gt 0 ]]; then
  find "$BACKUP_DIR" -maxdepth 1 -type f \( -name 'windrose-backup-*.tar.gz' -o -name 'windrose-backup-*.zip' \) -mtime +"$BACKUP_RETENTION_DAYS" -delete >/dev/null 2>&1 || true
fi

screen_section "Summary"
screen_kv "created:" "${#CREATED_BACKUPS[@]}"
if [[ "${#CREATED_BACKUPS[@]}" -gt 0 ]]; then
  for created_backup in "${CREATED_BACKUPS[@]}"; do
    screen_kv "archive:" "$(basename "$created_backup")"
  done
fi
log_ok "Backup completed."
