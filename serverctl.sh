#!/usr/bin/env bash
set -euo pipefail

resolve_script_dir() {
  local src="${BASH_SOURCE[0]}"

  while [[ -L "$src" ]]; do
    local dir
    dir="$(cd -P -- "$(dirname -- "$src")" && pwd)"
    src="$(readlink "$src")"
    [[ "$src" != /* ]] && src="$dir/$src"
  done

  cd -P -- "$(dirname -- "$src")" && pwd
}

SCRIPT_DIR="$(resolve_script_dir)"
COMPOSE_DIR="${COMPOSE_DIR:-$SCRIPT_DIR}"
SERVICE_NAME="${SERVICE_NAME:-windrose}"
MODE="${WINDROSE_MODE:-auto}"
DOCKER_BIN="${DOCKER_BIN:-}"
SELF_NAME="${WINDROSE_CMD_NAME:-$(basename "$0")}"
SERVER_DESC_FILE="$SCRIPT_DIR/data/R5/ServerDescription.json"
ROCKSDB_DIR="$SCRIPT_DIR/data/R5/Saved/SaveProfiles/Default/RocksDB"
WORLD_NAME_PENDING_FILE=".windrose-world-name"
UPDATE_LOG_DIR="$SCRIPT_DIR/logs"
UPDATE_LOG_FILE="$UPDATE_LOG_DIR/update.log"
MUTATION_LOCK_DIR="$SCRIPT_DIR/logs/.windrose-mutation-lock"
MUTATION_LOCK_META="$MUTATION_LOCK_DIR/meta"
DOCKER_CMD=()
MUTATION_LOCK_HELD="false"

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
    log_info "Non-interactive shell detected; defaulting to No: $question"
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

prompt_confirm_default_yes() {
  local question="$1"
  local answer

  if [[ ! -t 0 || ! -t 1 ]]; then
    log_info "Non-interactive shell detected; defaulting to Yes: $question"
    return 0
  fi

  read -r -p "$(prompt_text "$question ${_COLOR_YELLOW}[Y/n]${_COLOR_RESET}: ")" answer
  case "${answer,,}" in
  "" | y | yes)
    return 0
    ;;
  *)
    return 1
    ;;
  esac
}

fatal_exit() {
  local message="$1"
  local next_step="${2:-Review the error above and run ./$SELF_NAME doctor for diagnostics.}"

  log_error "$message"
  log_info "Next step: $next_step"
  exit 1
}

fatal_return() {
  local message="$1"
  local next_step="${2:-Review the error above and run ./$SELF_NAME doctor for diagnostics.}"

  log_error "$message"
  log_info "Next step: $next_step"
  return 1
}

log_step() {
  echo -ne "${_COLOR_CYAN}[windrose]${_COLOR_RESET} $1..."
}

log_step_done() {
  echo -e " ${_COLOR_GREEN}OK${_COLOR_RESET}"
}

log_step_failed() {
  echo -e " ${_COLOR_RED}FAIL${_COLOR_RESET}"
}

log_step_pending() {
  echo -e " ${_COLOR_YELLOW}SKIP${_COLOR_RESET}"
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

render_progress_bar() {
  local percent="$1"
  local width=30
  local filled empty
  local filled_bar empty_bar

  filled=$((percent * width / 100))
  empty=$((width - filled))

  filled_bar="$(printf '%*s' "$filled" '' | tr ' ' '#')"
  empty_bar="$(printf '%*s' "$empty" '' | tr ' ' '-')"

  printf '\r[windrose] Update progress [%s%s] %3d%%' "$filled_bar" "$empty_bar" "$percent"
  if [[ "$percent" -ge 100 ]]; then
    printf '\n'
  fi
}

rotate_update_logs() {
  rm -f "$UPDATE_LOG_FILE.3"
  [[ -f "$UPDATE_LOG_FILE.2" ]] && mv "$UPDATE_LOG_FILE.2" "$UPDATE_LOG_FILE.3"
  [[ -f "$UPDATE_LOG_FILE.1" ]] && mv "$UPDATE_LOG_FILE.1" "$UPDATE_LOG_FILE.2"
  [[ -f "$UPDATE_LOG_FILE" ]] && mv "$UPDATE_LOG_FILE" "$UPDATE_LOG_FILE.1"
  return 0
}

append_update_log() {
  printf '[%s] %s\n' "$(date -Ins)" "$*" >>"$UPDATE_LOG_FILE"
}

is_utf8_locale() {
  local active_locale="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
  [[ "${active_locale,,}" == *"utf-8"* || "${active_locale,,}" == *"utf8"* ]]
}

init_docker_cmd() {
  if ! command -v docker >/dev/null 2>&1; then
    log_error "[FAIL] docker is not installed or not in PATH."
    exit 1
  fi

  if [[ -n "$DOCKER_BIN" ]]; then
    read -r -a DOCKER_CMD <<<"$DOCKER_BIN"
    return
  fi

  if docker info >/dev/null 2>&1; then
    DOCKER_CMD=(docker)
  elif command -v sudo >/dev/null 2>&1; then
    DOCKER_CMD=(sudo docker)
  else
    log_error "[FAIL] docker needs elevated permissions and sudo is not available."
    log_info "Next step: run with DOCKER_BIN='sudo docker' ./$SELF_NAME status"
    exit 1
  fi
}

require_tools() {
  if [[ ! -f "$COMPOSE_DIR/docker-compose.yml" ]]; then
    log_error "[FAIL] docker-compose.yml not found in $COMPOSE_DIR"
    exit 1
  fi
}

dotenv_value() {
  local key="$1"
  local env_file="$SCRIPT_DIR/.env"

  if [[ ! -f "$env_file" ]]; then
    return 1
  fi

  awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, "", $0); print $0}' "$env_file" | tail -n 1
}

detect_mode() {
  if [[ "$MODE" == "auto" ]]; then
    if [[ -f "$COMPOSE_DIR/docker-compose.dev.yml" && "${COMPOSE_DIR##*/}" == *dev* ]]; then
      echo "dev"
    else
      echo "prod"
    fi
  else
    echo "$MODE"
  fi
}

ACTIVE_MODE="$(detect_mode)"
COMPOSE_FILES=(-f docker-compose.yml)
if [[ "$ACTIVE_MODE" == "dev" && -f "$COMPOSE_DIR/docker-compose.dev.yml" ]]; then
  COMPOSE_FILES+=(-f docker-compose.dev.yml)
fi

dc() {
  (
    cd "$COMPOSE_DIR"
    "${DOCKER_CMD[@]}" compose "${COMPOSE_FILES[@]}" "$@"
  )
}

usage() {
  cat <<EOF
Windrose helper script

Usage:
  $SELF_NAME setup
  $SELF_NAME start
  $SELF_NAME stop
  $SELF_NAME restart
  $SELF_NAME status
  $SELF_NAME status-json
  $SELF_NAME doctor
  $SELF_NAME diagnostics [log-lines]
  $SELF_NAME logs
  $SELF_NAME activity [events|history|status] [lines]
  $SELF_NAME worlds
  $SELF_NAME worlds-check
  $SELF_NAME worlds-prune [--apply]
  $SELF_NAME switch
  $SELF_NAME notify [test [message]|status]
  $SELF_NAME backup
  $SELF_NAME restore-preview [archive]
  $SELF_NAME install-backup-cron [schedule]
  $SELF_NAME pull
  $SELF_NAME update [--force-down]
  $SELF_NAME update-log [lines]
  $SELF_NAME down
  $SELF_NAME install [target]

Sections:
  Lifecycle     setup, start, stop, restart, down, install
  Health        status, status-json, status-snapshot, doctor, diagnostics, logs
  Activity      activity, notify
  Worlds        worlds, worlds-check, worlds-prune, switch
  Data safety   backup, restore-preview, install-backup-cron
  Updates       pull, update, update-log

Notes:
  - compose directory: $COMPOSE_DIR
  - detected mode: $ACTIVE_MODE
  - docker permissions are auto-detected; set DOCKER_BIN manually only if needed
  - set WINDROSE_MODE=prod or WINDROSE_MODE=dev to override auto detection
  - backup archives default to ./backups with 7-day retention
  - legacy aliases kept: player-history, player-events, test-notify
EOF
}

acquire_mutation_lock() {
  local op="$1"
  local now

  mkdir -p "$(dirname "$MUTATION_LOCK_DIR")"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if mkdir "$MUTATION_LOCK_DIR" 2>/dev/null; then
    {
      echo "pid=$$"
      echo "op=$op"
      echo "started_at=$now"
    } >"$MUTATION_LOCK_META"
    MUTATION_LOCK_HELD="true"
    return 0
  fi

  log_error "Another state-changing operation is already in progress."
  if [[ -f "$MUTATION_LOCK_META" ]]; then
    log_info "Current lock metadata:"
    sed 's/^/  /' "$MUTATION_LOCK_META"
  fi
  log_info "Wait for it to finish, then retry: ./$SELF_NAME $op"
  exit 1
}

release_mutation_lock() {
  if [[ "$MUTATION_LOCK_HELD" == "true" ]]; then
    rm -rf "$MUTATION_LOCK_DIR"
    MUTATION_LOCK_HELD="false"
  fi
}

is_mutating_command() {
  local cmd="$1"

  case "$cmd" in
  setup | start | stop | restart | switch | worlds-prune | backup | install-backup-cron | pull | update | down)
    return 0
    ;;
  *)
    return 1
    ;;
  esac
}

start_server() {
  log_step "Starting server ($ACTIVE_MODE mode)"
  if ! dc up -d >/dev/null 2>&1; then
    log_step_failed
    log_error "Failed to start server."
    exit 1
  fi
  log_step_done
}

stop_server() {
  log_step "Stopping server"
  if ! dc stop "$SERVICE_NAME" >/dev/null 2>&1; then
    log_step_failed
    log_error "Failed to stop server."
    exit 1
  fi
  log_step_done
}

server_is_running() {
  dc ps --status running --services 2>/dev/null | grep -Fx "$SERVICE_NAME" >/dev/null 2>&1
}

require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    log_error "jq is required for world switching. Install jq on the host and try again."
    exit 1
  fi
}

detect_world_version() {
  if [[ ! -d "$ROCKSDB_DIR" ]]; then
    return 1
  fi

  find "$ROCKSDB_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -V | tail -n 1
}

generate_world_id() {
  od -An -N16 -tx1 /dev/urandom | tr -d ' \n' | tr '[:lower:]' '[:upper:]'
}

worlds_dir_for_version() {
  local version="$1"
  printf '%s' "$ROCKSDB_DIR/$version/Worlds"
}

world_description_file() {
  local version="$1"
  local world_id="$2"
  printf '%s' "$(worlds_dir_for_version "$version")/$world_id/WorldDescription.json"
}

world_pending_name_file() {
  local version="$1"
  local world_id="$2"
  printf '%s' "$(worlds_dir_for_version "$version")/$world_id/$WORLD_NAME_PENDING_FILE"
}

read_pending_world_name() {
  local version="$1"
  local world_id="$2"
  local pending_file

  pending_file="$(world_pending_name_file "$version" "$world_id")"
  if [[ -f "$pending_file" ]]; then
    head -n 1 "$pending_file"
  fi
}

write_pending_world_name() {
  local version="$1"
  local world_id="$2"
  local world_name="$3"
  local pending_file

  pending_file="$(world_pending_name_file "$version" "$world_id")"
  printf '%s\n' "$world_name" >"$pending_file"
}

sync_world_name_metadata() {
  local version="$1"
  local world_id="$2"
  local world_name="$3"
  local world_desc_file tmp_file pending_file

  [[ -z "$world_name" ]] && return 1

  world_desc_file="$(world_description_file "$version" "$world_id")"
  pending_file="$(world_pending_name_file "$version" "$world_id")"
  if [[ ! -f "$world_desc_file" ]]; then
    return 1
  fi

  tmp_file="$world_desc_file.tmp"
  jq --arg world_name "$world_name" '.WorldDescription.WorldName = $world_name' "$world_desc_file" >"$tmp_file"
  mv "$tmp_file" "$world_desc_file"
  rm -f "$pending_file"
  return 0
}

apply_pending_world_name() {
  local version="$1"
  local world_id="$2"
  local pending_name

  pending_name="$(read_pending_world_name "$version" "$world_id")"
  if [[ -n "$pending_name" ]]; then
    sync_world_name_metadata "$version" "$world_id" "$pending_name" >/dev/null 2>&1 || true
  fi
}

wait_and_sync_world_name() {
  local version="$1"
  local world_id="$2"
  local world_name="$3"

  [[ -z "$world_name" ]] && return 0

  log_step "Waiting for world metadata so the new name can be saved"
  for _ in $(seq 1 60); do
    if sync_world_name_metadata "$version" "$world_id" "$world_name" >/dev/null 2>&1; then
      log_step_done
      log_ok "Saved world name to metadata: $world_name"
      return 0
    fi
    if ! server_is_running; then
      break
    fi
    sleep 1
  done

  log_step_pending
  log_warn "World metadata is not available yet. The requested name will be applied automatically later."
  return 0
}

load_world_ids() {
  local worlds_dir="$1"

  find "$worlds_dir" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort
}

world_display_name() {
  local version="$1"
  local world_id="$2"
  local current_world_id="$3"
  local current_server_name="$4"
  local world_desc_file world_name pending_name

  apply_pending_world_name "$version" "$world_id"

  world_desc_file="$(world_description_file "$version" "$world_id")"
  if [[ -f "$world_desc_file" ]]; then
    world_name="$(jq -r '.WorldDescription.WorldName // empty' "$world_desc_file" 2>/dev/null || true)"
    if [[ -n "$world_name" && "$world_name" != "null" ]]; then
      printf '%s' "$world_name"
      return 0
    fi
  fi

  pending_name="$(read_pending_world_name "$version" "$world_id")"
  if [[ -n "$pending_name" ]]; then
    printf '%s' "$pending_name"
    return 0
  fi

  if [[ "$world_id" == "$current_world_id" && -n "$current_server_name" ]]; then
    printf '%s' "$current_server_name"
    return 0
  fi

  printf '%s' "$world_id"
}

world_is_initialized() {
  local version="$1"
  local world_id="$2"
  local world_desc_file

  world_desc_file="$(world_description_file "$version" "$world_id")"
  [[ -f "$world_desc_file" ]]
}

world_is_pending_init() {
  local version="$1"
  local world_id="$2"
  local pending_file

  pending_file="$(world_pending_name_file "$version" "$world_id")"
  [[ -f "$pending_file" ]]
}

world_is_ghost_placeholder() {
  local version="$1"
  local world_id="$2"
  local world_dir extra_entry

  if world_is_initialized "$version" "$world_id"; then
    return 1
  fi

  if ! world_is_pending_init "$version" "$world_id"; then
    return 1
  fi

  world_dir="$(worlds_dir_for_version "$version")/$world_id"
  extra_entry="$(find "$world_dir" -mindepth 1 -maxdepth 1 ! -name "$WORLD_NAME_PENDING_FILE" -print -quit 2>/dev/null || true)"
  [[ -z "$extra_entry" ]]
}

should_hide_world_from_list() {
  local version="$1"
  local world_id="$2"
  local current_world_id="$3"

  if [[ "$world_id" == "$current_world_id" ]]; then
    return 1
  fi

  world_is_ghost_placeholder "$version" "$world_id"
}

build_visible_world_ids() {
  local version="$1"
  local worlds_dir="$2"
  local current_world_id="$3"
  local world_id

  while IFS= read -r world_id; do
    if should_hide_world_from_list "$version" "$world_id" "$current_world_id"; then
      continue
    fi
    printf '%s\n' "$world_id"
  done < <(load_world_ids "$worlds_dir")
}

print_world_header() {
  local version="$1"
  local worlds_dir="$2"

  log_info "Worlds"
  echo -e "${_COLOR_CYAN}  Save version:${_COLOR_RESET} $version"
  echo -e "${_COLOR_CYAN}  Worlds path:${_COLOR_RESET} $worlds_dir"
  echo
}

