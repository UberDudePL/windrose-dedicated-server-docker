#!/usr/bin/env bash
set -euo pipefail

# Migration script: organize backups/ into backups/, logs/, state/, diagnostics/

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Colors
_COLOR_RESET='\033[0m'
_COLOR_CYAN='\033[0;36m'
_COLOR_GREEN='\033[0;32m'
_COLOR_YELLOW='\033[1;33m'
_COLOR_RED='\033[0;31m'

log_info() {
  echo -e "${_COLOR_CYAN}[windrose-migrate]${_COLOR_RESET} $*"
}

log_ok() {
  echo -e "${_COLOR_GREEN}[windrose-migrate]${_COLOR_RESET} $*"
}

log_warn() {
  echo -e "${_COLOR_YELLOW}[windrose-migrate]${_COLOR_RESET} $*"
}

log_error() {
  echo -e "${_COLOR_RED}[windrose-migrate]${_COLOR_RESET} $*"
}

# Folders
BACKUPS_DIR="$SCRIPT_DIR/backups"
LOGS_DIR="$SCRIPT_DIR/logs"
STATE_DIR="$SCRIPT_DIR/state"
DIAGNOSTICS_DIR="$SCRIPT_DIR/diagnostics"

if [[ ! -d "$BACKUPS_DIR" ]]; then
  log_warn "No backups/ directory found. Nothing to migrate."
  exit 0
fi

log_info "Starting folder migration..."
echo

# Create target directories
mkdir -p "$LOGS_DIR" "$STATE_DIR" "$DIAGNOSTICS_DIR"
log_ok "Created directories: logs/, state/, diagnostics/"
echo

# Migrate log files from backups/ to logs/
log_info "Moving log files to logs/..."
for logfile in update.log update.log.1 player-history.log player-events.log notify.log backup.log; do
  if [[ -f "$BACKUPS_DIR/$logfile" ]]; then
    mv "$BACKUPS_DIR/$logfile" "$LOGS_DIR/$logfile"
    log_ok "  Moved $logfile"
  fi
done
echo

# Migrate state files from backups/ to state/
log_info "Moving state files to state/..."
for statefile in player-identities.tsv player-events.seen; do
  if [[ -f "$BACKUPS_DIR/$statefile" ]]; then
    mv "$BACKUPS_DIR/$statefile" "$STATE_DIR/$statefile"
    log_ok "  Moved $statefile"
  fi
done
echo

# Migrate diagnostics archives and directories from backups/ to diagnostics/
log_info "Moving diagnostics to diagnostics/..."
for item in windrose-diagnostics-*.tar.gz diagnostics-*; do
  if [[ -f "$BACKUPS_DIR/$item" || -d "$BACKUPS_DIR/$item" ]]; then
    mv "$BACKUPS_DIR/$item" "$DIAGNOSTICS_DIR/$item"
    log_ok "  Moved $item"
  fi
done
echo

# List remaining files in backups/ (should be only .tar.gz and .zip archives)
log_info "Remaining files in backups/ (should be backup archives only):"
if ls -la "$BACKUPS_DIR" 2>/dev/null | grep -qE '\.(tar\.gz|zip)$'; then
  ls -lh "$BACKUPS_DIR"/*.{tar.gz,zip} 2>/dev/null | awk '{print "  " $9 " (" $5 ")"}'
  log_ok "Backup archives are in place."
else
  log_warn "No backup archives found."
fi
echo

log_ok "Migration completed successfully."
echo "Folder structure:"
echo "  ./backups/      - Backup archives only (.tar.gz, .zip)"
echo "  ./logs/         - Log files (update, backup, player activity, notify)"
echo "  ./state/        - Metadata (player identities, event deduplication)"
echo "  ./diagnostics/  - Diagnostics bundles (.tar.gz)"
