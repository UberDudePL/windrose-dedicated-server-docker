#!/usr/bin/env bash
set -euo pipefail

resolve_script_dir() {
    local src="${BASH_SOURCE[0]}"

    while [[ -h "$src" ]]; do
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
UPDATE_LOG_DIR="$SCRIPT_DIR/backups"
UPDATE_LOG_FILE="$UPDATE_LOG_DIR/update.log"
DOCKER_CMD=()

# ANSI color codes
_COLOR_RESET='\033[0m'
_COLOR_CYAN='\033[0;36m'
_COLOR_GREEN='\033[0;32m'
_COLOR_YELLOW='\033[1;33m'
_COLOR_RED='\033[0;31m'

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

log_step() {
    echo -ne "${_COLOR_CYAN}[windrose]${_COLOR_RESET} $1..."
}

log_step_done() {
    echo -e " ${_COLOR_GREEN}DONE${_COLOR_RESET}"
}

log_step_failed() {
    echo -e " ${_COLOR_RED}FAILED${_COLOR_RESET}"
}

log_step_pending() {
    echo -e " ${_COLOR_YELLOW}PENDING${_COLOR_RESET}"
}

render_progress_bar() {
    local percent="$1"
    local width=30
    local filled empty
    local filled_bar empty_bar

    filled=$(( percent * width / 100 ))
    empty=$(( width - filled ))

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
}

append_update_log() {
    printf '[%s] %s\n' "$(date -Ins)" "$*" >> "$UPDATE_LOG_FILE"
}

is_utf8_locale() {
    local active_locale="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
    [[ "${active_locale,,}" == *"utf-8"* || "${active_locale,,}" == *"utf8"* ]]
}

init_docker_cmd() {
    if ! command -v docker >/dev/null 2>&1; then
        echo "[windrose] Error: docker is not installed or not in PATH."
        exit 1
    fi

    if [[ -n "$DOCKER_BIN" ]]; then
        read -r -a DOCKER_CMD <<< "$DOCKER_BIN"
        return
    fi

    if docker info >/dev/null 2>&1; then
        DOCKER_CMD=(docker)
    elif command -v sudo >/dev/null 2>&1; then
        DOCKER_CMD=(sudo docker)
    else
        echo "[windrose] Error: docker needs elevated permissions and sudo is not available."
        echo "[windrose] Try running with: DOCKER_BIN='sudo docker' ./$SELF_NAME status"
        exit 1
    fi
}

require_tools() {
    if [[ ! -f "$COMPOSE_DIR/docker-compose.yml" ]]; then
        echo "[windrose] Error: docker-compose.yml not found in $COMPOSE_DIR"
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
  $SELF_NAME start
  $SELF_NAME stop
  $SELF_NAME restart
  $SELF_NAME status
  $SELF_NAME logs
  $SELF_NAME worlds
  $SELF_NAME worlds-check
  $SELF_NAME switch
  $SELF_NAME notify
  $SELF_NAME test-notify [message]
  $SELF_NAME backup
  $SELF_NAME install-backup-cron [schedule]
  $SELF_NAME pull
  $SELF_NAME update [--force-down]
  $SELF_NAME update-log [lines]
  $SELF_NAME down
  $SELF_NAME install [target]

Notes:
  - compose directory: $COMPOSE_DIR
  - detected mode: $ACTIVE_MODE
  - docker permissions are auto-detected; set DOCKER_BIN manually only if needed
  - set WINDROSE_MODE=prod or WINDROSE_MODE=dev to override auto detection
  - backup archives default to ./backups with 7-day retention
EOF
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
    printf '%s\n' "$world_name" > "$pending_file"
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
    jq --arg world_name "$world_name" '.WorldDescription.WorldName = $world_name' "$world_desc_file" > "$tmp_file"
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
    read -r -p "Select a world: " choice

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
            read -r -p "New world name (optional): " new_world_name
            if [[ -n "$new_world_name" ]]; then
                write_pending_world_name "$version" "$selected_id" "$new_world_name"
            fi
            ;;
        *)
            if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#world_ids[@]} )); then
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
    jq --arg world_id "$selected_id" '.ServerDescription_Persistent.WorldIslandId = $world_id' "$SERVER_DESC_FILE" > "$tmp_file"
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
    log_info "Service status ($ACTIVE_MODE mode):"
    dc ps
}