print_world_entry() {
  local index="$1"
  local display_name="$2"
  local is_current="$3"
  local is_pending="$4"

  printf '  %b%d)%b %s' "${_COLOR_CYAN}" "$index" "${_COLOR_RESET}" "$display_name"

  if [[ "$is_current" == "true" ]]; then
    printf ' %b[current]%b' "${_COLOR_GREEN}" "${_COLOR_RESET}"
  fi

  if [[ "$is_pending" == "true" ]]; then
    printf ' %b[pending init]%b' "${_COLOR_YELLOW}" "${_COLOR_RESET}"
  fi

  printf '\n'
}

print_worlds() {
  local version="$1"
  local current_world_id="$2"
  local current_server_name="$3"
  local worlds_dir display_name
  local is_current is_pending
  local -a world_ids=()

  worlds_dir="$(worlds_dir_for_version "$version")"
  while IFS= read -r world_id; do
    world_ids+=("$world_id")
  done < <(build_visible_world_ids "$version" "$worlds_dir" "$current_world_id")

  print_world_header "$version" "$worlds_dir"

  if ((${#world_ids[@]} == 0)); then
    log_warn "No existing worlds were found for version $version."
    return 0
  fi

  for i in "${!world_ids[@]}"; do
    display_name="$(world_display_name "$version" "${world_ids[$i]}" "$current_world_id" "$current_server_name")"
    if [[ "${world_ids[$i]}" == "$current_world_id" ]]; then
      is_current="true"
    else
      is_current="false"
    fi

    if ! world_is_initialized "$version" "${world_ids[$i]}" && world_is_pending_init "$version" "${world_ids[$i]}"; then
      is_pending="true"
    else
      is_pending="false"
    fi

    print_world_entry "$((i + 1))" "$display_name" "$is_current" "$is_pending"
  done
}

list_worlds() {
  local version current_world_id current_server_name

  require_jq

  if [[ ! -f "$SERVER_DESC_FILE" ]]; then
    log_error "ServerDescription.json not found at $SERVER_DESC_FILE"
    log_info "Start the server once so the game can generate its config, then try again."
    exit 1
  fi

  version="$(detect_world_version || true)"
  if [[ -z "$version" ]]; then
    log_error "No RocksDB version directory found under $ROCKSDB_DIR"
    log_info "Start the server once so the save path is initialized, then try again."
    exit 1
  fi

  current_world_id="$(jq -r '.ServerDescription_Persistent.WorldIslandId // empty' "$SERVER_DESC_FILE")"
  current_server_name="$(jq -r '.ServerDescription_Persistent.ServerName // empty' "$SERVER_DESC_FILE")"
  print_worlds "$version" "$current_world_id" "$current_server_name"
}

check_worlds() {
  local version worlds_dir world_id pending_file extra_entry
  local issue_count=0

  version="$(detect_world_version || true)"
  if [[ -z "$version" ]]; then
    log_error "No RocksDB version directory found under $ROCKSDB_DIR"
    log_info "Start the server once so the save path is initialized, then try again."
    exit 1
  fi

  worlds_dir="$(worlds_dir_for_version "$version")"
  if [[ ! -d "$worlds_dir" ]]; then
    log_warn "Worlds directory does not exist yet: $worlds_dir"
    return 0
  fi

  log_info "Checking worlds for orphan or broken entries"
  echo -e "${_COLOR_CYAN}  Save version:${_COLOR_RESET} $version"
  echo -e "${_COLOR_CYAN}  Worlds path:${_COLOR_RESET} $worlds_dir"

  while IFS= read -r world_id; do
    if world_is_initialized "$version" "$world_id"; then
      continue
    fi

    issue_count=$((issue_count + 1))
    pending_file="$(world_pending_name_file "$version" "$world_id")"
    extra_entry="$(find "$worlds_dir/$world_id" -mindepth 1 -maxdepth 1 ! -name "$WORLD_NAME_PENDING_FILE" -print -quit 2>/dev/null || true)"

    if [[ -f "$pending_file" && -z "$extra_entry" ]]; then
      echo -e "  ${_COLOR_YELLOW}- $world_id${_COLOR_RESET}: pending placeholder (only $WORLD_NAME_PENDING_FILE)"
    elif [[ -f "$pending_file" ]]; then
      echo -e "  ${_COLOR_YELLOW}- $world_id${_COLOR_RESET}: incomplete world (missing WorldDescription.json, has pending name)"
    else
      echo -e "  ${_COLOR_RED}- $world_id${_COLOR_RESET}: broken world (missing WorldDescription.json)"
    fi
  done < <(load_world_ids "$worlds_dir")

  if [[ "$issue_count" -eq 0 ]]; then
    log_ok "No orphan or broken worlds detected."
  else
    log_warn "Detected $issue_count orphan or broken world entries."
  fi
}

worlds_prune() {
  local version worlds_dir current_world_id apply_mode="no"
  local world_id candidate_paths=()

  require_jq

  if [[ ! -f "$SERVER_DESC_FILE" ]]; then
    log_error "ServerDescription.json not found at $SERVER_DESC_FILE"
    log_info "Start the server once so the game can generate its config, then try again."
    exit 1
  fi

  version="$(detect_world_version || true)"
  if [[ -z "$version" ]]; then
    log_warn "No RocksDB version directory found under $ROCKSDB_DIR"
    log_info "Start the server once so the save path is initialized, then try again."
    return 0
  fi

  worlds_dir="$(worlds_dir_for_version "$version")"
  if [[ ! -d "$worlds_dir" ]]; then
    log_warn "Worlds directory does not exist: $worlds_dir"
    return 0
  fi

  if [[ "${1:-}" == "--apply" ]]; then
    apply_mode="yes"
  fi

  current_world_id="$(jq -r '.ServerDescription_Persistent.WorldIslandId // empty' "$SERVER_DESC_FILE" 2>/dev/null || true)"
  if [[ -z "$current_world_id" || "$current_world_id" == "null" ]]; then
    log_warn "Current world is not defined in $SERVER_DESC_FILE"
  fi

  while IFS= read -r world_id; do
    if [[ -z "$world_id" || "$world_id" == "$current_world_id" ]]; then
      continue
    fi
    candidate_paths+=("$worlds_dir/$world_id")
  done < <(load_world_ids "$worlds_dir")

  if [[ ${#candidate_paths[@]} -eq 0 ]]; then
    log_ok "No non-active world directories found to prune."
    return 0
  fi

  log_info "Worlds prune dry-run candidates:"
  for world_id in "${candidate_paths[@]}"; do
    echo "  - $world_id"
  done

  if [[ "$apply_mode" != "yes" ]]; then
    log_info "Dry run only. Re-run with --apply to delete these candidate world directories."
    return 0
  fi

  if [[ ! -t 0 || ! -t 1 ]]; then
    fatal_exit "Cannot apply worlds-prune in a non-interactive shell." "Run this command in an interactive shell with --apply when you are ready to remove non-active worlds."
  fi

  if ! prompt_confirm_default_no "Delete ${#candidate_paths[@]} non-active world(s) from $worlds_dir?"; then
    log_info "World prune canceled."
    return 0
  fi

  for world_id in "${candidate_paths[@]}"; do
    if [[ -d "$world_id" ]]; then
      rm -rf "$world_id"
      log_ok "Removed $world_id"
    fi
  done

  log_ok "Removed ${#candidate_paths[@]} non-active world(s)."
}

switch_world() {
  local version worlds_dir current_world_id current_server_name was_running=""
  local selected_id choice tmp_file created_new="false" new_world_name=""
  local -a world_ids=()

  require_jq

  if [[ ! -f "$SERVER_DESC_FILE" ]]; then
    log_error "ServerDescription.json not found at $SERVER_DESC_FILE"
    log_info "Start the server once so the game can generate its config, then try again."
    exit 1
  fi

  version="$(detect_world_version || true)"
  if [[ -z "$version" ]]; then
    log_error "No RocksDB version directory found under $ROCKSDB_DIR"
    log_info "Start the server once so the save path is initialized, then try again."
    exit 1
  fi

  worlds_dir="$ROCKSDB_DIR/$version/Worlds"
  mkdir -p "$worlds_dir"

  current_world_id="$(jq -r '.ServerDescription_Persistent.WorldIslandId // empty' "$SERVER_DESC_FILE")"
  if [[ -z "$current_world_id" || "$current_world_id" == "null" ]]; then
    log_error "WorldIslandId is missing in $SERVER_DESC_FILE"
    exit 1
  fi

  current_server_name="$(jq -r '.ServerDescription_Persistent.ServerName // empty' "$SERVER_DESC_FILE")"

  while IFS= read -r world_id; do
    world_ids+=("$world_id")
  done < <(build_visible_world_ids "$version" "$worlds_dir" "$current_world_id")

  print_worlds "$version" "$current_world_id" "$current_server_name"

  echo -e "  ${_COLOR_CYAN}N)${_COLOR_RESET} Create a new world"
  echo -e "  ${_COLOR_CYAN}Q)${_COLOR_RESET} Cancel"
  echo
  read -r -p "$(prompt_text "Select a world: ")" choice

  case "$choice" in
  [Qq])
    log_info "World switch canceled."
    return 0
    ;;
  [Nn])
    selected_id="$(generate_world_id)"
    mkdir -p "$worlds_dir/$selected_id"
    created_new="true"
    if ! is_utf8_locale; then
      log_warn "Current shell locale is not UTF-8. Non-ASCII world names may display incorrectly."
      log_warn "Consider: export LANG=C.UTF-8"
    fi
    read -r -p "$(prompt_text "New world name (optional): ")" new_world_name
    if [[ -n "$new_world_name" ]]; then
      write_pending_world_name "$version" "$selected_id" "$new_world_name"
    fi
    ;;
  *)
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || ((choice < 1 || choice > ${#world_ids[@]})); then
      log_error "Invalid selection."
      exit 1
    fi
    selected_id="${world_ids[$((choice - 1))]}"
    ;;
  esac

  if server_is_running; then
    was_running="yes"
    log_step "Stopping server before world switch"
    if ! dc stop "$SERVICE_NAME" >/dev/null 2>&1; then
      log_step_failed
      log_error "Failed to stop container before changing WorldIslandId."
      exit 1
    fi
    log_step_done
  fi

  tmp_file="$SERVER_DESC_FILE.tmp"
  jq --arg world_id "$selected_id" '.ServerDescription_Persistent.WorldIslandId = $world_id' "$SERVER_DESC_FILE" >"$tmp_file"
  mv "$tmp_file" "$SERVER_DESC_FILE"

  if [[ "$created_new" == "true" ]]; then
    if [[ -n "$new_world_name" ]]; then
      log_ok "Created and selected new world: $new_world_name"
    else
      log_ok "Created and selected new world: $selected_id"
    fi
    log_info "The server will initialize the new world data on next start."
  elif [[ "$selected_id" == "$current_world_id" ]]; then
    log_ok "World remains unchanged: $(world_display_name "$version" "$selected_id" "$current_world_id" "$current_server_name")"
  else
    log_ok "Selected world: $(world_display_name "$version" "$selected_id" "$current_world_id" "$current_server_name")"
  fi

  if [[ -n "$was_running" ]]; then
    log_step "Starting server again"
    if ! dc up -d >/dev/null 2>&1; then
      log_step_failed
      log_error "World was switched, but the container failed to start again."
      exit 1
    fi
    log_step_done
    if [[ "$created_new" == "true" && -n "$new_world_name" ]]; then
      wait_and_sync_world_name "$version" "$selected_id" "$new_world_name"
    fi
  else
    log_info "Server was not running. Start it manually when you want to load the selected world."
  fi
}

restart_server() {
  log_step "Restarting server"
  if ! dc restart "$SERVICE_NAME"; then
    dc stop "$SERVICE_NAME" || true
    if ! dc up -d >/dev/null 2>&1; then
      log_step_failed
      log_error "Failed to restart server."
      exit 1
    fi
  fi
  log_step_done
  dc ps
}

status_server() {
  local container_name running compose_state compose_status compose_name health
  local activity_since="24h"
  local online_tmp_file
  local online_now="unknown"
  local last_event="unknown"
  local players_short="unknown"
  local backup_dir latest_backup backup_age backup_mtime now_ts age_secs
  local backup_is_old="false"
  local notify_pid_file="$SCRIPT_DIR/state/notify.pid"
  local notify_pid=""
  local notifier_state="not running"
  local provider configured_provider resolved_provider
  local -a next_steps=()

  container_name="$(dotenv_value CONTAINER_NAME 2>/dev/null || true)"
  container_name="${container_name:-$SERVICE_NAME}"

  if server_is_running; then
    running="yes"
  else
    running="no"
  fi

  compose_state="unknown"
  compose_status="unknown"
  compose_name="$container_name"
  local compose_line
  compose_line="$(dc ps --all --format '{{.Service}}|{{.State}}|{{.Status}}|{{.Name}}' 2>/dev/null | awk -F'|' -v svc="$SERVICE_NAME" '$1 == svc {print; exit}' || true)"
  if [[ -n "$compose_line" ]]; then
    compose_state="$(printf '%s' "$compose_line" | awk -F'|' '{print $2}')"
    compose_status="$(printf '%s' "$compose_line" | awk -F'|' '{print $3}')"
    compose_name="$(printf '%s' "$compose_line" | awk -F'|' '{print $4}')"
  fi

  health="$("${DOCKER_CMD[@]}" inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_name" 2>/dev/null || true)"
  health="${health//$'\n'/}"
  health="${health:-unknown}"

  online_tmp_file="$(mktemp)"
  if activity_collect_metrics "" "$online_tmp_file" "$activity_since"; then
    online_now="$ACTIVITY_METRICS_ONLINE_COUNT"
    last_event="$ACTIVITY_METRICS_LAST_EVENT_TS"
    players_short="$(awk -F'\t' 'NR<=3 { entry = ($2 != "" ? $2 " [" $1 "]" : $1); if (out == "") out = entry; else out = out ", " entry } END { print out }' "$online_tmp_file")"
    if [[ -z "$players_short" ]]; then
      players_short="(none)"
    fi
    if [[ "$online_now" =~ ^[0-9]+$ ]] && ((online_now > 3)); then
      players_short+=" ..."
    fi
  else
    log_warn "Activity metrics unavailable; showing partial status."
  fi
  rm -f "$online_tmp_file"

  backup_dir="$(dotenv_value BACKUP_DIR 2>/dev/null || true)"
  backup_dir="${backup_dir:-$SCRIPT_DIR/backups}"
  if [[ "$backup_dir" != /* ]]; then
    backup_dir="$SCRIPT_DIR/$backup_dir"
  fi

  backup_age="unknown"
  if [[ -d "$backup_dir" ]]; then
    latest_backup="$(find "$backup_dir" -maxdepth 1 -type f \( -name 'windrose-backup-*.tar.gz' -o -name 'windrose-backup-*.zip' \) -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | awk '{print $2}')"
    if [[ -z "$latest_backup" ]]; then
      backup_age="none"
      backup_is_old="true"
    else
      backup_mtime="$(stat -c %Y "$latest_backup" 2>/dev/null || true)"
      now_ts="$(date +%s)"
      if [[ -n "$backup_mtime" && "$backup_mtime" =~ ^[0-9]+$ ]]; then
        age_secs=$((now_ts - backup_mtime))
        if ((age_secs < 3600)); then
          backup_age="$((age_secs / 60))m ago"
        elif ((age_secs < 86400)); then
          backup_age="$((age_secs / 3600))h ago"
        else
          backup_age="$((age_secs / 86400))d ago"
        fi
        if ((age_secs > 172800)); then
          backup_is_old="true"
        fi
      fi
    fi
  fi

  if [[ -f "$notify_pid_file" ]]; then
    notify_pid="$(head -n 1 "$notify_pid_file" 2>/dev/null || true)"
    if [[ -n "$notify_pid" ]] && ! kill -0 "$notify_pid" >/dev/null 2>&1; then
      rm -f "$notify_pid_file"
      notify_pid=""
    fi
  fi
  if [[ -z "$notify_pid" ]]; then
    notify_pid="$(pgrep -f "$SCRIPT_DIR/notify.sh" | head -n 1 || true)"
  fi
  if [[ -n "$notify_pid" ]]; then
    notifier_state="running (pid $notify_pid)"
  fi

  configured_provider="${NOTIFY_PROVIDER:-$(dotenv_value NOTIFY_PROVIDER || true)}"
  configured_provider="${configured_provider:-auto}"
  provider="$configured_provider"
  if [[ "$configured_provider" == "auto" ]]; then
    local gotify_url_resolve gotify_token_resolve discord_webhook_url_resolve
    gotify_url_resolve="${GOTIFY_URL:-$(dotenv_value GOTIFY_URL || true)}"
    gotify_token_resolve="${GOTIFY_TOKEN:-$(dotenv_value GOTIFY_TOKEN || true)}"
    discord_webhook_url_resolve="${DISCORD_WEBHOOK_URL:-$(dotenv_value DISCORD_WEBHOOK_URL || true)}"
    if [[ -n "$gotify_url_resolve" && -n "$gotify_token_resolve" ]]; then
      resolved_provider="gotify"
    elif [[ -n "$discord_webhook_url_resolve" ]]; then
      resolved_provider="discord"
    else
      resolved_provider="none"
    fi
  else
    resolved_provider="$configured_provider"
  fi

  screen_title "Windrose Operator Status"

  screen_section "Runtime/Container"
  screen_kv "mode:" "$ACTIVE_MODE"
  screen_kv "service:" "$SERVICE_NAME"
  screen_kv "container:" "$compose_name"
  screen_kv "running:" "$running"
  screen_kv "state:" "$compose_state"
  screen_kv "status:" "$compose_status"
  screen_kv "health:" "$health"

  screen_section "Game/Activity"
  screen_kv "online now:" "$online_now"
  screen_kv "players:" "$players_short"
  screen_kv "last event:" "$last_event"

  screen_section "Operations"
  screen_kv "backup age:" "$backup_age"
  screen_kv "notifier:" "$notifier_state"
  screen_kv "provider:" "$provider -> $resolved_provider"

  if [[ "$running" != "yes" || "$compose_state" == "exited" || "$compose_state" == "dead" ]]; then
    next_steps+=("./$SELF_NAME start")
  elif [[ "$health" == "unhealthy" ]]; then
    next_steps+=("./$SELF_NAME logs")
  fi

  if [[ "$notifier_state" == "not running" && "$resolved_provider" != "none" ]]; then
    next_steps+=("./$SELF_NAME notify")
  fi

  if [[ "$backup_is_old" == "true" ]]; then
    next_steps+=("./$SELF_NAME backup")
  fi

  if ((${#next_steps[@]} > 0)); then
    screen_section "Next Steps"
    printf '  1) %s\n' "${next_steps[0]}"
    if ((${#next_steps[@]} > 1)); then
      printf '  2) %s\n' "${next_steps[1]}"
    fi
  fi
}

status_json() {
  local container_name running health="unknown"
  local invite_code="" world_id="" server_name=""
  local generated_at

  container_name="$(dotenv_value CONTAINER_NAME || true)"
  container_name="${container_name:-$SERVICE_NAME}"

  if server_is_running; then
    running="true"
  else
    running="false"
  fi

  health="$("${DOCKER_CMD[@]}" inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_name" 2>/dev/null || true)"
  health="${health//$'\n'/}"
  if [[ -z "$health" ]]; then
    health="not-found"
  fi
  generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if [[ -f "$SERVER_DESC_FILE" ]] && command -v jq >/dev/null 2>&1; then
    invite_code="$(jq -r '.ServerDescription_Persistent.InviteCode // .InviteCode // empty' "$SERVER_DESC_FILE" 2>/dev/null || true)"
    world_id="$(jq -r '.ServerDescription_Persistent.WorldIslandId // empty' "$SERVER_DESC_FILE" 2>/dev/null || true)"
    server_name="$(jq -r '.ServerDescription_Persistent.ServerName // empty' "$SERVER_DESC_FILE" 2>/dev/null || true)"
  fi

  if command -v jq >/dev/null 2>&1; then
    jq -n \
      --arg mode "$ACTIVE_MODE" \
      --arg service "$SERVICE_NAME" \
      --arg container "$container_name" \
      --arg running "$running" \
      --arg health "$health" \
      --arg invite_code "$invite_code" \
      --arg world_id "$world_id" \
      --arg server_name "$server_name" \
      --arg generated_at "$generated_at" \
      '{
                mode: $mode,
                service: $service,
                container: $container,
                running: ($running == "true"),
                health: $health,
                invite_code: $invite_code,
                world_id: $world_id,
                server_name: $server_name,
                generated_at: $generated_at
            }'
  else
    printf '{"mode":"%s","service":"%s","container":"%s","running":%s,"health":"%s","invite_code":"%s","world_id":"%s","server_name":"%s","generated_at":"%s"}\n' \
      "$ACTIVE_MODE" "$SERVICE_NAME" "$container_name" "$running" "$health" "$invite_code" "$world_id" "$server_name" "$generated_at"
  fi
}

status_snapshot() {
  local running health invite_code world_id server_name
  local backup_dir latest_backup backup_age
  local container_name

  container_name="$(dotenv_value CONTAINER_NAME 2>/dev/null || true)"
  container_name="${container_name:-$SERVICE_NAME}"

  if server_is_running; then
    running="yes"
  else
    running="no"
  fi

  health="$("${DOCKER_CMD[@]}" inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_name" 2>/dev/null || true)"
  health="${health//$'\n'/}"
  health="${health:-unknown}"

  invite_code=""
  world_id=""
  server_name=""
  if [[ -f "$SERVER_DESC_FILE" ]] && command -v jq >/dev/null 2>&1; then
    invite_code="$(jq -r '.ServerDescription_Persistent.InviteCode // ""' "$SERVER_DESC_FILE" 2>/dev/null || true)"
    world_id="$(jq -r '.ServerDescription_Persistent.WorldIslandId // ""' "$SERVER_DESC_FILE" 2>/dev/null || true)"
    server_name="$(jq -r '.ServerDescription_Persistent.ServerName // ""' "$SERVER_DESC_FILE" 2>/dev/null || true)"
  fi

  backup_dir="$(dotenv_value BACKUP_DIR 2>/dev/null || true)"
  backup_dir="${backup_dir:-$SCRIPT_DIR/backups}"
  if [[ "$backup_dir" != /* ]]; then
    backup_dir="$SCRIPT_DIR/$backup_dir"
  fi

  backup_age="unknown"
  if [[ -d "$backup_dir" ]]; then
    latest_backup="$(find "$backup_dir" -maxdepth 1 -type f \( -name 'windrose-backup-*.tar.gz' -o -name 'windrose-backup-*.zip' \) -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | awk '{print $2}')"
    if [[ -z "$latest_backup" ]]; then
      backup_age="none"
    else
      local backup_mtime now_ts age_secs
      backup_mtime="$(stat -c %Y "$latest_backup" 2>/dev/null || true)"
      now_ts="$(date +%s)"
      if [[ -n "$backup_mtime" && "$backup_mtime" =~ ^[0-9]+$ ]]; then
        age_secs=$((now_ts - backup_mtime))
        if ((age_secs < 3600)); then
          backup_age="$((age_secs / 60))m ago"
        elif ((age_secs < 86400)); then
          backup_age="$((age_secs / 3600))h ago"
        else
          backup_age="$((age_secs / 86400))d ago"
        fi
      else
        backup_age="unknown"
      fi
    fi
  fi

  local invite_display
  if [[ -n "$invite_code" ]]; then
    invite_display="set"
  else
    invite_display="not set"
  fi

  screen_title "Windrose Status Snapshot"

  screen_section "Runtime"
  screen_kv "mode:" "${ACTIVE_MODE:-unknown}"
  screen_kv "running:" "$running"
  screen_kv "health:" "$health"

  screen_section "Server"
  screen_kv "server:" "${server_name:-unknown}"
  screen_kv "world:" "${world_id:-unknown}"
  screen_kv "invite code:" "$invite_display"

  screen_section "Backup"
  screen_kv "backup age:" "$backup_age"
  screen_kv "backup dir:" "$backup_dir"
}

doctor_server() {
  local min_ram_mb=8192
  local min_disk_mb=8192
  local total_ram_mb=0
  local free_disk_mb=0
  local disk_mount="unknown"
  local fail_count=0
  local warn_count=0
  local game_port query_port
  local container_name health="unknown"

  screen_title "Windrose Doctor"
  screen_kv "mode:" "$ACTIVE_MODE"
  screen_section "Preflight"

  if command -v docker >/dev/null 2>&1; then
    log_ok "Docker CLI is available"
  else
    log_error "Docker CLI is not available in PATH"
    fail_count=$((fail_count + 1))
  fi

  if "${DOCKER_CMD[@]}" compose version >/dev/null 2>&1; then
    log_ok "Docker Compose v2 is available"
  else
    log_error "Docker Compose v2 is not available"
    fail_count=$((fail_count + 1))
  fi

  if dc config -q >/dev/null 2>&1; then
    log_ok "Compose configuration is valid"
  else
    log_error "Compose configuration is invalid"
    fail_count=$((fail_count + 1))
  fi

  if [[ -r /proc/meminfo ]]; then
    total_ram_mb="$(awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo)"
  fi

  screen_section "Host Resources"

  if [[ "$total_ram_mb" =~ ^[0-9]+$ ]] && [[ "$total_ram_mb" -gt 0 ]]; then
    if [[ "$total_ram_mb" -lt "$min_ram_mb" ]]; then
      log_error "Host RAM is ${total_ram_mb} MB (minimum ${min_ram_mb} MB)"
      fail_count=$((fail_count + 1))
    else
      log_ok "Host RAM is ${total_ram_mb} MB"
    fi
  else
    log_warn "Could not detect host RAM"
    warn_count=$((warn_count + 1))
  fi

  read -r free_disk_mb disk_mount < <(df -Pm "$SCRIPT_DIR" | awk 'NR==2 {print $4, $6}')
  if [[ "$free_disk_mb" =~ ^[0-9]+$ ]] && [[ "$free_disk_mb" -gt 0 ]]; then
    if [[ "$free_disk_mb" -lt "$min_disk_mb" ]]; then
      log_error "Free disk on ${disk_mount} is ${free_disk_mb} MB (minimum ${min_disk_mb} MB)"
      fail_count=$((fail_count + 1))
    else
      log_ok "Free disk on ${disk_mount} is ${free_disk_mb} MB"
    fi
  else
    log_warn "Could not detect free disk space"
    warn_count=$((warn_count + 1))
  fi

  screen_section "Data Paths"

  if [[ -d "$SCRIPT_DIR/data/R5" ]]; then
    log_ok "Save path exists: $SCRIPT_DIR/data/R5"
  else
    log_warn "Save path not initialized yet: $SCRIPT_DIR/data/R5"
    warn_count=$((warn_count + 1))
  fi

  if [[ -d "$SCRIPT_DIR/data" && -w "$SCRIPT_DIR/data" ]]; then
    log_ok "Data path is writable: $SCRIPT_DIR/data"
  else
    log_warn "Data path is not writable: $SCRIPT_DIR/data"
    warn_count=$((warn_count + 1))
  fi

  container_name="$(dotenv_value CONTAINER_NAME || true)"
  container_name="${container_name:-$SERVICE_NAME}"

  screen_section "Runtime"

  if server_is_running; then
    log_ok "Service is running: $SERVICE_NAME"
    health="$("${DOCKER_CMD[@]}" inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_name" 2>/dev/null || true)"
    health="${health//$'\n'/}"
    if [[ -z "$health" || "$health" == "not-found" ]]; then
      log_warn "Container health could not be determined for $container_name"
      warn_count=$((warn_count + 1))
    elif [[ "$health" == "healthy" ]]; then
      log_ok "Container health: healthy"
    elif [[ "$health" == "none" ]]; then
      log_warn "Container healthcheck is not configured"
      warn_count=$((warn_count + 1))
    else
      log_warn "Container health: $health"
      warn_count=$((warn_count + 1))
    fi
  else
    log_warn "Service is not running: $SERVICE_NAME"
    warn_count=$((warn_count + 1))
  fi

  game_port="${PORT:-$(dotenv_value PORT || true)}"
  query_port="${QUERYPORT:-$(dotenv_value QUERYPORT || true)}"
  game_port="${game_port:-7777}"
  query_port="${query_port:-7778}"

  screen_section "Network"

  if port_is_in_use "$game_port"; then
    if server_is_running; then
      log_ok "PORT ${game_port} is bound"
    else
      local port_owner_game
      port_owner_game="$(get_port_owner "$game_port")"
      log_warn "PORT ${game_port} is already in use while service is stopped (held by: $port_owner_game)"
      warn_count=$((warn_count + 1))
    fi
  else
    if server_is_running; then
      log_info "PORT ${game_port} is not detected as bound on host (can be normal with invite-code NAT punch-through)"
    else
      log_ok "PORT ${game_port} is free"
    fi
  fi

  if port_is_in_use "$query_port"; then
    if server_is_running; then
      log_ok "QUERYPORT ${query_port} is bound"
    else
      local port_owner_query
      port_owner_query="$(get_port_owner "$query_port")"
      log_warn "QUERYPORT ${query_port} is already in use while service is stopped (held by: $port_owner_query)"
      warn_count=$((warn_count + 1))
    fi
  else
    if server_is_running; then
      log_info "QUERYPORT ${query_port} is not detected as bound on host (can be normal with invite-code NAT punch-through)"
    else
      log_ok "QUERYPORT ${query_port} is free"
    fi
  fi

  screen_section "Summary"
  screen_kv "fails:" "$fail_count"
  screen_kv "warnings:" "$warn_count"
  if [[ "$fail_count" -gt 0 ]]; then
    log_error "Doctor checks failed. Fix errors above and run ./$SELF_NAME doctor again."
    return 1
  fi

  if [[ "$warn_count" -gt 0 ]]; then
    log_warn "Doctor checks finished with warnings."
  else
    log_ok "Doctor checks passed."
  fi

  return 0
}

follow_logs() {
  log_info "Following logs"
  dc logs --timestamps -f "$SERVICE_NAME" | sed 's/\.[0-9]*Z/Z/' | sed \
    -e $'s/\(.*Error.*\)/\x1b[0;31m\\1\x1b[0m/' \
    -e $'s/\(.*Warning.*\)/\x1b[1;33m\\1\x1b[0m/'
}

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/ }"
  value="${value//$'\r'/}"
  printf '%s' "$value"
}

player_history() {
  local lines="${1:-1200}"
  local history_file="$SCRIPT_DIR/logs/player-history.log"
  local writer_cmd=(tee -a "$history_file")

  if [[ ! "$lines" =~ ^[0-9]+$ ]] || [[ "$lines" -le 0 ]]; then
    log_error "Invalid line count '$lines'. Use a positive integer."
    exit 1
  fi

  mkdir -p "$(dirname "$history_file")"

  if ! touch "$history_file" >/dev/null 2>&1; then
    log_warn "Cannot write to $history_file (permission denied). Showing matched lines only."
    writer_cmd=(cat)
  fi

  log_info "Scanning last $lines container log lines for player activity (best-effort)"
  if ! dc logs --no-color --timestamps --tail "$lines" "$SERVICE_NAME" 2>&1 |
    sed 's/\.[0-9]*Z/Z/' |
    grep -Ei 'lognet: join succeeded|lognet: leave:|saidfarewell|disconnectaccount' |
    grep -iv 'server account was not found' |
    "${writer_cmd[@]}"; then
    log_warn "No player activity lines matched in the scanned log window."
    return 0
  fi

  if [[ "${writer_cmd[0]}" == "tee" ]]; then
    log_ok "Player activity lines appended to $history_file"
  else
    log_info "Matched lines printed to stdout (history log file was not writable)."
  fi
}

ACTIVITY_METRICS_MATCHED_COUNT=0
ACTIVITY_METRICS_ONLINE_COUNT=0
ACTIVITY_METRICS_LAST_EVENT_TS="unknown"

activity_collect_metrics() {
  local lines="$1"
  local online_out_file="$2"
  local since="${3:-}"
  local identities_file="$SCRIPT_DIR/state/player-identities.tsv"
  local log_tmp_file
  local parsed_tmp_file
  local matched_count=0
  local online_count=0
  local last_event_ts="unknown"
  local player_key
  local player_name=""
  local event_ts event_type event_player
  declare -A online_players=()
  declare -A known_names=()
  declare -a online_keys=()

  : >"$online_out_file"

  if [[ -f "$identities_file" ]]; then
    while IFS=$'\t' read -r player_key player_name; do
      [[ -z "$player_key" || -z "$player_name" ]] && continue
      known_names["$player_key"]="$player_name"
    done <"$identities_file"
  fi

  log_tmp_file="$(mktemp)"
  parsed_tmp_file="$(mktemp)"

  if [[ -n "$since" ]]; then
    if ! dc logs --no-color --timestamps --since "$since" "$SERVICE_NAME" 2>&1 | sed 's/\.[0-9]*Z/Z/' >"$log_tmp_file"; then
      rm -f "$log_tmp_file" "$parsed_tmp_file"
      return 1
    fi
  else
    if ! dc logs --no-color --timestamps --tail "$lines" "$SERVICE_NAME" 2>&1 | sed 's/\.[0-9]*Z/Z/' >"$log_tmp_file"; then
      rm -f "$log_tmp_file" "$parsed_tmp_file"
      return 1
    fi
  fi

  awk '
        {
            line = $0
            low = tolower(line)
            ts = ""
            player = ""
            type = ""
            tmp = ""

            if (match(line, /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[^ ]+/)) {
                ts = substr(line, RSTART, RLENGTH)
            } else {
                ts = strftime("%Y-%m-%dT%H:%M:%SZ")
            }

            if (low ~ /lognet: join succeeded:/) {
                sub(/.*[Jj]oin succeeded:[[:space:]]*/, "", line)
                player = line
                type = "join"
            } else if (low ~ /lognet: leave:/) {
                sub(/.*[Ll]eave:[[:space:]]*/, "", line)
                player = line
                type = "leave"
            } else if (line ~ /Name '\''[^'\'']+'\''.*State '\''SaidFarewell'\''/) {
                tmp = line
                sub(/^.*Name '\''/, "", tmp)
                sub(/'\''.*$/, "", tmp)
                player = tmp
                type = "leave"
            } else if (low ~ /disconnectaccount.*accountid[[:space:]]+[a-z0-9]+/) {
                tmp = low
                sub(/^.*disconnectaccount.*accountid[[:space:]]+/, "", tmp)
                sub(/[^a-z0-9].*$/, "", tmp)
                player = toupper(tmp)
                type = "leave"
            }

            gsub(/^[[:space:]]+|[[:space:]]+$/, "", player)
            if (player != "" && player != "INVALID" && player != "NULL") {
                print ts "\t" type "\t" player
            }
        }
      ' "$log_tmp_file" >"$parsed_tmp_file"

  while IFS=$'\t' read -r event_ts event_type event_player; do
    [[ -z "$event_ts" || -z "$event_type" || -z "$event_player" ]] && continue
    matched_count=$((matched_count + 1))
    last_event_ts="$event_ts"

    case "$event_type" in
    join)
      online_players["$event_player"]="1"
      ;;
    leave)
      unset 'online_players[$event_player]'
      ;;
    esac
  done <"$parsed_tmp_file"

  rm -f "$log_tmp_file" "$parsed_tmp_file"

  for player_key in "${!online_players[@]}"; do
    online_keys+=("$player_key")
  done

  if ((${#online_keys[@]} > 0)); then
    mapfile -t online_keys < <(printf '%s\n' "${online_keys[@]}" | sort)
  fi

  online_count="${#online_keys[@]}"

  for player_key in "${online_keys[@]}"; do
    player_name="${known_names[$player_key]:-}"
    printf '%s\t%s\n' "$player_key" "$player_name" >>"$online_out_file"
  done

  ACTIVITY_METRICS_MATCHED_COUNT="$matched_count"
  ACTIVITY_METRICS_ONLINE_COUNT="$online_count"
  ACTIVITY_METRICS_LAST_EVENT_TS="$last_event_ts"
  return 0
}

activity_status() {
  local lines="${1:-4000}"
  local online_tmp_file
  local matched_count=0
  local online_count=0
  local last_event_ts="unknown"
  local player_key
  local player_name
  local row
  local idx

  if [[ ! "$lines" =~ ^[0-9]+$ ]] || [[ "$lines" -le 0 ]]; then
    log_error "Invalid line count '$lines'. Use a positive integer."
    exit 1
  fi

  mkdir -p "$SCRIPT_DIR/state"

  online_tmp_file="$(mktemp)"
  log_info "Scanning last $lines container log lines for current online activity status"
  if ! activity_collect_metrics "$lines" "$online_tmp_file"; then
    rm -f "$online_tmp_file"
    log_warn "Could not collect activity metrics from logs."
    return 0
  fi

  matched_count="$ACTIVITY_METRICS_MATCHED_COUNT"
  online_count="$ACTIVITY_METRICS_ONLINE_COUNT"
  last_event_ts="$ACTIVITY_METRICS_LAST_EVENT_TS"

  echo
  echo "+------------------------------------------------------+"
  echo "| Activity Status                                      |"
  echo "+------------------------------------------------------+"
  printf '| %-18s | %-29s |\n' "Scanned lines" "$lines"
  printf '| %-18s | %-29s |\n' "Matched events" "$matched_count"
  printf '| %-18s | %-29s |\n' "Online now" "$online_count"
  printf '| %-18s | %-29s |\n' "Last event" "$last_event_ts"
  echo "+------------------------------------------------------+"
  echo "| Online players                                       |"
  echo "+------------------------------------------------------+"

  if [[ "$online_count" -eq 0 ]]; then
    printf '| %-52s |\n' "(none)"
  else
    idx=1
    while IFS=$'\t' read -r player_key player_name; do
      if [[ -n "$player_name" ]]; then
        row="$idx) $player_name [$player_key]"
      else
        row="$idx) $player_key"
      fi
      printf '| %-52.52s |\n' "$row"
      idx=$((idx + 1))
    done <"$online_tmp_file"
  fi

  rm -f "$online_tmp_file"

  echo "+------------------------------------------------------+"

  if [[ "$matched_count" -eq 0 ]]; then
    log_warn "No join/leave patterns matched in the scanned log window."
    log_info "Try: ./$SELF_NAME activity history $lines"
  fi
}

player_events_basic_fallback() {
  local lines="$1"
  local events_file="$SCRIPT_DIR/logs/player-events.log"
  local seen_file="$SCRIPT_DIR/state/player-events.seen"
  local tmp_file
  local log_tmp_file
  local parsed_count=0
  local new_count=0

  mkdir -p "$SCRIPT_DIR/logs" "$SCRIPT_DIR/state"
  touch "$events_file" "$seen_file"
  tmp_file="$(mktemp)"
  log_tmp_file="$(mktemp)"

  log_warn "gawk is not available; using basic join/leave parser."
  log_info "Scanning last $lines container log lines for structured join/leave events (basic mode)"
  dc logs --no-color --timestamps --tail "$lines" "$SERVICE_NAME" 2>&1 | sed 's/\.[0-9]*Z/Z/' >"$log_tmp_file"

  awk '
        {
            line = $0
            low = tolower(line)
            ts = ""
            player = ""
            type = ""
            reason = ""

            if (match(line, /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[^ ]+/)) {
                ts = substr(line, RSTART, RLENGTH)
            } else {
                ts = strftime("%Y-%m-%dT%H:%M:%SZ")
            }

            if (low ~ /lognet: join succeeded:/) {
                sub(/.*[Jj]oin succeeded:[[:space:]]*/, "", line)
                player = line
                type = "join"
                reason = "lognet_join"
            } else if (low ~ /lognet: leave:/) {
                sub(/.*[Ll]eave:[[:space:]]*/, "", line)
                player = line
                type = "leave"
                reason = "lognet_leave"
            }

            gsub(/^[[:space:]]+|[[:space:]]+$/, "", player)
            if (player != "" && player != "INVALID" && player != "NULL") {
                print ts "\t" type "\t" player "\t" reason "\t"
            }
        }
      ' "$log_tmp_file" >"$tmp_file"

  while IFS=$'\t' read -r event_ts event_type event_player event_reason event_name; do
    [[ -z "$event_ts" ]] && continue
    parsed_count=$((parsed_count + 1))

    local event_id
    local json_line
    event_id="$event_ts|$event_type|$event_player|$event_reason"

    if grep -Fqx "$event_id" "$seen_file"; then
      continue
    fi

    printf '%s\n' "$event_id" >>"$seen_file"

    if command -v jq >/dev/null 2>&1; then
      json_line="$(jq -cn \
        --arg ts "$event_ts" \
        --arg type "$event_type" \
        --arg player "$event_player" \
        --arg reason "$event_reason" \
        '{ts:$ts, type:$type, player:$player, reason:$reason}')"
    else
      json_line="{\"ts\":\"$(json_escape "$event_ts")\",\"type\":\"$(json_escape "$event_type")\",\"player\":\"$(json_escape "$event_player")\",\"reason\":\"$(json_escape "$event_reason")\"}"
    fi

    printf '%s\n' "$json_line" | tee -a "$events_file"
    new_count=$((new_count + 1))
  done <"$tmp_file"

  rm -f "$tmp_file" "$log_tmp_file"

  if [[ "$parsed_count" -eq 0 ]]; then
    log_warn "No join/leave patterns matched in the scanned log window."
    return 0
  fi

  if [[ "$new_count" -eq 0 ]]; then
    log_info "No new unique events detected (all matched events were already recorded)."
    return 0
  fi

  log_ok "Appended $new_count new events to $events_file"
  return 0
}

player_events() {
  local lines="${1:-4000}"
  local events_file="$SCRIPT_DIR/logs/player-events.log"
  local seen_file="$SCRIPT_DIR/state/player-events.seen"
  local identities_file="$SCRIPT_DIR/state/player-identities.tsv"
  local tmp_file
  local log_tmp_file
  local identity_tmp_file
  local parsed_count=0
  local new_count=0
  local event_name=""
  local event_id_key
  declare -A known_names=()

  if [[ ! "$lines" =~ ^[0-9]+$ ]] || [[ "$lines" -le 0 ]]; then
    log_error "Invalid line count '$lines'. Use a positive integer."
    exit 1
  fi

  mkdir -p "$SCRIPT_DIR/logs" "$SCRIPT_DIR/state"
  touch "$events_file" "$seen_file" "$identities_file"

  if ! command -v gawk >/dev/null 2>&1; then
    player_events_basic_fallback "$lines"
    return $?
  fi

  tmp_file="$(mktemp)"
  log_tmp_file="$(mktemp)"
  identity_tmp_file="$(mktemp)"

  log_info "Scanning last $lines container log lines for structured join/leave events"
  dc logs --no-color --timestamps --tail "$lines" "$SERVICE_NAME" 2>&1 | sed 's/\.[0-9]*Z/Z/' >"$log_tmp_file"

  # Update persistent identity map from account summary and login lines.
  gawk '
        function trim(v) {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
            return v
        }
        {
            line = $0
            if (match(line, /Name '\''([^'\'']+)'\''.*AccountId '\''([A-Za-z0-9]+)'\''/, m)) {
                print toupper(m[2]) "\t" trim(m[1])
            }

            if (match(line, /Login request:.*Name=([^?[:space:]]+).*userId:[[:space:]]*([^[:space:]]+)/, m)) {
                print trim(m[2]) "\t" trim(m[1])
            }
        }
    ' "$log_tmp_file" >"$identity_tmp_file"

  if [[ -s "$identity_tmp_file" ]]; then
    cat "$identities_file" "$identity_tmp_file" |
      awk -F '\t' 'NF >= 2 { key=$1; name=$2; if (key != "" && name != "") m[key]=name } END { for (k in m) print k "\t" m[k] }' |
      sort -t $'\t' -k1,1 >"$identities_file.tmp"
    mv "$identities_file.tmp" "$identities_file"
  fi

  while IFS=$'\t' read -r event_id_key event_name; do
    [[ -z "$event_id_key" || -z "$event_name" ]] && continue
    known_names["$event_id_key"]="$event_name"
  done <"$identities_file"

  gawk '
            function is_invalid_player(player) {
                player = toupper(player)
                return (player == "" || player == "INVALID" || player == "NULL")
            }

            function emit(ts, type, player, reason, name) {
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", player)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
                if (is_invalid_player(player)) {
                    return
                }
                if (type == "join" && joined[player]) {
                    return
                }
                key = ts "|" type "|" player "|" reason
                if (!seen[key]++) {
                    if (type == "join") {
                        joined[player] = 1
                    } else if (type == "leave") {
                        joined[player] = 0
                    }
                    print ts "\t" type "\t" player "\t" reason "\t" name
                }
            }

            function emit_inferred_join_if_missing(ts, player) {
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", player)
                if (is_invalid_player(player)) {
                    return
                }
                if (!(player in joined)) {
                    emit(ts, "join", player, "join_inferred_p2p", identity_name[player])
                }
            }

            function sanitize_reason(value) {
                gsub(/[^[:alnum:]_]+/, "_", value)
                gsub(/^_+|_+$/, "", value)
                return tolower(value)
            }

            function best_player(account_id, unique_id, fallback) {
                account_id = toupper(account_id)
                if (unique_id != "") {
                    return unique_id
                }
                if (account_id != "" && (account_id in acct_uid) && acct_uid[account_id] != "") {
                    return acct_uid[account_id]
                }
                if (account_id != "") {
                    return account_id
                }
                return fallback
            }

            function best_name(account_id, player, fallback_name) {
                account_id = toupper(account_id)
                if (account_id != "" && (account_id in acct_name) && acct_name[account_id] != "") {
                    return acct_name[account_id]
                }
                if (player != "" && (player in identity_name) && identity_name[player] != "") {
                    return identity_name[player]
                }
                return fallback_name
            }

            function is_raw_identifier(value, upper) {
                upper = toupper(value)
                if (value == "") {
                    return 1
                }
                if (upper ~ /^[A-F0-9]{16,}$/) {
                    return 1
                }
                if (upper ~ /^NULL:[A-Z0-9._-]+$/) {
                    return 1
                }
                if (upper ~ /^DESKTOP-[A-Z0-9-]+$/) {
                    return 1
                }
                if (upper ~ /^[A-Z0-9._-]+-[A-F0-9]{12,}$/) {
                    return 1
                }
                return 0
            }

            function remember_identity_name(player, name) {
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", player)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
                if (!is_invalid_player(player) && name != "" && !(player in identity_name)) {
                    identity_name[player] = name
                }
            }

            {
                line = $0
                low = tolower(line)
                ts = ""
                if (match(line, /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[^ ]+/)) {
                    ts = substr(line, RSTART, RLENGTH)
                } else {
                    ts = strftime("%Y-%m-%dT%H:%M:%SZ")
                }

                if (low ~ /lognet: join succeeded:/) {
                    if (match(line, /Join succeeded:[[:space:]]*(.*)$/, m)) {
                        emit(ts, "join", m[1], "lognet_join", best_name("", m[1], ""))
                    }
                    next
                }

                if (match(line, /UniqueId:[[:space:]]*([^ ,]+)/, m)) {
                    unique = m[1]
                    if (unique == "INVALID") {
                        unique = ""
                    }
                } else {
                    unique = ""
                }

                if (match(line, /PC:[[:space:]]*([^ ,]+)/, m)) {
                    pc = m[1]
                    if (toupper(pc) == "NULL" || toupper(pc) == "INVALID") {
                        pc = ""
                    }
                } else {
                    pc = ""
                }

                if (match(line, /BLPlayerSessionId=([a-z0-9]+)/, m)) {
                    session_id = m[1]
                } else {
                    session_id = ""
                }

                if (match(line, /Name=([^?[:space:]]+)/, m)) {
                    login_name = m[1]
                } else {
                    login_name = ""
                }

                if (match(line, /userId:[[:space:]]*([^[:space:]]+)/, m)) {
                    user_id = m[1]
                    if (toupper(user_id) == "INVALID" || toupper(user_id) == "NULL") {
                        user_id = ""
                    }
                } else {
                    user_id = ""
                }

                if (session_id != "" && user_id != "") {
                    session_uid[session_id] = user_id
                    remember_identity_name(user_id, login_name)
                }

                if (low ~ /notifyacceptedconnection|notifyacceptingconnection|login request|postlogin|addclientconnection/) {
                    candidate_player = ""
                    candidate_name = ""

                    if (user_id != "") {
                        candidate_player = user_id
                        candidate_name = best_name("", user_id, login_name)
                    } else if (unique != "") {
                        candidate_player = unique
                        candidate_name = best_name("", unique, login_name)
                    } else if (pc != "") {
                        candidate_player = pc
                        candidate_name = best_name("", pc, "")
                    }

                    # Avoid duplicate/noisy joins: skip inferred_net when both player and name
                    # are raw identifiers (machine IDs, NULL:<uid>, hashes).
                    if (candidate_player != "") {
                        if (!(is_raw_identifier(candidate_player) && is_raw_identifier(candidate_name))) {
                            emit(ts, "join", candidate_player, "join_inferred_net", candidate_name)
                        }
                    }
                    next
                }

                if (match(line, /OnAccountUePrelogin.*Address '\''([^'\'']+)'\''.*UniqueId '\''([^'\'']+)'\''/, m)) {
                    addr_uid[m[1]] = m[2]
                    remember_identity_name(m[2], login_name)
                    next
                }

                if (match(line, /AccountId '\''([A-Za-z0-9]+)'\'' verified on Prelogin\. Address ([^ ]+)/, m)) {
                    acct_id = toupper(m[1])
                    addr_acct[m[2]] = acct_id
                    if (m[2] in addr_uid) {
                        acct_uid[acct_id] = addr_uid[m[2]]
                    }
                    next
                }

                if (match(low, /process addplayer\. accountid[[:space:]]+([a-z0-9]+)\. blplayersessionid[[:space:]]+([a-z0-9]+)/, m) || match(low, /add player\. accountid[[:space:]]+([a-z0-9]+)\. blplayersessionid[[:space:]]+([a-z0-9]+)/, m)) {
                    acct_id = toupper(m[1])
                    session_acct[m[2]] = acct_id
                    if (m[2] in session_uid) {
                        acct_uid[acct_id] = session_uid[m[2]]
                    }
                    next
                }

                if (match(low, /onueconnect.*\[([a-z0-9]+)\].*ue p2p connection created/, m)) {
                    session_id = m[1]
                    if (!(session_id in session_uid)) {
                        next
                    }
                    acct_id = (session_id in session_acct) ? session_acct[session_id] : ""
                    player = best_player(acct_id, (session_id in session_uid) ? session_uid[session_id] : "", session_id)
                    emit(ts, "join", player, "ue_p2p_connected", best_name(acct_id, player, ""))
                    next
                }

                if (match(line, /AccountName '\''([^'\'']+)'\''.*AccountId[[:space:]]+([A-Za-z0-9]+)/, m)) {
                    acct[toupper(m[2])] = m[1]
                    next
                }

                if (match(line, /Name '\''([^'\'']+)'\''.*AccountId '\''([A-Za-z0-9]+)'\''.*State '\''([^'\'']+)'\''.*NetAddress '\''([^'\'']*)'\''.*FarewellReason[[:space:]]*(.*)$/, m)) {
                    player_name = m[1]
                    acct_id = toupper(m[2])
                    account_state = m[3]
                    net_address = m[4]
                    farewell_reason = m[5]
                    acct_name[acct_id] = player_name
                    acct[acct_id] = player_name
                    if (net_address in addr_uid) {
                        acct_uid[acct_id] = addr_uid[net_address]
                    } else if (match(net_address, /R5:([A-Za-z0-9]+)/, n) && (n[1] in session_uid)) {
                        acct_uid[acct_id] = session_uid[n[1]]
                    }
                    player = best_player(acct_id, "", net_address)
                    remember_identity_name(player, player_name)

                    if (account_state == "SaidFarewell") {
                        emit(ts, "leave", player, "saidfarewell_dump", player_name)
                    } else if (account_state == "UePreloginVerified" || account_state == "ReadyToPlay") {
                        emit(ts, "join", player, "account_" sanitize_reason(account_state), player_name)
                    }
                    next
                }

                if (low ~ /lognet: leave:/) {
                    if (match(line, /Leave:[[:space:]]*(.*)$/, m)) {
                        emit(ts, "leave", m[1], "lognet_leave", best_name("", m[1], ""))
                    }
                    next
                }

                if (match(line, /Name '\''([^'\'']+)'\''.*State '\''SaidFarewell'\''/, m)) {
                    emit(ts, "leave", m[1], "saidfarewell", m[1])
                    next
                }

                if (low ~ /unetconnection::tick: connection graceful close timed out/) {
                    if (unique != "") {
                        emit_inferred_join_if_missing(ts, unique)
                        emit(ts, "leave", unique, "leave_inferred_unet_close", best_name("", unique, ""))
                    } else if (pc != "") {
                        emit_inferred_join_if_missing(ts, pc)
                        emit(ts, "leave", pc, "leave_inferred_unet_close", best_name("", pc, ""))
                    }
                    next
                }

                if (match(low, /disconnectaccount.*accountid[[:space:]]+([a-z0-9]+)/, m)) {
                    acct_id = toupper(m[1])
                    player = best_player(acct_id, "", acct_id)
                    if (acct_id in acct) {
                        emit(ts, "leave", player, "disconnectaccount", acct[acct_id])
                    } else {
                        emit(ts, "leave", player, "disconnectaccount", best_name(acct_id, player, ""))
                    }
                }
            }
        ' "$log_tmp_file" >"$tmp_file"

  while IFS=$'\t' read -r event_ts event_type event_player event_reason event_name; do
    [[ -z "$event_ts" ]] && continue
    parsed_count=$((parsed_count + 1))

    if [[ -z "$event_name" && -n "${known_names[$event_player]:-}" ]]; then
      event_name="${known_names[$event_player]}"
    fi

    if [[ -n "$event_name" ]]; then
      known_names["$event_player"]="$event_name"
    fi

    local event_id
    local json_line
    event_id="$event_ts|$event_type|$event_player|$event_reason"

    if grep -Fqx "$event_id" "$seen_file"; then
      continue
    fi

    printf '%s\n' "$event_id" >>"$seen_file"

    if command -v jq >/dev/null 2>&1; then
      json_line="$(jq -cn \
        --arg ts "$event_ts" \
        --arg type "$event_type" \
        --arg player "$event_player" \
        --arg reason "$event_reason" \
        --arg name "$event_name" \
        '{ts:$ts, type:$type, player:$player, reason:$reason} + (if $name != "" then {name:$name} else {} end)')"
    else
      if [[ -n "$event_name" ]]; then
        json_line="{\"ts\":\"$(json_escape "$event_ts")\",\"type\":\"$(json_escape "$event_type")\",\"player\":\"$(json_escape "$event_player")\",\"reason\":\"$(json_escape "$event_reason")\",\"name\":\"$(json_escape "$event_name")\"}"
      else
        json_line="{\"ts\":\"$(json_escape "$event_ts")\",\"type\":\"$(json_escape "$event_type")\",\"player\":\"$(json_escape "$event_player")\",\"reason\":\"$(json_escape "$event_reason")\"}"
      fi
    fi

    printf '%s\n' "$json_line" | tee -a "$events_file"
    new_count=$((new_count + 1))
  done <"$tmp_file"

  : >"$identities_file.tmp"
  for event_id_key in "${!known_names[@]}"; do
    printf '%s\t%s\n' "$event_id_key" "${known_names[$event_id_key]}" >>"$identities_file.tmp"
  done
  sort -t $'\t' -k1,1 "$identities_file.tmp" >"$identities_file"

  rm -f "$tmp_file" "$log_tmp_file" "$identity_tmp_file" "$identities_file.tmp"

  if [[ "$parsed_count" -eq 0 ]]; then
    log_warn "No join/leave patterns matched in the scanned log window."
    return 0
  fi

  if [[ "$new_count" -eq 0 ]]; then
    log_info "No new unique events detected (all matched events were already recorded)."
    return 0
  fi

  log_ok "Appended $new_count new events to $events_file"
}

run_activity() {
  local mode="${1:-events}"

  case "$mode" in
  events)
    player_events "${2:-4000}"
    ;;
  history)
    player_history "${2:-1200}"
    ;;
  status)
    activity_status "${2:-4000}"
    ;;
  help | -h | --help)
    cat <<EOF
Usage:
  $SELF_NAME activity [events|history|status] [lines]

Modes:
  events   Emit structured join/leave JSON events.
  history  Show raw matched activity lines.
  status   Show current online count and player list (best-effort).

Examples:
  $SELF_NAME activity
  $SELF_NAME activity events 4000
  $SELF_NAME activity history 1200
  $SELF_NAME activity status 4000
EOF
    ;;
  *)
    log_error "Unknown activity mode '$mode'. Use: events, history, status"
    exit 1
    ;;
  esac
}

