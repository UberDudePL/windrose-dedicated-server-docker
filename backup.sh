#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

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

prompt_text() {
  printf '%b' "${_COLOR_YELLOW}[windrose]${_COLOR_RESET} $1"
}

log_step() {
  echo -ne "${_COLOR_CYAN}[windrose]${_COLOR_RESET} $1..."
}

dotenv_value() {
  local key="$1"

  if [[ ! -f "$ENV_FILE" ]]; then
    return 1
  fi

  awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, "", $0); print $0}' "$ENV_FILE" | tail -n 1
}

DATA_DIR="${DATA_DIR:-$SCRIPT_DIR/data}"
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
TIMESTAMP="$(date +%F-%H%M%S)"

case "$BACKUP_FORMAT" in
tar.gz)
  ARCHIVE_EXT="tar.gz"
  ;;
zip)
  ARCHIVE_EXT="zip"
  ;;
*)
  log_error "unsupported BACKUP_FORMAT '$BACKUP_FORMAT' (supported: tar.gz, zip)"
  exit 1
  ;;
esac

case "$BACKUP_SCOPE" in
full | save | both) ;;
*)
  log_error "unsupported BACKUP_SCOPE '$BACKUP_SCOPE' (supported: full, save, both)"
  exit 1
  ;;
esac

run_quiet() {
  "$@" >/dev/null 2>&1
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
    log_error "zip command not found and shell is non-interactive. Install zip package or set BACKUP_FORMAT=tar.gz"
    return 1
  fi

  read -r -p "$(prompt_text "zip command not found. Install it now? ${_COLOR_YELLOW}[y/N]${_COLOR_RESET}: ")" answer
  case "$answer" in
  y | Y | yes | YES)
    log_info "Installing zip package..."
    if ! install_zip_package; then
      log_error "failed to install zip package."
      return 1
    fi
    if ! command -v zip >/dev/null 2>&1; then
      log_error "zip command still not available after installation."
      return 1
    fi
    log_ok "zip package installed successfully."
    ;;
  *)
    log_error "zip is required for BACKUP_FORMAT=zip. Install zip or set BACKUP_FORMAT=tar.gz"
    return 1
    ;;
  esac
}

if [[ ! -d "$DATA_DIR/R5" ]]; then
  log_error "expected data directory not found at $DATA_DIR/R5"
  exit 1
fi

if [[ "$BACKUP_SCOPE" == "save" || "$BACKUP_SCOPE" == "both" ]]; then
  if [[ ! -d "$DATA_DIR/R5/Saved" ]]; then
    log_error "expected save directory not found at $DATA_DIR/R5/Saved"
    exit 1
  fi
fi

mkdir -p "$BACKUP_DIR"
BACKUP_DIR="$(cd "$BACKUP_DIR" && pwd)"

create_archive() {
  local label="$1"
  local archive_path="$2"
  shift 2

  log_step "Creating $label backup"
  if [[ "$BACKUP_FORMAT" == "zip" ]]; then
    if ! (
      cd "$DATA_DIR"
      zip -qr "$archive_path" "$@" >/dev/null 2>&1
    ); then
      echo -e " ${_COLOR_RED}FAILED${_COLOR_RESET}"
      log_error "Failed to create backup archive: $archive_path"
      return 1
    fi
  else
    if ! tar -czf "$archive_path" -C "$DATA_DIR" "$@" >/dev/null 2>&1; then
      echo -e " ${_COLOR_RED}FAILED${_COLOR_RESET}"
      log_error "Failed to create backup archive: $archive_path"
      return 1
    fi
  fi
  echo -e " ${_COLOR_GREEN}DONE${_COLOR_RESET}  → $(basename "$archive_path")"

  log_step "Verifying $label backup integrity"
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
  echo -e " ${_COLOR_GREEN}PASS${_COLOR_RESET}"
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