follow_logs() {
    log_info "Following logs"
    dc logs --timestamps -f "$SERVICE_NAME" | sed 's/\.[0-9]*Z/Z/' | sed \
        -e $'s/\(.*Error.*\)/\x1b[0;31m\\1\x1b[0m/' \
        -e $'s/\(.*Warning.*\)/\x1b[1;33m\\1\x1b[0m/'
}

run_notifier() {
    local choice
    local notify_pid_file="$SCRIPT_DIR/backups/notify.pid"
    local notify_log_file="$SCRIPT_DIR/backups/notify.log"
    local notify_pid=""

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
            printf '%s\n' "$notify_pid" > "$notify_pid_file"
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
        echo "[windrose] Activity notifier is already running in background (PID $notify_pid)."
        echo "[windrose] Stop it now? [y/N]"
        read -r choice

        case "${choice,,}" in
            y|yes)
                log_step "Stopping activity notifier"
                if ! kill "$notify_pid" >/dev/null 2>&1; then
                    log_step_failed
                    log_error "Failed to stop notifier process (PID $notify_pid)."
                    exit 1
                fi

                for _ in $(seq 1 20); do
                    if ! kill -0 "$notify_pid" >/dev/null 2>&1; then
                        break
                    fi
                done

                if kill -0 "$notify_pid" >/dev/null 2>&1; then
                    if ! kill -9 "$notify_pid" >/dev/null 2>&1; then
                        log_step_failed
                        log_error "Notifier did not stop cleanly and could not be force-stopped."
                        exit 1
                    fi
                fi

                rm -f "$notify_pid_file"
                log_step_done
                log_ok "Notifier stopped."
                return 0
                ;;
            *)
                log_info "Notifier left running in background."
                return 0
                ;;
        esac
    fi

    echo "[windrose] Run activity notifier in background? [y/N]"
    read -r choice

    case "${choice,,}" in
        y|yes)
            mkdir -p "$(dirname "$notify_log_file")"
            log_step "Starting activity notifier in background"
            if nohup "$SCRIPT_DIR/notify.sh" >>"$notify_log_file" 2>&1 & then
                notify_pid="$!"
                printf '%s\n' "$notify_pid" > "$notify_pid_file"
                log_step_done
                log_ok "Notifier is running in background (PID $notify_pid)."
                log_info "Log file: $notify_log_file"
            else
                log_step_failed
                log_error "Failed to start notifier in background."
                exit 1
            fi
            ;;
        *)
            log_info "Starting activity notifier in foreground"
            exec "$SCRIPT_DIR/notify.sh"
            ;;
    esac
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

    local scope_label
    case "$backup_scope" in
        full) scope_label="full backup" ;;
        save) scope_label="save backup" ;;
        both) scope_label="full + save backup" ;;
        *)    scope_label="backup" ;;
    esac

    if dc ps --status running --services 2>/dev/null | grep -Fx "$SERVICE_NAME" >/dev/null 2>&1; then
        was_running="yes"
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
    fi

    if [[ "$backup_exit" -eq 0 && "$notify_success" == "true" ]]; then
        "$SCRIPT_DIR/notify.sh" test "⚓ Windrose backup finished successfully on $(hostname -s)." >/dev/null 2>&1 || true
    fi

    if [[ "$backup_exit" -eq 0 && "$discord_upload" == "true" ]]; then
        upload_backup_to_discord || true
    fi

    if [[ "$backup_exit" -ne 0 && "$notify_fail" == "true" ]]; then
        "$SCRIPT_DIR/notify.sh" test "⚓ Windrose backup failed on $(hostname -s) (exit=$backup_exit)." >/dev/null 2>&1 || true
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
    local max_discord_size=$(( 25 * 1024 * 1024 ))
    if [[ "$file_size" -gt "$max_discord_size" ]]; then
        log_warn "backup exceeds Discord 25 MB limit ($(( file_size / 1024 / 1024 )) MB), skipping upload."
        return 0
    fi

    log_step "Uploading $(basename "$latest_file") to Discord ($(( file_size / 1024 )) KB)"
    http_code="$(curl -s -o /dev/null -w "%{http_code}" \
        -F "file=@$latest_file" \
        -F "payload_json={\"content\":\"⚓ Backup \`$(basename "$latest_file")\` — $(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" \
        "$discord_url")"

    if [[ "$http_code" =~ ^2 ]]; then
        log_step_done
    else
        echo -e " ${_COLOR_RED}FAILED (HTTP $http_code)${_COLOR_RESET}"
    fi
}