run_notify_command() {
  local mode="${1:-run}"

  case "$mode" in
  run | watch | start | "")
    run_notifier
    ;;
  test)
    shift || true
    test_notifier "$@"
    ;;
  status)
    notify_status
    ;;
  help | -h | --help)
    cat <<EOF
Usage:
  $SELF_NAME notify [run]
  $SELF_NAME notify test [message]
  $SELF_NAME notify status

Modes:
  run      Start watcher (default behavior).
  test     Send one test notification.
  status   Show notifier process and backend preflight.
EOF
    ;;
  *)
    log_error "Unknown notify mode '$mode'. Use: notify, notify test [message], notify status"
    log_info "Next step: run ./$SELF_NAME notify --help"
    exit 1
    ;;
  esac
}

_check_notifier_endpoint() {
  local provider="$1"
  local url="$2"

  if [[ -z "$url" ]]; then
    log_warn "Endpoint reachability: skipped (no URL configured)"
    return
  fi

  if ! command -v curl >/dev/null 2>&1; then
    log_warn "Endpoint reachability: skipped (curl not available)"
    return
  fi

  local http_code
  http_code="$(curl --silent --max-time 5 --output /dev/null \
    --write-out '%{http_code}' \
    "$url" 2>/dev/null || true)"

  if [[ "$http_code" =~ ^[2345][0-9]{2}$ ]]; then
    log_ok "Endpoint reachability ($provider): reachable (HTTP $http_code)"
  else
    log_warn "Endpoint reachability ($provider): unreachable or no response (HTTP ${http_code:-none})"
  fi
}

