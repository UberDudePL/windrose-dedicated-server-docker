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
DOCKER_CMD=()

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
  $SELF_NAME notify
  $SELF_NAME backup
  $SELF_NAME install-backup-cron [schedule]
  $SELF_NAME pull
  $SELF_NAME update
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
    echo "[windrose] Starting server ($ACTIVE_MODE mode)..."
    dc up -d
    dc ps
}

stop_server() {
    echo "[windrose] Stopping server..."
    dc stop "$SERVICE_NAME"
}

restart_server() {
    echo "[windrose] Restarting server..."
    if ! dc restart "$SERVICE_NAME"; then
        dc stop "$SERVICE_NAME" || true
        dc up -d
    fi
    dc ps
}

status_server() {
    echo "[windrose] Service status ($ACTIVE_MODE mode):"
    dc ps
}

follow_logs() {
    echo "[windrose] Following logs..."
    dc logs -f "$SERVICE_NAME"
}

run_notifier() {
    echo "[windrose] Starting activity notifier..."
    exec "$SCRIPT_DIR/notify.sh"
}

backup_server() {
    local was_running=""
    local backup_exit=0

    if dc ps --status running --services 2>/dev/null | grep -Fx "$SERVICE_NAME" >/dev/null 2>&1; then
        was_running="yes"
        echo "[windrose] Stopping server for a consistent backup..."
        dc stop "$SERVICE_NAME"
    fi

    if "$SCRIPT_DIR/backup.sh"; then
        backup_exit=0
    else
        backup_exit=$?
    fi

    if [[ -n "$was_running" ]]; then
        echo "[windrose] Starting server again..."
        dc up -d
        dc ps
    fi

    return "$backup_exit"
}

install_backup_cron() {
    local schedule="${1:-0 */6 * * *}"
    local cron_line="$schedule cd $SCRIPT_DIR && $SCRIPT_DIR/backup.sh >/dev/null 2>&1"

    if ! command -v crontab >/dev/null 2>&1; then
        echo "[windrose] Error: crontab is not available on this host."
        exit 1
    fi

    if crontab -l 2>/dev/null | grep -F "$SCRIPT_DIR/backup.sh" >/dev/null 2>&1; then
        echo "[windrose] Backup cron already installed."
        crontab -l
        return
    fi

    (crontab -l 2>/dev/null; echo "$cron_line") | crontab -
    echo "[windrose] Installed backup cron:"
    echo "$cron_line"
}

pull_image() {
    echo "[windrose] Pulling image defined in compose..."
    dc pull
}

update_server() {
    echo "[windrose] Pulling the selected image tag and recreating the container..."
    dc pull
    dc up -d
    dc ps
}

down_server() {
    echo "[windrose] Stopping and removing the stack..."
    dc down
}

install_self() {
    local target="${1:-/usr/local/bin/windrosectl}"
    local target_dir
    target_dir="$(dirname "$target")"

    mkdir -p "$target_dir"
    cat > "$target" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec "$SCRIPT_DIR/windrose" "\$@"
EOF
    chmod +x "$target"
    echo "[windrose] Installed launcher at $target"
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
    notify)
        run_notifier
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
        update_server
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