install_backup_cron() {
    local schedule="${1:-0 */6 * * *}"
    local backup_cmd="$SCRIPT_DIR/windrose backup"
    local backup_log_dir="$SCRIPT_DIR/backups"
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

update_server() {
    local mode="${1:-}"

    if [[ -n "$mode" && "$mode" != "--force-down" ]]; then
        log_error "Invalid update option '$mode'. Supported: --force-down"
        exit 1
    fi

    mkdir -p "$UPDATE_LOG_DIR"
    rotate_update_logs
    append_update_log "Update started (mode=$ACTIVE_MODE, compose_dir=$COMPOSE_DIR, service=$SERVICE_NAME, strategy=${mode:---safe})"
    log_info "Progress bar shows update stages, not byte-level download progress."

    render_progress_bar 0

    if [[ "$mode" == "--force-down" ]]; then
        append_update_log "Running (force-down): docker compose down"
        if ! dc down >>"$UPDATE_LOG_FILE" 2>&1; then
            printf '\n'
            log_error "Failed to stop and remove the stack before update. See $UPDATE_LOG_FILE"
            exit 1
        fi
        render_progress_bar 33

        append_update_log "Running (force-down): docker compose pull"
        if ! dc pull >>"$UPDATE_LOG_FILE" 2>&1; then
            printf '\n'
            log_error "Failed to pull the selected image tag. See $UPDATE_LOG_FILE"
            exit 1
        fi
        render_progress_bar 66

        append_update_log "Running (force-down): docker compose up -d"
        if ! dc up -d >>"$UPDATE_LOG_FILE" 2>&1; then
            printf '\n'
            log_error "Failed to recreate the container after update. See $UPDATE_LOG_FILE"
            exit 1
        fi
    else
        append_update_log "Running (safe): docker compose pull"
        if ! dc pull >>"$UPDATE_LOG_FILE" 2>&1; then
            printf '\n'
            log_error "Failed to pull the selected image tag. Existing container was left untouched. See $UPDATE_LOG_FILE"
            exit 1
        fi
        render_progress_bar 50

        append_update_log "Running (safe): docker compose up -d"
        if ! dc up -d >>"$UPDATE_LOG_FILE" 2>&1; then
            printf '\n'
            log_error "Failed to recreate the container after update. See $UPDATE_LOG_FILE"
            exit 1
        fi
    fi

    render_progress_bar 100
    log_ok "Server starting. Check status with: ./$SELF_NAME status"
    log_info "Detailed update log: $UPDATE_LOG_FILE"
    append_update_log "Update finished successfully"
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
    if ! cat > "$target" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec "$SCRIPT_DIR/windrose" "\$@"
EOF
    then
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

case "${1:-help}" in
    start)
        start_server
        ;;
    stop)
        stop_server
        ;;
    restart)
        restart_server
        ;;
    status|ps)
        status_server
        ;;
    logs)
        follow_logs
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
    notify)
        run_notifier
        ;;
    test-notify)
        shift || true
        test_notifier "$@"
        ;;
    backup)
        backup_server
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
    help|-h|--help|"")
        usage
        ;;
    *)
        usage
        exit 1
        ;;
esac