notify_status() {
  local notify_pid_file="$SCRIPT_DIR/state/notify.pid"
  local notify_log_file="$SCRIPT_DIR/logs/notify.log"
  local notify_pid=""
  local provider="${NOTIFY_PROVIDER:-$(dotenv_value NOTIFY_PROVIDER || true)}"
  local gotify_url_resolve="${GOTIFY_URL:-$(dotenv_value GOTIFY_URL || true)}"
  local gotify_token_resolve="${GOTIFY_TOKEN:-$(dotenv_value GOTIFY_TOKEN || true)}"
  local discord_webhook_url_resolve="${DISCORD_WEBHOOK_URL:-$(dotenv_value DISCORD_WEBHOOK_URL || true)}"
  local resolved_provider=""

  provider="${provider:-auto}"

  if [[ -f "$notify_pid_file" ]]; then
    notify_pid="$(head -n 1 "$notify_pid_file" 2>/dev/null || true)"
    if [[ -n "$notify_pid" ]] && ! kill -0 "$notify_pid" >/dev/null 2>&1; then
      rm -f "$notify_pid_file"
      notify_pid=""
    fi
  fi

  if [[ -z "$notify_pid" ]]; then
    notify_pid="$(pgrep -f "$SCRIPT_DIR/notify.sh" | head -n 1 || true)"
    if [[ -n "$notify_pid" ]]; then
      mkdir -p "$(dirname "$notify_pid_file")"
      printf '%s\n' "$notify_pid" >"$notify_pid_file"
    fi
  fi

  if [[ "$provider" == "auto" ]]; then
    if [[ -n "$gotify_url_resolve" && -n "$gotify_token_resolve" ]]; then
      resolved_provider="gotify"
    elif [[ -n "$discord_webhook_url_resolve" ]]; then
      resolved_provider="discord"
    else
      resolved_provider="none"
    fi
  else
    resolved_provider="$provider"
  fi

  screen_title "Windrose Notify Status"

  screen_section "Process"
  if [[ -n "$notify_pid" ]]; then
    screen_kv "state:" "running"
    screen_kv "pid:" "$notify_pid"
    log_ok "Activity notifier is running (PID $notify_pid)."
  else
    screen_kv "state:" "not running"
    log_warn "Activity notifier is not running."
    log_info "Run: ./$SELF_NAME notify"
  fi

  screen_section "Provider"
  screen_kv "configured:" "$provider"
  screen_kv "resolved:" "$resolved_provider"
  local discord_webhook_url gotify_url gotify_token
  discord_webhook_url="${DISCORD_WEBHOOK_URL:-$(dotenv_value DISCORD_WEBHOOK_URL 2>/dev/null || true)}"
  gotify_url="${GOTIFY_URL:-$(dotenv_value GOTIFY_URL 2>/dev/null || true)}"
  gotify_token="${GOTIFY_TOKEN:-$(dotenv_value GOTIFY_TOKEN 2>/dev/null || true)}"

  local discord_cfg="not set"
  local gotify_cfg="not set"
  if [[ -n "$discord_webhook_url" ]]; then discord_cfg="set"; fi
  if [[ -n "$gotify_url" && -n "$gotify_token" ]]; then
    gotify_cfg="set (url + token)"
  elif [[ -n "$gotify_url" ]]; then
    gotify_cfg="set (url only, token missing)"
  fi

  screen_kv "discord:" "$discord_cfg"
  screen_kv "gotify:" "$gotify_cfg"

  screen_section "Preflight"
  if [[ "$resolved_provider" == "discord" ]]; then
    _check_notifier_endpoint "discord" "$discord_webhook_url"
  elif [[ "$resolved_provider" == "gotify" ]]; then
    _check_notifier_endpoint "gotify" "$gotify_url"
  else
    log_info "Endpoint reachability: skipped (provider=none)"
  fi

  if [[ "$resolved_provider" == "none" ]]; then
    log_warn "No notification provider is configured. Set DISCORD_WEBHOOK_URL or GOTIFY_URL + GOTIFY_TOKEN in .env"
  fi
  screen_section "Logs"
  screen_kv "file:" "$notify_log_file"

  if [[ -f "$notify_log_file" ]]; then
    log_info "Last notifier log lines:"
    tail -n 10 "$notify_log_file"
  fi
}

run_notifier() {
  local choice
  local notify_pid_file="$SCRIPT_DIR/state/notify.pid"
  local notify_log_file="$SCRIPT_DIR/logs/notify.log"
  local notify_pid=""
  local -a notifier_pids=()
  local pid

  if [[ -f "$notify_pid_file" ]]; then
    notify_pid="$(head -n 1 "$notify_pid_file" 2>/dev/null || true)"
    if [[ -n "$notify_pid" ]] && ! kill -0 "$notify_pid" >/dev/null 2>&1; then
      rm -f "$notify_pid_file"
      notify_pid=""
    fi
  fi

  # Fallback detection for old runs started before PID tracking was added.
  if [[ -z "$notify_pid" ]]; then
    notify_pid="$(pgrep -f "$SCRIPT_DIR/notify.sh" | head -n 1 || true)"
    if [[ -n "$notify_pid" ]]; then
      mkdir -p "$(dirname "$notify_pid_file")"
      printf '%s\n' "$notify_pid" >"$notify_pid_file"
    fi
  fi

  if [[ ! -t 0 ]]; then
    if [[ -n "$notify_pid" ]]; then
      log_info "Activity notifier is already running in background (PID $notify_pid)."
      return 0
    fi
    log_info "Starting activity notifier in foreground (non-interactive shell)"
    exec "$SCRIPT_DIR/notify.sh"
  fi

  if [[ -n "$notify_pid" ]]; then
    log_info "Activity notifier is already running in background (PID $notify_pid)."
    if prompt_confirm_default_no "Stop it now?"; then
      if [[ -n "$notify_pid" ]]; then
        notifier_pids+=("$notify_pid")
      fi

      while IFS= read -r pid; do
        [[ -z "$pid" ]] && continue
        if [[ " ${notifier_pids[*]} " != *" $pid "* ]]; then
          notifier_pids+=("$pid")
        fi
      done < <(pgrep -f "$SCRIPT_DIR/notify.sh" || true)

      if [[ "${#notifier_pids[@]}" -eq 0 ]]; then
        rm -f "$notify_pid_file"
        log_warn "Notifier process is no longer running."
        return 0
      fi

      log_step "Stopping activity notifier"
      for pid in "${notifier_pids[@]}"; do
        kill "$pid" >/dev/null 2>&1 || true
      done

      for _ in $(seq 1 20); do
        local still_running=false

        for pid in "${notifier_pids[@]}"; do
          if kill -0 "$pid" >/dev/null 2>&1; then
            still_running=true
            break
          fi
        done

        if [[ "$still_running" == "false" ]]; then
          break
        fi

        sleep 0.1
      done

      for pid in "${notifier_pids[@]}"; do
        if kill -0 "$pid" >/dev/null 2>&1; then
          kill -9 "$pid" >/dev/null 2>&1 || true
        fi
      done

      for pid in "${notifier_pids[@]}"; do
        if kill -0 "$pid" >/dev/null 2>&1; then
          log_step_failed
          log_error "Notifier did not stop cleanly (PID $pid)."
          exit 1
        fi
      done

      rm -f "$notify_pid_file"
      log_step_done
      log_ok "Notifier stopped."
      return 0
    else
      log_info "Notifier left running in background."
      return 0
    fi
  fi

  if prompt_confirm_default_no "Run activity notifier in background?"; then
    mkdir -p "$(dirname "$notify_log_file")"
    log_step "Starting activity notifier in background"
    if nohup "$SCRIPT_DIR/notify.sh" >>"$notify_log_file" 2>&1 & then
      notify_pid="$!"
      printf '%s\n' "$notify_pid" >"$notify_pid_file"
      log_step_done
      log_ok "Notifier is running in background (PID $notify_pid)."
      log_info "Log file: $notify_log_file"
    else
      log_step_failed
      fatal_exit "Failed to start notifier in background." "Retry with ./$SELF_NAME notify and inspect $notify_log_file for details."
    fi
  else
    log_info "Starting activity notifier in foreground"
    exec "$SCRIPT_DIR/notify.sh"
  fi
}

test_notifier() {
  log_step "Sending test notification"
  if ! "$SCRIPT_DIR/notify.sh" test "${*:-⚓ Test notification from Windrose server}"; then
    log_step_failed
    log_error "Failed to send test notification."
    exit 1
  fi
  log_step_done
}

backup_server() {
  local was_running=""
  local backup_exit=0
  local notify_success notify_fail
  local backup_dir
  local discord_upload_note="discord-upload=disabled"
  local notify_pid_file="$SCRIPT_DIR/state/notify.pid"
  local notify_log_file="$SCRIPT_DIR/logs/notify.log"
  local notifier_was_running=false
  local notifier_pid=""

  notify_success="${BACKUP_NOTIFY_SUCCESS:-$(dotenv_value BACKUP_NOTIFY_SUCCESS || true)}"
  notify_fail="${BACKUP_NOTIFY_FAIL:-$(dotenv_value BACKUP_NOTIFY_FAIL || true)}"
  notify_success="${notify_success:-false}"
  notify_fail="${notify_fail:-true}"
  local discord_upload
  discord_upload="${BACKUP_DISCORD_UPLOAD:-$(dotenv_value BACKUP_DISCORD_UPLOAD || true)}"
  discord_upload="${discord_upload:-false}"

  local backup_scope
  backup_scope="${BACKUP_SCOPE:-$(dotenv_value BACKUP_SCOPE || true)}"
  backup_scope="${backup_scope:-full}"

  backup_dir="${BACKUP_DIR:-$(dotenv_value BACKUP_DIR || true)}"
  backup_dir="${backup_dir:-$SCRIPT_DIR/backups}"
  if [[ "$backup_dir" != /* ]]; then
    backup_dir="$SCRIPT_DIR/$backup_dir"
  fi

  local scope_label
  case "$backup_scope" in
  full) scope_label="full backup" ;;
  save) scope_label="save backup" ;;
  both) scope_label="full + save backup" ;;
  *) scope_label="backup" ;;
  esac

  if [[ "$discord_upload" == "true" ]]; then
    if [[ "$backup_scope" == "full" ]]; then
      discord_upload_note="discord-upload=enabled, skipped for scope=full"
    else
      discord_upload_note="discord-upload=enabled"
    fi
  fi

  if dc ps --status running --services 2>/dev/null | grep -Fx "$SERVICE_NAME" >/dev/null 2>&1; then
    was_running="yes"

    if [[ -f "$notify_pid_file" ]]; then
      notifier_pid="$(head -n 1 "$notify_pid_file" 2>/dev/null || true)"
      if [[ -n "$notifier_pid" ]] && kill -0 "$notifier_pid" >/dev/null 2>&1; then
        notifier_was_running=true
      fi
    fi
    if [[ "$notifier_was_running" == false ]]; then
      notifier_pid="$(pgrep -f "$SCRIPT_DIR/notify.sh" | head -n 1 || true)"
      if [[ -n "$notifier_pid" ]]; then
        notifier_was_running=true
      fi
    fi

    log_step "Stopping server for a consistent $scope_label"
    if ! dc stop "$SERVICE_NAME" >/dev/null 2>&1; then
      log_step_failed
      log_error "Failed to stop container before backup."
      return 1
    fi
    log_step_done
  fi

  if [[ ! -f "$SCRIPT_DIR/backup.sh" ]]; then
    log_error "backup script not found at $SCRIPT_DIR/backup.sh"
    backup_exit=1
  elif bash "$SCRIPT_DIR/backup.sh"; then
    backup_exit=0
  else
    backup_exit=$?
  fi

  if [[ -n "$was_running" ]]; then
    log_step "Starting server again"
    if ! dc up -d >/dev/null 2>&1; then
      log_step_failed
      log_error "Failed to start container after backup."
      backup_exit=1
    else
      log_step_done
    fi

    if [[ "$notifier_was_running" == true ]]; then
      log_step "Restarting activity notifier after backup"
      local old_pids=()
      while IFS= read -r pid; do
        [[ -n "$pid" ]] && old_pids+=("$pid")
      done < <(pgrep -f "$SCRIPT_DIR/notify.sh" || true)
      for pid in "${old_pids[@]}"; do
        kill "$pid" >/dev/null 2>&1 || true
      done
      rm -f "$notify_pid_file"
      sleep 0.5
      mkdir -p "$(dirname "$notify_log_file")" "$(dirname "$notify_pid_file")"
      if nohup "$SCRIPT_DIR/notify.sh" >>"$notify_log_file" 2>&1 & then
        local notify_new_pid="$!"
        printf '%s\n' "$notify_new_pid" >"$notify_pid_file"
        log_step_done
        log_ok "Activity notifier restarted (PID $notify_new_pid)."
      else
        log_step_failed
        log_warn "Failed to restart activity notifier. Run: ./windrose notify"
      fi
    fi
  fi

  if [[ "$backup_exit" -eq 0 && "$notify_success" == "true" ]]; then
    "$SCRIPT_DIR/notify.sh" test "⚓ Windrose backup finished successfully on $(hostname -s). scope=$backup_scope dir=$backup_dir $discord_upload_note" >/dev/null 2>&1 || true
  fi

  if [[ "$backup_exit" -eq 0 && "$discord_upload" == "true" ]]; then
    upload_backup_to_discord || true
  fi

  if [[ "$backup_exit" -ne 0 && "$notify_fail" == "true" ]]; then
    "$SCRIPT_DIR/notify.sh" test "⚓ Windrose backup failed on $(hostname -s) (exit=$backup_exit). scope=$backup_scope dir=$backup_dir $discord_upload_note" >/dev/null 2>&1 || true
  fi

  return "$backup_exit"
}

upload_backup_to_discord() {
  local discord_url backup_dir latest_file file_size http_code backup_scope

  discord_url="${DISCORD_WEBHOOK_URL:-$(dotenv_value DISCORD_WEBHOOK_URL || true)}"
  if [[ -z "$discord_url" ]]; then
    log_warn "DISCORD_WEBHOOK_URL not set, skipping Discord upload."
    return 0
  fi

  backup_dir="${BACKUP_DIR:-$(dotenv_value BACKUP_DIR || true)}"
  backup_dir="${backup_dir:-$SCRIPT_DIR/backups}"
  if [[ "$backup_dir" != /* ]]; then
    backup_dir="$SCRIPT_DIR/$backup_dir"
  fi

  backup_scope="${BACKUP_SCOPE:-$(dotenv_value BACKUP_SCOPE || true)}"
  backup_scope="${backup_scope:-full}"

  if [[ "$backup_scope" == "full" ]]; then
    log_info "BACKUP_SCOPE=full, skipping Discord upload (only save backups are uploaded)."
    return 0
  fi

  if [[ "$backup_scope" != "save" && "$backup_scope" != "both" ]]; then
    log_warn "unsupported BACKUP_SCOPE '$backup_scope', skipping Discord upload."
    return 0
  fi

  latest_file="$(find "$backup_dir" -maxdepth 1 -type f \( -name 'windrose-backup-save-*.tar.gz' -o -name 'windrose-backup-save-*.zip' \) -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)"
  if [[ -z "$latest_file" ]]; then
    log_warn "no save backup file found for Discord upload."
    return 0
  fi

  file_size="$(stat -c '%s' "$latest_file" 2>/dev/null || echo 0)"
  local max_discord_size=$((25 * 1024 * 1024))
  if [[ "$file_size" -gt "$max_discord_size" ]]; then
    log_warn "backup exceeds Discord 25 MB limit ($((file_size / 1024 / 1024)) MB), skipping upload."
    return 0
  fi

  log_step "Uploading $(basename "$latest_file") to Discord ($((file_size / 1024)) KB)"
  http_code="$(curl -s -o /dev/null -w "%{http_code}" \
    -F "file=@$latest_file" \
    -F "payload_json={\"content\":\"⚓ Backup \`$(basename "$latest_file")\` — $(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" \
    "$discord_url")"

  if [[ "$http_code" =~ ^2 ]]; then
    log_step_done
  else
    echo -e " ${_COLOR_RED}FAIL${_COLOR_RESET} (HTTP $http_code)"
  fi
}

restore_preview() {
  local archive_path="${1:-}"

  # Resolve backup dir
  local backup_dir
  backup_dir="${BACKUP_DIR:-$(dotenv_value BACKUP_DIR 2>/dev/null || true)}"
  backup_dir="${backup_dir:-$SCRIPT_DIR/backups}"
  if [[ "$backup_dir" != /* ]]; then
    backup_dir="$SCRIPT_DIR/$backup_dir"
  fi

  # If no archive specified, find the newest one
  if [[ -z "$archive_path" ]]; then
    if [[ ! -d "$backup_dir" ]]; then
      log_error "Backup directory not found: $backup_dir"
      return 1
    fi

    local all_archives=()
    while IFS= read -r f; do
      all_archives+=("$f")
    done < <(find "$backup_dir" -maxdepth 1 -type f \( -name 'windrose-backup-*.tar.gz' -o -name 'windrose-backup-*.zip' \) -printf '%T@ %p\n' 2>/dev/null | sort -n | awk '{print $2}')

    if [[ "${#all_archives[@]}" -eq 0 ]]; then
      # Try simpler approach: just find newest by name sort
      local newest
      newest="$(find "$backup_dir" -maxdepth 1 -type f \( -name 'windrose-backup-*.tar.gz' -o -name 'windrose-backup-*.zip' \) 2>/dev/null | sort | tail -1)"
      if [[ -z "$newest" ]]; then
        log_error "No backup archives found in $backup_dir"
        return 1
      fi
      archive_path="$newest"
      log_info "Auto-selected: $(basename "$archive_path")"
    elif [[ ! -t 0 ]] || [[ "${#all_archives[@]}" -eq 1 ]]; then
      # Non-interactive or only one archive: pick newest
      archive_path="${all_archives[-1]}"
      log_info "Auto-selected: $(basename "$archive_path")"
    else
      # Interactive: show list
      log_info "Available backups:"
      local i
      for ((i = 0; i < ${#all_archives[@]}; i++)); do
        printf '  [%d] %s\n' "$((i + 1))" "$(basename "${all_archives[$i]}")"
      done
      local selection
      read -r -p "$(prompt_text "Select archive [1-${#all_archives[@]}]: ")" selection
      if ! [[ "$selection" =~ ^[0-9]+$ ]] || ((selection < 1 || selection > ${#all_archives[@]})); then
        fatal_return "Invalid selection: $selection" "Run ./$SELF_NAME restore-preview and choose a number from the list."
      fi
      archive_path="${all_archives[$((selection - 1))]}"
    fi
  fi

  # Make relative paths absolute
  if [[ "$archive_path" != /* ]]; then
    archive_path="$SCRIPT_DIR/$archive_path"
  fi

  # Validate file exists
  if [[ ! -f "$archive_path" ]]; then
    log_error "Archive not found: $archive_path"
    return 1
  fi

  # Detect format
  local archive_type
  case "$archive_path" in
  *.tar.gz) archive_type="tar.gz" ;;
  *.zip) archive_type="zip" ;;
  *)
    log_error "Unsupported archive format: $(basename "$archive_path") (expected .tar.gz or .zip)"
    return 1
    ;;
  esac

  # Integrity check (read-only)
  local integrity="ok"
  if [[ "$archive_type" == "tar.gz" ]]; then
    if ! tar -tzf "$archive_path" >/dev/null 2>&1; then
      log_error "Archive is corrupt or unreadable: $(basename "$archive_path")"
      return 1
    fi
  else
    if ! command -v unzip >/dev/null 2>&1; then
      log_error "unzip command not found. Install unzip to preview zip archives."
      return 1
    fi
    if ! unzip -t "$archive_path" >/dev/null 2>&1; then
      log_error "Archive is corrupt or unreadable: $(basename "$archive_path")"
      return 1
    fi
  fi

  # Archive timestamp
  local archive_ts_str="unknown"
  local archive_mtime
  archive_mtime="$(stat -c %Y "$archive_path" 2>/dev/null || true)"
  if [[ -n "$archive_mtime" && "$archive_mtime" =~ ^[0-9]+$ ]]; then
    archive_ts_str="$(date -d "@$archive_mtime" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$archive_mtime" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo 'unknown')"
  fi

  # Top-level entries
  local top_entries=""
  if [[ "$archive_type" == "tar.gz" ]]; then
    top_entries="$(tar -tzf "$archive_path" 2>/dev/null | cut -d/ -f1 | sort -u | head -20 | sed 's/^/    /')"
  else
    top_entries="$(unzip -l "$archive_path" 2>/dev/null | awk 'NR>3 && NF>=4 {print $NF}' | cut -d/ -f1 | sort -u | head -20 | sed 's/^/    /')"
  fi
  [[ -z "$top_entries" ]] && top_entries="    (none detected)"

  # Overwrite scope
  local base overwrite_scope
  base="$(basename "$archive_path")"
  if [[ "$base" == *"-full-"* ]]; then
    overwrite_scope="data/R5 (full game data)"
  elif [[ "$base" == *"-save-"* ]]; then
    overwrite_scope="data/R5/Saved + ServerDescription.json"
  else
    overwrite_scope="unknown (inspect top-level entries)"
  fi

  # Print preview (no writes)
  printf '%s\n' "--- Restore Preview ---"
  printf '  %-18s %s\n' "archive:" "$base"
  printf '  %-18s %s\n' "type:" "$archive_type"
  printf '  %-18s %s\n' "created:" "$archive_ts_str"
  printf '  %-18s %s\n' "overwrite scope:" "$overwrite_scope"
  printf '  %-18s %s\n' "integrity:" "$integrity"
  printf '  %s\n' "top-level entries:"
  printf '%s\n' "$top_entries"
  printf '  %s\n' "NOTE: This is a preview only. No files were modified."
  printf '%s\n' "-----------------------"
}

install_backup_cron() {
  local schedule="${1:-0 6 * * *}"
  local backup_cmd="$SCRIPT_DIR/windrose backup"
  local backup_log_dir="$SCRIPT_DIR/logs"
  local backup_log_file="$backup_log_dir/backup.log"
  local cron_tag="# windrose-backup-job"
  local cron_cmd
  local existing_cron filtered_cron
  local had_legacy_entry=""
  local result_message

  if [[ ! -x "$SCRIPT_DIR/windrose" ]]; then
    backup_cmd="$SCRIPT_DIR/serverctl.sh backup"
  fi

  mkdir -p "$backup_log_dir"

  cron_cmd="echo \"[\$(date -Ins)] backup job started\"; if $backup_cmd; then echo \"[\$(date -Ins)] backup job finished successfully\"; else rc=\$?; echo \"[\$(date -Ins)] backup job failed (exit=\$rc)\"; exit \$rc; fi"
  local cron_line="$schedule /bin/bash -lc '$cron_cmd' >> $backup_log_file 2>&1 $cron_tag"

  if ! command -v crontab >/dev/null 2>&1; then
    log_error "crontab is not available on this host."
    exit 1
  fi

  existing_cron="$(crontab -l 2>/dev/null || true)"

  if printf '%s\n' "$existing_cron" | grep -E "($SCRIPT_DIR/backup\.sh|$SCRIPT_DIR/windrose backup|$SCRIPT_DIR/serverctl\.sh backup|backup job started|windrose-backup-job)" >/dev/null 2>&1; then
    had_legacy_entry="yes"
  fi

  filtered_cron="$(printf '%s\n' "$existing_cron" | grep -Ev "($SCRIPT_DIR/backup\.sh|$SCRIPT_DIR/windrose backup|$SCRIPT_DIR/serverctl\.sh backup|backup job started|windrose-backup-job)" || true)"

  log_step "Installing backup cron"
  if ! {
    if [[ -n "$filtered_cron" ]]; then
      printf '%s\n' "$filtered_cron"
    fi
    echo "$cron_line"
  } | crontab -; then
    log_step_failed
    log_error "Failed to install backup cron."
    exit 1
  fi
  log_step_done

  if [[ -n "$had_legacy_entry" ]]; then
    result_message="Updated legacy backup cron to use windrose backup:"
  else
    result_message="Installed backup cron:"
  fi
  log_ok "$result_message"
  echo "$cron_line"
}

pull_image() {
  log_step "Pulling image defined in compose"
  if ! dc pull; then
    log_step_failed
    log_error "Failed to pull image defined in compose."
    exit 1
  fi
  log_step_done
}

show_update_log() {
  local lines="${1:-120}"

  if [[ ! "$lines" =~ ^[0-9]+$ ]] || [[ "$lines" -le 0 ]]; then
    log_error "Invalid line count '$lines'. Use a positive integer."
    exit 1
  fi

  if [[ ! -f "$UPDATE_LOG_FILE" ]]; then
    log_warn "Update log file not found: $UPDATE_LOG_FILE"
    log_info "Run ./$SELF_NAME update first to generate logs."
    return 0
  fi

  log_info "Showing last $lines lines from $UPDATE_LOG_FILE"
  tail -n "$lines" "$UPDATE_LOG_FILE"
}

verify_update_runtime() {
  local timeout="${UPDATE_VERIFY_TIMEOUT:-120}"
  local container_name
  local health="unknown"

  if ! [[ "$timeout" =~ ^[0-9]+$ ]] || [[ "$timeout" -le 0 ]]; then
    timeout=120
  fi

  container_name="$(dotenv_value CONTAINER_NAME || true)"
  container_name="${container_name:-$SERVICE_NAME}"

  log_step "Verifying service runtime after update (timeout ${timeout}s)"

  for _ in $(seq 1 "$timeout"); do
    if server_is_running; then
      health="$("${DOCKER_CMD[@]}" inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_name" 2>/dev/null || true)"
      health="${health//$'\n'/}"

      if [[ "$health" == "healthy" || "$health" == "none" ]]; then
        log_step_done
        log_ok "Update verification passed (running=true, health=${health})."
        append_update_log "Post-update verify: running=true health=${health}"
        return 0
      fi

      if [[ "$health" == "unhealthy" ]]; then
        log_step_failed
        log_error "Container became unhealthy after update."
        log_info "Run: ./$SELF_NAME logs"
        log_info "Run: ./$SELF_NAME update-log"
        append_update_log "Post-update verify: unhealthy"
        return 1
      fi
    fi

    sleep 1
  done

  log_step_failed
  log_error "Update verification timed out after ${timeout}s."
  log_info "Run: ./$SELF_NAME status"
  log_info "Run: ./$SELF_NAME logs"
  log_info "Run: ./$SELF_NAME update-log"
  append_update_log "Post-update verify: timeout"
  return 1
}

diagnostics_bundle() {
  local lines="${1:-300}"
  local timestamp tmp_dir out_file
  local container_name

  if ! [[ "$lines" =~ ^[0-9]+$ ]] || [[ "$lines" -le 0 ]]; then
    log_error "Invalid log line count '$lines'. Use a positive integer."
    exit 1
  fi

  local diagnostics_dir="$SCRIPT_DIR/diagnostics"
  mkdir -p "$diagnostics_dir"
  timestamp="$(date -u +%Y%m%d-%H%M%S)"
  tmp_dir="$(mktemp -d "$diagnostics_dir/diagnostics-${timestamp}-XXXX")"
  out_file="$diagnostics_dir/windrose-diagnostics-${timestamp}.tar.gz"

  log_step "Collecting diagnostics bundle"

  {
    echo "generated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "mode=$ACTIVE_MODE"
    echo "service=$SERVICE_NAME"
    echo "compose_dir=$COMPOSE_DIR"
  } >"$tmp_dir/summary.txt"

  dc ps >"$tmp_dir/compose-ps.txt" 2>&1 || true
  dc config >"$tmp_dir/compose-config.txt" 2>&1 || true
  dc logs --no-color --timestamps --tail "$lines" "$SERVICE_NAME" >"$tmp_dir/container-logs-tail.txt" 2>&1 || true

  if [[ -f "$UPDATE_LOG_FILE" ]]; then
    tail -n "$lines" "$UPDATE_LOG_FILE" >"$tmp_dir/update-log-tail.txt" 2>&1 || true
  fi

  status_json >"$tmp_dir/status.json" 2>&1 || true
  if ! doctor_server >"$tmp_dir/doctor.txt" 2>&1; then
    echo "doctor_exit=nonzero" >>"$tmp_dir/summary.txt"
  fi

  if [[ -f "$SCRIPT_DIR/.env" ]]; then
    sed -E 's/(TOKEN|PASSWORD|WEBHOOK|PASS)=.*/\1=REDACTED/gI' "$SCRIPT_DIR/.env" >"$tmp_dir/env-redacted.txt"
  fi

  container_name="$(dotenv_value CONTAINER_NAME || true)"
  container_name="${container_name:-$SERVICE_NAME}"
  "${DOCKER_CMD[@]}" inspect "$container_name" >"$tmp_dir/container-inspect.json" 2>/dev/null || true

  if ! tar -czf "$out_file" -C "$tmp_dir" . >/dev/null 2>&1; then
    log_step_failed
    rm -rf "$tmp_dir"
    log_error "Failed to create diagnostics bundle archive."
    exit 1
  fi

  rm -rf "$tmp_dir"
  log_step_done
  log_ok "Diagnostics bundle created: $out_file"
}

_print_update_summary() {
  local result="$1"
  local old_ref="$2"
  local new_ref="$3"
  local duration_secs="$4"
  local running="$5"
  local health="$6"
  local mins=$((duration_secs / 60))
  local secs=$((duration_secs % 60))
  screen_title "Windrose Update Summary"

  screen_section "Result"
  screen_kv "result:" "$result"
  screen_kv "duration:" "${mins}m ${secs}s"

  screen_section "Image"
  screen_kv "old image:" "${old_ref:-unknown}"
  screen_kv "new image:" "${new_ref:-unknown}"

  screen_section "Runtime"
  screen_kv "running:" "$running"
  screen_kv "health:" "$health"
}

_update_fail() {
  local old_ref="$1"
  local new_ref="$2"
  local start_ts="$3"
  local now_ts duration container_name running health
  now_ts="$(date +%s)"
  duration=$((now_ts - start_ts))
  container_name="$(dotenv_value CONTAINER_NAME 2>/dev/null || true)"
  container_name="${container_name:-$SERVICE_NAME}"
  running="no"
  if server_is_running; then
    running="yes"
  fi
  health="$("${DOCKER_CMD[@]}" inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_name" 2>/dev/null || true)"
  health="${health//$'\n'/}"
  health="${health:-unknown}"
  _print_update_summary "failed" "$old_ref" "$new_ref" "$duration" "$running" "$health"
  exit 1
}

update_server() {
  local mode="${1:-}"
  local notify_pid_file="$SCRIPT_DIR/state/notify.pid"
  local notify_log_file="$SCRIPT_DIR/logs/notify.log"
  local notifier_was_running=false
  local notifier_pid=""
  local update_start_ts old_image_ref new_image_ref
  update_start_ts="$(date +%s)"
  local _upd_container_name
  _upd_container_name="$(dotenv_value CONTAINER_NAME 2>/dev/null || true)"
  _upd_container_name="${_upd_container_name:-$SERVICE_NAME}"
  old_image_ref="$("${DOCKER_CMD[@]}" inspect "$_upd_container_name" --format '{{.Config.Image}}' 2>/dev/null || true)"

  if [[ -n "$mode" && "$mode" != "--force-down" ]]; then
    log_error "Invalid update option '$mode'. Supported: --force-down"
    _update_fail "$old_image_ref" "$new_image_ref" "$update_start_ts"
  fi

  if [[ -f "$notify_pid_file" ]]; then
    notifier_pid="$(head -n 1 "$notify_pid_file" 2>/dev/null || true)"
    if [[ -n "$notifier_pid" ]] && kill -0 "$notifier_pid" >/dev/null 2>&1; then
      notifier_was_running=true
    fi
  fi
  if [[ "$notifier_was_running" == false ]]; then
    notifier_pid="$(pgrep -f "$SCRIPT_DIR/notify.sh" | head -n 1 || true)"
    if [[ -n "$notifier_pid" ]]; then
      notifier_was_running=true
    fi
  fi

  mkdir -p "$UPDATE_LOG_DIR"
  rotate_update_logs
  append_update_log "Update started (mode=$ACTIVE_MODE, compose_dir=$COMPOSE_DIR, service=$SERVICE_NAME, strategy=${mode:---safe})"

  if [[ -f "$SCRIPT_DIR/backups/player-events.log" ]]; then
    log_warn "Old file layout detected in backups/. Run ./migrate-folders.sh once to reorganize logs and state files."
  fi

  log_info "Progress bar shows update stages, not byte-level download progress."

  render_progress_bar 0

  if [[ "$mode" == "--force-down" ]]; then
    append_update_log "Running (force-down): docker compose down"
    if ! dc down >>"$UPDATE_LOG_FILE" 2>&1; then
      printf '\n'
      log_error "Failed to stop and remove the stack before update. See $UPDATE_LOG_FILE"
      _update_fail "$old_image_ref" "$new_image_ref" "$update_start_ts"
    fi
    render_progress_bar 33

    append_update_log "Running (force-down): docker compose pull"
    if ! dc pull >>"$UPDATE_LOG_FILE" 2>&1; then
      printf '\n'
      log_error "Failed to pull the selected image tag. See $UPDATE_LOG_FILE"
      _update_fail "$old_image_ref" "$new_image_ref" "$update_start_ts"
    fi
    render_progress_bar 66

    append_update_log "Running (force-down): docker compose up -d"
    if ! dc up -d >>"$UPDATE_LOG_FILE" 2>&1; then
      printf '\n'
      log_error "Failed to recreate the container after update. See $UPDATE_LOG_FILE"
      _update_fail "$old_image_ref" "$new_image_ref" "$update_start_ts"
    fi
    new_image_ref="$("${DOCKER_CMD[@]}" inspect "$_upd_container_name" --format '{{.Config.Image}}' 2>/dev/null || true)"
  else
    append_update_log "Running (safe): docker compose pull"
    if ! dc pull >>"$UPDATE_LOG_FILE" 2>&1; then
      printf '\n'
      log_error "Failed to pull the selected image tag. Existing container was left untouched. See $UPDATE_LOG_FILE"
      _update_fail "$old_image_ref" "$new_image_ref" "$update_start_ts"
    fi
    render_progress_bar 50

    append_update_log "Running (safe): docker compose up -d"
    if ! dc up -d >>"$UPDATE_LOG_FILE" 2>&1; then
      printf '\n'
      log_error "Failed to recreate the container after update. See $UPDATE_LOG_FILE"
      _update_fail "$old_image_ref" "$new_image_ref" "$update_start_ts"
    fi
    new_image_ref="$("${DOCKER_CMD[@]}" inspect "$_upd_container_name" --format '{{.Config.Image}}' 2>/dev/null || true)"
  fi

  if ! verify_update_runtime; then
    append_update_log "Update finished with verification failure"
    _update_fail "$old_image_ref" "$new_image_ref" "$update_start_ts"
  fi

  render_progress_bar 100
  log_ok "Server updated and verified."
  local update_end_ts duration post_running post_health
  update_end_ts="$(date +%s)"
  duration=$((update_end_ts - update_start_ts))
  post_running="no"
  if server_is_running; then
    post_running="yes"
  fi
  post_health="$("${DOCKER_CMD[@]}" inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$_upd_container_name" 2>/dev/null || true)"
  post_health="${post_health//$'\n'/}"
  post_health="${post_health:-unknown}"
  _print_update_summary "ok" "$old_image_ref" "$new_image_ref" "$duration" "$post_running" "$post_health"
  log_info "Detailed update log: $UPDATE_LOG_FILE"
  append_update_log "Update finished successfully"

  if [[ "$notifier_was_running" == true ]]; then
    log_step "Restarting activity notifier after update"
    local old_pids=()
    while IFS= read -r pid; do
      [[ -n "$pid" ]] && old_pids+=("$pid")
    done < <(pgrep -f "$SCRIPT_DIR/notify.sh" || true)
    for pid in "${old_pids[@]}"; do
      kill "$pid" >/dev/null 2>&1 || true
    done
    rm -f "$notify_pid_file"
    sleep 0.5
    mkdir -p "$(dirname "$notify_log_file")" "$(dirname "$notify_pid_file")"
    if nohup "$SCRIPT_DIR/notify.sh" >>"$notify_log_file" 2>&1 & then
      notify_new_pid="$!"
      printf '%s\n' "$notify_new_pid" >"$notify_pid_file"
      log_step_done
      log_ok "Activity notifier restarted (PID $notify_new_pid)."
    else
      log_step_failed
      log_warn "Failed to restart activity notifier. Run: ./windrose notify"
    fi
  fi
}

_set_env_value() {
  local key="$1"
  local value="$2"
  local env_file="$3"
  local escaped
  escaped="${value//\\/\\\\}"
  escaped="${escaped//|/\\|}"
  escaped="${escaped//&/\\&}"
  sed -i "s|^${key}=.*|${key}=${escaped}|" "$env_file"
}

port_is_in_use() {
  local port="$1"

  if ! command -v ss >/dev/null 2>&1; then
    return 1
  fi

  ss -H -lntu 2>/dev/null | awk '{print $5}' | grep -E "(^|[:\]])${port}$" >/dev/null 2>&1
}

get_port_owner() {
  local port="$1"
  local output
  output="$(ss -H -lntu -p 2>/dev/null | awk -v p="$port" '
    $5 ~ "(^|[:\\]])"p"$" {
      match($0, /users:\(\("([^"]+)"/, m)
      if (m[1] != "") print m[1]
      else print "unknown-process"
    }
  ' 2>/dev/null | head -1)"
  printf '%s' "${output:-unknown-process}"
}

run_setup_host_precheck() {
  local min_ram_mb=8192
  local rec_ram_mb=16384
  local min_disk_mb=8192
  local total_ram_mb=0
  local free_disk_mb=0
  local disk_mount="unknown"

  log_step "Running host precheck (docker/compose/resources)"

  if ! command -v docker >/dev/null 2>&1; then
    log_step_failed
    log_error "Docker is not installed or not in PATH. Install Docker 24+ and retry."
    exit 1
  fi

  if ! "${DOCKER_CMD[@]}" compose version >/dev/null 2>&1; then
    log_step_failed
    log_error "Docker Compose v2 is not available. Install the docker compose plugin and retry."
    exit 1
  fi

  if [[ -r /proc/meminfo ]]; then
    total_ram_mb="$(awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo)"
  fi

  if ! [[ "$total_ram_mb" =~ ^[0-9]+$ ]] || [[ "$total_ram_mb" -le 0 ]]; then
    log_step_failed
    log_error "Unable to detect host RAM. Check /proc/meminfo and retry."
    exit 1
  fi

  read -r free_disk_mb disk_mount < <(df -Pm "$SCRIPT_DIR" | awk 'NR==2 {print $4, $6}')
  if ! [[ "$free_disk_mb" =~ ^[0-9]+$ ]] || [[ "$free_disk_mb" -le 0 ]]; then
    log_step_failed
    log_error "Unable to detect free disk space for $SCRIPT_DIR."
    exit 1
  fi

  if [[ "$total_ram_mb" -lt "$min_ram_mb" ]]; then
    log_step_failed
    log_error "Detected RAM: ${total_ram_mb} MB. Minimum required is ${min_ram_mb} MB."
    exit 1
  fi

  if [[ "$free_disk_mb" -lt "$min_disk_mb" ]]; then
    log_step_failed
    log_error "Free disk on ${disk_mount}: ${free_disk_mb} MB. Minimum required is ${min_disk_mb} MB."
    exit 1
  fi

  log_step_done
  log_info "Host resources: RAM=${total_ram_mb} MB, free disk on ${disk_mount}=${free_disk_mb} MB"

  if [[ "$total_ram_mb" -lt "$rec_ram_mb" ]]; then
    log_warn "RAM below recommended ${rec_ram_mb} MB. 4-player sessions may be unstable under load."
  fi
}

setup_server() {
  local env_file="$SCRIPT_DIR/.env"
  local env_example="$SCRIPT_DIR/.env.example"

  if [[ -f "$env_file" ]]; then
    log_error ".env already exists at $env_file"
    log_info "Setup is a one-off operation. Edit .env directly to change the configuration."
    exit 1
  fi

  if [[ ! -f "$env_example" ]]; then
    log_error ".env.example not found at $env_example"
    exit 1
  fi

  run_setup_host_precheck

  log_info "Windrose first-time setup"
  echo

  local start_after="no"
  if prompt_confirm_default_yes "Start the server automatically after setup?"; then
    start_after="yes"
  else
    start_after="no"
  fi
  echo

  local server_name invite_code server_password max_players
  local invite_code_mode="manual"
  local enable_auto_backup="no"
  local backup_schedule backup_format backup_scope
  local backup_discord_upload="no"
  local discord_url=""

  read -r -p "$(prompt_text "Server name [My Windrose Server]: ")" server_name
  server_name="${server_name:-My Windrose Server}"

  log_info "Leave invite code empty to let the server generate it automatically on first successful start."
  read -r -p "$(prompt_text "Invite code (optional, alphanumeric, min 6 chars): ")" invite_code
  if [[ -n "$invite_code" ]] && [[ ! "$invite_code" =~ ^[A-Za-z0-9]{6,}$ ]]; then
    log_error "Invalid invite code. Use only letters and numbers, at least 6 characters."
    exit 1
  fi
  if [[ -z "$invite_code" ]]; then
    invite_code_mode="auto"
  fi

  read -r -p "$(prompt_text "Server password (leave empty for none): ")" server_password

  read -r -p "$(prompt_text "Max players [4]: ")" max_players
  max_players="${max_players:-4}"
  if [[ ! "$max_players" =~ ^[0-9]+$ ]] || [[ "$max_players" -le 0 ]]; then
    log_error "Invalid max players value: $max_players"
    exit 1
  fi

  if prompt_confirm_default_no "Enable automatic backup cron job?"; then
    enable_auto_backup="yes"
  else
    enable_auto_backup="no"
  fi

  if [[ "$enable_auto_backup" == "yes" ]]; then
    log_info "Default backup schedule is daily at 06:00 (cron: 0 6 * * *)."
    read -r -p "$(prompt_text "Backup cron schedule [0 6 * * *]: ")" backup_schedule
    backup_schedule="${backup_schedule:-0 6 * * *}"
  fi

  read -r -p "$(prompt_text "Backup format [tar.gz/zip] (default: tar.gz): ")" backup_format
  backup_format="${backup_format:-tar.gz}"
  if [[ "$backup_format" != "tar.gz" && "$backup_format" != "zip" ]]; then
    log_error "Invalid backup format: $backup_format (allowed: tar.gz, zip)"
    exit 1
  fi

  read -r -p "$(prompt_text "Backup scope [full/save/both] (default: full): ")" backup_scope
  backup_scope="${backup_scope:-full}"
  if [[ "$backup_scope" != "full" && "$backup_scope" != "save" && "$backup_scope" != "both" ]]; then
    log_error "Invalid backup scope: $backup_scope (allowed: full, save, both)"
    exit 1
  fi

  if prompt_confirm_default_no "Upload save backup file to Discord webhook?"; then
    backup_discord_upload="yes"
  else
    backup_discord_upload="no"
  fi

  if [[ "$backup_discord_upload" == "yes" ]]; then
    if [[ "$backup_scope" == "full" ]]; then
      log_warn "Discord upload works only for save backups. Changing BACKUP_SCOPE from full to both."
      backup_scope="both"
    fi
    read -r -p "$(prompt_text "Discord webhook URL (required for upload): ")" discord_url
    if [[ -z "$discord_url" ]]; then
      log_error "Discord webhook URL is required when Discord backup upload is enabled."
      exit 1
    fi
  fi

  echo

  local detected_puid detected_pgid
  detected_puid="$(id -u)"
  detected_pgid="$(id -g)"

  log_step "Creating .env from template"
  cp "$env_example" "$env_file"
  log_step_done

  _set_env_value "SERVER_NAME" "$server_name" "$env_file"
  _set_env_value "INVITE_CODE" "$invite_code" "$env_file"
  _set_env_value "SERVER_PASSWORD" "$server_password" "$env_file"
  _set_env_value "MAX_PLAYERS" "$max_players" "$env_file"
  _set_env_value "PUID" "$detected_puid" "$env_file"
  _set_env_value "PGID" "$detected_pgid" "$env_file"
  _set_env_value "BACKUP_FORMAT" "$backup_format" "$env_file"
  _set_env_value "BACKUP_SCOPE" "$backup_scope" "$env_file"
  if [[ "$backup_discord_upload" == "yes" ]]; then
    _set_env_value "BACKUP_DISCORD_UPLOAD" "true" "$env_file"
  else
    _set_env_value "BACKUP_DISCORD_UPLOAD" "false" "$env_file"
  fi
  if [[ -n "$discord_url" ]]; then
    _set_env_value "DISCORD_WEBHOOK_URL" "$discord_url" "$env_file"
  fi

  log_ok "Configuration written to $env_file"
  echo
  log_info "Summary:"
  echo -e "  ${_COLOR_CYAN}Server name:${_COLOR_RESET}   $server_name"
  echo -e "  ${_COLOR_CYAN}Invite code:${_COLOR_RESET}   ${invite_code:-(auto/empty)}"
  echo -e "  ${_COLOR_CYAN}Password:${_COLOR_RESET}      ${server_password:-(none)}"
  echo -e "  ${_COLOR_CYAN}Max players:${_COLOR_RESET}   $max_players"
  echo -e "  ${_COLOR_CYAN}PUID/PGID:${_COLOR_RESET}     $detected_puid/$detected_pgid"
  echo -e "  ${_COLOR_CYAN}Backup format:${_COLOR_RESET} $backup_format"
  echo -e "  ${_COLOR_CYAN}Backup scope:${_COLOR_RESET}  $backup_scope"
  if [[ "$enable_auto_backup" == "yes" ]]; then
    echo -e "  ${_COLOR_CYAN}Backup cron:${_COLOR_RESET}   $backup_schedule"
  else
    echo -e "  ${_COLOR_CYAN}Backup cron:${_COLOR_RESET}   disabled"
  fi
  if [[ "$backup_discord_upload" == "yes" ]]; then
    echo -e "  ${_COLOR_CYAN}Discord upload:${_COLOR_RESET} enabled"
  else
    echo -e "  ${_COLOR_CYAN}Discord upload:${_COLOR_RESET} disabled"
  fi
  echo

  if [[ "$enable_auto_backup" == "yes" ]]; then
    if command -v crontab >/dev/null 2>&1; then
      install_backup_cron "$backup_schedule"
    else
      log_warn "crontab is not available on this host. Skipping automatic backup schedule setup."
    fi
  fi

  if [[ "$start_after" == "yes" ]]; then
    local game_port query_port
    local generated_invite_code=""
    game_port="$(dotenv_value PORT || true)"
    query_port="$(dotenv_value QUERYPORT || true)"

    log_step "Running startup preflight checks"
    if ! dc config -q >/dev/null 2>&1; then
      log_step_failed
      log_error "Docker Compose configuration is invalid. Fix compose/.env values and retry."
      exit 1
    fi
    log_step_done

    if [[ -n "$game_port" ]] && port_is_in_use "$game_port"; then
      log_warn "Port $game_port is already in use on the host (PORT). Startup may fail."
    fi

    if [[ -n "$query_port" ]] && port_is_in_use "$query_port"; then
      log_warn "Port $query_port is already in use on the host (QUERYPORT). Startup may fail."
    fi

    log_info "If LAN clients fail to connect while WAN works, see README: 'Troubleshooting -> LAN clients fail, WAN clients work'."

    log_step "Pulling image"
    if ! dc pull; then
      log_step_failed
      log_error "Failed to pull image. Check IMAGE_TAG in $env_file and try again."
      exit 1
    fi
    log_step_done

    log_step "Starting server"
    if ! dc up -d >/dev/null 2>&1; then
      log_step_failed
      log_error "Failed to start server."
      exit 1
    fi
    log_step_done
    log_ok "Server is starting. Check status with: ./$SELF_NAME status"
    log_info "Follow logs with: ./$SELF_NAME logs"

    if [[ "$invite_code_mode" == "auto" ]]; then
      if command -v jq >/dev/null 2>&1; then
        log_info "Invite code was left empty, waiting for automatic generation..."
        for _ in $(seq 1 90); do
          generated_invite_code="$(jq -r '.ServerDescription_Persistent.InviteCode // .InviteCode // empty' "$SERVER_DESC_FILE" 2>/dev/null || true)"
          if [[ -n "$generated_invite_code" && "$generated_invite_code" != "null" ]]; then
            break
          fi
          sleep 1
        done

        if [[ -n "$generated_invite_code" && "$generated_invite_code" != "null" ]]; then
          log_ok "Generated invite code: $generated_invite_code"
        else
          log_warn "Invite code was not detected yet. Check $SERVER_DESC_FILE after the server finishes booting."
        fi
      else
        log_info "Invite code was left empty. It will be generated automatically."
        log_info "Check it in: $SERVER_DESC_FILE"
      fi
    fi
  else
    log_info "Start the server when ready: ./$SELF_NAME start"
    if [[ "$invite_code_mode" == "auto" ]]; then
      log_info "Invite code was left empty and will be generated on first successful start."
      log_info "After startup, check it in: $SERVER_DESC_FILE"
    fi
  fi
}

down_server() {
  log_step "Stopping and removing the stack"
  if ! dc down; then
    log_step_failed
    log_error "Failed to stop and remove the stack."
    exit 1
  fi
  log_step_done
}

install_self() {
  local target="${1:-/usr/local/bin/windrosectl}"
  local target_dir
  target_dir="$(dirname "$target")"

  log_step "Installing launcher at $target"
  mkdir -p "$target_dir"
  if ! cat >"$target" <<EOF; then
#!/usr/bin/env bash
set -euo pipefail
exec "$SCRIPT_DIR/windrose" "\$@"
EOF
    log_step_failed
    log_error "Failed to write launcher to $target"
    exit 1
  fi

  if ! chmod +x "$target"; then
    log_step_failed
    log_error "Failed to make launcher executable at $target"
    exit 1
  fi

  log_step_done
  log_ok "Installed launcher at $target"
}

init_docker_cmd
require_tools

trap release_mutation_lock EXIT

CMD="${1:-help}"
if is_mutating_command "$CMD"; then
  acquire_mutation_lock "$CMD"
fi

case "$CMD" in
setup)
  setup_server
  ;;
start)
  start_server
  ;;
stop)
  stop_server
  ;;
restart)
  restart_server
  ;;
status | ps)
  status_server
  ;;
status-json)
  status_json
  ;;
status-snapshot)
  status_snapshot
  ;;
doctor)
  doctor_server
  ;;
diagnostics)
  diagnostics_bundle "${2:-300}"
  ;;
logs)
  follow_logs
  ;;
activity)
  shift || true
  run_activity "$@"
  ;;
player-history)
  player_history "${2:-1200}"
  ;;
player-events)
  player_events "${2:-4000}"
  ;;
worlds)
  list_worlds
  ;;
worlds-check)
  check_worlds
  ;;
switch)
  switch_world
  ;;
worlds-prune)
  worlds_prune "${2:-}"
  ;;
notify)
  shift || true
  run_notify_command "$@"
  ;;
test-notify)
  shift || true
  test_notifier "$@"
  ;;
backup)
  backup_server
  ;;
restore-preview)
  restore_preview "${2:-}"
  ;;
install-backup-cron)
  install_backup_cron "${2:-}"
  ;;
pull)
  pull_image
  ;;
update)
  update_server "${2:-}"
  ;;
update-log)
  show_update_log "${2:-120}"
  ;;
down)
  down_server
  ;;
install)
  install_self "${2:-}"
  ;;
help | -h | --help | "")
  usage
  ;;
*)
  usage
  exit 1
  ;;
esac
